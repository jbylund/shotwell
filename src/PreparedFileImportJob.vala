
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

    private bool copy_if_necessary(PreparedFile prepared_file) {
        // copy if necessary return true on success, false on failure
        if (!prepared_file.copy_to_library)
            return true;
        File final_file = prepared_file.file;
        File? final_associated_file = prepared_file.associated_file;
        // Copy file.
        try {
            final_file = LibraryFiles.duplicate(prepared_file.file, null, true);
            if (final_file == null) {
                failed = new BatchImportResult(prepared_file.job, prepared_file.file,
                    prepared_file.file.get_path(), prepared_file.file.get_path(), null,
                    ImportResult.FILE_ERROR);
                return false;
            }
            // Copy associated file.
            if (final_associated_file != null) {
                final_associated_file = LibraryFiles.duplicate(prepared_file.associated_file, null, true);
            }
        } catch (Error err) {
            string filename = final_file != null ? final_file.get_path() : prepared_file.source_id;
            failed = new BatchImportResult.from_error(prepared_file.job, prepared_file.file, filename, filename, err, ImportResult.FILE_ERROR);
            return false;
        }
        return true;
    }

    public override void execute() {
        Timer timer = new Timer();

        PreparedFile prepared_file = not_ready;
        not_ready = null;
        File final_file = prepared_file.file;
        File? final_associated_file = prepared_file.associated_file;

        stderr.printf("PreparedFileJob.execute starting %s...\n", final_file.get_path());
        stderr.printf("final_file.get_path took %f\n", timer.elapsed());

        if (prepared_file.copy_to_library) {
            try {
                // Copy file.
                // the copy has to do a metadata read... in order to figure out where to put it... this is evil
                final_file = LibraryFiles.duplicate(prepared_file.file, null, true);
                stderr.printf("getting final file took took %f\n", timer.elapsed());
                if (final_file == null) {
                    failed = new BatchImportResult(prepared_file.job, prepared_file.file, prepared_file.file.get_path(), prepared_file.file.get_path(), null, ImportResult.FILE_ERROR);
                    return;
                }

                // Copy associated file.
                if (final_associated_file != null) {
                    stderr.printf("final file = %s, final associated file = %s...\n", final_file.get_path(), final_associated_file.get_path());
                    final_associated_file = LibraryFiles.duplicate(prepared_file.associated_file, null, true);
                    stderr.printf("duplicating prepared associated took %f\n", timer.elapsed());
                }
            } catch (Error err) {
                string filename = final_file != null ? final_file.get_path() : prepared_file.source_id;
                failed = new BatchImportResult.from_error(prepared_file.job, prepared_file.file, filename, filename, err, ImportResult.FILE_ERROR);
                return;
            }
        }

        stderr.printf("Copy took %f\n", timer.elapsed());

        // See if the prepared job has a file associated already, then use that
        // Usually works for import from Cameras
        if (final_associated_file == null) {
            final_associated_file = prepared_file.job.get_associated_file();
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
            photo_import_params = new PhotoImportParams(final_file, final_associated_file, import_id,
                PhotoFileSniffer.Options.GET_ALL, prepared_file.exif_md5,
                prepared_file.thumbnail_md5, prepared_file.full_md5, new Thumbnails());
            result = Photo.prepare_for_import(photo_import_params);
            stderr.printf("Construct and prepare %f\n", timer.elapsed());
        }
        if (result != ImportResult.SUCCESS && final_file != prepared_file.file) {
            debug("Deleting failed imported copy %s", final_file.get_path());
            try {
                final_file.delete(null);
            } catch (Error err) {
                // don't let this file error cause a failure
                warning("Unable to delete copy of imported file %s: %s", final_file.get_path(), err.message);
            }
        }
        BatchImportResult batch_result = new BatchImportResult(prepared_file.job, final_file, final_file.get_path(), final_file.get_path(), null, result);
        if (batch_result.result != ImportResult.SUCCESS)
            failed = batch_result;
        else
            ready = new ReadyForImport(final_file, prepared_file, photo_import_params, video_import_params, batch_result);
        stderr.printf("PreparedFileJob.execute finished after %f...\n", timer.elapsed());
    }
}
