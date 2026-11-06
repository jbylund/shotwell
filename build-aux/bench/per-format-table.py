#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Prints a Markdown table of counters per shot (per raw file) for result files of single-format
# corpus sets (see per-format.sh).
#
#   per-format-table.py RESULT.json [RESULT.json ...]

import json
import sys

COLUMNS = [
    ("libraw_open", "libraw open"),
    ("libraw_unpack", "full raw decode"),
    ("libraw_unpack_thumb", "libraw thumb"),
    ("exiv2_preview_extract", "exiv2 preview"),
    ("glycin_decode_library", "glycin decode"),
    ("glycin_sniff", "glycin sniff"),
    ("glycin_encode_jpeg", "JPEG encode"),
    ("exiv2_read_file", "exiv2 parse"),
    ("exiv2_write_file", "exiv2 write"),
    ("md5_source", "md5 src MB"),
    ("md5_library", "md5 lib MB"),
    ("library_copy", "copy MB"),
]


def main():
    header = ["set", "files", "wall s", "main ms/shot", "max main ms"] + [c[1] for c in COLUMNS]
    print("| " + " | ".join(header) + " |")
    print("|" + "---|" * len(header))
    for path in sys.argv[1:]:
        with open(path) as f:
            r = json.load(f)
        s = r.get("shotwell", {})
        c = s.get("counters", {})
        shots = c.get("md5_source", {}).get("count") or 1
        row = [r.get("corpus_set", "?").split("-", 2)[-1], str(s.get("corpus_files")),
               "%.1f" % s.get("wall_s", 0),
               "%.0f" % (1000 * s.get("main_thread_callbacks_s", 0) / shots),
               "%.0f" % (1000 * c.get("main_import_files_completed", {}).get("max_s", 0))]
        for key, label in COLUMNS:
            v = c.get(key, {})
            if label.endswith("MB"):
                row.append("%.1f" % (v.get("bytes", 0) / 1e6 / shots))
            else:
                row.append("%.2g" % (v.get("count", 0) / shots))
        print("| " + " | ".join(row) + " |")
    print()
    print("Counts are per shot (one raw file, plus its JPEG sibling for RAW+JPEG sets); MB are per shot.")


if __name__ == "__main__":
    main()
