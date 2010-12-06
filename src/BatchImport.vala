/* Copyright 2009-2010 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

// A BatchImportJob describes a unit of work the BatchImport object should perform.  It returns
// a file to be imported.  If the file is a directory, it is automatically recursed by BatchImport
// to find all files that need to be imported into the library.
//
// NOTE: All methods may be called from the context of a background thread or the main GTK thread.
// Implementations should be able to handle either situation.  The prepare method will always be
// called by the same thread context.
public abstract class BatchImportJob {
    public abstract string get_identifier();
    
    public abstract bool is_directory();
    
    // Returns the file size of the BatchImportJob or returns a file/directory which can be queried
    // by BatchImportJob to determine it.  Returns true if the size is return, false if the File is
    // specified.
    // 
    // filesize should only be returned if BatchImportJob represents a single file.
    public abstract bool determine_file_size(out uint64 filesize, out File file_or_dir);
    
    public abstract bool prepare(out File file_to_import, out bool copy_to_library) throws Error;
    
    // Completes the import for the new library photo once it's been imported.
    // If the job is directory based, this method will be called for each photo
    // discovered in the directory. This method is only called for photographs
    // that have been successfully imported.
    //
    // Returns true if any action was taken, false otherwise.
    public virtual bool complete(MediaSource source, ViewCollection generated_events) throws Error {
        return false;
    }
    
    // returns a non-zero time_t value if this has a valid exposure time override, returns zero
    // otherwise
    public virtual time_t get_exposure_time_override() {
        return 0;
    }
}

public class FileImportJob : BatchImportJob {
    private File file_or_dir;
    private bool copy_to_library;
    
    public FileImportJob(File file_or_dir, bool copy_to_library) {
        this.file_or_dir = file_or_dir;
        this.copy_to_library = copy_to_library;
    }
    
    public override string get_identifier() {
        return file_or_dir.get_path();
    }
    
    public override bool is_directory() {
        return query_is_directory(file_or_dir);
    }
    
    public override bool determine_file_size(out uint64 filesize, out File file) {
        file = file_or_dir;
        
        return false;
    }
    
    public override bool prepare(out File file_to_import, out bool copy) {
        file_to_import = file_or_dir;
        copy = copy_to_library;
        
        return true;
    }
    
    public File get_file() {
        return file_or_dir;
    }
}

// A BatchImportRoll represents important state for a group of imported media.  If this is shared
// among multiple BatchImport objects, the imported media will appear to have been imported all at
// once.
public class BatchImportRoll {
    public ImportID import_id;
    public ViewCollection generated_events = new ViewCollection("BatchImportRoll generated events");
    
    public BatchImportRoll() {
        this.import_id = ImportID.generate();
    }
}

// A BatchImportResult associates a particular job with a File that an import was performed on
// and the import result.  A BatchImportJob can specify multiple files, so there is not necessarily
// a one-to-one relationship beteen it and this object.
//
// Note that job may be null (in the case of a pre-failed job that must be reported) and file may
// be null (for similar reasons).
public class BatchImportResult {
    public BatchImportJob job;
    public File? file;
    public string identifier;
    public ImportResult result;
    public string? errmsg = null;
    
    public BatchImportResult(BatchImportJob job, File? file, string identifier, ImportResult result) {
        this.job = job;
        this.file = file;
        this.identifier = identifier;
        this.result = result;
    }
    
    public BatchImportResult.from_error(BatchImportJob job, File? file, string identifier,
        Error err, ImportResult default_result) {
        this.job = job;
        this.file = file;
        this.identifier = identifier;
        this.result = ImportResult.convert_error(err, default_result);
        this.errmsg = err.message;
    }
}

public class ImportManifest {
    public Gee.List<MediaSource> imported = new Gee.ArrayList<MediaSource>();
    public Gee.List<BatchImportResult> success = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> camera_failed = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> failed = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> skipped_photos = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> skipped_files = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> aborted = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> already_imported = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> all = new Gee.ArrayList<BatchImportResult>();
    
    public ImportManifest(Gee.List<BatchImportJob>? prefailed = null,
        Gee.List<BatchImportJob>? pre_already_imported = null) {
        if (prefailed != null) {
            foreach (BatchImportJob job in prefailed) {
                BatchImportResult batch_result = new BatchImportResult(job, null, job.get_identifier(), 
                    ImportResult.FILE_ERROR);
                add_result(batch_result);
            }
        }
        
        if (pre_already_imported != null) {
            foreach (BatchImportJob job in pre_already_imported) {
                BatchImportResult batch_result = new BatchImportResult(job, null, job.get_identifier(),
                    ImportResult.PHOTO_EXISTS);
                add_result(batch_result);
            }
        }
    }
    
    public void add_result(BatchImportResult batch_result) {
        bool reported = true;
        switch (batch_result.result) {
            case ImportResult.SUCCESS:
                success.add(batch_result);
            break;

            case ImportResult.USER_ABORT:
                if (batch_result.file != null && !query_is_directory(batch_result.file))
                    aborted.add(batch_result);
                else
                    reported = false;
            break;

            case ImportResult.UNSUPPORTED_FORMAT:
                skipped_photos.add(batch_result);
            break;

            case ImportResult.NOT_A_FILE:
            case ImportResult.NOT_AN_IMAGE:
                skipped_files.add(batch_result);
            break;
            
            case ImportResult.PHOTO_EXISTS:
                already_imported.add(batch_result);
            break;
            
            case ImportResult.CAMERA_ERROR:
                camera_failed.add(batch_result);
            break;
            
            default:
                failed.add(batch_result);
            break;
        }
        
        if (reported)
            all.add(batch_result);
    }
}

// BatchImport performs the work of taking a file (supplied by BatchImportJob's) and properly importing
// it into the system, including database additions and thumbnail creation.  It can be monitored by
// multiple observers, but only one ImportReporter can be registered.
//
// TODO: With background threads. the better way to implement this is via a FSM (finite state 
// machine) that exists in states and responds to various events thrown off by the background
// jobs.  However, getting this code to a point that it works with threads is task enough, so it
// will have to wait (especially since we'll want to write a generic FSM engine).
public class BatchImport : Object {
    private const int WORK_SNIFFER_THROBBER_MSEC = 125;
    
    public const int REPORT_EVERY_N_PREPARED_FILES = 100;
    public const int REPORT_PREPARED_FILES_EVERY_N_MSEC = 3000;
    
    private const int READY_SOURCES_COUNT_OVERFLOW = 10;
    
    private const int DISPLAY_QUEUE_TIMER_MSEC = 125;
    private const int DISPLAY_QUEUE_HYSTERESIS_OVERFLOW = (3 * 1000) / DISPLAY_QUEUE_TIMER_MSEC;
    
    private static Workers feeder_workers = new Workers(1, false);
    private static Workers import_workers = new Workers(Workers.thread_per_cpu_minus_one(), false);
    
    private Gee.Iterable<BatchImportJob> jobs;
    private BatchImportRoll import_roll;
    private string name;
    private uint64 completed_bytes = 0;
    private uint64 total_bytes = 0;
    private ImportReporter reporter;
    private ImportManifest manifest;
    private bool scheduled = false;
    private bool completed = false;
    private int file_imports_to_perform = -1;
    private int file_imports_completed = 0;
    private Cancellable? cancellable = null;
    private ulong last_preparing_ms = 0;
    private Gee.HashSet<File> skipset;
#if !NO_DUPE_DETECTION
    private Gee.MultiMap<string, PhotoFileFormat> imported_thumbnail_md5 =
        new Gee.HashMultiMap<string, PhotoFileFormat>();
    private Gee.MultiMap<string, PhotoFileFormat> imported_full_md5 =
        new Gee.HashMultiMap<string, PhotoFileFormat>();
#endif
    private uint throbber_id = 0;
    private int max_outstanding_import_jobs = Workers.thread_per_cpu_minus_one();
    
    // These queues are staging queues, holding batches of work that must happen in the import
    // process, working on them all at once to minimize overhead.
    private Gee.List<PreparedFile> ready_files = new Gee.LinkedList<PreparedFile>();
    private Gee.List<CompletedImportObject> ready_thumbnails =
        new Gee.LinkedList<CompletedImportObject>();
    private Gee.List<CompletedImportObject> display_imported_queue =
        new Gee.LinkedList<CompletedImportObject>();
    private Gee.List<MediaSource> ready_sources = new Gee.LinkedList<MediaSource>();
    
    // Called at the end of the batched jobs.  Can be used to report the result of the import
    // to the user.  This is called BEFORE import_complete is fired.
    public delegate void ImportReporter(ImportManifest manifest, BatchImportRoll import_roll);
    
    // Called once, when the scheduled task begins
    public signal void starting();
    
    // Called repeatedly while preparing the launched BatchImport
    public signal void preparing();
    
    // Called repeatedly to report the progress of the BatchImport (but only called after the
    // last "preparing" signal)
    public signal void progress(uint64 completed_bytes, uint64 total_bytes);
    
    // Called for each Photo or Video imported to the system. For photos, the pixbuf is
    // screen-sized and rotated. For videos, the pixbuf is a frame-grab of the first frame.
    //
    // The to_follow number is the number of queued-up sources to expect following this signal
    // in one burst.
    public signal void imported(MediaSource source, Gdk.Pixbuf pixbuf, int to_follow);
    
    // Called when a fatal error occurs that stops the import entirely.  Remaining jobs will be
    // failed and import_complete() is still fired.
    public signal void fatal_error(ImportResult result, string message);
    
    // Called when a job fails.  import_complete will also be called at the end of the batch
    public signal void import_job_failed(BatchImportResult result);
    
    // Called at the end of the batched jobs; this will be signalled exactly once for the batch
    public signal void import_complete(ImportManifest manifest, BatchImportRoll import_roll);

    public BatchImport(Gee.Iterable<BatchImportJob> jobs, string name, ImportReporter? reporter,
        Gee.ArrayList<BatchImportJob>? prefailed = null,
        Gee.ArrayList<BatchImportJob>? pre_already_imported = null,
        Cancellable? cancellable = null, BatchImportRoll? import_roll = null,
        ImportManifest? skip_manifest = null) {
        this.jobs = jobs;
        this.name = name;
        this.reporter = reporter;
        this.manifest = new ImportManifest(prefailed, pre_already_imported);
        this.cancellable = (cancellable != null) ? cancellable : new Cancellable();
        this.import_roll = import_roll != null ? import_roll : new BatchImportRoll();
        
        if (skip_manifest != null) {
            skipset = new Gee.HashSet<File>(file_hash, file_equal);
            foreach (MediaSource source in skip_manifest.imported) {
                skipset.add(source.get_file());
            }
        }
        
        // watch for user exit in the application
        Application.get_instance().exiting.connect(user_halt);
        
        // Use a timer to report imported photos to observers
        Timeout.add(DISPLAY_QUEUE_TIMER_MSEC, display_imported_timer);
    }
    
    ~BatchImport() {
#if TRACE_DTORS
        debug("DTOR: BatchImport (%s)", name);
#endif
        Application.get_instance().exiting.disconnect(user_halt);
    }
    
    public string get_name() {
        return name;
    }
    
    public void user_halt() {
        cancellable.cancel();
    }
    
    private void log_status(string where) {
#if TRACE_IMPORT
        debug("%s: to_perform=%d completed=%d ready_files=%d ready_thumbnails=%d display_queue=%d ready_sources=%d",
            where, file_imports_to_perform, file_imports_completed, ready_files.size,
            ready_thumbnails.size, display_imported_queue.size, ready_sources.size);
        debug("%s workers: feeder=%d import=%d", where, feeder_workers.get_pending_job_count(),
            import_workers.get_pending_job_count());
#endif
    }
    
    private bool report_failure(BatchImportResult import_result) {
        bool proceed = true;
        
        manifest.add_result(import_result);
        
        if (import_result.result != ImportResult.SUCCESS) {
            import_job_failed(import_result);
            
            if (import_result.file != null && !import_result.result.is_abort()) {
                uint64 filesize = 0;
                try {
                    // A BatchImportResult file is guaranteed to be a single file
                    filesize = query_total_file_size(import_result.file);
                } catch (Error err) {
                    warning("Unable to query file size of %s: %s", import_result.file.get_path(),
                        err.message);
                }
                
                report_progress(filesize);
            }
        }
        
        // fire this signal only once, and only on non-user aborts
        if (import_result.result.is_nonuser_abort() && proceed) {
            fatal_error(import_result.result, import_result.errmsg);
            proceed = false;
        }
        
        return proceed;
    }
    
    private void report_progress(uint64 increment_of_progress) {
        completed_bytes += increment_of_progress;
        
        // only report "progress" if progress has been made (and enough time has progressed),
        // otherwise still preparing
        if (completed_bytes == 0) {
            ulong now = now_ms();
            if (now - last_preparing_ms > 250) {
                last_preparing_ms = now;
                preparing();
            }
        } else if (increment_of_progress > 0) {
            ulong now = now_ms();
            if (now - last_preparing_ms > 250) {
                last_preparing_ms = now;
                progress(completed_bytes, total_bytes);
            }
        }
    }
    
    private bool report_failures(BackgroundImportJob background_job) {
        bool proceed = true;
        
        foreach (BatchImportResult import_result in background_job.failed) {
            if (!report_failure(import_result))
                proceed = false;
        }
        
        return proceed;
    }
    
    private void report_completed(string where) {
        if (completed)
            error("Attempted to complete already-completed import: %s", where);
        
        completed = true;
        
        flush_ready_sources();
        
        log_status("Import completed: %s".printf(where));
        
        // report completed to the reporter (called prior to the "import_complete" signal)
        if (reporter != null)
            reporter(manifest, import_roll);
        
        import_complete(manifest, import_roll);
        
        // resume the MimicManager
        LibraryPhoto.mimic_manager.resume();
    }
    
    // This should be called whenever a file's import process is complete, successful or otherwise
    private void file_import_complete() {
        // mark this job as completed
        file_imports_completed++;
        if (file_imports_to_perform != -1)
            assert(file_imports_completed <= file_imports_to_perform);
        
        // because notifications can come in after completions, have to watch if this is the
        // last file
        if (file_imports_to_perform != -1 && file_imports_completed == file_imports_to_perform)
            report_completed("completed preparing files, all outstanding imports completed");
    }
    
    public void schedule() {
        assert(scheduled == false);
        scheduled = true;
        
        // halt the MimicManager will performing import, as it will drag the system down
        LibraryPhoto.mimic_manager.pause();
        
        starting();
        
        // fire off a background job to generate all FileToPrepare work
        feeder_workers.enqueue(new WorkSniffer(this, jobs, on_work_sniffed_out, cancellable,
            on_sniffer_cancelled, skipset));
        throbber_id = Timeout.add(WORK_SNIFFER_THROBBER_MSEC, on_sniffer_working);
    }
    
    //
    // WorkSniffer stage
    //
    
    private bool on_sniffer_working() {
        report_progress(0);
        
        return true;
    }
    
    private void on_work_sniffed_out(BackgroundJob j) {
        assert(!completed);
        
        WorkSniffer sniffer = (WorkSniffer) j;
        
        log_status("on_work_sniffed_out");
        
        if (!report_failures(sniffer) || sniffer.files_to_prepare.size == 0) {
            report_completed("work sniffed out: nothing to do");
            
            return;
        }
        
        total_bytes = sniffer.total_bytes;
        
        // submit single background job to go out and prepare all the files, reporting back when/if
        // they're ready for import; this is important because gPhoto can't handle multiple accesses
        // to a camera without fat locking, and it's just not worth it.  Serializing the imports
        // also means the user sees the photos coming in in (roughly) the order they selected them
        // on the screen
        PrepareFilesJob prepare_files_job = new PrepareFilesJob(this, sniffer.files_to_prepare, 
            on_file_prepared, on_files_prepared, cancellable, on_file_prepare_cancelled);
        
        feeder_workers.enqueue(prepare_files_job);
        
        if (throbber_id > 0) {
            Source.remove(throbber_id);
            throbber_id = 0;
        }
    }
    
    private void on_sniffer_cancelled(BackgroundJob j) {
        assert(!completed);
        
        WorkSniffer sniffer = (WorkSniffer) j;
        
        log_status("on_sniffer_cancelled");
        
        report_failures(sniffer);
        report_completed("work sniffer cancelled");
        
        if (throbber_id > 0) {
            Source.remove(throbber_id);
            throbber_id = 0;
        }
    }
    
    //
    // PrepareFiles stage
    //
    
    private void flush_import_jobs() {
        // flush ready thumbnails before ready files because PreparedFileImportJob is more intense
        // than ThumbnailWriterJob; reversing this order causes work to back up in ready_thumbnails
        // and takes longer for the user to see progress (which is only reported after the thumbnail
        // has been written)
        while (ready_thumbnails.size > 0 && import_workers.get_pending_job_count() < max_outstanding_import_jobs) {
            import_workers.enqueue(new ThumbnailWriterJob(this, ready_thumbnails.remove_at(0),
                on_thumbnail_writer_completed, cancellable, on_thumbnail_writer_cancelled));
        }
        
        while(ready_files.size > 0 && import_workers.get_pending_job_count() < max_outstanding_import_jobs) {
            import_workers.enqueue(new PreparedFileImportJob(this, ready_files.remove_at(0),
                import_roll.import_id, on_import_files_completed, cancellable,
                on_import_files_cancelled));
        }
    }
    
    // This checks for duplicates in the current import batch, which may not already be in the
    // library and therefore not detected there.
    private bool is_in_current_import(PreparedFile prepared_file) {
#if !NO_DUPE_DETECTION
        if (prepared_file.thumbnail_md5 != null
            && imported_thumbnail_md5.contains(prepared_file.thumbnail_md5)) {
            foreach (PhotoFileFormat file_format in imported_thumbnail_md5.get(prepared_file.thumbnail_md5)) {
                if (file_format == prepared_file.file_format) {
                    debug("Not importing %s: thumbnail match detected in import set",
                        prepared_file.file.get_path());
                    
                    return true;
                }
            }
        }
        
        if (prepared_file.full_md5 != null
            && imported_full_md5.contains(prepared_file.full_md5)) {
            foreach (PhotoFileFormat file_format in imported_full_md5.get(prepared_file.full_md5)) {
                if (file_format == prepared_file.file_format) {
                    debug("Not importing %s: full match detected in import set",
                        prepared_file.file.get_path());
                    
                    return true;
                }
            }
        }
        
        // add for next one
        if (prepared_file.thumbnail_md5 != null)
            imported_thumbnail_md5.set(prepared_file.thumbnail_md5, prepared_file.file_format);
        
        if (prepared_file.full_md5 != null)
            imported_full_md5.set(prepared_file.full_md5, prepared_file.file_format);
#endif
        return false;
    }
    
    // Called when a cluster of files are located and deemed proper for import by PrepareFiledJob
    private void on_file_prepared(BackgroundJob j, NotificationObject? user) {
        assert(!completed);
        
        PreparedFileCluster cluster = (PreparedFileCluster) user;
        
        log_status("on_file_prepared (%d files)".printf(cluster.list.size));
        
        process_prepared_files.begin(cluster.list);
    }
    
    private async void process_prepared_files(Gee.List<PreparedFile> list) {
        foreach (PreparedFile prepared_file in list) {
            Idle.add(process_prepared_files.callback);
            yield;
            
            BatchImportResult import_result = null;
            
            if (prepared_file.is_video && Video.is_duplicate(prepared_file.file, prepared_file.full_md5)) {
                import_result = new BatchImportResult(prepared_file.job, prepared_file.file, 
                    prepared_file.file.get_path(), ImportResult.PHOTO_EXISTS);
            }
            
            if (Photo.is_duplicate(prepared_file.file, prepared_file.thumbnail_md5,
                prepared_file.full_md5, prepared_file.file_format)) {
                // If a file is being linked and has a dupe in the trash, we take it out of the trash
                // and revert its edits.
                LibraryPhoto photo = LibraryPhoto.global.get_trashed_by_file(prepared_file.file);
                
                if (photo == null && prepared_file.full_md5 != null)
                    photo = LibraryPhoto.global.get_trashed_by_md5(prepared_file.full_md5);
                
                if (photo != null) {
                    debug("duplicate linked photo found in trash, untrashing and removing" + 
                            " transforms for %s", prepared_file.file.get_path());
                    
                    photo.untrash();
                    photo.remove_all_transformations();
                    
                    import_result = new BatchImportResult(prepared_file.job, prepared_file.file,
                        prepared_file.file.get_path(), ImportResult.SUCCESS);
                    
                    report_progress(photo.get_filesize());
                    file_import_complete();
                    
                    continue;
                }
                
                // Photos with duplicates that exist outside of the trash are marked as already existing
                if (LibraryPhoto.has_nontrash_duplicate(prepared_file.file,
                    prepared_file.thumbnail_md5, prepared_file.full_md5, prepared_file.file_format)) {
                    debug("duplicate photo detected outside of trash, not importing %s",
                        prepared_file.file.get_path());
                    
                    import_result = new BatchImportResult(prepared_file.job, prepared_file.file, 
                        prepared_file.file.get_path(), ImportResult.PHOTO_EXISTS);
                }
            } else if (is_in_current_import(prepared_file)) {
                // this looks for duplicates within the import set, since Photo.is_duplicate
                // only looks within already-imported photos for dupes
                import_result = new BatchImportResult(prepared_file.job, prepared_file.file,
                    prepared_file.file.get_path(), ImportResult.PHOTO_EXISTS);
            }
            
            if (import_result != null) {
                report_failure(import_result);
                file_import_complete();
                
                continue;
            }
            
            report_progress(0);
            
            ready_files.add(prepared_file);
        }
        
        flush_import_jobs();
    }
    
    private void done_preparing_files(BackgroundJob j, string caller) {
        assert(!completed);
        
        PrepareFilesJob prepare_files_job = (PrepareFilesJob) j;
        
        report_failures(prepare_files_job);
        
        // mark this job as completed and record how many file imports must finish to be complete
        file_imports_to_perform = prepare_files_job.prepared_files;
        assert(file_imports_to_perform >= file_imports_completed);
        
        log_status(caller);
        
        // this call can result in report_completed() being called, so don't call twice
        flush_import_jobs();
        
        // if none prepared, then none outstanding (or will become outstanding, depending on how
        // the notifications are queued)
        if (file_imports_to_perform == 0 && !completed)
            report_completed("no files prepared for import");
        else if (file_imports_completed == file_imports_to_perform && !completed)
            report_completed("completed preparing files, all outstanding imports completed");
    }
    
    private void on_files_prepared(BackgroundJob j) {
        done_preparing_files(j, "on_files_prepared");
    }
    
    private void on_file_prepare_cancelled(BackgroundJob j) {
        done_preparing_files(j, "on_file_prepare_cancelled");
    }
    
    //
    // Files ready for import stage
    //
    
    private void on_import_files_completed(BackgroundJob j) {
        assert(!completed);
        
        PreparedFileImportJob job = (PreparedFileImportJob) j;
        
        log_status("on_import_files_completed");
        
        // should be ready in some form
        assert(job.not_ready == null);
        
        // mark failed photo
        if (job.failed != null) {
            assert(job.failed.result != ImportResult.SUCCESS);
            
            report_failure(job.failed);
            file_import_complete();
        }
        
        // resurrect ready photos before adding to database and rest of system ... this is more
        // efficient than doing them one at a time
        if (job.ready != null) {
            assert(job.ready.batch_result.result == ImportResult.SUCCESS);
            
            Tombstone? tombstone = Tombstone.global.locate(job.ready.final_file,
                job.ready.prepared_file.full_md5);
            if (tombstone != null)
                Tombstone.global.resurrect(tombstone);
        
            // import ready photos into database
            MediaSource? source = null;
            if (job.ready.is_video) {
                job.ready.batch_result.result = Video.import_create(job.ready.video_import_params,
                    out source);
            } else {
                job.ready.batch_result.result = LibraryPhoto.import_create(job.ready.photo_import_params,
                    out source);
            }
            
            if (job.ready.batch_result.result != ImportResult.SUCCESS) {
                debug("on_import_file_completed: %s", job.ready.batch_result.result.to_string());
                
                report_failure(job.ready.batch_result);
                file_import_complete();
            } else {
                // complete the import job
                PreparedFile src_prepared_file = job.ready.prepared_file;
                BatchImportJob src_job = src_prepared_file.job;
                try {
                    src_job.complete(source, import_roll.generated_events);
                } catch(Error e) {
                    // TODO: improve failure handling to report it properly
                    warning("Could not complete import job: %s", e.message);
                }
                
                // TODO: should this be inside the try/catch statement to only
                // be called if the completion is successful?
                ready_thumbnails.add(new CompletedImportObject(source, job.ready.get_thumbnails(),
                    job.ready.batch_result));
            }
        }
        
        flush_import_jobs();
    }
    
    private void on_import_files_cancelled(BackgroundJob j) {
        assert(!completed);
        
        PreparedFileImportJob job = (PreparedFileImportJob) j;
        
        log_status("on_import_files_cancelled");
        
        if (job.not_ready != null) {
            report_failure(new BatchImportResult(job.not_ready.job, job.not_ready.file,
                job.not_ready.file.get_path(), ImportResult.USER_ABORT));
            file_import_complete();
        }
        
        if (job.failed != null) {
            report_failure(job.failed);
            file_import_complete();
        }
        
        if (job.ready != null) {
            report_failure(job.ready.abort());
            file_import_complete();
        }
        
        flush_import_jobs();
    }
    
    //
    // ThumbnailWriter stage
    //
    // Because the LibraryPhoto has been created at this stage, any cancelled work must also
    // destroy the LibraryPhoto.
    //
    
    private void on_thumbnail_writer_completed(BackgroundJob j) {
        assert(!completed);
        
        ThumbnailWriterJob job = (ThumbnailWriterJob) j;
        CompletedImportObject completed = job.completed_import_source;
        
        log_status("on_thumbnail_writer_completed");
        
        if (completed.batch_result.result != ImportResult.SUCCESS) {
            warning("Failed to import %s: unable to write thumbnails (%s)",
                completed.source.to_string(), completed.batch_result.result.to_string());
            
            if (completed.source is LibraryPhoto)
                LibraryPhoto.import_failed(completed.source as LibraryPhoto);
            else if (completed.source is Video)
                Video.import_failed(completed.source as Video);

            report_failure(completed.batch_result);
            file_import_complete();
        } else {
            manifest.imported.add(completed.source as MediaSource);
            manifest.add_result(completed.batch_result);
            
            display_imported_queue.add(completed);
        }
        
        flush_import_jobs();
    }
    
    private void on_thumbnail_writer_cancelled(BackgroundJob j) {
        assert(!completed);
        
        ThumbnailWriterJob job = (ThumbnailWriterJob) j;
        CompletedImportObject completed = job.completed_import_source;
        
        log_status("on_thumbnail_writer_cancelled");
        
        if (completed.source is LibraryPhoto)
            LibraryPhoto.import_failed(completed.source as LibraryPhoto);
        else if (completed.source is Video)
            Video.import_failed(completed.source as Video);

        report_failure(completed.batch_result);
        file_import_complete();
        
        flush_import_jobs();
    }
    
    //
    // Display imported sources and integrate into system
    //
    
    private void flush_ready_sources() {
        if (ready_sources.size == 0)
            return;
        
        log_status("flush_ready_sources (%d)".printf(ready_sources.size));
        
        Gee.ArrayList<LibraryPhoto> photos = null;
        Gee.ArrayList<Video> videos = null;
        foreach (MediaSource source in ready_sources) {
            LibraryPhoto? photo = source as LibraryPhoto;
            if (photo != null) {
                if (photos == null)
                    photos = new Gee.ArrayList<LibraryPhoto>();
                
                photos.add(photo);
                
                continue;
            }
            
            Video? video = source as Video;
            assert(video != null);
            
            if (videos == null)
                videos = new Gee.ArrayList<Video>();
            
            videos.add(video);
        }
        
        MediaCollectionRegistry.get_instance().freeze_all();
        
        if (photos != null)
            LibraryPhoto.global.add_many(photos);
        
        if (videos != null)
            Video.global.add_many(videos);
        
        Event.generate_many_events(ready_sources, import_roll.generated_events);
        
        MediaCollectionRegistry.get_instance().thaw_all();
        
        ready_sources.clear();
    }
    
    // This is called throughout the import process to notify watchers of imported photos in such
    // a way that the GTK event queue gets a chance to operate.
    private bool display_imported_timer() {
        if (display_imported_queue.size == 0)
            return !completed;
        
        if (cancellable.is_cancelled())
            debug("Importing %d photos at once", display_imported_queue.size);
        
        log_status("display_imported_timer");
        
        // only display one at a time, so the user can see them come into the library in order.
        // however, if the queue backs up to the hysteresis point (currently defined as more than
        // 3 seconds wait for the last photo on the queue), then begin doing them in increasingly
        // larger chunks, to stop the queue from growing and then to get ahead of the other
        // import cycles.
        //
        // if cancelled, want to do as many as possible, but want to relinquish the thread to
        // keep the system active
        int total = 1;
        if (!cancellable.is_cancelled()) {
            if (display_imported_queue.size > DISPLAY_QUEUE_HYSTERESIS_OVERFLOW)
                total = 
                    1 << ((display_imported_queue.size / DISPLAY_QUEUE_HYSTERESIS_OVERFLOW) + 2).clamp(0, 16);
        } else {
            // do in overflow-sized chunks
            total = DISPLAY_QUEUE_HYSTERESIS_OVERFLOW;
        }
        
        total = int.min(total, display_imported_queue.size);
        
#if TRACE_IMPORT
        if (total > 1) {
            debug("DISPLAY IMPORT QUEUE: hysteresis, dumping %d/%d media sources", total,
                display_imported_queue.size);
        }
#endif
        
        // post-decrement because the 0-based total is used when firing "imported"
        while (total-- > 0) {
            CompletedImportObject completed_object = display_imported_queue.remove_at(0);
            
            // Stage the number of ready media objects to incorporate into the system rather than
            // doing them one at a time, to keep the UI thread responsive.
            ready_sources.add(completed_object.source);
            
            imported(completed_object.source, completed_object.user_preview, total);
            report_progress(completed_object.source.get_filesize());
            file_import_complete();
        }
        
        if (ready_sources.size >= READY_SOURCES_COUNT_OVERFLOW || cancellable.is_cancelled())
            flush_ready_sources();
        
        return true;
    }
}

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
    
    protected void report_failure(BatchImportJob job, File? file, string identifier, 
        ImportResult result) {
        assert(result != ImportResult.SUCCESS);
        
        // if fatal but the flag is not set, set it now
        if (result.is_abort())
            abort(result);
        else
            debug("Import failure %s: %s", identifier, result.to_string());
        
        failed.add(new BatchImportResult(job, file, identifier, result));
    }
    
    protected void report_error(BatchImportJob job, File? file, string identifier,
        Error err, ImportResult default_result) {
        ImportResult result = ImportResult.convert_error(err, default_result);
        
        debug("Import error %s: %s (%s)", identifier, err.message, result.to_string());
        
        if (result.is_abort())
            abort(result);
        
        failed.add(new BatchImportResult.from_error(job, file, identifier, err, default_result));
    }
}

private class FileToPrepare {
    public BatchImportJob job;
    public File? file;
    public bool copy_to_library;
    
    public FileToPrepare(BatchImportJob job, File? file = null, bool copy_to_library = true) {
        this.job = job;
        this.file = file;
        this.copy_to_library = copy_to_library;
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
    }
    
    public override void execute() {
        // walk the list of jobs accumulating work for the background jobs; if submitted job
        // is a directory, recurse into the directory picking up files to import (also creating
        // work for the background jobs)
        foreach (BatchImportJob job in jobs) {
            ImportResult result = abort_check();
            if (result != ImportResult.SUCCESS) {
                report_failure(job, null, job.get_identifier(), result);
                
                continue;
            }
            
            try {
                sniff_job(job);
            } catch (Error err) {
                report_error(job, null, job.get_identifier(), err, ImportResult.FILE_ERROR);
            }
            
            if (is_cancelled())
                break;
        }
    }
    
    private void sniff_job(BatchImportJob job) throws Error {
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
                report_failure(job, null, job.get_identifier(), ImportResult.FILE_ERROR);
                
                return;
            }
            assert(query_is_directory(dir));
            
            try {
                search_dir(job, dir, copy_to_library);
            } catch (Error err) {
                report_error(job, dir, dir.get_path(), err, ImportResult.FILE_ERROR);
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
    }
    
    public void search_dir(BatchImportJob job, File dir, bool copy_to_library) throws Error {
        FileEnumerator enumerator = dir.enumerate_children("standard::*",
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        
        FileInfo info = null;
        while ((info = enumerator.next_file(get_cancellable())) != null) {
            // next_file() doesn't always respect the cancellable
            if (is_cancelled())
                break;
            
            File child = dir.get_child(info.get_name());
            FileType file_type = info.get_file_type();
            
            if (file_type == FileType.DIRECTORY) {
                if (info.get_name().has_prefix("."))
                    continue;

                try {
                    search_dir(job, child, copy_to_library);
                } catch (Error err) {
                    report_error(job, child, child.get_path(), err, ImportResult.FILE_ERROR);
                }
            } else if (file_type == FileType.REGULAR) {
                if ((skipset != null) && skipset.contains(child))
                    continue; /* don't enqueue if this file is to be skipped */

                if ((Photo.is_file_image(child) && Photo.is_file_supported(child)) ||
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

private class PreparedFile {
    public BatchImportJob job;
    public ImportResult result;
    public File file;
    public string id;
    public bool copy_to_library;
    public string? exif_md5;
    public string? thumbnail_md5;
    public string? full_md5;
    public PhotoFileFormat file_format;
    public uint64 filesize;
    public bool is_video;
    
    public PreparedFile(BatchImportJob job, File file, string id, bool copy_to_library, string? exif_md5, 
        string? thumbnail_md5, string? full_md5, PhotoFileFormat file_format, uint64 filesize,
        bool is_video = false) {
        this.job = job;
        this.result = ImportResult.SUCCESS;
        this.file = file;
        this.id = id;
        this.copy_to_library = copy_to_library;
        this.exif_md5 = exif_md5;
        this.thumbnail_md5 = thumbnail_md5;
        this.full_md5 = full_md5;
        this.file_format = file_format;
        this.filesize = filesize;
        this.is_video = is_video;
    }
}

private class PreparedFileCluster : InterlockedNotificationObject {
    public Gee.ArrayList<PreparedFile> list;
    
    public PreparedFileCluster(Gee.ArrayList<PreparedFile> list) {
        this.list = list;
    }
}

private class PrepareFilesJob : BackgroundImportJob {
    // Do not examine until the CompletionCallback has been called.
    public int prepared_files = 0;
    
    private Gee.List<FileToPrepare> files_to_prepare;
    private NotificationCallback notification;
    private File library_dir;
    
    // these are for debugging and testing only
    private int import_file_count = 0;
    private int fail_every = 0;
    private int skip_every = 0;
    
    public PrepareFilesJob(BatchImport owner, Gee.List<FileToPrepare> files_to_prepare,
        NotificationCallback notification, CompletionCallback callback, Cancellable cancellable,
        CancellationCallback cancellation) {
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
        
        return (value == null || value.length == 0) ? 0 : value.to_int();
    }
    
    public override void execute() {
        Timer timer = new Timer();
        
        Gee.ArrayList<PreparedFile> list = new Gee.ArrayList<PreparedFile>();
        foreach (FileToPrepare file_to_prepare in files_to_prepare) {
            ImportResult result = abort_check();
            if (result != ImportResult.SUCCESS) {
                report_failure(file_to_prepare.job, null, file_to_prepare.job.get_identifier(),
                    result);
                
                continue;
            }
            
            BatchImportJob job = file_to_prepare.job;
            File? file = file_to_prepare.file;
            bool copy_to_library = file_to_prepare.copy_to_library;
            
            // if no file seen, then it needs to be offered/generated by the BatchImportJob
            if (file == null) {
                try {
                    if (!job.prepare(out file, out copy_to_library)) {
                        report_failure(job, null, job.get_identifier(), ImportResult.FILE_ERROR);
                        
                        continue;
                    }
                } catch (Error err) {
                    report_error(job, null, job.get_identifier(), err, ImportResult.FILE_ERROR);
                    
                    continue;
                }
            }
            
            try {
                PreparedFile prepared_file;
                result = prepare_file(job, file, copy_to_library, out prepared_file);
                if (result == ImportResult.SUCCESS) {
                    prepared_files++;
                    list.add(prepared_file);
                } else {
                    report_failure(job, file, file.get_path(), result);
                }
            } catch (Error err) {
                report_error(job, file, file.get_path(), err, ImportResult.FILE_ERROR);
            }
            
            if (list.size >= BatchImport.REPORT_EVERY_N_PREPARED_FILES 
                || ((timer.elapsed() * 1000.0) > BatchImport.REPORT_PREPARED_FILES_EVERY_N_MSEC && list.size > 0)) {
#if TRACE_IMPORT
                debug("Notifying that %d prepared files are ready", list.size);
#endif
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
                    report_failure(prepared_file.job, prepared_file.file, prepared_file.file.get_path(),
                        result);
                }
            }
        }
    }
    
    private ImportResult prepare_file(BatchImportJob job, File file, bool copy_to_library,
        out PreparedFile prepared_file) throws Error {
        bool is_video = VideoReader.is_supported_video_file(file);
        
        if ((!is_video) && (!Photo.is_file_image(file)))
            return ImportResult.NOT_AN_IMAGE;

        if ((!is_video) && (!Photo.is_file_supported(file)))
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
        
        // duplicate detection:
        //     for photos: if EXIF data present, look for a match with either EXIF itself or
        //                 the thumbnail. Still do a full MD5 for tombstones.
        //     for videos: always compare on full MD5
        try {
            full_md5 = md5_file(file);
        } catch (Error err) {
            warning("Unable to perform MD5 checksum on video file %s: %s", file.get_path(),
                err.message);
        }
#if TRACE_MD5
            debug("import MD5 for file %s = %s", file.get_basename(), full_md5);
#endif
        // we only care about file extensions and metadata if we're importing a photo --
        // we don't care about these things for video
        PhotoFileFormat file_format = PhotoFileFormat.get_by_file_extension(file);
        if (!is_video) {
            if (file_format == PhotoFileFormat.UNKNOWN) {
                warning("Skipping %s: unrecognized file extension", file.get_path());
                
                return ImportResult.UNSUPPORTED_FORMAT;
            }
            PhotoFileReader reader = file_format.create_reader(file.get_path());
            PhotoMetadata? metadata = reader.read_metadata();
            if (metadata != null) {
                uint8[]? flattened_sans_thumbnail = metadata.flatten_exif(false);
                if (flattened_sans_thumbnail != null && flattened_sans_thumbnail.length > 0)
                    exif_only_md5 = md5_binary(flattened_sans_thumbnail, flattened_sans_thumbnail.length);
                
                uint8[]? flattened_thumbnail = metadata.flatten_exif_preview();
                if (flattened_thumbnail != null && flattened_thumbnail.length > 0)
                    thumbnail_md5 = md5_binary(flattened_thumbnail, flattened_thumbnail.length);
            }
        }

        uint64 filesize = query_total_file_size(file, get_cancellable());
        
        // never copy file if already in library directory
        bool is_in_library_dir = file.has_prefix(library_dir);
        
        // notify the BatchImport this is ready to go
        prepared_file = new PreparedFile(job, file, file.get_path(), 
            copy_to_library && !is_in_library_dir, exif_only_md5, thumbnail_md5, full_md5,
            file_format, filesize, is_video);
        
        return ImportResult.SUCCESS;
    }
}

private class ReadyForImport {
    public File final_file;
    public PreparedFile prepared_file;
    public PhotoImportParams? photo_import_params;
    public VideoImportParams? video_import_params;
    public BatchImportResult batch_result;
    public bool is_video;
    
    public ReadyForImport(File final_file, PreparedFile prepared_file,
        PhotoImportParams? photo_import_params, VideoImportParams? video_import_params,
        BatchImportResult batch_result) {
        if (prepared_file.is_video)
            assert((video_import_params != null) && (photo_import_params == null));
        else
            assert((video_import_params == null) && (photo_import_params != null));

        this.final_file = final_file;
        this.prepared_file = prepared_file;
        this.batch_result = batch_result;
        this.video_import_params = video_import_params;
        this.photo_import_params = photo_import_params;
        this.is_video = prepared_file.is_video;
    }
    
    public BatchImportResult abort() {
        // if file copied, delete it
        if (final_file != null && final_file != prepared_file.file) {
            debug("Deleting aborted import copy %s", final_file.get_path());
            try {
                final_file.delete(null);
            } catch (Error err) {
                warning("Unable to delete copy of imported file (aborted import) %s: %s",
                    final_file.get_path(), err.message);
            }
        }
        
        batch_result = new BatchImportResult(prepared_file.job, prepared_file.file, prepared_file.id,
            ImportResult.USER_ABORT);
        
        return batch_result;
    }
    
    public Thumbnails get_thumbnails() {
        return (photo_import_params != null) ? photo_import_params.thumbnails :
            video_import_params.thumbnails;
    }
}

private class PreparedFileImportJob : BackgroundJob {
    public PreparedFile? not_ready;
    public ReadyForImport? ready = null;
    public BatchImportResult? failed = null;
    
    private ImportID import_id;
    
    public PreparedFileImportJob(BatchImport owner, PreparedFile prepared_file, ImportID import_id,
        CompletionCallback callback, Cancellable cancellable, CancellationCallback cancellation) {
        base (owner, callback, cancellable, cancellation);
        
        this.import_id = import_id;
        not_ready = prepared_file;
        
        set_completion_priority(Priority.LOW);
    }
    
    public override void execute() {
        PreparedFile prepared_file = not_ready;
        not_ready = null;
        
        File final_file = prepared_file.file;
        if (prepared_file.copy_to_library) {
            try {
                final_file = LibraryFiles.duplicate(prepared_file.file, null, true);
                if (final_file == null) {
                    failed = new BatchImportResult(prepared_file.job, prepared_file.file,
                        prepared_file.id, ImportResult.FILE_ERROR);
                    
                    return;
                }
            } catch (Error err) {
                failed = new BatchImportResult.from_error(prepared_file.job, prepared_file.file,
                    prepared_file.id, err, ImportResult.FILE_ERROR);
                
                return;
            }
        }
        
        ImportResult result = ImportResult.SUCCESS;
        VideoImportParams? video_import_params = null;
        PhotoImportParams? photo_import_params = null;
        if (prepared_file.is_video) {
            video_import_params = new VideoImportParams(final_file, import_id,
                prepared_file.full_md5, new Thumbnails(),
                prepared_file.job.get_exposure_time_override());
            
            result = VideoReader.prepare_for_import(video_import_params);
        } else {
            photo_import_params = new PhotoImportParams(final_file, import_id,
                PhotoFileSniffer.Options.GET_ALL, prepared_file.exif_md5,
                prepared_file.thumbnail_md5, prepared_file.full_md5, new Thumbnails());
            
            result = Photo.prepare_for_import(photo_import_params);
        }
        
        if (result != ImportResult.SUCCESS && final_file != prepared_file.file) {
            debug("Deleting failed imported copy %s", final_file.get_path());
            try {
                final_file.delete(null);
            } catch (Error err) {
                // don't let this file error cause a failure
                warning("Unable to delete copy of imported file %s: %s", final_file.get_path(),
                    err.message);
            }
        }
        
        BatchImportResult batch_result = new BatchImportResult(prepared_file.job, final_file,
            prepared_file.id, result);
        if (batch_result.result != ImportResult.SUCCESS)
            failed = batch_result;
        else
            ready = new ReadyForImport(final_file, prepared_file, photo_import_params,
                video_import_params, batch_result);
    }
}

private class CompletedImportObject {
    public Thumbnails? thumbnails;
    public BatchImportResult batch_result;
    public MediaSource source;
    public Gdk.Pixbuf user_preview;
    
    public CompletedImportObject(MediaSource source, Thumbnails thumbnails,
        BatchImportResult import_result) {
        this.thumbnails = thumbnails;
        this.batch_result = import_result;
        this.source = source;
        user_preview = thumbnails.get(ThumbnailCache.Size.LARGEST);
    }
}

private class ThumbnailWriterJob : BackgroundImportJob {
    public CompletedImportObject completed_import_source;
    
    public ThumbnailWriterJob(BatchImport owner, CompletedImportObject completed_import_source,
        CompletionCallback callback, Cancellable cancellable, CancellationCallback cancel_callback) {
        base (owner, callback, cancellable, cancel_callback);
        
        assert(completed_import_source.thumbnails != null);
        this.completed_import_source = completed_import_source;
        
        set_completion_priority(Priority.LOW);
    }
    
    public override void execute() {
        try {
            ThumbnailCache.import_thumbnails(completed_import_source.source,
                completed_import_source.thumbnails, true);
            completed_import_source.batch_result.result = ImportResult.SUCCESS;
        } catch (Error err) {
            completed_import_source.batch_result.result = ImportResult.convert_error(err,
                ImportResult.FILE_ERROR);
        }
        
        // destroy the thumbnails (but not the user preview) to free up memory
        completed_import_source.thumbnails = null;
    }
}

