const std = @import("std");
const henc = @import("header_encoder.zig");

// The db is made up of the following:
// metadata.db - what is stored where
// sequence.dat - blob of paged binary data for sequence
// alignment.dat - blob of what references what and where
//

const PageId = u32;
const SequenceId = u32;

const FileKind = enum(u3) {
    META_DATA = 0b000,
    SEQUENCE_DATA = 0b001,
    ALIGNMENT_DATA = 0b010,
    // reserve rest
};

const SequenceEncoding = enum(u2) {
    BIT_2,
    BIT3_REFERENCED,
    // reserve rest
};

const FileHeader = struct { // 83
    const Self = @This();
    const Engine = henc.StructEncoderBuilder(Self);
    const byteSize = (@bitSizeOf(Self) + 7) / 8;

    version: u8,
    kind: FileKind,
    page_shift: u8,
    generation: u64,

    pub fn Encode(self: Self) ![]const u8 {
        var buffer: [byteSize]u8 = undefined;
        return try Engine.Encode(self, &buffer);
    }

    pub fn Decode(slice: []const u8) !Self {
        return try Engine.Decode(slice);
    }
};

const SequenceRecord = struct { // max 226 bits
    const Self = @This();
    const Engine = henc.StructEncoderBuilder(Self);
    const byteSize = (@bitSizeOf(Self) + 7) / 8;

    id: SequenceId,
    length: u64, // real length, not encoded length
    encoding: SequenceEncoding,
    payload: Extent, // encoded position and length
    reference: ?SequenceId,

    pub fn Encode(self: Self) ![]const u8 {
        var buffer: [byteSize]u8 = undefined;
        return try Engine.Encode(self, &buffer);
    }

    pub fn Decode(slice: []const u8) !Self {
        return try Engine.Decode(slice);
    }
};

const Extent = struct { // 96
    const Self = @This();
    const Engine = henc.StructEncoderBuilder(Self);
    const byteSize = (@bitSizeOf(Self) + 7) / 8;

    first_page: PageId, // Stable id
    page_length: u32, // How many pages are used (even partially)
    page_unused: u32, // How much of the last page is leftover

    pub fn Encode(self: Self) ![]const u8 {
        var buffer: [byteSize]u8 = undefined;
        return try Engine.Encode(self, &buffer);
    }

    pub fn Decode(slice: []const u8) !Self {
        return try Engine.Decode(slice);
    }
};

test "FileHeader_encodes_and_decodes_same" {
    var fh: FileHeader = .{ .version = 10, .kind = FileKind.SEQUENCE_DATA, .page_shift = 12, .generation = 3 };

    const enc: []const u8 = try fh.Encode();
    const dec: FileHeader = try FileHeader.Decode(enc);

    try std.testing.expectEqualDeep(fh, dec);
}
