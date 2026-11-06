#!/bin/bash
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Downloads the samples listed in corpus-manifest.json into the docker volume
# shotwell-bench-corpus (checking their sha256) and makes a corpus set of N unique shots.
#
#   build-aux/bench/make-corpus.sh [SEED [N [ONLY]]]   default: SEED=1, N=$DEFAULT_SHOTS
#                                                 ONLY: only samples whose name contains it
#   build-aux/bench/make-corpus.sh --pairs-only [SEED [N]]
#                                                 only the samples that get a JPEG sibling, so
#                                                 every shot is a RAW+JPEG pair: set sSEED-nN-pairs
#   build-aux/bench/make-corpus.sh --inspect      preview sizes, libraw support, exiv2 writability
#
# The set is /corpus/sets/sSEED-nN inside the volume; run.sh takes its name with --set.
# Keep the corpus on a volume: on macOS a bind mount goes through virtiofs, which makes IO
# timing meaningless.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
image="${SHOTWELL_BENCH_IMAGE:-shotwell-bench:latest}"
corpus_volume="${SHOTWELL_BENCH_CORPUS_VOLUME:-shotwell-bench-corpus}"
# Calibrated so that the baseline (master) sd-slow import takes about 60 s; see README.md.
# Do not change it, or results stop being comparable.
DEFAULT_SHOTS=99

if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker build -t "$image" -f "$here/Dockerfile" "$here"
fi

docker_run() {
    docker run --rm -v "$corpus_volume:/corpus" -v "$here:/bench:ro" "$image" "$@"
}

docker_run python3 -I /bench/corpus.py fetch /bench/corpus-manifest.json

if [ "${1:-}" = "--inspect" ]; then
    docker_run python3 -I /bench/corpus.py inspect
    exit 0
fi

pairs=()
if [ "${1:-}" = "--pairs-only" ]; then
    pairs=(--pairs-only)
    shift
fi

seed="${1:-1}"
shots="${2:-$DEFAULT_SHOTS}"
docker_run python3 -I /bench/corpus.py make "$seed" "$shots" ${3:+"$3"} ${pairs[@]+"${pairs[@]}"}
