/* SPDX-FileCopyrightText: 2026 Shotwell contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

// Counters and stage timers for the import benchmark.
//
// This file is only compiled when Shotwell is configured with -Dbenchmark=true. All hooks in
// the rest of the code are single-line calls into this namespace, wrapped in #if BENCHMARK, so
// that a normal build is unchanged.
//
// Every entry point is safe to call from any thread.
namespace BenchCounters {

// Each probe has a call count, a byte count, the time spent inside it (summed over all threads),
// the longest single call, and the time span during which it was active.
public enum Probe {
    // libraw (GRaw.Processor)
    LIBRAW_OPEN,
    LIBRAW_UNPACK,              // the first half of every full raw decode
    LIBRAW_PROCESS,             // demosaic, the second half of every full raw decode
    LIBRAW_UNPACK_THUMB,        // embedded thumbnail extraction through libraw
    // RawReader entry points
    RAW_UNSCALED_READ,
    RAW_SCALED_READ,
    // glycin
    GLYCIN_DECODE_LIBRARY,      // GlycinReader.unscaled_read (a full decode) of a library file
    GLYCIN_DECODE_SOURCE,       // ... of a file below the import source directory
    GLYCIN_DECODE_OTHER,        // ... of any other file, mostly cached thumbnails for the UI
    GLYCIN_SNIFF,               // GlycinSniffer.sniff: a full decode on master
    GLYCIN_ENCODE_JPEG,         // GlycinWriter.do_write*, JPEG output
    GLYCIN_ENCODE_OTHER,        // GlycinWriter.do_write*, any other format
    // exiv2 (PhotoMetadata)
    EXIV2_READ_FILE,
    EXIV2_READ_BUFFER,
    EXIV2_WRITE_FILE,
    EXIV2_PREVIEW_EXTRACT,      // embedded preview extraction through exiv2
    // whole-file IO
    MD5_SOURCE,                 // md5_file() on a file below the import source directory
    MD5_LIBRARY,                // md5_file() on a file below the library directory
    MD5_OTHER,                  // md5_file() anywhere else
    LIBRARY_COPY,               // the copy in LibraryFiles.duplicate()
    // BatchImport callbacks on the main thread
    MAIN_PROCESS_PREPARED_FILE, // one iteration of process_prepared_files()
    MAIN_IMPORT_FILES_COMPLETED,
    MAIN_THUMBNAIL_WRITER_COMPLETED,
    MAIN_FLUSH_READY_SOURCES,
    MAIN_DISPLAY_IMPORTED_TIMER,
    // BatchImport worker stages
    WORKER_PREPARE_FILES_JOB,   // the single feeder job, for the whole batch
    WORKER_PREPARE_FILE,        // one file inside the feeder job
    WORKER_PREPARED_FILE_IMPORT,
    WORKER_THUMBNAIL_WRITER,
    WORKER_FEEDER_NOTIFY_WAIT,  // PrepareFilesJob waiting in notify() until the main thread took a cluster
    // thumbnails made outside the import pipeline
    LIBRARY_PHOTO_GENERATE_THUMBNAILS, // LibraryPhoto.generate_thumbnails(), on the main thread
    THUMBNAIL_IMPORT_FROM_SOURCE,      // ThumbnailCache.import_from_source(), any thread

    COUNT;

    public string to_key() {
        return ((EnumClass) typeof(Probe).class_ref()).get_value(this).value_nick.replace("-", "_");
    }

    public bool is_main_thread() {
        return this >= MAIN_PROCESS_PREPARED_FILE && this <= MAIN_DISPLAY_IMPORTED_TIMER;
    }
}

private struct Slot {
    public int64 count;
    public int64 bytes;
    public int64 total_us;
    public int64 max_us;
    public int64 first_start_us;
    public int64 last_end_us;
}

private Mutex mutex;
private Slot[]? slots = null;
private int64 origin_us = 0;
private File? source_dir = null;
private File? library_dir = null;

// Must be called on the main thread before any worker thread starts.
public void init() {
    if (slots != null)
        return;

    slots = new Slot[Probe.COUNT];
    origin_us = get_monotonic_time();
}

// Sets the directories that md5_file() reads are attributed to. Call before the import starts.
public void set_directories(File source, File library) {
    source_dir = source;
    library_dir = library;
}

public int64 now_us() {
    return get_monotonic_time() - origin_us;
}

private void record(Probe probe, int64 start_us, int64 end_us, int64 bytes) {
    if (slots == null)
        return;

    int64 elapsed = end_us - start_us;

    mutex.lock();
    if (slots[probe].count == 0 || start_us < slots[probe].first_start_us)
        slots[probe].first_start_us = start_us;
    if (end_us > slots[probe].last_end_us)
        slots[probe].last_end_us = end_us;
    slots[probe].count++;
    slots[probe].bytes += bytes;
    slots[probe].total_us += elapsed;
    if (elapsed > slots[probe].max_us)
        slots[probe].max_us = elapsed;
    mutex.unlock();
}

// Records a call that started at start_us (from now_us()) and ends now. For blocks that a Scope
// cannot wrap.
public void add_since(Probe probe, int64 start_us) {
    record(probe, start_us, now_us(), 0);
}

// Counts one event that has no duration.
public void hit(Probe probe) {
    int64 now = now_us();
    record(probe, now, now, 0);
}

private int64 file_size(File file) {
    try {
        return file.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size();
    } catch (Error err) {
        return 0;
    }
}

private Probe location_probe(File file, Probe library, Probe source, Probe other) {
    if (library_dir != null && file.has_prefix(library_dir))
        return library;
    if (source_dir != null && file.has_prefix(source_dir))
        return source;

    return other;
}

// Times a block. Declare it as a local variable at the start of the block and start it on the
// same line; the time is recorded when the variable goes out of scope:
//
//     var bench_scope = new BenchCounters.Scope(BenchCounters.Probe.WORKER_THUMBNAIL_WRITER); bench_scope.start();
//
// (The start() call also keeps valac from warning that the variable is never used.)
[Compact (opaque = true)]
public class Scope {
    private Probe probe;
    private int64 start_us;
    private int64 bytes;

    public Scope(Probe probe) {
        this.probe = probe;
        bytes = 0;
        start_us = now_us();
    }

    // Also records the size of the file as bytes read (or copied).
    public Scope.file(Probe probe, File file) {
        this.probe = probe;
        bytes = file_size(file);
        start_us = now_us();
    }

    // An md5_file() call. The probe depends on where the file is.
    public Scope.md5(File file) {
        probe = location_probe(file, Probe.MD5_LIBRARY, Probe.MD5_SOURCE, Probe.MD5_OTHER);
        bytes = file_size(file);
        start_us = now_us();
    }

    // A full glycin decode. The probe depends on where the file is.
    public Scope.glycin_decode(File file) {
        probe = location_probe(file, Probe.GLYCIN_DECODE_LIBRARY, Probe.GLYCIN_DECODE_SOURCE,
            Probe.GLYCIN_DECODE_OTHER);
        bytes = 0;
        start_us = now_us();
    }

    // A glycin encode.
    public Scope.encode(bool is_jpeg) {
        probe = is_jpeg ? Probe.GLYCIN_ENCODE_JPEG : Probe.GLYCIN_ENCODE_OTHER;
        bytes = 0;
        start_us = now_us();
    }

    // Restarts the clock, so that the stat() done by the file constructors is not counted.
    public void start() {
        start_us = now_us();
    }

    ~Scope() {
        record(probe, start_us, now_us(), bytes);
    }
}

// Returns a copy of all slots, for a report.
private Slot[] snapshot() {
    Slot[] copy = new Slot[Probe.COUNT];
    if (slots == null)
        return copy;

    mutex.lock();
    for (int i = 0; i < Probe.COUNT; i++)
        copy[i] = slots[i];
    mutex.unlock();

    return copy;
}

public class Snapshot {
    internal Slot[] slots;

    public Snapshot() {
        slots = snapshot();
    }

    public int64 count(Probe probe) {
        return slots[probe].count;
    }

    public int64 bytes(Probe probe) {
        return slots[probe].bytes;
    }

    public int64 total_us(Probe probe) {
        return slots[probe].total_us;
    }

    // The counts and times in this snapshot minus the ones in an earlier snapshot.
    public string to_json(Snapshot? since, string indent) {
        StringBuilder builder = new StringBuilder("{\n");
        for (int i = 0; i < Probe.COUNT; i++) {
            Slot slot = slots[i];
            if (since != null) {
                slot.count -= since.slots[i].count;
                slot.bytes -= since.slots[i].bytes;
                slot.total_us -= since.slots[i].total_us;
            }

            int64 active_us = slot.count > 0 ? slot.last_end_us - slot.first_start_us : 0;
            builder.append_printf("%s  \"%s\": { \"count\": %s, \"bytes\": %s, \"total_s\": %.6f, "
                + "\"max_s\": %.6f, \"first_start_s\": %.6f, \"active_s\": %.6f }%s\n", indent,
                ((Probe) i).to_key(), slot.count.to_string(), slot.bytes.to_string(),
                slot.total_us / 1e6, slot.max_us / 1e6, slot.first_start_us / 1e6, active_us / 1e6,
                (i < Probe.COUNT - 1) ? "," : "");
        }
        builder.append_printf("%s}", indent);

        return builder.str;
    }
}

}
