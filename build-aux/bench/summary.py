#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Prints a short human-readable summary of one or more benchmark result files.
#
#   summary.py RESULT.json [RESULT.json ...]

import json
import sys


KEYS = [
    ("libraw_open", "libraw opens"),
    ("libraw_unpack", "full raw decodes (unpack)"),
    ("libraw_process", "  demosaic (process)"),
    ("libraw_unpack_thumb", "libraw thumbnail extractions"),
    ("exiv2_preview_extract", "exiv2 preview extractions"),
    ("glycin_decode_library", "glycin full decodes, library"),
    ("glycin_decode_source", "glycin full decodes, source"),
    ("glycin_decode_other", "glycin full decodes, other"),
    ("glycin_sniff", "glycin sniffs (full decode)"),
    ("glycin_encode_jpeg", "JPEG encodes"),
    ("exiv2_read_file", "exiv2 parses (file)"),
    ("exiv2_read_buffer", "exiv2 parses (buffer)"),
    ("exiv2_write_file", "exiv2 metadata writes"),
    ("md5_source", "md5 reads of source files"),
    ("md5_library", "md5 reads of library files"),
    ("library_copy", "library copies"),
]

MAIN = ["main_process_prepared_file", "main_import_files_completed", "main_thumbnail_writer_completed",
        "main_flush_ready_sources", "main_display_imported_timer"]
WORKER = ["worker_prepare_files_job", "worker_prepare_file", "worker_prepared_file_import",
          "worker_thumbnail_writer", "worker_feeder_notify_wait"]
# thumbnails made outside the import pipeline (generate_thumbnails runs on the main thread)
OTHER = ["library_photo_generate_thumbnails", "thumbnail_import_from_source"]


def show(path):
    with open(path) as f:
        r = json.load(f)
    s = r.get("shotwell", {})
    c = s.get("counters", {})
    files = s.get("corpus_files") or 0
    mb = (s.get("corpus_bytes") or 0) / 1e6
    lb = r.get("lower_bound", {})
    print("%s: %s, mode %s, ok=%s" % (path, r.get("build"), r.get("mode"), r.get("ok")))
    if "wall_s" not in s:
        print("  no result from shotwell: %s" % s.get("error"))
        return
    print("  import %.1f s for %d files, %.0f MB (%.1f MB/s); T_read %.1f s, T_decode(all) %.1f s, "
          "T_decode(SHOTWELL subset) %.1f s; efficiency %.2f" % (
              s["wall_s"], files, mb, mb / s["wall_s"], lb.get("t_read_s") or 0,
              lb.get("t_decode_all_s") or 0, lb.get("t_decode_shotwell_subset_s") or 0,
              r.get("efficiency") or 0))
    print("  main thread in import callbacks %.1f s (%.0f%% of wall time); process CPU %.1f s user"
          % (s.get("main_thread_callbacks_s", 0), 100 * s.get("main_thread_busy_fraction", 0),
             s.get("process_cpu_s", {}).get("user", 0)))
    print("  first photo shown after %.2f s" % s.get("first_imported_s", -1))
    for key, label in (("main_loop_lag", "during import"),
                       ("main_loop_lag_after_completion", "after import_complete")):
        lag = s.get(key)
        if lag:
            print("  main-loop lag %s: longest stall %.3f s, %d stalls over 20 ms totalling %.2f s"
                  % (label, lag["max_s"], lag["stalls_over_20ms"], lag["stall_total_over_20ms_s"]))
    cg = r.get("cgroup", {})
    print("  shotwell peak RSS %.0f MB; container memory limit %s" % (
        s.get("peak_rss_mb", 0), cg.get("memory_max")))
    io = cg.get("import_device_io", {})
    if io:
        print("  device reads during import %.0f MB (%.2f x corpus), writes %.0f MB" % (
            io.get("rbytes", 0) / 1e6, (io.get("rbytes", 0) / 1e6) / mb if mb else 0,
            io.get("wbytes", 0) / 1e6))
    for key, label in KEYS:
        v = c.get(key, {})
        if v.get("count"):
            extra = (", %.0f MB" % (v["bytes"] / 1e6)) if v.get("bytes") else ""
            print("  %-32s %6d  (%.2f per file, %.1f s total%s)" % (
                label, v["count"], v["count"] / files if files else 0, v["total_s"], extra))
    for key in MAIN + WORKER + OTHER:
        v = c.get(key, {})
        if v.get("count"):
            print("  %-32s %6d calls, %.2f s total, max %.3f s, active %.1f s" % (
                key, v["count"], v["total_s"], v["max_s"], v["active_s"]))
    after = s.get("counters_after_completion", {})
    late = {k: v["count"] for k, v in after.items() if v.get("count")}
    if late:
        print("  after import_complete: %s" % late)


for p in sys.argv[1:]:
    show(p)
