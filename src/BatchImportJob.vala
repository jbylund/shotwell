// A BatchImportJob describes a unit of work the BatchImport object should perform.  It returns
// a file to be imported.  If the file is a directory, it is automatically recursed by BatchImport
// to find all files that need to be imported into the library.
//
// NOTE: All methods may be called from the context of a background thread or the main GTK thread.
// Implementations should be able to handle either situation.  The prepare method will always be
// called by the same thread context.
public abstract class BatchImportJob {
    public abstract string get_dest_identifier();
    public abstract string get_source_identifier();
    public abstract bool is_directory();
    public abstract string get_basename();
    public abstract string get_path();
    public virtual DuplicatedFile? get_duplicated_file() {
        return null;
    }
    public virtual File? get_associated_file() {
        return null;
    }
    // Attaches a sibling job (for RAW+JPEG)
    public abstract void set_associated(BatchImportJob associated);
    // Returns the file size of the BatchImportJob or returns a file/directory which can be queried
    // by BatchImportJob to determine it.  Returns true if the size is return, false if the File is
    // specified.
    //
    // filesize should only be returned if BatchImportJob represents a single file.
    public abstract bool determine_file_size(out uint64 filesize, out File file_or_dir);
    // NOTE: prepare( ) is called from a background thread in the worker pool
    public abstract bool prepare(out File file_to_import, out bool copy_to_library) throws Error;
    // Completes the import for the new library photo once it's been imported.
    // If the job is directory based, this method will be called for each photo
    // discovered in the directory. This method is only called for photographs
    // that have been successfully imported.
    //
    // Returns true if any action was taken, false otherwise.
    //
    // NOTE: complete( )is called from the foreground thread
    public virtual bool complete(MediaSource source, BatchImportRoll import_roll) throws Error {
        return false;
    }
    // returns a non-zero time_t value if this has a valid exposure time override, returns zero
    // otherwise
    public virtual time_t get_exposure_time_override() {
        return 0;
    }
    public virtual bool recurse() {
        return true;
    }
}


public class FileImportJob : BatchImportJob {
    private File file_or_dir;
    private bool copy_to_library;
    private FileImportJob? associated = null;
    private bool _recurse;
    public FileImportJob(File file_or_dir, bool copy_to_library, bool recurse) {
        this.file_or_dir = file_or_dir;
        this.copy_to_library = copy_to_library;
        this._recurse = recurse;
    }
    public override string get_dest_identifier() {
        return file_or_dir.get_path();
    }
    public override string get_source_identifier() {
        return file_or_dir.get_path();
    }
    public override bool is_directory() {
        return query_is_directory(file_or_dir);
    }
    public override string get_basename() {
        return file_or_dir.get_basename();
    }
    public override string get_path() {
        return is_directory() ? file_or_dir.get_path() : file_or_dir.get_parent().get_path();
    }
    public override void set_associated(BatchImportJob associated) {
        this.associated = associated as FileImportJob;
    }
    public override bool determine_file_size(out uint64 filesize, out File file) {
        filesize = 0;
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
    public override bool recurse() {
        return this._recurse;
    }
}
