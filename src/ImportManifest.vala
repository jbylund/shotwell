
public class ImportManifest {
    public Gee.List<MediaSource> imported = new Gee.ArrayList<MediaSource>();
    public Gee.List<BatchImportResult> success = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> camera_failed = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> failed = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> write_failed = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> skipped_photos = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> skipped_files = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> aborted = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> already_imported = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> corrupt_files = new Gee.ArrayList<BatchImportResult>();
    public Gee.List<BatchImportResult> all = new Gee.ArrayList<BatchImportResult>();
    public GLib.Timer timer;
    public ImportManifest(Gee.List<BatchImportJob>? prefailed = null,
        Gee.List<BatchImportJob>? pre_already_imported = null) {
        this.timer = new Timer();
        if (prefailed != null) {
            foreach (BatchImportJob job in prefailed) {
                BatchImportResult batch_result = new BatchImportResult(job, null,
                    job.get_source_identifier(), job.get_dest_identifier(), null,
                    ImportResult.FILE_ERROR);
                add_result(batch_result);
            }
        }
        if (pre_already_imported != null) {
            foreach (BatchImportJob job in pre_already_imported) {
                BatchImportResult batch_result = new BatchImportResult(job,
                    File.new_for_path(job.get_basename()),
                    job.get_source_identifier(), job.get_dest_identifier(),
                    job.get_duplicated_file(), ImportResult.PHOTO_EXISTS);
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
            case ImportResult.FILE_WRITE_ERROR:
                write_failed.add(batch_result);
            break;
            case ImportResult.PIXBUF_CORRUPT_IMAGE:
                corrupt_files.add(batch_result);
            break;
            default:
                failed.add(batch_result);
            break;
        }
        if (reported)
            all.add(batch_result);
    }
}

