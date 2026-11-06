#!/bin/bash
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Builds Shotwell with -Dbenchmark=true inside the benchmark container.
#
#   build-aux/bench/build.sh [options] NAME SOURCE
#
# SOURCE is either a git ref (branch, tag, commit) of the repository this script is in,
# or the path to a checkout/worktree. A path is built as it is on disk, including
# uncommitted changes to tracked files and new files that are not ignored.
# NAME is the name of the build inside the shotwell-bench-builds volume; run.sh takes it.
#
# Options:
#   --test               also run "meson test"
#   --no-benchmark       configure with -Dbenchmark=false (to check that build)
#   --rebuild-image      rebuild the docker image first
#   -- ARGS...           pass the remaining arguments to "meson setup"
#
# Examples (compare a baseline with a change):
#   build-aux/bench/build.sh base bench-harness          # a branch
#   build-aux/bench/build.sh fix  ../shotwell-phase1      # a worktree with local changes
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
image="${SHOTWELL_BENCH_IMAGE:-shotwell-bench:latest}"
builds_volume="${SHOTWELL_BENCH_BUILDS_VOLUME:-shotwell-bench-builds}"

extra=()
rebuild_image=0
while [ $# -gt 0 ]; do
    case "$1" in
        --test) extra+=(--test); shift ;;
        --no-benchmark) extra+=(--benchmark=false); shift ;;
        --rebuild-image) rebuild_image=1; shift ;;
        --) shift; break ;;
        -h|--help) sed -n '5,25p' "$0"; exit 0 ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
if [ $# -lt 2 ]; then
    sed -n '5,25p' "$0" >&2
    exit 2
fi
name="$1"
source="$2"
shift 2
[ $# -gt 0 ] && extra+=("$@")

case "$name" in
    *[!A-Za-z0-9._-]*|"") echo "NAME may only contain letters, digits, '.', '_' and '-'" >&2; exit 2 ;;
esac

if [ "$rebuild_image" = 1 ] || ! docker image inspect "$image" >/dev/null 2>&1; then
    docker build -t "$image" -f "$here/Dockerfile" "$here"
fi

repo="$(git -C "$here" rev-parse --show-toplevel)"
# keep macOS tar from adding AppleDouble files to the archive
export COPYFILE_DISABLE=1

# Produce a tar of the source tree on stdout.
make_tar() {
    if [ -d "$source" ]; then
        local dir
        dir="$(cd "$source" >/dev/null && git rev-parse --show-toplevel)"
        local desc
        desc="$dir @ $(git -C "$dir" rev-parse --short HEAD)$(git -C "$dir" diff --quiet HEAD -- || echo '+dirty')"
        local tmp
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' RETURN
        echo "$desc" > "$tmp/.bench-ref"
        # tracked files (as on disk) and untracked files that are not ignored
        (cd "$dir" >/dev/null && git ls-files -z --cached --others --exclude-standard \
            | xargs -0 sh -c 'for f; do if [ -e "$f" ] || [ -L "$f" ]; then printf "%s\0" "$f"; fi; done' _ \
            | tar -c --null -T - -f -) > "$tmp/src.tar"
        tar -r -f "$tmp/src.tar" -C "$tmp" .bench-ref
        cat "$tmp/src.tar"
    else
        local commit
        commit="$(git -C "$repo" rev-parse --verify "$source^{commit}")"
        local tmp
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' RETURN
        echo "$source @ ${commit:0:12}" > "$tmp/.bench-ref"
        git -C "$repo" archive --format=tar "$commit" > "$tmp/src.tar"
        tar -r -f "$tmp/src.tar" -C "$tmp" .bench-ref
        cat "$tmp/src.tar"
    fi
}

make_tar | docker run --rm -i \
    -v "$builds_volume:/builds" \
    -v "$here:/bench:ro" \
    "$image" /bench/build-in-container.sh "$name" ${extra[@]+"${extra[@]}"}
