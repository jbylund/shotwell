<!--
SPDX-FileCopyrightText: 2026 Shotwell contributors
SPDX-License-Identifier: LGPL-2.1-or-later
-->

# Import benchmark

A headless benchmark of a RAW import with copy-to-library, in an Ubuntu 26.04 container. It
reports wall time, deterministic counters (decodes, parses, bytes read), the time spent in the
main-thread import callbacks and in each worker stage, and a lower bound measured in the same
run. It is Phase 0 of `docs/import-performance-plan.md`.

It needs Docker (tested with Docker Desktop 29 on an arm64 Mac, which runs an arm64 Linux VM)
and about 6 GB of disk space for the image, the builds and the default corpus.

## Quick start

```sh
# 1. build two versions to compare: a git ref, or the path of a checkout or worktree
#    (uncommitted changes are included). Both must contain the -Dbenchmark code.
build-aux/bench/build.sh base HEAD
build-aux/bench/build.sh fix  ../shotwell-phase1

# 2. download the samples and make the default corpus (99 shots, 135 files, 2.4 GB)
build-aux/bench/make-corpus.sh

# 3. run; results go to ./bench-results/<time>-<build>-<mode>.json
build-aux/bench/run.sh --mode sd-slow base
build-aux/bench/run.sh --mode sd-slow fix
build-aux/bench/run.sh --mode unthrottled base

# a human-readable summary of result files
python3 build-aux/bench/summary.py bench-results/*.json

# counters per format: one small set per sample, imported unthrottled
build-aux/bench/per-format.sh base

# equivalence: keep the library of two runs and compare them
build-aux/bench/run.sh --keep --mode unthrottled base    # prints "kept /work/run.XXXXXX"
build-aux/bench/run.sh --keep --mode unthrottled fix
docker run --rm -v shotwell-bench-work:/work -v "$PWD/build-aux/bench:/bench:ro" \
    shotwell-bench python3 -I /bench/equiv.py /work/run.AAAAAA /work/run.BBBBBB
```

`run.sh --developer SHOTWELL` (or `CAMERA`, `EMBEDDED`) sets the default RAW developer of the
run; otherwise it is the default, `CAMERA`.

`run.sh` runs the GTK window under `weston --backend=headless`; `DISPLAY_BACKEND=xvfb` in the
container environment switches to `xvfb-run` and the X11 backend.

`build.sh --test` also runs `meson test`; `build.sh --no-benchmark` configures with
`-Dbenchmark=false`. Builds are kept in the docker volume `shotwell-bench-builds` and are
incremental. The image is built on first use; `build.sh --rebuild-image` rebuilds it.

## What is measured

`shotwell --benchmark-import DIR` (only in a `-Dbenchmark=true` build) imports DIR with
copy-to-library into a fresh library, waits for the import to complete plus a settle period of
2 s (`SHOTWELL_BENCHMARK_SETTLE_MS`), prints one JSON object and exits with status 0 only if
every file was imported. `run-in-container.sh` adds the lower bound and cgroup figures and
`merge-result.py` merges them. The main fields of the result:

| Field | Meaning |
|---|---|
| `t_import_s` | wall time from queueing the import to `import_complete` |
| `lower_bound.t_read_s` | `cat` of the whole corpus with a cold cache, same throttle |
| `lower_bound.t_decode_all_s` | `dcraw_emu` time of every raw file, divided by the number of CPUs |
| `lower_bound.t_decode_shotwell_subset_s` | the same, for the files whose largest embedded preview is smaller than 1024 px (they need a full decode with the default developer) |
| `efficiency` | `max(t_read, t_decode_shotwell_subset) / t_import` (plan section 3.6) |
| `shotwell.counters.<probe>` | count, bytes, total time summed over threads, longest call, active span |
| `shotwell.counters_after_completion` | what happened during the settle period |
| `shotwell.main_thread_callbacks_s` | time in the BatchImport main-thread callbacks |
| `shotwell.main_loop_lag` | stalls of the main loop during the import (see below) |
| `shotwell.main_loop_lag_after_completion` | the same, during the settle period |
| `cgroup.import_device_io.rbytes` | bytes the container read from the block device during the import |
| `counters_per_file` | counts divided by the number of corpus files |

The probes are defined in `src/BenchCounters.vala`. Some notes on them:

- `libraw_unpack` counts full raw decodes (every full decode calls `unpack` and then `process`).
- `glycin_sniff` counts `GlycinSniffer.sniff` calls. On master every call decodes the whole
  image to learn its size.
- `glycin_decode_other` is mostly the UI reading cached thumbnails.
- `md5_source` and `md5_library` split `md5_file()` reads by directory. The glycin sniffer
  hashes files itself and is not included.
- `worker_feeder_notify_wait` is the time `PrepareFilesJob` spends in `notify()`: it hands a
  cluster of prepared files to the main thread and waits until the main thread has taken it,
  so it grows when the main thread is busy.
- `library_photo_generate_thumbnails` is `LibraryPhoto.generate_thumbnails()`, which runs on the
  main thread at `Priority.LOW` after a change to the image of a photo (for example attaching
  the camera JPEG of a RAW+JPEG pair). It is not one of the BatchImport callbacks, so it is not
  in `main_thread_callbacks_s`. `thumbnail_import_from_source` is the `ThumbnailCache` call
  inside it (and in any other caller).

`main_loop_lag` comes from a timer at `Priority.HIGH` that fires every 5 ms. When the main thread
is busy in one callback for X ms, the next tick is about X ms late. `max_s` is the longest stall,
`stalls_over_20ms` and `stall_total_over_20ms_s` count the ticks that were more than 20 ms late
and their total lateness, and `lag_total_s` adds up all lateness. It covers all main-thread work,
including GTK.

## Modes and throttling

| Mode | Read cap |
|---|---|
| `unthrottled` | none |
| `sd-slow` (default) | 40 MB/s |
| `sd-fast` | 90 MB/s |
| `sd-uhs2` | 250 MB/s |

The cap is `docker run --device-read-bps <dev>:<rate>`, which sets cgroup v2 `io.max` on the
block device that holds the corpus volume (`/dev/vda` in the Docker Desktop VM; `run.sh` finds
it, or set `SHOTWELL_BENCH_DEVICE`). cgroup v2 charges page-cache misses of buffered reads to
the reading cgroup, so the cap works for normal reads. Before the read-bound measurement and
before the import, `evict.py` drops the corpus from the page cache with
`posix_fadvise(POSIX_FADV_DONTNEED)`, which needs no privileges.

Checked on Docker Desktop 29 (18 CPUs): 400 MB after eviction took 9.87 s at `40mb`
(40.5 MB/s), and `cat` of the 2.4 GB corpus took 57.8 s (41.9 MB/s).

Things to know:

- The cap applies to every read of the container from that device, not only to the corpus.
  The library is on the same device, so a re-read of a copied file that misses the page cache
  is capped too. Writes are not capped.
- In `unthrottled` mode on macOS, "cold" reads are served from the macOS cache of the VM disk
  image, at several GB/s. That mode therefore measures CPU and main-thread cost only.
- The VM has a large page cache, so a file that is read twice is normally read from the device
  once. `--memory SIZE` limits the container's memory, page cache included, to model an import
  that is larger than the page cache (hypothesis H2 of the plan). Shotwell itself peaks at about
  1.2-1.5 GB RSS during the default import (`shotwell.peak_rss_mb`), so 1 GB gets it killed;
  2 GB works.
- Docker Desktop does not allow `perf`; see the plan, section 3.7.

## The glycin sandbox

glycin runs its image loaders in a bubblewrap sandbox. In a default container `bwrap` fails:
Docker's seccomp profile blocks the namespace system calls, and with
`seccomp=unconfined` alone it still fails with "Can't mount proc on /newroot/proc", because
Docker masks paths under `/proc`. `run.sh` therefore passes

```
--security-opt seccomp=unconfined --security-opt systempaths=unconfined
```

and nothing else: no `--privileged` and no added capabilities. With these two options the
sandbox works for root and for an unprivileged user in the container.

## Corpus

`corpus-manifest.json` lists the samples, with URL, sha256 and licence. They all come from
[raw.pixls.us](https://raw.pixls.us/) and are CC0-1.0. raw.pixls.us has no OM-1 file, so an
E-M1 Mark III ORF stands in for it. The Pixel 4a DNG has a 672 px preview, so with the default
developer it takes the `SHOTWELL` path.

`make-corpus.sh [SEED [N]]` downloads the samples into the docker volume
`shotwell-bench-corpus` and makes the set `sSEED-nN` of N shots, taking the samples in turn.
The four primary bodies (D600, 100D, 200D, E-M1 III) also get a JPEG sibling, made from the
largest embedded preview, so they form RAW+JPEG pairs. Every copy is made unique, because the
import skips files whose MD5 is already in the library:

- formats that exiv2 can write (ORF, NEF, CR2, ARW, DNG, JPEG): new
  `Exif.Photo.ImageUniqueID`, `DateTimeOriginal`, `DateTimeDigitized` and `Exif.Image.DateTime`,
  with times that make several events;
- formats that exiv2 cannot write (CR3, RAF, RW2): a small trailer after the end of the file
  (a `free` box for CR3). These copies keep the original date.

Every copy is checked with `raw-identify`, and the first copy of each sample is decoded with
`dcraw_emu`. `make-corpus.sh --pairs-only [SEED [N]]` makes the set `sSEED-nN-pairs` from the
four paired samples only, so that every shot is a RAW+JPEG pair (N shots, 2N files).
`make-corpus.sh --inspect` prints the preview sizes, libraw support and exiv2
writability of the samples. The downloaded files stay in the volume and are only read by
exiv2 and libraw.

The default N is 99 (9 cycles of 11 samples). It was chosen once so that the baseline
`sd-slow` import takes about 60 s on the reference machine. Do not change it, so that results
stay comparable.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `Dockerfile` | | Ubuntu 26.04 with the build dependencies, vala 0.56.19 and gexiv2 0.16.2 |
| `build.sh` | host | builds a ref or a worktree with `-Dbenchmark=true` |
| `build-in-container.sh` | container | meson setup, ninja, optionally meson test |
| `make-corpus.sh`, `corpus.py` | host, container | downloads the samples and makes a corpus set |
| `run.sh` | host | one run in a mode, with throttle and sandbox options |
| `run-in-container.sh` | container | lower bound, weston, D-Bus, the import, merge |
| `evict.py` | container | drops files from the page cache |
| `decode-bound.py` | container | `dcraw_emu` lower bound |
| `merge-result.py`, `summary.py` | container, host | result JSON and summary |
| `equiv.py` | container | compares the database, library files and thumbnails of two kept runs |
| `per-format.sh`, `per-format-table.py` | host | one 9-shot set per sample, unthrottled, table of counters per shot |

The image builds vala 0.56.19 from the release tarball, because the gtk4 bindings of the
packaged valac 0.56.18 predate GTK 4.20 and master does not compile with them. It builds
gexiv2 0.16.2 because Ubuntu only has 0.14.6.
