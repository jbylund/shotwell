#!/bin/bash
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Runs inside the shotwell-bench image (called by build.sh).
# Reads a tar of the Shotwell source tree on stdin and builds it in /builds/NAME.
#
#   build-in-container.sh NAME [--test] [--benchmark=true|false] [extra meson args...]
set -euo pipefail

name="$1"
shift
run_tests=0
benchmark=true
meson_args=()
for arg in "$@"; do
    case "$arg" in
        --test) run_tests=1 ;;
        --benchmark=*) benchmark="${arg#--benchmark=}" ;;
        *) meson_args+=("$arg") ;;
    esac
done

root="/builds/$name"
rm -rf "$root/src"
mkdir -p "$root/src"
tar -x -C "$root/src" -f -

if [ -f "$root/src/.bench-ref" ]; then
    echo "building $(cat "$root/src/.bench-ref") as $name" >&2
fi

if grep -q "option('benchmark'" "$root/src/meson_options.txt"; then
    meson_args=(-Dbenchmark="$benchmark" ${meson_args[@]+"${meson_args[@]}"})
else
    echo "warning: this tree has no benchmark option; building without it (no --benchmark-import)" >&2
fi

builddir="$root/build"
if [ -d "$builddir" ]; then
    # keep the build directory so rebuilds are incremental
    meson setup --reconfigure "$builddir" "$root/src" "${meson_args[@]}" >&2
else
    meson setup "$builddir" "$root/src" "${meson_args[@]}" >&2
fi
ninja -C "$builddir" >&2

if [ "$run_tests" = 1 ]; then
    meson test -C "$builddir" --print-errorlogs >&2
fi

echo "$builddir/src/shotwell"
