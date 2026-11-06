#!/bin/bash
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Per-format counters: makes one small corpus set per sample (9 shots each, the same seed as
# the default set) and imports each one unthrottled, then prints counters per shot.
#
#   build-aux/bench/per-format.sh BUILD [OUT_DIR]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
build="$1"
out_dir="${2:-$PWD/bench-results/per-format}"
shots=9

samples="$(python3 -I -c 'import json, sys; print("\n".join(s["file"] for s in json.load(open(sys.argv[1]))["samples"]))' "$here/corpus-manifest.json")"
results=()
for sample in $samples; do
    name="$(basename "$sample")"
    stem="${name%.*}"
    set_name="$("$here/make-corpus.sh" 1 "$shots" "$stem" | tail -1)"
    "$here/run.sh" --mode unthrottled --set "$set_name" --out "$out_dir" --no-decode-bound "$build" || true
    results+=("$(ls -t "$out_dir"/*-"$build"-unthrottled.json | head -1)")
done

python3 -I "$here/per-format-table.py" "${results[@]}"
