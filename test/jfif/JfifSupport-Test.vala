// SPDX-FileCopyrightText: Software Freedom Conservancy Inc.
// SPDX-License-Identifier: LGPL-2.1-or-later

[CCode (cname="TEST_DATA_DIR")]
extern const string TEST_DATA_DIR;

void add_jfif_sof_tests () {
    Test.add_func ("/unit/photos/jfif/is_sof", () => {
      Jpeg.Marker m = (Jpeg.Marker)0x8f;
      assert(! m.is_sof());
      m = (Jpeg.Marker)0xc0;
      assert(m.is_sof());
      m = (Jpeg.Marker)0xc4;
      assert(! m.is_sof());
      m = (Jpeg.Marker)0xe0;
      assert(! m.is_sof());
    });
}

void add_jfif_sniff_fast_tests () {
    Test.add_func ("/functional/photos/jfif/sniff_fast", () => {
            File f = File.new_for_path(TEST_DATA_DIR + "/shotwell-street.jpg");
            JfifSniffer s = new JfifSniffer(f, PhotoFileSniffer.Options.NO_MD5);
            bool is_corrupted = false;
            try {
                DetectedPhotoInformation detected = s.sniff(out is_corrupted);
                assert(!is_corrupted);
                assert(detected.channels == 3);
                assert(detected.bits_per_channel == 8);
                assert(detected.format_name == "jpeg");
                assert(detected.image_dim.width == 360);
                assert(detected.image_dim.height == 236);
                // NO_MD5 must not hash the file; the caller supplies the hashes
                assert(detected.md5 == null);
                assert(detected.thumbnail_md5 == null);
                } catch (Error err) {
                assert_not_reached();
            }
    });
}

void add_jfif_sniff_fast_metadata_tests () {
    Test.add_func ("/functional/photos/jfif/sniff_fast_reads_jpeg_metadata", () => {
            File f = File.new_for_path(TEST_DATA_DIR + "/shotwell-street.jpg");
            JfifSniffer s = new JfifSniffer(f, PhotoFileSniffer.Options.NO_MD5);
            bool is_corrupted = false;
            try {
                int reads = PhotoMetadata.read_count;
                DetectedPhotoInformation? detected = s.sniff(out is_corrupted);
                assert(detected != null);
                assert(!is_corrupted);
                // The metadata of a JPEG is parsed, once
                assert(PhotoMetadata.read_count == reads + 1);
            } catch (Error err) {
                assert_not_reached();
            }
    });

    Test.add_func ("/functional/photos/jfif/sniff_fast_not_jpeg", () => {
            try {
                // A little-endian TIFF header, as at the start of most RAW files
                FileIOStream ios;
                File f = File.new_tmp("jfif-test-XXXXXX.tif", out ios);
                uint8[] tiff = { 0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00 };
                size_t written;
                ios.output_stream.write_all(tiff, out written);
                ios.close();

                JfifSniffer s = new JfifSniffer(f, PhotoFileSniffer.Options.NO_MD5);
                bool is_corrupted = false;
                int reads = PhotoMetadata.read_count;
                DetectedPhotoInformation? detected = s.sniff(out is_corrupted);
                f.delete();

                assert(detected == null);
                assert(!is_corrupted);
                // The metadata of a file that is not a JPEG must not be parsed
                assert(PhotoMetadata.read_count == reads);
            } catch (Error err) {
                assert_not_reached();
            }
    });
}

// Small JPEGs that cover a baseline file, a progressive file with odd dimensions, a file
// whose EXIF orientation swaps width and height on display and a grayscale file (one component,
// still reported as three channels because it is decoded as RGB). The sizes are the ones in
// the SOF marker, which is what the sniffers report: they ignore the EXIF orientation.
struct TestJpeg {
    string name;
    int width;
    int height;
}

const TestJpeg[] TEST_JPEGS = {
    { "shotwell-street.jpg", 360, 236 },
    { "shotwell-street-progressive.jpg", 357, 233 },
    { "shotwell-street-rotated.jpg", 341, 223 },
    { "shotwell-street-gray.jpg", 357, 233 }
};

void add_jfif_header_dimensions_tests () {
    // Does not need a glycin loader: NO_MD5 reads the size from the header.
    Test.add_func ("/functional/photos/jfif/header_dimensions_fast", () => {
            foreach (unowned TestJpeg jpeg in TEST_JPEGS) {
                File f = File.new_for_path(TEST_DATA_DIR + "/" + jpeg.name);
                bool is_corrupted = false;
                try {
                    DetectedPhotoInformation? fast =
                        new JfifSniffer(f, PhotoFileSniffer.Options.NO_MD5).sniff(out is_corrupted);
                    assert(fast != null);
                    assert(!is_corrupted);
                    assert(fast.image_dim.equals(Dimensions(jpeg.width, jpeg.height)));
                } catch (Error err) {
                    critical("%s: %s", jpeg.name, err.message);
                    assert_not_reached();
                }
            }
    });

    // Decodes with glycin, so it is skipped where glycin cannot start its sandboxed loader
    // (for example in a flatpak-builder build).
    Test.add_func ("/functional/photos/jfif/header_dimensions_glycin", () => {
            foreach (unowned TestJpeg jpeg in TEST_JPEGS) {
                File f = File.new_for_path(TEST_DATA_DIR + "/" + jpeg.name);
                try {
                    // What the image decodes to, ignoring the EXIF orientation like the
                    // sniffers do
                    Gdk.Pixbuf decoded;
                    try {
                        decoded = new JfifReader(f.get_path()).unscaled_read();
                    } catch (Error err) {
                        Test.skip("glycin cannot decode: " + err.message);
                        return;
                    }
                    Dimensions decoded_dim = Dimensions.for_pixbuf(decoded);
                    assert(decoded_dim.equals(Dimensions(jpeg.width, jpeg.height)));

                    bool is_corrupted = false;
                    DetectedPhotoInformation? full =
                        new JfifSniffer(f, PhotoFileSniffer.Options.GET_ALL).sniff(out is_corrupted);
                    assert(full != null);
                    assert(!is_corrupted);
                    assert(full.image_dim.equals(decoded_dim));
                    assert(full.channels == 3);
                    assert(full.format_name == "jpeg");
                    assert(full.md5 != null);
                } catch (Error err) {
                    critical("%s: %s", jpeg.name, err.message);
                    assert_not_reached();
                }
            }
    });
}

void main (string[] args) {
    Test.init (ref args);
    add_jfif_sof_tests();
    add_jfif_sniff_fast_tests();
    add_jfif_sniff_fast_metadata_tests();
    add_jfif_header_dimensions_tests();
    Test.run();
}

