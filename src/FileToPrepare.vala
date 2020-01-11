private class FileToPrepare {
    public BatchImportJob job;
    public File? file;
    public bool copy_to_library;
    public FileToPrepare? associated = null;
    public FileToPrepare(BatchImportJob job, File? file = null, bool copy_to_library = true) {
        this.job = job;
        this.file = file;
        this.copy_to_library = copy_to_library;
    }
    public void set_associated(FileToPrepare? a) {
        associated = a;
    }
    public string get_parent_path() {
        return file != null ? file.get_parent().get_path() : job.get_path();
    }
    public string get_path() {
        return file != null ? file.get_path() : (File.new_for_path(job.get_path()).get_child(
            job.get_basename())).get_path();
    }
    public string get_basename() {
        return file != null ? file.get_basename() : job.get_basename();
    }
    public bool is_directory() {
        return file != null ? (file.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) :
            job.is_directory();
    }
}
