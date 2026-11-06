#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Lower bound for the CPU term: decode each distinct raw sample of a corpus set once with
# dcraw_emu (single thread, options that match GRaw.Processor.configure_for_rgb_display) and
# scale by the number of copies in the set.
#
#   decode-bound.py SET_DIR   (prints JSON)
#
# SET_DIR/index.tsv lists "relative path <TAB> sample file name" for every corpus file and
# SET_DIR/samples.json the samples with their largest embedded preview (from make-corpus).

import json
import os
import subprocess
import sys
import time

RAW_EXTENSIONS = {".orf", ".nef", ".cr2", ".cr3", ".arw", ".raf", ".rw2", ".dng", ".pef", ".srw"}
MIN_EMBEDDED_SIZE = 1024  # Photo.vala: below this the CAMERA/EMBEDDED developer falls back to SHOTWELL

DCRAW_ARGS = ["-w", "-a", "-q", "2", "-W", "-H", "0", "-o", "1", "-Z", "-"]


def time_decode(path, repeat):
    best = None
    for _ in range(repeat):
        start = time.monotonic()
        result = subprocess.run(["dcraw_emu", *DCRAW_ARGS, path], stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, env={**os.environ, "OMP_NUM_THREADS": "1"})
        elapsed = time.monotonic() - start
        if result.returncode != 0:
            return None, result.stderr.decode(errors="replace").strip()
        best = elapsed if best is None else min(best, elapsed)
    return best, None


def main():
    set_dir = sys.argv[1]
    samples_dir = os.path.join(os.path.dirname(os.path.dirname(set_dir)), "samples")
    with open(os.path.join(set_dir, "samples.json")) as f:
        samples = {s["file"]: s for s in json.load(f)["samples"]}

    copies = {}
    with open(os.path.join(set_dir, "index.tsv")) as f:
        for line in f:
            rel, sample = line.rstrip("\n").split("\t")[:2]
            copies[sample] = copies.get(sample, 0) + 1

    repeat = int(os.environ.get("DECODE_REPEAT", "1"))
    nproc = os.cpu_count() or 1
    per_sample = {}
    cpu_all = 0.0
    cpu_shotwell = 0.0
    files_shotwell = 0
    for sample, count in sorted(copies.items()):
        if os.path.splitext(sample)[1].lower() not in RAW_EXTENSIONS:
            continue
        seconds, err = time_decode(os.path.join(samples_dir, sample), repeat)
        preview = samples.get(sample, {}).get("largest_preview")
        needs_shotwell = preview is None or max(preview) < MIN_EMBEDDED_SIZE
        per_sample[sample] = {"copies": count, "decode_s": seconds, "error": err,
                              "largest_preview": preview, "needs_shotwell": needs_shotwell}
        if seconds is not None:
            cpu_all += seconds * count
            if needs_shotwell:
                cpu_shotwell += seconds * count
                files_shotwell += count

    json.dump({
        "nproc": nproc,
        "decode_cpu_all_s": cpu_all,
        "t_decode_all_s": cpu_all / nproc,
        "decode_cpu_shotwell_subset_s": cpu_shotwell,
        "t_decode_shotwell_subset_s": cpu_shotwell / nproc,
        "files_needing_shotwell": files_shotwell,
        "samples": per_sample,
    }, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
