
private class PreparedFile {
    public BatchImportJob job;
    public ImportResult result;
    public File file;
    public File? associated_file = null;
    public string source_id;
    public string dest_id;
    public bool copy_to_library;
    public string? exif_md5;
    public string? thumbnail_md5;
    public string? full_md5;
    public PhotoFileFormat file_format;
    public uint64 filesize;
    public bool is_video;
    public PreparedFile(BatchImportJob job, File file, File? associated_file, string source_id, string dest_id,
        bool copy_to_library, string? exif_md5, string? thumbnail_md5, string? full_md5,
        PhotoFileFormat file_format, uint64 filesize, bool is_video = false) {
        this.job = job;
        this.result = ImportResult.SUCCESS;
        this.file = file;
        this.associated_file = associated_file;
        this.source_id = source_id;
        this.dest_id = dest_id;
        this.copy_to_library = copy_to_library;
        this.exif_md5 = exif_md5;
        this.thumbnail_md5 = thumbnail_md5;
        this.full_md5 = full_md5;
        this.file_format = file_format;
        this.filesize = filesize;
        this.is_video = is_video;
    }
}
