

private class CompletedImportObject {
    public Thumbnails? thumbnails;
    public BatchImportResult batch_result;
    public MediaSource source;
    public BatchImportJob original_job;
    public Gdk.Pixbuf user_preview;
    public CompletedImportObject(MediaSource source, Thumbnails thumbnails,
        BatchImportJob original_job, BatchImportResult import_result) {
        this.thumbnails = thumbnails;
        this.batch_result = import_result;
        this.source = source;
        this.original_job = original_job;
        user_preview = thumbnails.get(ThumbnailCache.Size.LARGEST);
    }
}
