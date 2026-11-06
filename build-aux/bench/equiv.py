#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Equivalence check (plan section 8.3): compares two run directories that run.sh --keep left in
# the work volume, for example one import with a baseline build and one with a change.
#
#   equiv.py RUN_A RUN_B          (inside the shotwell-bench image, work volume at /work)
#
# Compared: the PhotoTable and BackingPhotoTable rows (without ids, import ids and creation
# times), the developments of each photo, the events and their members, the tags, the bytes of
# every file in the library and the bytes of every thumbnail.
#
# Not compared across runs, but checked within each run: the "timestamp" columns. They are the
# modification times of the files in the library, which are the time of the copy, so they always
# differ between two imports. Each run is checked for timestamp == mtime of the file instead.
#
# Reported separately, because they differ between two imports with the same build: the primary
# photo of an event.
#
# The exit status is 1 if anything else differs.

import hashlib
import json
import os
import sqlite3
import sys

IGNORE_PHOTO = {"id", "import_id", "time_created", "event_id", "editable_id", "timestamp",
                "develop_shotwell_id", "develop_camera_id", "develop_embedded_id",
                "time_reimported", "backlinks"}
IGNORE_BACKING = {"id", "time_created", "timestamp"}


def find(run, name):
    for root, dirs, files in os.walk(run):
        if name in files:
            return os.path.join(root, name)
    raise SystemExit("no %s in %s" % (name, run))


class Run:
    def __init__(self, path):
        self.path = path.rstrip("/")
        self.lib = os.path.join(self.path, "home", "Pictures")
        self.db_path = find(os.path.join(self.path, "data"), "photo.db")
        self.data = os.path.join(self.path, "data")
        self.db = sqlite3.connect(self.db_path)
        self.db.row_factory = sqlite3.Row
        self.backing = {r["id"]: r for r in self.rows("BackingPhotoTable")}
        self.photos = self.rows("PhotoTable")
        self.photo_by_id = {r["id"]: r for r in self.photos}
        self.events = self.rows("EventTable")
        self.tags = self.rows("TagTable")

    def rel(self, p):
        if p is None:
            return None
        for prefix in (self.lib + "/", self.path + "/"):
            if p.startswith(prefix):
                return p[len(prefix):]
        return p

    def rows(self, table):
        return [dict(r) for r in self.db.execute("SELECT * FROM %s" % table)]


def norm_backing(run, row):
    if row is None:
        return None
    out = {k: v for k, v in row.items() if k not in IGNORE_BACKING}
    out["filepath"] = run.rel(out["filepath"])
    return out


def norm_photo(run, row):
    out = {k: v for k, v in row.items() if k not in IGNORE_PHOTO}
    out["filename"] = run.rel(out["filename"])
    for d in ("develop_shotwell_id", "develop_camera_id", "develop_embedded_id"):
        bid = row[d]
        out[d] = norm_backing(run, run.backing.get(bid)) if bid not in (None, -1) else None
    return out


def photo_file(run, sid):
    # thumbnails and events refer to photos as "thumb%016x"
    if sid and sid.startswith("thumb"):
        p = run.photo_by_id.get(int(sid[5:], 16))
        return run.rel(p["filename"]) if p else "?" + sid
    return sid


def norm_events(run):
    out = {}
    for e in run.events:
        members = tuple(sorted(run.rel(p["filename"]) for p in run.photos if p["event_id"] == e["id"]))
        if e["primary_source_id"]:
            primary = photo_file(run, e["primary_source_id"])
        else:
            p = run.photo_by_id.get(e["primary_photo_id"])
            primary = run.rel(p["filename"]) if p else None
        out[members] = {"name": e["name"], "comment": e["comment"], "primary": primary}
    return out


def norm_tags(run):
    out = {}
    for t in run.tags:
        ids = [s for s in (t["photo_id_list"] or "").split(",") if s]
        out[t["name"]] = sorted(photo_file(run, s) for s in ids)
    return out


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def tree(root):
    out = {}
    for d, dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            out[os.path.relpath(p, root)] = sha(p)
    return out


def thumbs(run):
    out = {}
    tdir = os.path.join(run.data, "thumbs")
    for d, dirs, files in os.walk(tdir):
        for f in files:
            name = f.split(".")[0]
            key = os.path.relpath(d, tdir) + "/" + (photo_file(run, name) if name.startswith("thumb") else name)
            out[key] = sha(os.path.join(d, f))
    return out


def check_timestamps(run, label, report):
    for r in run.photos:
        if os.path.exists(r["filename"]) and r["timestamp"] != int(os.stat(r["filename"]).st_mtime):
            report.append("%s: PhotoTable[%s] timestamp is not the mtime of the file" % (label, run.rel(r["filename"])))
    for r in run.backing.values():
        if os.path.exists(r["filepath"]) and r["timestamp"] != int(os.stat(r["filepath"]).st_mtime):
            report.append("%s: BackingPhotoTable[%s] timestamp is not the mtime of the file" % (label, run.rel(r["filepath"])))


def diff_maps(label, a, b, report):
    for k in sorted(set(a) | set(b), key=str):
        if k not in a or k not in b:
            report.append("%s %s: only in %s" % (label, k, "A" if k in a else "B"))
        elif a[k] != b[k]:
            if isinstance(a[k], dict) and isinstance(b[k], dict):
                for f in sorted(set(a[k]) | set(b[k])):
                    if a[k].get(f) != b[k].get(f):
                        report.append("%s %s: %s %r != %r" % (label, k, f, a[k].get(f), b[k].get(f)))
            else:
                report.append("%s %s: %r != %r" % (label, k, a[k], b[k]))


def main():
    A, B = Run(sys.argv[1]), Run(sys.argv[2])
    report, nondeterministic = [], []

    pa = {r["filename"]: r for r in (norm_photo(A, p) for p in A.photos)}
    pb = {r["filename"]: r for r in (norm_photo(B, p) for p in B.photos)}
    diff_maps("PhotoTable", pa, pb, report)

    ba = {r["filepath"]: r for r in (norm_backing(A, x) for x in A.backing.values())}
    bb = {r["filepath"]: r for r in (norm_backing(B, x) for x in B.backing.values())}
    diff_maps("BackingPhotoTable", ba, bb, report)

    ea, eb = norm_events(A), norm_events(B)
    for members in sorted(set(ea) | set(eb)):
        if members not in ea or members not in eb:
            report.append("event with members %s: only in %s" % (list(members), "A" if members in ea else "B"))
            continue
        for f in ("name", "comment"):
            if ea[members][f] != eb[members][f]:
                report.append("event of %s: %s %r != %r" % (members[0], f, ea[members][f], eb[members][f]))
        if ea[members]["primary"] != eb[members]["primary"]:
            nondeterministic.append("event of %s: primary photo %s != %s" % (
                members[0], ea[members]["primary"], eb[members]["primary"]))

    diff_maps("tag", norm_tags(A), norm_tags(B), report)

    la, lb = tree(A.lib), tree(B.lib)
    diff_maps("library file", la, lb, report)
    tha, thb = thumbs(A), thumbs(B)
    diff_maps("thumbnail", tha, thb, report)

    check_timestamps(A, "A", report)
    check_timestamps(B, "B", report)

    print(json.dumps({
        "a": A.path, "b": B.path,
        "counts": {"photos": [len(pa), len(pb)], "backing": [len(ba), len(bb)],
                   "events": [len(ea), len(eb)], "library_files": [len(la), len(lb)],
                   "thumbnails": [len(tha), len(thb)]},
        "differences": len(report), "nondeterministic": len(nondeterministic)}))
    for line in report:
        print(line)
    for line in nondeterministic:
        print("(differs between runs of one build) " + line)
    sys.exit(1 if report else 0)


main()
