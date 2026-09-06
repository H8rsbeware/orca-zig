const std = @import("std");
const henc = @import("header_encoder.zig");

// The db is made up of the following:
// metadata.db - what is stored where
// sequence.dat - blob of paged binary data for sequence
// alignment.dat - blob of what references what and where
//

test "Headers_all_assert_as_headers" {
    assertIsHeaderType(FileHeader);
    assertIsHeaderType(SequenceRecord);
    assertIsHeaderType(Extent);
}

pub fn assertIsHeaderType(comptime T: type) void {
    const has_encode = @hasDecl(T, "Encode");
    const has_decode = @hasDecl(T, "Decode");

    if (!has_encode or !has_decode) {
        @compileError("Type '" ++ @typeName(T) ++
            "' is missing Header methods. Must implement both " ++
            "'pub fn Encode(self) []const u8' and 'pub fn Decode([]const u8) self'.");
    }
}

const PageId = u32;
const SequenceId = u32;

/// File type with top header of DB files
pub const DBFileType = enum(u3) {
    META_DATA = 0b000,
    SEQUENCE_DATA = 0b001,
    ALIGNMENT_DATA = 0b010,
    COLD_DATA = 0b011,
    // reserve rest
};

/// File header is written to the top of each db file,
/// including version, kind (DBFileType), page_shift (where size == 1<<S),
/// and generation (update count).
pub const FileHeader = struct { // 83
    const Self = @This();
    const Engine = henc.StructEncoderBuilder(Self);
    const byteSize = (@bitSizeOf(Self) + 7) / 8;

    version: u8,
    kind: DBFileType,
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

/// Sequences encoding type within DB
const SequenceEncoding = enum(u2) {
    BIT_2,
    BIT3_REFERENCED,
    // reserve rest
};

/// Meta data for a sequence, determining what, where, and how long sequences are.
pub const SequenceRecord = struct { // max 226 bits
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

/// Records the start and end page of a given sequence and how much of the
/// last page remains.
/// sequence length == (page_length * (1 << page_shift)) - page_unused
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
