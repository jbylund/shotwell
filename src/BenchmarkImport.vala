/* SPDX-FileCopyrightText: 2026 Shotwell contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

// Driver for "shotwell --benchmark-import DIR" (only built with -Dbenchmark=true).
//
// It queues one BatchImport of DIR with copy-to-library, waits until the import is complete and
// the main loop has settled, prints one JSON object to stdout and closes the library window.
// The process exit status (see get_exit_status()) is 0 only if every file was imported.
namespace BenchmarkImport {

// After import_complete, keep the main loop running for this long so that work which the import
// schedules for later (for example thumbnail regeneration after notify_altered) is counted too.
// It is reported separately and is not part of the wall time. Override with
// SHOTWELL_BENCHMARK_SETTLE_MS.
private const uint DEFAULT_SETTLE_MSEC = 2000;

private int exit_status = 2;
private File? source_dir = null;
private int64 start_us = 0;
private int64 end_us = 0;
private int64 first_imported_us = -1;
private int64 imported_signals = 0;
private int64 corpus_files = 0;
private int64 corpus_bytes = 0;
private BatchImport? batch_import = null;
private BenchCounters.Snapshot? at_completion = null;
private ImportManifest? result_manifest = null;
private string? proc_io_start = null;
private string? proc_io_end = null;
private double cpu_user_start = 0;
private double cpu_sys_start = 0;
private double cpu_user_end = 0;
private int64 rss_peak_kb = 0;
private double cpu_sys_end = 0;

public int get_exit_status() {
    return exit_status;
}

private void walk(File dir) {
    try {
        FileEnumerator enumerator = dir.enumerate_children("standard::name,standard::type,standard::size",
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        FileInfo? info = null;
        while ((info = enumerator.next_file(null)) != null) {
            File child = dir.get_child(info.get_name());
            if (info.get_file_type() == FileType.DIRECTORY) {
                walk(child);
            } else if (info.get_file_type() == FileType.REGULAR) {
                corpus_files++;
                corpus_bytes += info.get_size();
            }
        }
    } catch (Error err) {
        warning("benchmark: unable to scan %s: %s", dir.get_path(), err.message);
    }
}

private string read_proc_io() {
    try {
        string contents;
        FileUtils.get_contents("/proc/self/io", out contents);

        return contents;
    } catch (Error err) {
        return "";
    }
}

// /proc/self/io as a JSON object of deltas since the start of the import.
private string proc_io_json(string start, string end) {
    var start_values = new Gee.HashMap<string, int64?>();
    foreach (string line in start.split("\n")) {
        string[] parts = line.split(":");
        if (parts.length == 2)
            start_values.set(parts[0].strip(), int64.parse(parts[1].strip()));
    }

    StringBuilder builder = new StringBuilder("{");
    bool first = true;
    foreach (string line in end.split("\n")) {
        string[] parts = line.split(":");
        if (parts.length != 2)
            continue;
        string key = parts[0].strip();
        int64 value = int64.parse(parts[1].strip());
        if (start_values.has_key(key))
            value -= start_values.get(key);
        builder.append_printf("%s\"%s\": %s", first ? " " : ", ", key, value.to_string());
        first = false;
    }
    builder.append(" }");

    return builder.str;
}

// User and system CPU time of this process (all threads), in seconds, from /proc/self/stat.
// The values there are in USER_HZ, which is 100 on Linux. Sandboxed glycin loaders run in
// other processes and are not included.
private void get_cpu_times(out double user, out double sys) {
    user = 0;
    sys = 0;
    try {
        string contents;
        FileUtils.get_contents("/proc/self/stat", out contents);
        // the command name in field 2 may contain spaces, so start after its closing parenthesis
        string[] fields = contents.substring(contents.last_index_of(")") + 2).split(" ");
        // fields[0] is field 3 (state), so utime (field 14) is fields[11]
        if (fields.length > 12) {
            user = int64.parse(fields[11]) / 100.0;
            sys = int64.parse(fields[12]) / 100.0;
        }
    } catch (Error err) {
        // not on Linux
    }
}

// Peak resident set size of this process in kB (VmHWM in /proc/self/status).
private int64 peak_rss_kb() {
    try {
        string contents;
        FileUtils.get_contents("/proc/self/status", out contents);
        foreach (string line in contents.split("\n")) {
            if (line.has_prefix("VmHWM:"))
                return int64.parse(line.substring(6).strip().split(" ")[0]);
        }
    } catch (Error err) {
        // not on Linux
    }

    return 0;
}

private string escape(string? str) {
    if (str == null)
        return "null";

    return "\"" + str.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\"";
}

// Called from library_exec() after the library window is presented and before the main loop
// starts.
public void start(string dir) {
    source_dir = File.new_for_commandline_arg(dir);
    File library_dir = AppDirs.get_import_dir();

    BenchCounters.set_directories(source_dir, library_dir);
    walk(source_dir);

    if (AppDirs.is_in_import_dir(source_dir))
        warning("benchmark: %s is inside the library directory %s, files will not be copied",
            source_dir.get_path(), library_dir.get_path());

    Gee.ArrayList<FileImportJob> jobs = new Gee.ArrayList<FileImportJob>();
    jobs.add(new FileImportJob(source_dir, !AppDirs.is_in_import_dir(source_dir), true));

    batch_import = new BatchImport(jobs, "benchmark_import", null);
    batch_import.imported.connect(on_imported);
    batch_import.import_complete.connect(on_import_complete);

    proc_io_start = read_proc_io();
    get_cpu_times(out cpu_user_start, out cpu_sys_start);
    start_us = BenchCounters.now_us();

    LibraryWindow library_window = (LibraryWindow) AppWindow.get_instance();
    library_window.enqueue_batch_import(batch_import, true);
    library_window.switch_to_import_queue_page();
}

private void on_imported(MediaSource source, Gdk.Pixbuf pixbuf, int to_follow) {
    if (first_imported_us < 0)
        first_imported_us = BenchCounters.now_us();
    imported_signals++;
}

private void on_import_complete(ImportManifest manifest, BatchImportRoll import_roll) {
    end_us = BenchCounters.now_us();
    at_completion = new BenchCounters.Snapshot();
    proc_io_end = read_proc_io();
    get_cpu_times(out cpu_user_end, out cpu_sys_end);
    rss_peak_kb = peak_rss_kb();
    result_manifest = manifest;

    uint settle = DEFAULT_SETTLE_MSEC;
    string? env = Environment.get_variable("SHOTWELL_BENCHMARK_SETTLE_MS");
    if (env != null && env != "")
        settle = (uint) int.parse(env);

    // Let the rest of the import roll through the main loop first (flush_ready_sources and
    // friends run right after the signal), then wait for deferred work.
    Timeout.add(settle, () => {
        Idle.add(finish, Priority.LOW);

        return false;
    });
}

private bool finish() {
    BenchCounters.Snapshot after_settle = new BenchCounters.Snapshot();

    ImportManifest manifest = result_manifest;
    int failures = manifest.failed.size + manifest.camera_failed.size + manifest.write_failed.size
        + manifest.skipped_photos.size + manifest.skipped_files.size + manifest.aborted.size
        + manifest.already_imported.size + manifest.corrupt_files.size;

    int64 imported_bytes = 0;
    int64 imported_files = 0;
    foreach (MediaSource source in manifest.imported) {
        imported_files++;
        if (source is PhotoSource)
            imported_bytes += (int64) ((PhotoSource) source).get_master_filesize();
        else
            imported_bytes += (int64) source.get_filesize();
    }

    // RAW+JPEG pairs: the JPEG becomes the CAMERA development of the RAW, so it is not in
    // manifest.imported (and its size is not in imported_bytes), but it was copied.
    int64 associated_files = 0;
    foreach (MediaSource source in manifest.imported) {
        Photo? photo = source as Photo;
        if (photo != null && photo.get_master_file_format() == PhotoFileFormat.RAW
            && photo.is_raw_developer_available(RawDeveloper.CAMERA))
            associated_files++;
    }

    double wall = (end_us - start_us) / 1e6;
    int64 main_thread_us = 0;
    for (int i = 0; i < BenchCounters.Probe.COUNT; i++) {
        BenchCounters.Probe probe = (BenchCounters.Probe) i;
        if (probe.is_main_thread())
            main_thread_us += at_completion.total_us(probe);
    }

    exit_status = (failures == 0 && imported_files > 0
        && imported_files + associated_files == corpus_files) ? 0 : 1;

    StringBuilder json = new StringBuilder("{\n");
    json.append_printf("  \"benchmark\": \"shotwell-import\",\n");
    json.append_printf("  \"version\": %s,\n", escape(Resources.APP_VERSION));
    json.append_printf("  \"git_version\": %s,\n", escape(Resources.GIT_VERSION));
    json.append_printf("  \"source_dir\": %s,\n", escape(source_dir.get_path()));
    json.append_printf("  \"library_dir\": %s,\n", escape(AppDirs.get_import_dir().get_path()));
    json.append_printf("  \"threads\": %d,\n", (int) get_num_processors());
    json.append_printf("  \"import_workers\": %u,\n", Workers.thread_per_cpu_minus_one());
    json.append_printf("  \"default_raw_developer\": %s,\n",
        escape(Config.Facade.get_instance().get_default_raw_developer().to_string()));
    json.append_printf("  \"wall_s\": %.6f,\n", wall);
    json.append_printf("  \"first_imported_s\": %.6f,\n",
        first_imported_us >= 0 ? (first_imported_us - start_us) / 1e6 : -1.0);
    json.append_printf("  \"corpus_files\": %s,\n", corpus_files.to_string());
    json.append_printf("  \"corpus_bytes\": %s,\n", corpus_bytes.to_string());
    json.append_printf("  \"imported_files\": %s,\n", imported_files.to_string());
    json.append_printf("  \"associated_files\": %s,\n", associated_files.to_string());
    json.append_printf("  \"imported_bytes\": %s,\n", imported_bytes.to_string());
    json.append_printf("  \"imported_signals\": %s,\n", imported_signals.to_string());
    json.append_printf("  \"results\": { \"success\": %d, \"failed\": %d, \"camera_failed\": %d, "
        + "\"write_failed\": %d, \"skipped_photos\": %d, \"skipped_files\": %d, \"aborted\": %d, "
        + "\"already_imported\": %d, \"corrupt_files\": %d },\n", manifest.success.size,
        manifest.failed.size, manifest.camera_failed.size, manifest.write_failed.size,
        manifest.skipped_photos.size, manifest.skipped_files.size, manifest.aborted.size,
        manifest.already_imported.size, manifest.corrupt_files.size);
    json.append_printf("  \"failures\": %d,\n", failures);
    json.append_printf("  \"ok\": %s,\n", exit_status == 0 ? "true" : "false");
    json.append_printf("  \"throughput_mb_s\": %.3f,\n", wall > 0 ? corpus_bytes / wall / 1e6 : 0.0);
    json.append_printf("  \"main_thread_callbacks_s\": %.6f,\n", main_thread_us / 1e6);
    json.append_printf("  \"main_thread_busy_fraction\": %.4f,\n",
        wall > 0 ? main_thread_us / 1e6 / wall : 0.0);
    json.append_printf("  \"process_cpu_s\": { \"user\": %.3f, \"system\": %.3f },\n",
        cpu_user_end - cpu_user_start, cpu_sys_end - cpu_sys_start);
    json.append_printf("  \"peak_rss_mb\": %.1f,\n", rss_peak_kb / 1024.0);
    json.append_printf("  \"proc_self_io\": %s,\n", proc_io_json(proc_io_start, proc_io_end));
    json.append_printf("  \"counters\": %s,\n", at_completion.to_json(null, "  "));
    json.append_printf("  \"counters_after_completion\": %s\n", after_settle.to_json(at_completion, "  "));
    json.append("}\n");

    stdout.printf("%s", json.str);
    stdout.flush();

    if (exit_status != 0) {
        foreach (BatchImportResult result in manifest.all) {
            if (result.result != ImportResult.SUCCESS)
                printerr("benchmark: %s: %s %s\n", result.src_identifier, result.result.to_string(),
                    result.errmsg ?? "");
        }
        if (imported_files + associated_files != corpus_files)
            printerr("benchmark: %s files in %s, %s imported and %s attached as RAW+JPEG\n",
                corpus_files.to_string(), source_dir.get_path(), imported_files.to_string(),
                associated_files.to_string());
    }

    AppWindow.get_instance().close();

    return false;
}

}
