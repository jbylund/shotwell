public class DuplicatedFile : Object {
    private VideoID? video_id;
    private PhotoID? photo_id;
    private File? file;
    private DuplicatedFile() {
        this.video_id = null;
        this.photo_id = null;
        this.file = null;
    }
    public static DuplicatedFile create_from_photo_id(PhotoID photo_id) {
        assert(photo_id.is_valid());
        DuplicatedFile result = new DuplicatedFile();
        result.photo_id = photo_id;
        return result;
    }
    public static DuplicatedFile create_from_video_id(VideoID video_id) {
        assert(video_id.is_valid());
        DuplicatedFile result = new DuplicatedFile();
        result.video_id = video_id;
        return result;
    }
    public static DuplicatedFile create_from_file(File file) {
        DuplicatedFile result = new DuplicatedFile();
        result.file = file;
        return result;
    }
    public File get_file() {
        if (file != null) {
            return file;
        } else if (photo_id != null) {
            Photo photo_object = (Photo) LibraryPhoto.global.fetch(photo_id);
            file = photo_object.get_master_file();
            return file;
        } else if (video_id != null) {
            Video video_object = (Video) Video.global.fetch(video_id);
            file = video_object.get_master_file();
            return file;
        } else {
            assert_not_reached();
        }
    }
}
