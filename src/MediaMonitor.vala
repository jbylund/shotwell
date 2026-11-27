/* SPDX-FileCopyrightText: 2016 Software Freedom Conservancy Inc.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

// A file's size and modification time.  The time is kept as whole seconds, which is what the
// database stores, so no DateTime is needed to compare it.
public class FileStamp {
    public int64 size;
    public int64 mtime;
    
    public FileStamp(int64 size, int64 mtime) {
        this.size = size;
        this.mtime = mtime;
    }
    
    public FileStamp.from_info(FileInfo info) {
        this(info.get_size(), info.get_modification_date_time().to_unix());
    }
    
    public static uint hash(FileStamp stamp) {
        return (uint) (stamp.size ^ (stamp.size >> 32) ^ (stamp.mtime * 0x9E3779B1));
    }
    
    public static bool equal(FileStamp a, FileStamp b) {
        return a.size == b.size && a.mtime == b.mtime;
    }
}

// Finds the items whose backing file has the same size and modification time as a FileInfo, in
// one hash lookup.  Fill it once, then only look things up: it is a snapshot, and does not follow
// later changes to the items.
public class FileStampIndex<G> {
    private Gee.HashMap<FileStamp, Gee.ArrayList<G>> items =
        new Gee.HashMap<FileStamp, Gee.ArrayList<G>>(FileStamp.hash, FileStamp.equal);
    
    // An item without a modification time can never match.  Adding the same item twice in a row
    // for the same stamp (a photo with two backing files that look alike) is recorded once.
    public void add(int64 size, DateTime? mtime, G item) {
        if (mtime == null)
            return;
        
        FileStamp stamp = new FileStamp(size, mtime.to_unix());
        Gee.ArrayList<G>? list = items.get(stamp);
        if (list == null) {
            list = new Gee.ArrayList<G>();
            items.set(stamp, list);
        } else if (list.get(list.size - 1) == item) {
            return;
        }
        
        list.add(item);
    }
    
    // Returns null if nothing matches.
    public Gee.List<G>? get_matching(FileInfo info) {
        return items.get(new FileStamp.from_info(info));
    }
}

// The media that an unknown file found by the startup scan might be a moved copy of.  The scan
// only knows the file's size and modification time; the hash is read later, in a background job,
// and then narrows the candidates down.  Implementations must be safe to use from that job.
public abstract class MoveCandidates : Object {
    // How many media match the file's size and modification time.
    public abstract int get_count();
    
    // The only candidate, if get_count() is 1.
    public abstract Monitorable? get_single();
    
    // The candidates whose hash is md5.  Null if there are none.
    public abstract Gee.Collection<Monitorable>? with_md5(string md5);
}

// Candidates that are already known, narrowed by comparing each one's hash.
public class ListMoveCandidates : MoveCandidates {
    private Gee.Collection<Monitorable> candidates;
    
    public ListMoveCandidates(Gee.Collection<Monitorable> candidates) {
        this.candidates = candidates;
    }
    
    public override int get_count() {
        return candidates.size;
    }
    
    public override Monitorable? get_single() {
        foreach (Monitorable candidate in candidates)
            return candidate;
        
        return null;
    }
    
    public override Gee.Collection<Monitorable>? with_md5(string md5) {
        Gee.ArrayList<Monitorable> matching = new Gee.ArrayList<Monitorable>();
        foreach (Monitorable candidate in candidates) {
            if (candidate.get_master_md5() == md5)
                matching.add(candidate);
        }
        
        return matching;
    }
}

// Finds the media whose master has a given size, modification time and hash.  The size and time
// are known when the startup scan finds a file, the hash only after it was read, so both are
// looked up separately: a file whose size and time match nothing is never read, and one that
// does is matched by its hash in one more lookup, however many media share its size and time.
// Fill it once, then only look things up: it is a snapshot, and does not follow later changes to
// the media.
public class MoveIndex : Object {
    private class StampEntry {
        public Monitorable first;
        public int count = 0;
        
        public StampEntry(Monitorable first) {
            this.first = first;
        }
    }
    
    private class Key {
        public int64 size;
        public int64 mtime;
        public string md5;
        
        public Key(int64 size, int64 mtime, string md5) {
            this.size = size;
            this.mtime = mtime;
            this.md5 = md5;
        }
        
        public static uint hash(Key key) {
            return (uint) (key.size ^ (key.size >> 32) ^ (key.mtime * 0x9E3779B1)) ^ str_hash(key.md5);
        }
        
        public static bool equal(Key a, Key b) {
            return a.size == b.size && a.mtime == b.mtime && a.md5 == b.md5;
        }
    }
    
    private class Candidates : MoveCandidates {
        private MoveIndex index;
        private StampEntry entry;
        private FileStamp stamp;
        
        public Candidates(MoveIndex index, StampEntry entry, FileStamp stamp) {
            this.index = index;
            this.entry = entry;
            this.stamp = stamp;
        }
        
        public override int get_count() {
            return entry.count;
        }
        
        public override Monitorable? get_single() {
            return entry.first;
        }
        
        public override Gee.Collection<Monitorable>? with_md5(string md5) {
            return index.items.get(new Key(stamp.size, stamp.mtime, md5));
        }
    }
    
    private Gee.HashMap<FileStamp, StampEntry> stamps =
        new Gee.HashMap<FileStamp, StampEntry>(FileStamp.hash, FileStamp.equal);
    private Gee.HashMap<Key, Gee.ArrayList<Monitorable>> items =
        new Gee.HashMap<Key, Gee.ArrayList<Monitorable>>(Key.hash, Key.equal);
    
    // An item without a modification time can never match.  One without a hash counts as a
    // candidate for its size and time, but cannot be found by hash.
    public void add(int64 size, DateTime? mtime, string? md5, Monitorable item) {
        if (mtime == null)
            return;
        
        int64 seconds = mtime.to_unix();
        FileStamp stamp = new FileStamp(size, seconds);
        StampEntry? entry = stamps.get(stamp);
        if (entry == null) {
            entry = new StampEntry(item);
            stamps.set(stamp, entry);
        }
        entry.count++;
        
        if (md5 == null)
            return;
        
        Key key = new Key(size, seconds, md5);
        Gee.ArrayList<Monitorable>? list = items.get(key);
        if (list == null) {
            list = new Gee.ArrayList<Monitorable>();
            items.set(key, list);
        }
        
        list.add(item);
    }
    
    // Returns null if no item has this file's size and modification time.
    public MoveCandidates? get_candidates(FileInfo info) {
        FileStamp stamp = new FileStamp.from_info(info);
        StampEntry? entry = stamps.get(stamp);
        
        return (entry != null) ? new Candidates(this, entry, stamp) : null;
    }
}

public class MonitorableUpdates {
    public Monitorable monitorable;
    
    private File? master_file = null;
    private bool master_file_info_altered = false;
    private FileInfo? master_file_info = null;
    private bool master_in_alteration = false;
    private bool online = false;
    private bool offline = false;
    
    public MonitorableUpdates(Monitorable monitorable) {
        this.monitorable = monitorable;
    }
    
    public File? get_master_file() {
        return master_file;
    }
    
    public FileInfo? get_master_file_info() {
        return master_file_info;
    }
    
    public virtual bool is_in_alteration() {
        return master_in_alteration;
    }
    
    public bool is_set_offline() {
        return offline;
    }
    
    public bool is_set_online() {
        return online;
    }
    
    public virtual void set_master_file(File? file) {
        master_file = file;
        
        if (file != null)
            mark_online();
    }
    
    public virtual void set_master_file_info_altered(bool altered) {
        master_file_info_altered = altered;
        
        if (altered)
            mark_online();
    }
    
    public virtual void set_master_file_info(FileInfo? info) {
        master_file_info = info;
        
        if (master_file_info == null)
            set_master_file_info_altered(false);
    }
    
    public virtual void set_master_in_alteration(bool in_alteration) {
        master_in_alteration = in_alteration;
    }
    
    public virtual void set_master_alterations_complete(FileInfo info) {
        set_master_in_alteration(false);
        set_master_file_info(info);
        mark_online();
    }
    
    public virtual void mark_offline() {
        online = false;
        offline = true;
        
        master_file_info_altered = false;
        master_file_info = null;
        master_in_alteration = false;
    }
    
    public virtual void mark_online() {
        online = true;
        offline = false;
    }
    
    public virtual void reset_online_offline() {
        online = false;
        offline = false;
    }
    
    public virtual bool is_all_updated() {
        return master_file == null
            && master_file_info_altered == false
            && master_file_info == null
            && master_in_alteration == false
            && online == false
            && offline == false;
    }
}

public abstract class MediaMonitor : Object {
    public enum DiscoveredFile {
        REPRESENTED,
        IGNORE,
        UNKNOWN
    }
    
    protected const int MAX_OPERATIONS_PER_CYCLE = 100;
    
    private const int FLUSH_PENDING_UPDATES_MSEC = 500;
    
    private MediaSourceCollection sources;
    private Cancellable cancellable;
    private Gee.HashMap<Monitorable, MonitorableUpdates> pending_updates = new Gee.HashMap<Monitorable,
        MonitorableUpdates>();
    private uint pending_updates_timer_id = 0;
    
    protected MediaMonitor(MediaSourceCollection sources, Cancellable cancellable) {
        this.sources = sources;
        this.cancellable = cancellable;
        
        sources.item_destroyed.connect(on_media_source_destroyed);
        sources.unlinked_destroyed.connect(on_media_source_destroyed);
        
        pending_updates_timer_id = Timeout.add(FLUSH_PENDING_UPDATES_MSEC, on_flush_pending_updates,
            Priority.LOW);
    }
    
    ~MediaMonitor() {
        sources.item_destroyed.disconnect(on_media_source_destroyed);
        sources.unlinked_destroyed.disconnect(on_media_source_destroyed);
    }
    
    public abstract MediaSourceCollection get_media_source_collection();
    
    public virtual void close() {
    }
    
    public virtual string to_string() {
        return "MediaMonitor for %s".printf(get_media_source_collection().to_string());
    }
    
    protected virtual MonitorableUpdates create_updates(Monitorable monitorable) {
        return new MonitorableUpdates(monitorable);
    }
    
    protected virtual void on_media_source_destroyed(DataSource source) {
        remove_updates((Monitorable) source);
    }
    
    //
    // The following are called when the startup scan is initiated.
    //
    
    public virtual void notify_discovery_started() {
    }
    
    // Returns the Monitorable represented in some form by the monitors' MediaSourceCollection.
    // If DiscoveredFile.REPRESENTED is returns, monitorable should be set.
    public abstract DiscoveredFile notify_file_discovered(File file, FileInfo info,
        out Monitorable monitorable);
    
    // Called around the loop that asks move_candidates_for_unknown_file() about every unknown file
    // of the startup scan.  Between the two calls a monitor may answer from a snapshot taken in
    // the first one, instead of searching its media for every file.
    public virtual void notify_unknown_file_matching_started() {
    }

    public virtual void notify_unknown_file_matching_completed() {
    }

    // Returns REPRESENTED if the file has been *definitively* associated with a Monitorable,
    // in which case the file will no longer be considered unknown.  Returns IGNORE if the file
    // is known in some other case and should not be considered unknown.  Returns UNKNOWN otherwise,
    // with potentially a collection of candidates for the file.  The collection may be zero-length.
    //
    // NOTE: This method may be called after the startup scan as well.
    public abstract Gee.Collection<Monitorable>? candidates_for_unknown_file(File file, FileInfo info,
        out DiscoveredFile result);
    
    // Like candidates_for_unknown_file(), for the startup scan: the candidates are returned
    // without their hash being compared, so that the file is only read if there are any.
    public virtual DiscoveredFile move_candidates_for_unknown_file(File file, FileInfo info,
        out MoveCandidates? candidates) {
        DiscoveredFile result;
        Gee.Collection<Monitorable>? matched = candidates_for_unknown_file(file, info, out result);
        candidates = (matched != null && matched.size > 0) ? new ListMoveCandidates(matched) : null;
        
        return result;
    }
    
    public virtual File[]? get_auxilliary_backing_files(Monitorable monitorable) {
        return null;
    }
    
    // info is null if the file was not found.  Note that master online/offline state is already
    // set by LibraryMonitor.
    public virtual void update_backing_file_info(Monitorable monitorable, File file, FileInfo? info) {
    }
    
    // Not that discovery has completed, but the MediaMonitor's role in it has finished.
    public virtual void notify_discovery_completing() {
    }
    
    //
    // The following are called after the startup scan for runtime monitoring.
    //
    
    public abstract bool is_file_represented(File file);
    
    public abstract bool notify_file_created(File file, FileInfo info);
    
    public abstract bool notify_file_moved(File old_file, File new_file, FileInfo new_file_info);
    
    public abstract bool notify_file_altered(File file);
    
    public abstract bool notify_file_attributes_altered(File file);
    
    public abstract bool notify_file_alteration_completed(File file, FileInfo info);
    
    public abstract bool notify_file_deleted(File file);
    
    protected static void mdbg(string msg) {
#if TRACE_MONITORING
        debug("%s", msg);
#endif
    }
    
    public bool has_pending_updates() {
        return pending_updates.size > 0;
    }
    
    public Gee.Collection<Monitorable> get_monitorables() {
        return pending_updates.keys;
    }
    
    // This will create a MonitorableUpdates and register it with this updater if not already
    // exists.
    public MonitorableUpdates fetch_updates(Monitorable monitorable) {
        MonitorableUpdates? updates = pending_updates.get(monitorable);
        if (updates != null)
            return updates;
        
        updates = create_updates(monitorable);
        pending_updates.set(monitorable, updates);
        
        return updates;
    }
    
    public MonitorableUpdates? get_existing_updates(Monitorable monitorable) {
        return pending_updates.get(monitorable);
    }
    
    public void remove_updates(Monitorable monitorable) {
        pending_updates.unset(monitorable);
    }
    
    public bool is_online(Monitorable monitorable) {
        MonitorableUpdates? updates = get_existing_updates(monitorable);
        
        return (updates != null) ? updates.is_set_online() : !monitorable.is_offline();
    }
    
    public bool is_offline(Monitorable monitorable) {
        MonitorableUpdates? updates = get_existing_updates(monitorable);
        
        return (updates != null) ? updates.is_set_offline() : monitorable.is_offline();
    }
    
    public File get_master_file(Monitorable monitorable) {
        MonitorableUpdates? updates = get_existing_updates(monitorable);
        
        return (updates != null && updates.get_master_file() != null) ? updates.get_master_file()
            : monitorable.get_master_file();
    }
    
    public void update_master_file(Monitorable monitorable, File file) {
        fetch_updates(monitorable).set_master_file(file);
    }
    
    public void update_master_file_info_altered(Monitorable monitorable) {
        fetch_updates(monitorable).set_master_file_info_altered(true);
    }
    
    public void update_master_file_in_alteration(Monitorable monitorable, bool in_alteration) {
        fetch_updates(monitorable).set_master_in_alteration(in_alteration);
    }
    
    public void update_master_file_alterations_completed(Monitorable monitorable, FileInfo info) {
        fetch_updates(monitorable).set_master_alterations_complete(info);
    }
    
    public void update_online(Monitorable monitorable) {
        fetch_updates(monitorable).mark_online();
    }
    
    public void update_offline(Monitorable monitorable) {
        fetch_updates(monitorable).mark_offline();
    }
    
    // Children should call this method before doing their own processing.  Every operation should
    // be recorded by incrementing op_count.  If it is greater than MAX_OPERATIONS_PER_CYCLE,
    // the method should process what has been done and exit to let the operations be handled in
    // the next cycle.
    protected virtual void process_updates(Gee.Collection<MonitorableUpdates> all_updates,
        TransactionController controller, ref int op_count) throws Error {
        Gee.Map<Monitorable, File> set_master_file = null;
        Gee.Map<Monitorable, FileInfo> set_master_file_info = null;
        Gee.ArrayList<Monitorable> to_offline = null;
        Gee.ArrayList<Monitorable> to_online = null;
        
        foreach (MonitorableUpdates updates in all_updates) {
            if (op_count >= MAX_OPERATIONS_PER_CYCLE)
                break;
            
            if (updates.get_master_file() != null) {
                if (set_master_file == null)
                    set_master_file = new Gee.HashMap<Monitorable, File>();
                
                set_master_file.set(updates.monitorable, updates.get_master_file());
                updates.set_master_file(null);
                op_count++;
            }
            
            if (updates.get_master_file_info() != null) {
                if (set_master_file_info == null)
                    set_master_file_info = new Gee.HashMap<Monitorable, FileInfo>();
                
                set_master_file_info.set(updates.monitorable, updates.get_master_file_info());
                updates.set_master_file_info(null);
                op_count++;
            }
            
            if (updates.is_set_offline()) {
                if (to_offline == null)
                    to_offline = new Gee.ArrayList<LibraryPhoto>();
                
                to_offline.add(updates.monitorable);
                updates.reset_online_offline();
                op_count++;
            }
            
            if (updates.is_set_online()) {
                if (to_online == null)
                    to_online = new Gee.ArrayList<LibraryPhoto>();
                
                to_online.add(updates.monitorable);
                updates.reset_online_offline();
                op_count++;
            }
        }
        
        if (set_master_file != null) {
            mdbg("Changing master file of %d objects in %s".printf(set_master_file.size, to_string()));
            
            Monitorable.set_many_master_file(set_master_file, controller);
        }
        
        if (set_master_file_info != null) {
            mdbg("Updating %d master files timestamps in %s".printf(set_master_file_info.size,
                to_string()));
            
            Monitorable.set_many_master_timestamp(set_master_file_info, controller);
        }
        
        if (to_offline != null || to_online != null) {
            mdbg("Marking %d online, %d offline in %s".printf(
                (to_online != null) ? to_online.size : 0,
                (to_offline != null) ? to_offline.size : 0,
                to_string()));
            
            Monitorable.mark_many_online_offline(to_online, to_offline, controller);
        }
    }
    
    private bool on_flush_pending_updates() {
        if (cancellable.is_cancelled())
            return false;
        
        if (pending_updates.size == 0)
            return true;
        
        Timer timer = new Timer();
        
        // build two lists: one, of MonitorableUpdates that are not in_alteration() (which
        // simplifies matters), and two, of completed MonitorableUpdates that should be removed
        // from the list (which would have happened after the last pass)
        Gee.ArrayList<MonitorableUpdates> to_process = null;
        Gee.ArrayList<Monitorable> to_remove = null;
        foreach (MonitorableUpdates updates in pending_updates.values) {
            if (updates.is_in_alteration())
                continue;
            
            if (updates.is_all_updated()) {
                if (to_remove == null)
                    to_remove = new Gee.ArrayList<Monitorable>();
                
                to_remove.add(updates.monitorable);
                continue;
            }
            
            if (to_process == null)
                to_process = new Gee.ArrayList<MonitorableUpdates>();
            
            to_process.add(updates);
        }
        
        int op_count = 0;
        if (to_process != null) {
            TransactionController controller = get_media_source_collection().transaction_controller;
            
            try {
                controller.begin();
                process_updates(to_process, controller, ref op_count);
                controller.commit();
            } catch (Error err) {
                if (err is DatabaseError)
                    AppWindow.database_error((DatabaseError) err);
                else
                    AppWindow.panic(_("Unable to process monitoring updates: %s").printf(err.message));
            }
        }
        
        if (to_remove != null) {
            foreach (Monitorable monitorable in to_remove)
                remove_updates(monitorable);
        }
        
        double elapsed = timer.elapsed();
        if (elapsed > 0.01 || op_count > 0) {
            mdbg("Total pending queue time for %s: %lf (%d ops)".printf(to_string(), elapsed,
                op_count));
        }
        
        return true;
    }
}

