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
        batch_result = new BatchImportResult(prepared_file.job, prepared_file.file,
            prepared_file.job.get_source_identifier(), prepared_file.job.get_dest_identifier(),
            null, ImportResult.USER_ABORT);
        return batch_result;
    }
    public Thumbnails get_thumbnails() {
        return (photo_import_params != null) ? photo_import_params.thumbnails :
            video_import_params.thumbnails;
    }
}
