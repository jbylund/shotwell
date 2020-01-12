//
// The order of the background jobs is important, both for how feedback is presented to the user
// and to protect certain subsystems which don't work well in a multithreaded situation (i.e.
// gPhoto).
//
// 1. WorkSniffer builds a list of all the work to do.  If the BatchImportJob is a file, there's
// not much more to do.  If it represents a directory, the directory is traversed, with more work
// generated for each file.  Very little processing is done here on each file, however, and the
// BatchImportJob.prepare is only called when a directory.
//
// 2. PrepareFilesJob walks the list WorkSniffer generated, preparing each file and examining it
// for any obvious problems.  This in turn generates a list of prepared files (i.e. downloaded from
// camera).
//
// 3. Each file ready for importing is a separate background job.  It is responsible for copying
// the file (if required), examining it, and generating a pixbuf for preview and thumbnails.
//
private abstract class BackgroundImportJob : BackgroundJob {
    public ImportResult abort_flag = ImportResult.SUCCESS;
    public Gee.List<BatchImportResult> failed = new Gee.ArrayList<BatchImportResult>();
    protected BackgroundImportJob(BatchImport owner, CompletionCallback callback,
        Cancellable cancellable, CancellationCallback? cancellation) {
        base (owner, callback, cancellable, cancellation);
    }

    // Subclasses should call this every iteration, and if the result is not SUCCESS, consider the
    // operation (and therefore all after) aborted
    protected ImportResult abort_check() {
        if (abort_flag == ImportResult.SUCCESS && is_cancelled())
            abort_flag = ImportResult.USER_ABORT;
        return abort_flag;
    }

    protected void abort(ImportResult result) {
        // only update the abort flag if not already set
        if (abort_flag == ImportResult.SUCCESS)
            abort_flag = result;
    }

    protected void report_failure(BatchImportJob job, File? file, string src_identifier,
        string dest_identifier, ImportResult result) {
        assert(result != ImportResult.SUCCESS);
        // if fatal but the flag is not set, set it now
        if (result.is_abort())
            abort(result);
        else
            warning("Import failure %s: %s", src_identifier, result.to_string());
        failed.add(new BatchImportResult(job, file, src_identifier, dest_identifier, null, result));
    }

    protected void report_error(BatchImportJob job, File? file, string src_identifier,
        string dest_identifier, Error err, ImportResult default_result) {
        ImportResult result = ImportResult.convert_error(err, default_result);
        warning("Import error %s: %s (%s)", src_identifier, err.message, result.to_string());
        if (result.is_abort())
            abort(result);
        failed.add(new BatchImportResult.from_error(job, file, src_identifier, dest_identifier, err, default_result));
    }
}



private class WorkSniffer : BackgroundImportJob {
    public Gee.List<FileToPrepare> files_to_prepare = new Gee.ArrayList<FileToPrepare>();
    public uint64 total_bytes = 0;
    private Gee.Iterable<BatchImportJob> jobs;
    private Gee.HashSet<File>? skipset;

    public WorkSniffer(BatchImport owner, Gee.Iterable<BatchImportJob> jobs, CompletionCallback callback,
        Cancellable cancellable, CancellationCallback cancellation, Gee.HashSet<File>? skipset = null) {
        base (owner, callback, cancellable, cancellation);
        this.jobs = jobs;
        this.skipset = skipset;
        stderr.printf("Birth of a new worksniffer\n");
    }

    public override void execute() {
        stderr.printf("WorkSniffer.execute starting...\n");
        // walk the list of jobs accumulating work for the background jobs; if submitted job
        // is a directory, recurse into the directory picking up files to import (also creating
        // work for the background jobs)
        foreach (BatchImportJob job in jobs) {
            stderr.printf("WorkSniffer.execute starting a job...\n");
            ImportResult result = abort_check();
            if (result != ImportResult.SUCCESS) {
                report_failure(job, null, job.get_source_identifier(), job.get_dest_identifier(), result);
                continue;
            }
            try {
                sniff_job(job);
            } catch (Error err) {
                report_error(job, null, job.get_source_identifier(), job.get_dest_identifier(), err, ImportResult.FILE_ERROR);
            }
            if (is_cancelled())
                break;
        }

        stderr.printf("WorkSniffer.execute sorting...\n");
        // Time to handle RAW+JPEG pairs!
        // Now we build a new list of all the files (but not folders) we're
        // importing and sort it by filename.
        Gee.List<FileToPrepare> sorted = new Gee.ArrayList<FileToPrepare>();
        foreach (FileToPrepare file_to_prepare in files_to_prepare) {
            if (!file_to_prepare.is_directory())
                sorted.add(file_to_prepare);
        }
        sorted.sort((a, b) => {
            FileToPrepare file_a = (FileToPrepare) a;
            FileToPrepare file_b = (FileToPrepare) b;
            string sa = file_a.get_path();
            string sb = file_b.get_path();
            return utf8_cs_compare(sa, sb);
        });

        stderr.printf("WorkSniffer.execute pairing...\n");
        // For each file, check if the current file is RAW.  If so, check the previous
        // and next files to see if they're a "plus jpeg."
        for (int i = 0; i < sorted.size; ++i) {
            string name, ext;
            FileToPrepare file_to_prepare = sorted.get(i);
            disassemble_filename(file_to_prepare.get_basename(), out name, out ext);
            if (is_string_empty(ext))
                continue;
            if (RawFileFormatProperties.get_instance().is_recognized_extension(ext)) {
                // Got a raw file.  See if it has a pair.  If a pair is found, remove it
                // from the list and link it to the RAW file.
                if (i > 0 && is_paired(file_to_prepare, sorted.get(i - 1))) {
                    FileToPrepare associated_file = sorted.get(i - 1);
                    files_to_prepare.remove(associated_file);
                    file_to_prepare.set_associated(associated_file);
                } else if (i < sorted.size - 1 && is_paired(file_to_prepare, sorted.get(i + 1))) {
                    FileToPrepare associated_file = sorted.get(i + 1);
                    files_to_prepare.remove(associated_file);
                    file_to_prepare.set_associated(associated_file);
                }
            }
        }
        stderr.printf("WorkSniffer.execute done...\n");
    }

    // Check if a file is paired.  The raw file must be a raw photo.  A file
    // is "paired" if it has the same basename as the raw file, is in the same
    // directory, and is a JPEG.
    private bool is_paired(FileToPrepare raw, FileToPrepare maybe_paired) {
        if (raw.get_parent_path() != maybe_paired.get_parent_path())
            return false;
        string name, ext, test_name, test_ext;
        disassemble_filename(maybe_paired.get_basename(), out test_name, out test_ext);
        if (!JfifFileFormatProperties.get_instance().is_recognized_extension(test_ext))
            return false;
        disassemble_filename(raw.get_basename(), out name, out ext);
        return name == test_name;
    }

    private void sniff_job(BatchImportJob job) throws Error {
        stderr.printf("enter sniff_job...\n");
        uint64 size;
        File file_or_dir;
        bool determined_size = job.determine_file_size(out size, out file_or_dir);
        if (determined_size)
            total_bytes += size;
        if (job.is_directory()) {
            // safe to call job.prepare without it invoking extra I/O; this is merely a directory
            // to search
            File dir;
            bool copy_to_library;
            if (!job.prepare(out dir, out copy_to_library)) {
                report_failure(job, null, job.get_source_identifier(), job.get_dest_identifier(), ImportResult.FILE_ERROR);
                return;
            }
            assert(query_is_directory(dir));
            try {
                search_dir(job, dir, copy_to_library, job.recurse());
            } catch (Error err) {
                report_error(job, dir, job.get_source_identifier(), dir.get_path(), err, ImportResult.FILE_ERROR);
            }
        } else {
            // if did not get the file size, do so now
            if (!determined_size)
                total_bytes += query_total_file_size(file_or_dir, get_cancellable());
            // job is a direct file, so no need to search, prepare it directly
            if ((file_or_dir != null) && skipset != null && skipset.contains(file_or_dir))
                return;  /* do a short-circuit return and don't enqueue if this file is to be
                            skipped */
            files_to_prepare.add(new FileToPrepare(job));
        }
        stderr.printf("exit sniff_job...\n");
    }

    public void search_dir(BatchImportJob job, File dir, bool copy_to_library, bool recurse) throws Error {
        FileEnumerator enumerator = dir.enumerate_children("standard::*", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        FileInfo info = null;
        while ((info = enumerator.next_file(get_cancellable())) != null) {
            // next_file() doesn't always respect the cancellable
            if (is_cancelled())
                break;
            File child = dir.get_child(info.get_name());
            FileType file_type = info.get_file_type();
            if (file_type == FileType.DIRECTORY) {
                if (!recurse)
                    continue;
                if (info.get_name().has_prefix("."))
                    continue;
                try {
                    search_dir(job, child, copy_to_library, recurse);
                } catch (Error err) {
                    report_error(job, child, child.get_path(), child.get_path(), err,
                        ImportResult.FILE_ERROR);
                }
            } else if (file_type == FileType.REGULAR) {
                if ((skipset != null) && skipset.contains(child))
                    continue; /* don't enqueue if this file is to be skipped */
                if ((Photo.is_file_image(child) && PhotoFileFormat.is_file_supported(child)) ||
                    VideoReader.is_supported_video_file(child)) {
                    total_bytes += info.get_size();
                    files_to_prepare.add(new FileToPrepare(job, child, copy_to_library));
                    continue;
                }
            } else {
                warning("Ignoring import of %s file type %d", child.get_path(), (int) file_type);
            }
        }
    }
}

private class PrepareFilesJob : BackgroundImportJob {
    // Do not examine until the CompletionCallback has been called.
    public int prepared_files = 0;
    private Gee.List<FileToPrepare> files_to_prepare;
    private unowned NotificationCallback notification;
    private File library_dir;
    // these are for debugging and testing only
    private int import_file_count = 0;
    private int fail_every = 0;
    private int skip_every = 0;

    public PrepareFilesJob(
        BatchImport owner,
        Gee.List<FileToPrepare> files_to_prepare,
        NotificationCallback notification,
        CompletionCallback callback,
        Cancellable cancellable,
        CancellationCallback cancellation
    ) {
        base (owner, callback, cancellable, cancellation);
        this.files_to_prepare = files_to_prepare;
        this.notification = notification;
        library_dir = AppDirs.get_import_dir();
        fail_every = get_test_variable("SHOTWELL_FAIL_EVERY");
        skip_every = get_test_variable("SHOTWELL_SKIP_EVERY");
        set_notification_priority(Priority.LOW);
    }

    private static int get_test_variable(string name) {
        string value = Environment.get_variable(name);
        return (value == null || value.length == 0) ? 0 : int.parse(value);
    }

    public override void execute() {
        Timer timer = new Timer();
        stderr.printf("PrepareFileJob.execute starting...\n");
        Gee.ArrayList<PreparedFile> list = new Gee.ArrayList<PreparedFile>();
        foreach (FileToPrepare file_to_prepare in files_to_prepare) {
            ImportResult result = abort_check();
            if (result != ImportResult.SUCCESS) {
                report_failure(file_to_prepare.job, null, file_to_prepare.job.get_dest_identifier(), file_to_prepare.job.get_source_identifier(), result);
                continue;
            }
            BatchImportJob job = file_to_prepare.job;
            File? file = file_to_prepare.file;
            File? associated = file_to_prepare.associated != null ? file_to_prepare.associated.file : null;
            bool copy_to_library = file_to_prepare.copy_to_library;
            // if no file seen, then it needs to be offered/generated by the BatchImportJob
            if (file == null) {
                if (!create_file(job, out file, out copy_to_library))
                    continue;
            }
            if (associated == null && file_to_prepare.associated != null) {
                create_file(file_to_prepare.associated.job, out associated, out copy_to_library);
            }
            PreparedFile prepared_file;
            result = prepare_file(job, file, associated, copy_to_library, out prepared_file);
            if (result == ImportResult.SUCCESS) {
                prepared_files++;
                list.add(prepared_file);
            } else {
                report_failure(job, file, job.get_source_identifier(), file.get_path(), result);
            }
            if (
                list.size >= BatchImport.REPORT_EVERY_N_PREPARED_FILES ||
                (
                    (timer.elapsed() * 1000.0) > BatchImport.REPORT_PREPARED_FILES_EVERY_N_MSEC &&
                    list.size > 0
                )
            ) {
                PreparedFileCluster cluster = new PreparedFileCluster(list);
                list = new Gee.ArrayList<PreparedFile>();
                notify(notification, cluster);
                timer.start();
            }
        }
        if (list.size > 0) {
            ImportResult result = abort_check();
            if (result == ImportResult.SUCCESS) {
                notify(notification, new PreparedFileCluster(list));
            } else {
                // subtract these, as they are not being submitted
                assert(prepared_files >= list.size);
                prepared_files -= list.size;
                foreach (PreparedFile prepared_file in list) {
                    report_failure(prepared_file.job, prepared_file.file, prepared_file.job.get_source_identifier(), prepared_file.file.get_path(), result);
                }
            }
        }
        stderr.printf("PrepareFileJob.execute finished after %f...\n", timer.elapsed());
    }

    // If there's no file, call this function to get it from the batch import job.
    private bool create_file(BatchImportJob job, out File file, out bool copy_to_library) {
        try {
            if (!job.prepare(out file, out copy_to_library)) {
                report_failure(job, null, job.get_source_identifier(), job.get_dest_identifier(), ImportResult.FILE_ERROR);
                return false;
            }
        } catch (Error err) {
            report_error(job, null, job.get_source_identifier(), job.get_dest_identifier(), err, ImportResult.FILE_ERROR);
            return false;
        }
        return true;
    }

    private ImportResult prepare_file(
        BatchImportJob job,
        File file, File? associated_file,
        bool copy_to_library,
        out PreparedFile prepared_file
    ) {
        prepared_file = null;
        bool is_video = VideoReader.is_supported_video_file(file);
        if ((!is_video) && (!Photo.is_file_image(file)))
            return ImportResult.NOT_AN_IMAGE;
        if ((!is_video) && (!PhotoFileFormat.is_file_supported(file)))
            return ImportResult.UNSUPPORTED_FORMAT;
        import_file_count++;

        // test case (can be set with SHOTWELL_FAIL_EVERY environment variable)
        if (fail_every > 0) {
            if (import_file_count % fail_every == 0)
                return ImportResult.FILE_ERROR;
        }

        // test case (can be set with SHOTWELL_SKIP_EVERY environment variable)
        if (skip_every > 0) {
            if (import_file_count % skip_every == 0)
                return ImportResult.NOT_A_FILE;
        }

        string exif_only_md5 = null;
        string thumbnail_md5 = null;
        string full_md5 = null;
        try {
            full_md5 = md5_file(file);
        } catch (Error err) {
            warning("Unable to perform MD5 checksum on file %s: %s", file.get_path(), err.message);
            return ImportResult.convert_error(err, ImportResult.FILE_ERROR);
        }
        // we only care about file extensions and metadata if we're importing a photo --
        // we don't care about these things for video
        PhotoFileFormat file_format = PhotoFileFormat.get_by_file_extension(file);
        if (!is_video) {
            if (file_format == PhotoFileFormat.UNKNOWN) {
                warning("Skipping %s: unrecognized file extension", file.get_path());
                return ImportResult.UNSUPPORTED_FORMAT;
            }
            PhotoFileReader reader = file_format.create_reader(file.get_path());
            PhotoMetadata? metadata = null;
            try {
                metadata = reader.read_metadata();
            } catch (Error err) {
                warning("Unable to read metadata for %s (%s): continuing to attempt import", file.get_path(), err.message);
            }
            if (metadata != null) {
                exif_only_md5 = metadata.exif_hash ();
                thumbnail_md5 = metadata.thumbnail_hash();
            }
        }
        uint64 filesize = 0;
        try {
            filesize = query_total_file_size(file, get_cancellable());
        } catch (Error err) {
            warning("Unable to query file size of %s: %s", file.get_path(), err.message);
            return ImportResult.convert_error(err, ImportResult.FILE_ERROR);
        }
        // never copy file if already in library directory
        bool is_in_library_dir = file.has_prefix(library_dir);
        // notify the BatchImport this is ready to go
        prepared_file = new PreparedFile(
            job,
            file,
            associated_file,
            job.get_source_identifier(),
            job.get_dest_identifier(),
            copy_to_library && !is_in_library_dir,
            exif_only_md5,
            thumbnail_md5,
            full_md5,
            file_format,
            filesize,
            is_video
        );
        return ImportResult.SUCCESS;
    }
}

private class ThumbnailWriterJob : BackgroundImportJob {
    public CompletedImportObject completed_import_source;

    public ThumbnailWriterJob(
        BatchImport owner,
        CompletedImportObject completed_import_source,
        CompletionCallback callback,
        Cancellable cancellable,
        CancellationCallback cancel_callback
    ) {
        base (owner, callback, cancellable, cancel_callback);
        assert(completed_import_source.thumbnails != null);
        this.completed_import_source = completed_import_source;
        set_completion_priority(Priority.LOW);
    }

    public override void execute() {
        try {
            ThumbnailCache.import_thumbnails(completed_import_source.source, completed_import_source.thumbnails, true);
            completed_import_source.batch_result.result = ImportResult.SUCCESS;
        } catch (Error err) {
            completed_import_source.batch_result.result = ImportResult.convert_error(err, ImportResult.FILE_ERROR);
        }
        // destroy the thumbnails (but not the user preview) to free up memory
        completed_import_source.thumbnails = null;
    }
}
