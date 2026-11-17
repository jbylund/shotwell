#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Shotwell contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Evict files from the page cache without privileges:
# fsync, then posix_fadvise(POSIX_FADV_DONTNEED) on every regular file
# below the given paths. This only drops clean pages that belong to these
# files, which is what a cold-cache benchmark run needs.

import os
import sys


def evict(path):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError as err:
        print(f"evict: {path}: {err}", file=sys.stderr)
        return 0
    try:
        size = os.fstat(fd).st_size
        try:
            os.fdatasync(fd)
        except OSError:
            pass
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        return size
    finally:
        os.close(fd)


def main():
    total = 0
    count = 0
    for root in sys.argv[1:]:
        if os.path.isfile(root):
            total += evict(root)
            count += 1
            continue
        for dirpath, _dirs, files in os.walk(root):
            for name in files:
                full = os.path.join(dirpath, name)
                if os.path.isfile(full) and not os.path.islink(full):
                    total += evict(full)
                    count += 1
    print(f"evicted {count} files, {total} bytes", file=sys.stderr)


if __name__ == "__main__":
    main()
