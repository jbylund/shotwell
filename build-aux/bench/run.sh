#!/bin/bash
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Runs one headless benchmark import in the shotwell-bench container and saves the JSON.
#
#   build-aux/bench/run.sh [options] BUILD
#
# BUILD is a name given to build.sh. Options:
#   --mode MODE      unthrottled | sd-slow (default, 40 MB/s) | sd-fast (90 MB/s) | sd-uhs2 (250 MB/s)
#   --set NAME       corpus set made by make-corpus.sh (default: s1-n$DEFAULT_SHOTS)
#   --out DIR        directory for the results (default: ./bench-results)
#   --memory SIZE    docker --memory limit, e.g. 2g; the page cache is charged to it, so this
#                    makes the import bigger than the page cache (hypothesis H2)
#   --cpus N         docker --cpus limit
#   --repeat N       run N times (default 1)
#   --no-decode-bound  skip the dcraw_emu lower-bound measurement
#   --keep           keep the run directory (library, database, logs) in the work volume
#
# The read cap is applied with "docker run --device-read-bps" on the block device that holds
# the corpus volume (inside the Docker Desktop VM that is /dev/vda). It limits every read of
# the container from that device, through the page cache, which is evicted (without
# privileges, with posix_fadvise) before the read-bound measurement and before the import.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
image="${SHOTWELL_BENCH_IMAGE:-shotwell-bench:latest}"
builds_volume="${SHOTWELL_BENCH_BUILDS_VOLUME:-shotwell-bench-builds}"
corpus_volume="${SHOTWELL_BENCH_CORPUS_VOLUME:-shotwell-bench-corpus}"
work_volume="${SHOTWELL_BENCH_WORK_VOLUME:-shotwell-bench-work}"
DEFAULT_SHOTS=99

mode=sd-slow
set_name="s1-n$DEFAULT_SHOTS"
out_dir="$PWD/bench-results"
repeat=1
docker_extra=()
env_extra=()
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) mode="$2"; shift 2 ;;
        --set) set_name="$2"; shift 2 ;;
        --out) out_dir="$2"; shift 2 ;;
        --memory) docker_extra+=(--memory "$2" --memory-swap "$2"); shift 2 ;;
        --cpus) docker_extra+=(--cpus "$2"); shift 2 ;;
        --repeat) repeat="$2"; shift 2 ;;
        --no-decode-bound) env_extra+=(-e LOWER_BOUND_DECODE=0); shift ;;
        --keep) env_extra+=(-e KEEP_RUN_DIR=1); shift ;;
        -h|--help) sed -n '5,25p' "$0"; exit 0 ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
if [ $# -ne 1 ]; then
    sed -n '5,25p' "$0" >&2
    exit 2
fi
build="$1"

case "$mode" in
    unthrottled) rate="" ;;
    sd-slow) rate=40mb ;;
    sd-fast) rate=90mb ;;
    sd-uhs2) rate=250mb ;;
    *) echo "unknown mode $mode" >&2; exit 2 ;;
esac

# The block device behind the corpus volume, as the docker daemon sees it.
device="${SHOTWELL_BENCH_DEVICE:-}"
if [ -n "$rate" ] && [ -z "$device" ]; then
    device="$(docker run --rm -v "$corpus_volume:/corpus" "$image" sh -c '
        majmin=$(awk "\$5 == \"/corpus\" {print \$3}" /proc/self/mountinfo)
        sys=$(readlink -f /sys/dev/block/$majmin)
        if [ -e "$sys/partition" ]; then sys=$(dirname "$sys"); fi
        echo /dev/$(basename "$sys")')"
fi
throttle=()
if [ -n "$rate" ]; then
    throttle=(--device-read-bps "$device:$rate")
fi

# glycin decodes images in a bubblewrap sandbox. bwrap needs to create user, mount and PID
# namespaces and mount a fresh /proc. Docker's default seccomp profile blocks the namespace
# syscalls and the masked /proc paths make the proc mount fail, so lift exactly those two.
# No --privileged and no extra capabilities are needed.
sandbox=(--security-opt seccomp=unconfined --security-opt systempaths=unconfined)

mkdir -p "$out_dir"
# docker takes a relative path for a volume name
out_dir="$(cd "$out_dir" >/dev/null && pwd)"
for i in $(seq "$repeat"); do
    stamp="$(date +%Y%m%d-%H%M%S)"
    prefix="$stamp-$build-$mode"
    [ "$repeat" -gt 1 ] && prefix="$prefix-$i"
    echo "== run $i/$repeat: build $build, mode $mode ${rate:+($device at $rate/s)}, set $set_name" >&2
    set +e
    docker run --rm \
        ${throttle[@]+"${throttle[@]}"} "${sandbox[@]}" ${docker_extra[@]+"${docker_extra[@]}"} ${env_extra[@]+"${env_extra[@]}"} \
        -v "$builds_volume:/builds:ro" \
        -v "$corpus_volume:/corpus:ro" \
        -v "$work_volume:/work" \
        -e DISPLAY_BACKEND="${DISPLAY_BACKEND:-weston}" -v "$here:/bench:ro" \
        -v "$out_dir:/results" \
        "$image" /bench/run-in-container.sh "$build" "$set_name" "$mode" "/results/$prefix" \
        > /dev/null
    status=$?
    set -e
    if [ -f "$out_dir/$prefix.json" ]; then
        python3 -I "$here/summary.py" "$out_dir/$prefix.json" >&2
    fi
    echo "result: $out_dir/$prefix.json (exit status $status)" >&2
done
exit "$status"
