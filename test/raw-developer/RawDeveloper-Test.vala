// SPDX-FileCopyrightText: Software Freedom Conservancy Inc.
// SPDX-License-Identifier: LGPL-2.1-or-later

[CCode (cname="TEST_DATA_DIR")]
extern const string TEST_DATA_DIR;

// Stands in for the RawReader of the master file
class TestRawReader : PhotoFileReader {
    public Gdk.Pixbuf? pixbuf = null;
    public PhotoMetadata metadata = new PhotoMetadata();

    public TestRawReader(string filepath) {
        base (filepath, PhotoFileFormat.RAW);
    }

    public override PhotoMetadata read_metadata() throws Error {
        return metadata;
    }

    public override Gdk.Pixbuf unscaled_read() throws Error {
        if (pixbuf == null)
            throw new IOError.FAILED("decode failure requested by the test");

        return pixbuf;
    }
}

class BytesPreview : PhotoPreview {
    private Bytes bytes;

    public BytesPreview(Bytes bytes) {
        this.bytes = bytes;
    }

    public override Bytes flatten() throws Error {
        return bytes;
    }
}

string[] temp_dirs;

// A fresh directory with an (empty) master file in it, as after the copy into the library
string make_master() {
    try {
        string dir = DirUtils.make_tmp("raw-developer-test-XXXXXX");
        temp_dirs += dir;
        string master = Path.build_filename(dir, "IMG_0001.CR2");
        FileUtils.set_contents(master, "");

        return master;
    } catch (Error err) {
        error("%s", err.message);
    }
}

void reset_stubs() {
    MetadataStub.previews = {};
    MetadataStub.fail_write = false;
    MetadataStub.write_count = 0;
}

Bytes load_bytes(string path) {
    try {
        uint8[] contents;
        FileUtils.get_data(path, out contents);

        return new Bytes(contents);
    } catch (Error err) {
        error("%s", err.message);
    }
}

Gdk.Pixbuf make_pixbuf(int width, int height) {
    var pixbuf = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, width, height);
    pixbuf.fill(0x336699ff);

    return pixbuf;
}

Dimensions decoded_dimensions(string path) {
    try {
        return Dimensions.for_pixbuf(new JfifReader(path).unscaled_read());
    } catch (Error err) {
        error("%s: %s", path, err.message);
    }
}

bool is_jpeg(string path) {
    try {
        return Jpeg.is_jpeg(File.new_for_path(path));
    } catch (Error err) {
        return false;
    }
}

void add_embedded_tests() {
    Test.add_func("/functional/photos/raw/develop_embedded_jpeg", () => {
        reset_stubs();
        Bytes jpeg = load_bytes(TEST_DATA_DIR + "/shotwell-street.jpg");
        // A small preview first: the largest (last) one must be used
        MetadataStub.previews = {
            new BytesPreview(load_bytes(TEST_DATA_DIR + "/shotwell-street-rotated.jpg")),
            new BytesPreview(jpeg)
        };
        string master = make_master();

        BackingPhotoRow? row = RawDeveloper.EMBEDDED.develop(new TestRawReader(master));
        assert(row != null);
        assert(row.file_format == PhotoFileFormat.JFIF);
        assert(row.filepath == Path.build_filename(Path.get_dirname(master), "IMG_0001_CR2_embedded.jpg"));
        // A JPEG preview is written as it is, then the master's metadata is added
        assert(load_bytes(row.filepath).compare(jpeg) == 0);
        assert(MetadataStub.write_count == 1);
    });

    Test.add_func("/functional/photos/raw/develop_embedded_not_jpeg", () => {
        reset_stubs();
        uint8[] png;
        try {
            make_pixbuf(41, 29).save_to_buffer(out png, "png");
        } catch (Error err) {
            error("%s", err.message);
        }
        MetadataStub.previews = { new BytesPreview(new Bytes(png)) };
        string master = make_master();

        BackingPhotoRow? row = RawDeveloper.EMBEDDED.develop(new TestRawReader(master));
        assert(row != null);
        // Other preview formats are decoded and encoded as JPEG
        assert(is_jpeg(row.filepath));
        assert(decoded_dimensions(row.filepath).equals(Dimensions(41, 29)));
        assert(MetadataStub.write_count == 1);
    });

    Test.add_func("/functional/photos/raw/develop_embedded_no_preview", () => {
        reset_stubs();
        string master = make_master();

        assert(RawDeveloper.EMBEDDED.develop(new TestRawReader(master)) == null);
        // Nothing is created when there is no preview to write
        assert(!FileUtils.test(Path.build_filename(Path.get_dirname(master), "IMG_0001_CR2_embedded.jpg"),
            FileTest.EXISTS));
    });
}

void add_shotwell_tests() {
    Test.add_func("/functional/photos/raw/develop_shotwell", () => {
        reset_stubs();
        string master = make_master();
        var reader = new TestRawReader(master);
        reader.pixbuf = make_pixbuf(37, 23);

        BackingPhotoRow? row = RawDeveloper.SHOTWELL.develop(reader);
        assert(row != null);
        assert(row.file_format == PhotoFileFormat.JFIF);
        assert(row.filepath == Path.build_filename(Path.get_dirname(master), "IMG_0001_CR2_shotwell.jpg"));
        assert(is_jpeg(row.filepath));
        // Not rotated: the photo is displayed with the orientation of the master
        assert(decoded_dimensions(row.filepath).equals(Dimensions(37, 23)));
        assert(MetadataStub.write_count == 1);
    });

    Test.add_func("/functional/photos/raw/develop_shotwell_metadata_failure", () => {
        reset_stubs();
        MetadataStub.fail_write = true;
        string master = make_master();
        var reader = new TestRawReader(master);
        reader.pixbuf = make_pixbuf(37, 23);

        // The image was written, so the development is usable without the metadata
        BackingPhotoRow? row = RawDeveloper.SHOTWELL.develop(reader);
        assert(row != null);
        assert(decoded_dimensions(row.filepath).equals(Dimensions(37, 23)));
    });

    Test.add_func("/functional/photos/raw/develop_shotwell_decode_failure", () => {
        reset_stubs();
        string master = make_master();

        assert(RawDeveloper.SHOTWELL.develop(new TestRawReader(master)) == null);
        assert(MetadataStub.write_count == 0);
    });
}

void add_camera_tests() {
    Test.add_func("/functional/photos/raw/develop_camera", () => {
        reset_stubs();
        string master = make_master();
        var reader = new TestRawReader(master);
        reader.pixbuf = make_pixbuf(37, 23);

        // The camera supplies this development, there is nothing to do
        assert(RawDeveloper.CAMERA.develop(reader) == null);
    });
}

int main(string[] args) {
    Test.init(ref args);
    // develop() writes the JPEG with the JFIF writers
    PhotoFileFormat.JFIF.init();
    add_embedded_tests();
    add_shotwell_tests();
    add_camera_tests();
    int result = Test.run();

    foreach (string dir in temp_dirs) {
        try {
            Dir d = Dir.open(dir);
            string? name;
            while ((name = d.read_name()) != null)
                FileUtils.unlink(Path.build_filename(dir, name));
        } catch (Error err) {
            // leave it
        }
        DirUtils.remove(dir);
    }

    return result;
}
