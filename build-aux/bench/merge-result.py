#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Merges the JSON printed by "shotwell --benchmark-import" with the lower-bound and cgroup
# measurements taken by run-in-container.sh. Prints one JSON object.

import argparse
import json
import sys


def parse_io_stat(text):
    """cgroup v2 io.stat ("MAJ:MIN rbytes=.. wbytes=.. ...;" per device) -> {dev: {key: int}}"""
    devices = {}
    for line in text.split(";"):
        parts = line.split()
        if not parts:
            continue
        devices[parts[0]] = {k: int(v) for k, v in (p.split("=") for p in parts[1:] if "=" in p)}
    return devices


def io_delta(before, after):
    b, a = parse_io_stat(before), parse_io_stat(after)
    total = {"rbytes": 0, "wbytes": 0, "rios": 0, "wios": 0}
    for dev, values in a.items():
        for key in total:
            total[key] += values.get(key, 0) - b.get(dev, {}).get(key, 0)
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shotwell")
    ap.add_argument("--decode")
    ap.add_argument("--status", type=int)
    ap.add_argument("--mode")
    ap.add_argument("--build")
    ap.add_argument("--set")
    ap.add_argument("--set-dir")
    ap.add_argument("--t-read", type=float)
    ap.add_argument("--t-process", type=float)
    ap.add_argument("--cpu-usec", nargs=2, type=int)
    ap.add_argument("--io-stat-read", nargs=2)
    ap.add_argument("--io-stat-import", nargs=2)
    ap.add_argument("--io-max", default="")
    ap.add_argument("--memory-max", default="")
    args = ap.parse_args()

    try:
        with open(args.shotwell) as f:
            shotwell = json.load(f)
    except (OSError, ValueError) as err:
        shotwell = {"error": f"no JSON from shotwell: {err}"}
    with open(args.decode) as f:
        decode = json.load(f)

    t_import = shotwell.get("wall_s")
    t_decode_all = decode.get("t_decode_all_s")
    t_decode_shotwell = decode.get("t_decode_shotwell_subset_s")
    io_import = io_delta(*args.io_stat_import)
    corpus_bytes = shotwell.get("corpus_bytes") or 0

    # efficiency = max(T_read, T_decode) / T_import, where T_decode only counts the files that
    # need a full raw decode with the default developer (plan section 3.6).
    bound = max(x for x in (args.t_read, t_decode_shotwell or 0.0) if x is not None)
    efficiency = bound / t_import if t_import else None

    files = shotwell.get("corpus_files") or 0
    counters = shotwell.get("counters", {})
    per_file = {}
    if files:
        for key, value in counters.items():
            if value.get("count"):
                per_file[key] = round(value["count"] / files, 3)

    result = {
        "mode": args.mode,
        "build": args.build,
        "corpus_set": args.set,
        "exit_status": args.status,
        "ok": args.status == 0 and shotwell.get("ok") is True,
        "t_import_s": t_import,
        "t_process_s": args.t_process,
        "lower_bound": {
            "t_read_s": args.t_read,
            "read_mb_s": corpus_bytes / args.t_read / 1e6 if args.t_read else None,
            "t_decode_all_s": t_decode_all,
            "t_decode_shotwell_subset_s": t_decode_shotwell,
            "bound_s": bound,
        },
        "efficiency": efficiency,
        "counters_per_file": per_file,
        "cgroup": {
            "io_max": args.io_max,
            "memory_max": args.memory_max,
            "import_device_io": io_import,
            "import_device_read_per_corpus_byte": io_import["rbytes"] / corpus_bytes if corpus_bytes else None,
            "read_bound_device_io": io_delta(*args.io_stat_read),
            "container_cpu_s_during_import": (args.cpu_usec[1] - args.cpu_usec[0]) / 1e6,
        },
        "decode": decode,
        "shotwell": shotwell,
    }
    json.dump(result, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
