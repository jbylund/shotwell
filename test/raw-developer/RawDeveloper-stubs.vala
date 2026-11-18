// SPDX-FileCopyrightText: Software Freedom Conservancy Inc.
// SPDX-License-Identifier: LGPL-2.1-or-later
// Stubs for the parts of the application that RawDeveloper.develop() needs

// What the PhotoMetadata stub returns. This is not kept in static class fields, because the
// class initializer would reset them the first time a PhotoMetadata is created.
namespace MetadataStub {
    public PhotoPreview[] previews;
    public bool fail_write;
    public int write_count;
}

public class PhotoMetadata {
    public PhotoMetadata() { }
    public void read_from_file(File file) throws Error { }

    public void write_to_file(File file) throws Error {
        if (MetadataStub.fail_write)
            throw new IOError.FAILED("metadata write failure requested by the test");
        MetadataStub.write_count++;
    }

    public string? thumbnail_hash() { return null; }
    public uint get_preview_count() { return MetadataStub.previews.length; }
    public PhotoPreview? get_preview(uint number) { return MetadataStub.previews[number]; }
}

// Same interface as the PhotoPreview in src/photos/PhotoMetadata.vala
public abstract class PhotoPreview {
    public abstract Bytes flatten() throws Error;

    public virtual Gdk.Pixbuf? get_pixbuf() throws Error {
        try {
            return new Gdk.Pixbuf.from_stream(new MemoryInputStream.from_bytes(flatten()));
        } catch (Error err) {
            return null;
        }
    }
}

public struct BackingPhotoID {
    public const int64 INVALID = -1;
    public int64 id;
}

public class BackingPhotoRow {
    public BackingPhotoID id;
    public string? filepath = null;
    public PhotoFileFormat file_format;
}

namespace LibraryFiles {
    public string convert_basename(string basename) { return basename; }
}

public string md5_file(File file) throws Error {
    Checksum md5 = new Checksum(ChecksumType.MD5);
    uint8[] contents;
    file.load_contents(null, out contents, null);
    md5.update(contents, contents.length);

    return md5.get_string();
}
