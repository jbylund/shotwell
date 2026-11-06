#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Corpus tool for the import benchmark. Runs inside the shotwell-bench image, with the corpus
# volume mounted at /corpus (called by make-corpus.sh).
#
#   corpus.py fetch MANIFEST         download and verify the samples into /corpus/samples
#   corpus.py inspect                print preview sizes, libraw support and exiv2 writability
#   corpus.py make SEED N [ONLY]     make /corpus/sets/sSEED-nN with N unique shots; with ONLY,
#                                    use only the samples whose file name contains ONLY, and
#                                    call the set sSEED-nN-ONLY (for per-format counters)
#   corpus.py make SEED N --pairs-only
#                                    use only the samples marked make_jpeg_pair, so that every
#                                    shot is a RAW+JPEG pair; the set is sSEED-nN-pairs
#
# A "shot" is one copy of a sample. Samples marked make_jpeg_pair in the manifest also get a
# JPEG sibling with the same basename (made from the largest embedded preview), so N shots can
# be more than N files. Every copy gets its own Exif.Photo.ImageUniqueID and DateTimeOriginal,
# because the import skips files whose MD5 is already known. For formats that exiv2 cannot
# write (CR3, RAF, RW2, ...) the copy gets a small trailer instead (a "free" box for ISO-BMFF),
# and keeps the original dates.
#
# Downloaded files are untrusted: they are only read by exiv2 and libraw tools, never run.

import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timedelta

CORPUS = "/corpus"
SAMPLES = os.path.join(CORPUS, "samples")
DERIVED = os.path.join(CORPUS, "derived")
SETS = os.path.join(CORPUS, "sets")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def run(*cmd, check=True):
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise RuntimeError("%s failed (%d): %s" % (" ".join(cmd), result.returncode,
                                                   result.stderr.decode(errors="replace")))
    return result


def load_manifest(path):
    with open(path) as f:
        return json.load(f)["samples"]


def fetch(manifest_path):
    os.makedirs(SAMPLES, exist_ok=True)
    samples = load_manifest(manifest_path)
    for s in samples:
        dest = os.path.join(SAMPLES, s["file"])
        if os.path.exists(dest) and sha256(dest) == s["sha256"]:
            print("ok      %s" % s["file"], file=sys.stderr)
            continue
        print("fetch   %s <- %s" % (s["file"], s["url"]), file=sys.stderr)
        tmp = dest + ".part"
        req = urllib.request.Request(s["url"], headers={"User-Agent": "shotwell-bench"})
        with urllib.request.urlopen(req, timeout=300) as resp, open(tmp, "wb") as out:
            shutil.copyfileobj(resp, out, 1 << 20)
        digest = sha256(tmp)
        if digest != s["sha256"]:
            os.unlink(tmp)
            raise RuntimeError("%s: sha256 %s, expected %s" % (s["file"], digest, s["sha256"]))
        os.chmod(tmp, 0o444)
        os.replace(tmp, dest)
    shutil.copy(manifest_path, os.path.join(SAMPLES, "manifest.json"))


PREVIEW_RE = re.compile(r"Preview (\d+): (\S+), (\d+)x(\d+) pixels, (\d+) bytes")


def previews(path):
    out = run("exiv2", "-pp", path, check=False).stdout.decode(errors="replace")
    return [{"number": int(m.group(1)), "mime": m.group(2), "width": int(m.group(3)),
             "height": int(m.group(4)), "bytes": int(m.group(5))} for m in PREVIEW_RE.finditer(out)]


def libraw_identify(path):
    r = run("raw-identify", "-v", path, check=False)
    text = r.stdout.decode(errors="replace")
    ok = r.returncode == 0 and "is not supported" not in text and "Cannot" not in text
    info = {"ok": ok}
    for key, pattern in (("camera", r"Camera: (.*)"), ("image_size", r"Image size:\s+(.*)"),
                         ("thumb_size", r"Thumb size:\s+(.*)")):
        m = re.search(pattern, text)
        if m:
            info[key] = m.group(1).strip()
    return info


def decode_ok(path):
    r = run("dcraw_emu", "-w", "-q", "0", "-h", "-Z", "-", path, check=False)
    return r.returncode == 0


def sample_info(s):
    path = os.path.join(SAMPLES, s["file"])
    pv = previews(path)
    largest = max(pv, key=lambda p: p["width"] * p["height"]) if pv else None
    with tempfile.TemporaryDirectory(dir=DERIVED) as tmp:
        copy = os.path.join(tmp, s["file"])
        shutil.copy(path, copy)
        os.chmod(copy, 0o644)
        writable = run("exiv2", "-M", "set Exif.Photo.ImageUniqueID 0123456789abcdef0123456789abcdef",
                       copy, check=False).returncode == 0
        writable = writable and decode_ok(copy)
    return {
        "file": s["file"],
        "bytes": os.path.getsize(path),
        "previews": pv,
        "largest_preview": [largest["width"], largest["height"]] if largest else None,
        "libraw": libraw_identify(path),
        "decodes": decode_ok(path),
        "exiv2_writable": writable,
        "make_jpeg_pair": s.get("make_jpeg_pair", False),
    }


def inspect(manifest_path=None):
    os.makedirs(DERIVED, exist_ok=True)
    samples = load_manifest(manifest_path or os.path.join(SAMPLES, "manifest.json"))
    infos = [sample_info(s) for s in samples]
    json.dump(infos, sys.stdout, indent=1)
    print()
    return infos


def make_pair_template(info):
    """The largest embedded preview as a JPEG, used as the camera JPEG of a RAW+JPEG pair."""
    os.makedirs(DERIVED, exist_ok=True)
    base = os.path.splitext(info["file"])[0]
    dest = os.path.join(DERIVED, base + ".JPG")
    if os.path.exists(dest):
        return dest
    largest = max(info["previews"], key=lambda p: p["width"] * p["height"])
    with tempfile.TemporaryDirectory(dir=DERIVED) as tmp:
        run("exiv2", "-ep%d" % largest["number"], "-l", tmp, os.path.join(SAMPLES, info["file"]))
        produced = [f for f in os.listdir(tmp) if f.lower().endswith((".jpg", ".jpeg"))]
        if not produced:
            raise RuntimeError("no JPEG preview extracted from %s" % info["file"])
        shutil.move(os.path.join(tmp, produced[0]), dest)
    return dest


def append_trailer(path, tag, is_bmff):
    payload = ("shotwell-bench %s" % tag).encode()
    with open(path, "ab") as f:
        if is_bmff:
            # a top-level ISO-BMFF "free" box, which readers skip
            f.write((8 + len(payload)).to_bytes(4, "big") + b"free" + payload)
        else:
            # data after the end of a TIFF/RAF structure, which readers never look at
            f.write(b"\0" * 16 + payload)


def uniquify(path, writable, unique_id, when, is_bmff):
    if writable:
        stamp = when.strftime("%Y:%m:%d %H:%M:%S")
        run("exiv2",
            "-M", "set Exif.Photo.ImageUniqueID %s" % unique_id,
            "-M", "set Exif.Photo.DateTimeOriginal %s" % stamp,
            "-M", "set Exif.Photo.DateTimeDigitized %s" % stamp,
            "-M", "set Exif.Image.DateTime %s" % stamp,
            path)
        return "exiv2"
    append_trailer(path, unique_id, is_bmff)
    return "trailer"


def make(seed, n, only=None, pairs_only=False):
    samples = load_manifest(os.path.join(SAMPLES, "manifest.json"))
    if only:
        samples = [s for s in samples if only in s["file"]]
    if pairs_only:
        samples = [s for s in samples if s.get("make_jpeg_pair")]
    os.makedirs(DERIVED, exist_ok=True)
    infos = []
    for s in samples:
        info = sample_info(s)
        if not info["libraw"]["ok"] or not info["decodes"]:
            print("skip    %s: libraw cannot decode it" % s["file"], file=sys.stderr)
            continue
        infos.append(info)
    if not infos:
        raise RuntimeError("no usable samples")

    name = "s%d-n%d" % (seed, n) + ("-%s" % only if only else "") + ("-pairs" if pairs_only else "")
    set_dir = os.path.join(SETS, name)
    tmp_dir = set_dir + ".tmp"
    shutil.rmtree(tmp_dir, ignore_errors=True)
    photos = os.path.join(tmp_dir, "photos")
    os.makedirs(photos)

    rng = random.Random(seed)
    when = datetime(2024, 6, 1, 9, 0, 0) + timedelta(days=rng.randrange(365))
    seen_md5 = set()
    index = []
    pair_templates = {}
    for i in range(n):
        info = infos[i % len(infos)]
        # realistic shooting pattern: bursts a few seconds apart, a new day every ~30 shots
        when += timedelta(seconds=rng.randrange(2, 90))
        if rng.random() < 1 / 30:
            when += timedelta(days=1, hours=rng.randrange(-3, 4))
        base, ext = os.path.splitext(info["file"])
        stem = "c%05d_%s" % (i + 1, base)
        unique_id = hashlib.md5(("%d-%d-%d" % (seed, n, i)).encode()).hexdigest()
        is_bmff = ext.lower() == ".cr3"

        dest = os.path.join(photos, stem + ext)
        shutil.copy(os.path.join(SAMPLES, info["file"]), dest)
        os.chmod(dest, 0o644)
        method = uniquify(dest, info["exiv2_writable"], unique_id, when, is_bmff)
        files = [(dest, info["file"], method)]

        if pairs_only and not info["previews"]:
            raise RuntimeError("%s has no embedded preview to make a JPEG from" % info["file"])
        if info["make_jpeg_pair"] and info["previews"]:
            if info["file"] not in pair_templates:
                pair_templates[info["file"]] = make_pair_template(info)
            jpeg = os.path.join(photos, stem + ".JPG")
            shutil.copy(pair_templates[info["file"]], jpeg)
            os.chmod(jpeg, 0o644)
            files.append((jpeg, os.path.basename(pair_templates[info["file"]]),
                          uniquify(jpeg, True, unique_id, when, False)))

        for path, sample, how in files:
            digest = md5(path)
            if digest in seen_md5:
                raise RuntimeError("%s is not unique" % path)
            seen_md5.add(digest)
            index.append((os.path.relpath(path, photos), sample, how))

    # every copy must still be readable by libraw; decode the first copy of each sample fully
    decoded = set()
    for rel, sample, how in index:
        path = os.path.join(photos, rel)
        if rel.endswith(".JPG"):
            continue
        if not libraw_identify(path)["ok"]:
            raise RuntimeError("libraw cannot open %s after %s" % (rel, how))
        if sample not in decoded:
            if not decode_ok(path):
                raise RuntimeError("libraw cannot decode %s after %s" % (rel, how))
            decoded.add(sample)

    with open(os.path.join(tmp_dir, "index.tsv"), "w") as f:
        for row in index:
            f.write("\t".join(row) + "\n")
    with open(os.path.join(tmp_dir, "samples.json"), "w") as f:
        json.dump({"seed": seed, "shots": n, "files": len(index), "samples": infos}, f, indent=1)
    shutil.copy(os.path.join(SAMPLES, "manifest.json"), os.path.join(tmp_dir, "manifest.json"))

    shutil.rmtree(set_dir, ignore_errors=True)
    os.replace(tmp_dir, set_dir)
    total = sum(os.path.getsize(os.path.join(photos.replace(tmp_dir, set_dir), r)) for r, _, _ in index)
    print("made %s: %d shots, %d files, %.1f MB" % (set_dir, n, len(index), total / 1e6), file=sys.stderr)
    print(name)


def main():
    if len(sys.argv) < 2:
        print(__doc__ or "see the header of this file", file=sys.stderr)
        sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "fetch":
        fetch(sys.argv[2])
    elif cmd == "inspect":
        inspect(sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd == "make":
        rest = sys.argv[4:]
        pairs_only = "--pairs-only" in rest
        rest = [a for a in rest if a != "--pairs-only"]
        make(int(sys.argv[2]), int(sys.argv[3]), rest[0] if rest else None, pairs_only)
    else:
        print("unknown command %s" % cmd, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
