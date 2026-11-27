/* SPDX-FileCopyrightText: 2016 Software Freedom Conservancy Inc.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

internal class CameraImportJob : BatchImportJob {
    private GPhoto.Context context;
    private ImportSource import_file;
    private GPhoto.Camera camera;
    private string fulldir;
    private string filename;
    private uint64 filesize;
    private PhotoMetadata metadata;
    private DateTime exposure_time;
    private CameraImportJob? associated = null;
    private BackingPhotoRow? associated_file = null;
    private DuplicatedFile? duplicated_file;
    
    public CameraImportJob(GPhoto.Context context, ImportSource import_file,
        DuplicatedFile? duplicated_file = null) {
        this.context = context;
        this.import_file = import_file;
        this.duplicated_file = duplicated_file;
        
        // stash everything called in prepare(), as it may/will be called from a separate thread
        camera = import_file.get_camera();
        fulldir = import_file.get_fulldir();
        // this should've been caught long ago when the files were first enumerated
        assert(fulldir != null);
        filename = import_file.get_filename();
        filesize = import_file.get_filesize();
        var photo_import_source = import_file as PhotoImportSource;
        metadata = (photo_import_source != null) ?
            photo_import_source.get_metadata() : null;
        exposure_time = import_file.get_exposure_time();
    }
    
    public DateTime get_exposure_time() {
        return exposure_time;
    }
    
    public override DuplicatedFile? get_duplicated_file() {
        return duplicated_file;
    }

    public override DateTime? get_exposure_time_override() {
        return (import_file is VideoImportSource) ? get_exposure_time() : null;
    }
    
    public override string get_dest_identifier() {
        return filename;
    }
    
    public override string get_source_identifier() {
        return import_file.get_filename();
    }
    
    public override string get_basename() {
        return filename;
    }

    public override string get_path() {
        return fulldir;
    }
    
    public override void set_associated(BatchImportJob associated) {
        this.associated = associated as CameraImportJob;
    }
    
    public ImportSource get_source() {
        return import_file;
    }
    
    public override bool is_directory() {
        return false;
    }
    
    public override bool determine_file_size(out uint64 filesize, out File file) {
        file = null;
        filesize = this.filesize;
        
        return true;
    }
    
    public override bool prepare(out File file_to_import, out bool copy_to_library,
        Cancellable? cancellable = null) throws Error {
        file_to_import = null;
        copy_to_library = false;
        
        File dest_file = null;
        try {
            bool collision;
            dest_file = LibraryFiles.generate_unique_file(filename, metadata, exposure_time,
                out collision);
        } catch (Error err) {
            warning("Unable to generate local file for %s: %s", import_file.get_filename(),
                err.message);
        }
        
        if (dest_file == null) {
            message("Unable to generate local file for %s", import_file.get_filename());
            
            return false;
        }
        
        // always blacklist the copied images from the LibraryMonitor, otherwise it'll think
        // they should be auto-imported
        LibraryMonitor.blacklist_file(dest_file, "CameraImportJob.prepare");
        try {
            save_image(fulldir, filename, dest_file, cancellable);
        } catch (Error err) {
            // Remove the (possibly partial) download before propagating a cancellation or failure.
            try_delete_file(dest_file);
            throw err;
        } finally {
            LibraryMonitor.unblacklist_file(dest_file);
        }
        
        // Copy over associated file, if it exists.
        if (associated != null) {
            try {
                associated_file = 
                    RawDeveloper.CAMERA.create_backing_row_for_development(dest_file.get_path(),
                        associated.get_basename());
            } catch (Error err) {
                warning("Unable to generate backing associated file for %s: %s", associated.filename,
                    err.message);
            }
            
            if (associated_file == null) {
                message("Unable to generate backing associated file for %s", associated.filename);
                return false;
            }
            
            File assoc_dest = File.new_for_path(associated_file.filepath);
            LibraryMonitor.blacklist_file(assoc_dest, "CameraImportJob.prepare");
            try {
                save_image(associated.fulldir, associated.filename, assoc_dest, cancellable);
            } catch (Error err) {
                try_delete_file(assoc_dest);
                throw err;
            } finally {
                LibraryMonitor.unblacklist_file(assoc_dest);
            }
        }
        
        file_to_import = dest_file;
        copy_to_library = false;
        
        return true;
    }

    private static void try_delete_file(File file) {
        try {
            file.delete(null);
        } catch (Error err) {
            warning("Unable to delete partial camera download %s: %s", file.get_path(), err.message);
        }
    }

    // Downloads folder/filename off the camera into dest_file.  When cancellable is cancelled,
    // gphoto2 aborts the in-flight transfer via the context's cancel func and this throws
    // IOError.CANCELLED.
    private void save_image(string folder, string filename, File dest_file,
        Cancellable? cancellable = null) throws Error {
        var fd = Posix.creat(dest_file.get_path(), 0640);
        if (fd < 0) {
            throw new IOError.FAILED("[%d] Error creating file %s: %m", GLib.errno, dest_file.get_path());
        }

        // gphoto2 invokes the context's cancel func periodically during a transfer; return
        // CANCEL to abort an in-flight download when the caller has cancelled.
        if (cancellable != null)
            context.set_cancel_func((ctx) => cancellable.is_cancelled() ? GPhoto.ContextFeedback.CANCEL : GPhoto.ContextFeedback.OK);
        else
            context.set_cancel_func(null);

        GPhoto.CameraFile camera_file;
        GPhoto.Result res = GPhoto.CameraFile.create_from_fd(out camera_file, fd);
        if (res != GPhoto.Result.OK) {
            context.set_cancel_func(null);
            throw new GPhotoError.LIBRARY("[%d] Error allocating camera file: %s", (int) res, res.as_string());
        }

        res = camera.get_file(folder, filename, GPhoto.CameraFileType.NORMAL, camera_file, context);
        // Clear the cancel func so a stale Cancellable isn't referenced by later, unrelated transfers.
        context.set_cancel_func(null);

        if (cancellable != null && cancellable.is_cancelled())
            throw new IOError.CANCELLED("Camera download cancelled by user");

        if (res != GPhoto.Result.OK) {
            throw new GPhotoError.LIBRARY("[%d] Error retrieving file object for %s/%s: %s",
                (int) res, folder, filename, res.as_string());
        }
    }

    public override File? get_associated_file() {
        if (associated_file == null) {
            return null;
        }

        return File.new_for_path(associated_file.filepath);
    }
}
    

// A wrapper for a GPhoto.Camera, providing async functions to interact with the camera.
public class DiscoveredCamera : Object {
    public GPhoto.Camera gcamera;
    private GPhoto.Context context;
    private GPhoto.CameraStorageInformation[] storage_information;

    public string uri;
    public string display_name;
    public string? icon;

    private string port;
    private string camera_name;
    private string[] mount_uris;
    private Workers? workers = null;
    private Cancellable? cancellable = null;

    // The camera worker is one thread, because a camera can only be used by one at a time. What is
    // done with the bytes it fetches (parsing the EXIF data, decoding the preview) needs no camera,
    // so it is done by these threads and does not hold up the next fetch.
    private static Workers decode_workers = new Workers(Workers.thread_per_cpu_minus_one(), false);

    // The camera worker can fetch faster than the pool can decode. The bytes that it has fetched and
    // that are still waiting to be parsed or decoded are limited to this, so that a slow decode
    // (or a card of large previews) does not fill the memory. When the limit is reached, the
    // camera worker waits after a fetch until the pool has caught up.
    private const int64 FETCH_BYTE_BUDGET = 64 * 1024 * 1024;
    private static ByteBudget fetch_budget = new ByteBudget(FETCH_BYTE_BUDGET);

    public DiscoveredCamera(string name, string port, GPhoto.PortInfo port_info, GPhoto.CameraAbilities camera_abilities) throws GPhotoError {
        this.port = port;
        this.camera_name = name;
        this.uri = "gphoto2://[%s]".printf(port);

        this.mount_uris = new string[0];
        this.mount_uris += this.uri;
        this.mount_uris += "mtp://[%s]".printf(port);

        var res = GPhoto.Camera.create(out this.gcamera);

        if (res != GPhoto.Result.OK) {
            throw new GPhotoError.LIBRARY("[%d] Unable to create camera object for %s: %s",
                (int) res, name, res.as_string());
        }

        res = gcamera.set_abilities(camera_abilities);
        if (res != GPhoto.Result.OK) {
            throw new GPhotoError.LIBRARY("[%d] Unable to set camera abilities for %s: %s",
                (int) res, name, res.as_string());
        }

        res = gcamera.set_port_info(port_info);
        if (res != GPhoto.Result.OK) {
            throw new GPhotoError.LIBRARY("[%d] Unable to set port info for %s: %s",
                (int) res, name, res.as_string());
        }

        var path = get_port_path(port);
        if (path != null) {
            var monitor = VolumeMonitor.get();
            foreach (var volume in monitor.get_volumes()) {
                if (volume.get_identifier(VolumeIdentifier.UNIX_DEVICE) == path) {
                    this.display_name = volume.get_name();
                    this.icon = volume.get_symbolic_icon().to_string();
                }
            }

#if HAVE_UDEV
            var client = new GUdev.Client(null);
            var device = client.query_by_device_file(path);


            // Create alternative uris (used for unmount)
            var serial = device.get_property("ID_SERIAL");
            this.mount_uris += "gphoto2://%s".printf(serial);
            this.mount_uris += "mtp://%s".printf(serial);

            // Look-up alternative display names
            if (display_name == null) {
                display_name = device.get_sysfs_attr("product");
            }

            if (display_name == null) {
                display_name = device.get_property("ID_MODEL");
            }
#endif
        }

        if (port.has_prefix("disk:")) {
            try {
                var mount = File.new_for_path (port.substring(5)).find_enclosing_mount();
                var volume = mount.get_volume();
                if (volume != null) {
                    // Translators: First %s is the name of camera as gotten from GPhoto, second is the GVolume name, e.g. Mass storage camera (510MB volume)
                    display_name = _("%s (%s)").printf (name, volume.get_name ());
                    icon = volume.get_symbolic_icon().to_string();
                } else {
                    // Translators: First %s is the name of camera as gotten from GPhoto, second is the GMount name, e.g. Mass storage camera (510MB volume)
                    display_name = _("%s (%s)").printf (name, mount.get_name ());
                    icon = mount.get_symbolic_icon().to_string();
                }

            } catch (Error e) { }
        }

        if (display_name == null) {
            this.display_name = camera_name;
        }
    }

    public void attach(Workers workers) {
        this.workers = workers;
    }

    public void set_cancellable(Cancellable? cancellable) {
        this.cancellable = cancellable;
    }

    public bool is_cancelled() {
        return (this.cancellable != null) && this.cancellable.is_cancelled();
    }

    public Mount? get_mount() {
        foreach (var uri in this.mount_uris) {
            var f = File.new_for_uri(uri);
            try {
                var mount = f.find_enclosing_mount(null);
                if (mount != null)
                    return mount;
            } catch (Error error) {}
        }

        return null;
    }

    private string? get_port_path(string port) {
        // Accepted format is usb:001,005
        return port.has_prefix("usb:") ? 
            "/dev/bus/usb/%s".printf(port.substring(4).replace(",", "/")) : null;
    }
    

    private delegate void CameraOp();

    private class CameraOpJob : BackgroundJob {
        private CameraOp op;
        private unowned SourceFunc source_func;
        private GPhoto.Context? context;

        public CameraOpJob(Object owner, GPhoto.Context? context, Cancellable? cancellable,
            SourceFunc source_func, CameraOp op) {
            base(owner, on_finished, cancellable, on_finished, null);
            this.context = context;
            this.source_func = source_func;
            this.op = op;
        }

        // Runs on the worker thread. The context is shared by all the ops of a camera and the
        // camera worker runs one at a time, but several can be queued. So the cancel callback is
        // set here, around the op, and not when the op is queued from the main thread, where it
        // would change under the op that is running and be cleared by the end of the first one.
        public override void execute() {
            Cancellable? cancellable = get_cancellable();
            if (context == null || cancellable == null) {
                op();

                return;
            }

            // gphoto2 stores the delegate as an unowned void*, so it must outlive the op
            GPhoto.ContextCancelFunc cancel_func = (ctx) => cancellable.is_cancelled() ?
                GPhoto.ContextFeedback.CANCEL : GPhoto.ContextFeedback.OK;
            context.set_cancel_func(cancel_func);
            op();
            context.set_cancel_func(null);
        }

        private static void on_finished(BackgroundJob job) {
            ((CameraOpJob) job).source_func();
        }
    }

    // Runs a blocking libgphoto2 call on the camera worker pool, then resumes the caller
    private async void run_op(CameraOp op, bool use_cancellable = true) {
        Cancellable? job_cancellable = use_cancellable ? this.cancellable : null;
        workers.enqueue(new CameraOpJob(this, context, job_cancellable, run_op.callback, op));
        yield;
    }

    // Runs work on bytes that the camera worker has already fetched on the decode pool, then
    // resumes the caller. It does not use the camera.
    private async void run_decode(CameraOp op) {
        decode_workers.enqueue(new CameraOpJob(this, null, this.cancellable, run_decode.callback, op));
        yield;
    }

    private void throw_if_cancelled(Error? error) throws Error {
        if (this.cancellable != null && this.cancellable.is_cancelled() && error == null) {
            throw new IOError.CANCELLED("Camera operation cancelled by user");
        }

        if (error != null) {
            throw error;
        }
    }

    public async GPhoto.Result init() {
        this.context = new GPhoto.Context();

        GPhoto.Result result = GPhoto.Result.OK;
        yield run_op(() => {
            result = this.gcamera.init(this.context);
        });

        return result;
    }

    public BatchImportJob create_import_job(ImportSource import_file, DuplicatedFile? duplicated_file = null) {
        return new CameraImportJob(this.context, import_file, duplicated_file);
    }

    // Need to do this because some phones (iPhone, in particular) changes the name of their filesystem
    // between each mount
    public async string? get_fs_basedir(int fsid) {
        // Just to make sure, probably never called?
        if (this.storage_information == null) {
            debug("Storage information was not cached, re-getting");
            yield this.get_storage_information(null);
        }

        if (fsid >= this.storage_information.length) {
            return null;
        }

        if (GPhoto.CameraStorageInfoFields.BASE in this.storage_information[fsid].fields) {
            return (string) this.storage_information[fsid].basedir;
        }

        return "/";
    }
    
    private static string chomp_ch(string str, char ch) {
        long offset = str.length;
        while (--offset >= 0) {
            if (str[offset] != ch)
                return str.slice(0, offset);
        }
        
        return "";
    }

    public static string append_path(string basepath, string addition) {
        if (!basepath.has_suffix("/") && !addition.has_prefix("/"))
            return basepath + "/" + addition;
        else if (basepath.has_suffix("/") && addition.has_prefix("/"))
            return chomp_ch(basepath, '/') + addition;
        else
            return basepath + addition;
    }

    public async string? get_fulldir(int fsid, string folder) {
        var basedir = yield get_fs_basedir(fsid);
        if (basedir == null) {
            debug("Unable to find base directory for %s fsid %d", display_name, fsid);
            
            return folder;
        }
        
        return append_path(basedir, folder);
    }

    public async GPhoto.Result enumerate_files(int fsid, string dir, Gee.ArrayList<ImportSource> import_list) {
        string? fulldir = yield get_fulldir(fsid, dir);
        if (fulldir == null) {
            warning("Skipping enumerating %s: invalid folder name", dir);
            
            return GPhoto.Result.OK;
        }

        GPhoto.CameraList files = null;
        GPhoto.Result result = GPhoto.Result.OK;
        yield run_op(() => {
            GPhoto.CameraList tmp;
            result = GPhoto.CameraList.create(out tmp);
            if (result != GPhoto.Result.OK) {
                warning("Unable to create file list: %s", result.to_full_string());

                return;
            }

            result = gcamera.list_files(fulldir, tmp, this.context);
            files = tmp;
        });
        if (result != GPhoto.Result.OK) {
            warning("Unable to list files in %s: %s", fulldir, result.to_full_string());
            
            // Although an error, don't abort the import because of this
            return GPhoto.Result.OK;
        }
        files.sort();

        for (int ctr = 0; ctr < files.count(); ctr++) {
            if (is_cancelled())
                return GPhoto.Result.OK;
            string filename;
            result = files.get_name(ctr, out filename);
            if (result != GPhoto.Result.OK) {
                warning("Unable to get the name of file %d in %s: %s", ctr, fulldir,
                    result.to_full_string());
                
                return result;
            }

            ulong size = 0;
            long mtime = 0;
            uint fields = 0;
            string type = null;
            yield run_op(() => {
                GPhoto.CameraFileInfo tmp;
                result = gcamera.get_file_info(fulldir, filename, out tmp, this.context);
                size = tmp.file.size;
                mtime = tmp.file.mtime;
                fields = tmp.file.fields;
                type = (string) tmp.file.type;
            });
            if (result != GPhoto.Result.OK) {
                warning("Skipping import of %s/%s: name too long", fulldir, filename);
                continue;
            }

            if ((fields & GPhoto.CameraFileInfoFields.TYPE) == 0) {
                message("Skipping %s/%s: No file (file=%02Xh)", fulldir, filename, fields);
                    
                continue;
            }
            
            if (VideoReader.is_supported_video_filename(filename)) {
                VideoImportSource video_source = new VideoImportSource(display_name, gcamera,
                    fsid, fulldir, dir, filename, size, new DateTime.from_unix_utc(mtime));
                import_list.add(video_source);
            } else {
                // determine file format from type, and then from file extension
                string file_type = (string) type;
                PhotoFileFormat file_format = PhotoFileFormat.from_gphoto_type(file_type);               
                if (file_format == PhotoFileFormat.UNKNOWN) {
                    file_format = PhotoFileFormat.get_by_basename_extension(filename);
                    if (file_format == PhotoFileFormat.UNKNOWN) {
                        message("Skipping %s/%s: Not a supported file extension (%s)", fulldir,
                            filename, file_type);
                        
                        continue;
                    }
                }
                import_list.add(new PhotoImportSource(display_name, gcamera, fsid, fulldir, dir, filename,
                    size, new DateTime.from_unix_utc(mtime), file_format));
            }
        }

        GPhoto.CameraList folders = null;
        yield run_op(() => {
            GPhoto.CameraList tmp;
            result = GPhoto.CameraList.create(out tmp);
            if (result != GPhoto.Result.OK) {
                warning("Unable to create file list: %s", result.to_full_string());

                return;
            }

            result = gcamera.list_folders(fulldir, tmp, this.context);
            folders = tmp;
        });
        if (result != GPhoto.Result.OK) {
            warning("Unable to list folders in %s: %s", fulldir, result.to_full_string());
            
            // Although an error, don't abort the import because of this
            return GPhoto.Result.OK;
        }
        
        for (int ctr = 0; ctr < folders.count(); ctr++) {
            string subdir;
            result = folders.get_name(ctr, out subdir);
            if (result != GPhoto.Result.OK) {
                warning("Unable to get name of folder %d: %s", ctr, result.to_full_string());
                
                return result;
            }
            
            if (subdir.has_prefix(".")) {
                debug("Skipping hidden sub-folder %s in %s", subdir, dir);
            } else {
                result = yield enumerate_files(fsid, append_path(dir, subdir), import_list);
                if (result != GPhoto.Result.OK) {
                    return result;
                }
            }
        }
        
        return GPhoto.Result.OK;
    }

    /**
     * @brief Returns whether the current device has a given directory or not.
     *
     * @param fsid The file system id of the camera or other device to search.
     * @param dir The path to start searching from.
     * @param search_target The name of the directory to look for.
     */
    public async bool check_directory_exists(int fsid, string dir, string search_target) {
        string? fulldir = yield get_fulldir(fsid, dir);

        GPhoto.CameraList folders = null;
        GPhoto.Result result = GPhoto.Result.OK;
        yield run_op(() => {
            GPhoto.CameraList tmp;
            result = GPhoto.CameraList.create(out tmp);
            if (result != GPhoto.Result.OK) {
                warning("Unable to create file list: %s", result.to_full_string());

                return;
            }

            result = gcamera.list_folders(fulldir, tmp, this.context);
            folders = tmp;
        });
        if (result != GPhoto.Result.OK) {
            // fetching the list failed - can't determine whether specified dir is present
            return false;
        }

        int list_len = folders.count();

        for (int list_index = 0; list_index < list_len; list_index++) {
            string tmp;

            folders.get_name(list_index, out tmp);
            if (tmp == search_target) {
                return true;
            }
        }
        return false;
    }

    public async GPhoto.Result get_storage_information(out GPhoto.CameraStorageInformation[] sifs) {
        GPhoto.CameraStorageInformation[] storage = null;
        GPhoto.Result result = GPhoto.Result.OK;
        yield run_op(() => {
            GPhoto.CameraStorageInformation[] tmp;
            result = gcamera.get_storageinfo(out tmp, this.context);
            storage = tmp;
        }, false);
        this.storage_information = storage;
        sifs = this.storage_information;

        return result;
    }

    public async PhotoMetadata load_metadata(string fulldir, string filename) throws Error {
        PhotoMetadata metadata = null;
        Bytes? camera_raw = null;
        int64 reserved = 0;
        Error? error = null;
        yield run_op(() => {
            try {
                try {
                    camera_raw = GPhoto.load_file_into_buffer(this.context, gcamera, fulldir,
                        filename, GPhoto.CameraFileType.EXIF);
                } catch (Error e) {
                    camera_raw = null;
                    metadata = GPhoto.get_fallback_metadata(gcamera, this.context, fulldir,
                        filename);
                    return;
                }

                if (camera_raw != null && camera_raw.length == 0)
                    camera_raw = null;

                // The bytes are given back to the budget below, when they have been parsed.
                if (camera_raw != null) {
                    fetch_budget.acquire(camera_raw.length);
                    reserved = camera_raw.length;
                }
            } catch (Error e) {
                camera_raw = null;
                error = e;
            }
        });

        if (camera_raw != null) {
            // parsed off the camera thread
            Bytes raw = camera_raw;
            yield run_decode(() => {
                try {
                    PhotoMetadata loaded = new PhotoMetadata();
                    loaded.read_from_app1_segment(raw);
                    metadata = loaded;
                } catch (Error e) {
                    error = e;
                }
            });
        }
        fetch_budget.release(reserved);
        throw_if_cancelled(error);

        return metadata;
    }

    public async Gdk.Pixbuf load_preview(string fulldir, string filename, out string md5) throws Error {
        Gdk.Pixbuf preview = null;
        string checksum = null;
        Bytes? raw = null;
        int64 reserved = 0;
        Error? error = null;
        yield run_op(() => {
            try {
                try {
                    raw = GPhoto.load_file_into_buffer(this.context, gcamera, fulldir, filename,
                        GPhoto.CameraFileType.PREVIEW);
                } catch (Error e) {
                    PhotoMetadata metadata = GPhoto.get_fallback_metadata(gcamera, this.context,
                        fulldir, filename);
                    if (metadata == null)
                        return;
                    if (metadata.get_preview_count() == 0)
                        return;

                    // Get the smallest preview from meta-data
                    var fallback = metadata.get_preview(metadata.get_preview_count() - 1);
                    raw = fallback.flatten();
                }

                // The bytes are given back to the budget below, when they have been decoded.
                if (raw != null) {
                    fetch_budget.acquire(raw.length);
                    reserved = raw.length;
                }
            } catch (Error e) {
                raw = null;
                error = e;
            }
        });

        if (raw != null) {
            // hashed and decoded off the camera thread
            Bytes fetched = raw;
            yield run_decode(() => {
                try {
                    checksum = Checksum.compute_for_bytes(ChecksumType.MD5, fetched);

                    MemoryInputStream mins = new MemoryInputStream.from_bytes(fetched);

                    preview = new Gdk.Pixbuf.from_stream_at_scale(mins, ImportPreview.MAX_SCALE,
                        ImportPreview.MAX_SCALE, true, null);
                } catch (Error e) {
                    error = e;
                }
            });
        }
        fetch_budget.release(reserved);
        throw_if_cancelled(error);
        md5 = checksum;

        return preview;
    }

    public async GPhoto.Result shutdown() {
        GPhoto.Result result = GPhoto.Result.OK;
        yield run_op(() => {
            result = gcamera.exit(this.context);
        }, false);

        this.storage_information = null;

        return result;
    }

    public async GPhoto.Result delete_file(string fulldir, string filename) {
        GPhoto.Result result = GPhoto.Result.OK;
        yield run_op(() => {
            result = gcamera.delete_file(fulldir, filename, this.context);
        });

        return result;
    }
}


