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
            "'pub fn Encode(self) []const u8' and 'pub fn Decode([]const u8) struct {value: self, cursor: usize}'.");
    }
}

pub const PageId = u32;
pub const SequenceId = u32;

/// File type with top header of DB files
pub const DBFileType = enum(u3) {
    META_DATA = 0b000,
    SEQUENCE_DATA = 0b001,
    ALIGNMENT_DATA = 0b010,
    COLD_DATA = 0b011,
    TRANSACTIONS_STATE = 0b100,
    INDEX_DATA = 0b101,
    // reserve rest
};

/// File header is written to the top of each db file,
/// including version, kind (DBFileType), page_shift (where size == 1<<S),
/// and generation (update count).
pub const FileHeader = struct { // 83
    const Self = @This();
    const Engine = henc.StructEncoderBuilder(Self);
    pub const max_encoded_size = Engine.max_encoded_size;

    version: u8,
    kind: DBFileType,
    page_shift: u8,
    generation: u64,

    pub fn Encode(self: Self) ![]const u8 {
        var buffer: [max_encoded_size]u8 = undefined;
        return try Engine.Encode(self, &buffer);
    }

    pub fn Decode(slice: []const u8) !henc.DecodeResult(Self) {
        return try Engine.Decode(slice);
    }
};

/// Sequences encoding type within DB
pub const SequenceEncoding = enum(u2) {
    BIT_2,
    BIT3_REFERENCED,
    // reserve rest
};

pub const SequenceState = enum(u2) {
    RESERVED = 0b00,
    DELETED = 0b01,
    ACTIVE = 0b10,
    // reserved
};

/// Meta data for a sequence, determining what, where, and how long sequences are.
pub const SequenceRecord = struct { // max 228 bits
    const Self = @This();
    const Engine = henc.StructEncoderBuilder(Self);
    pub const max_encoded_size = Engine.max_encoded_size;

    id: SequenceId,
    length: u64, // real length, not encoded length
    state: SequenceState,
    encoding: SequenceEncoding,
    payload: Extent, // encoded position and length
    reference: ?SequenceId,

    pub fn Encode(self: Self) ![]const u8 {
        var buffer: [max_encoded_size]u8 = undefined;
        return try Engine.Encode(self, &buffer);
    }

    pub fn Decode(slice: []const u8) !henc.DecodeResult(Self) {
        return try Engine.Decode(slice);
    }
};

/// Records the start and end page of a given sequence and how much of the
/// last page remains.
/// sequence length == (page_length * (1 << page_shift)) - page_unused
pub const Extent = struct { // 96
    const Self = @This();
    const Engine = henc.StructEncoderBuilder(Self);
    pub const max_encoded_size = Engine.max_encoded_size;

    first_page: PageId, // Stable id
    page_length: u32, // How many pages are used (even partially)
    page_unused: u32, // How much of the last page is leftover

    pub fn Encode(self: Self) ![]const u8 {
        var buffer: [max_encoded_size]u8 = undefined;
        return try Engine.Encode(self, &buffer);
    }

    pub fn Decode(slice: []const u8) !henc.DecodeResult(Self) {
        return try Engine.Decode(slice);
    }
};

pub const TransactionState = enum(u3) {
    TRANSACTION = 0b000,
    INDEXED = 0b001,
    RECORDED = 0b010,
    CREATED = 0b011,
    DONE = 0b100,
    // reserved
};

pub const Transaction = struct {
    const Self = @This();
    const Engine = henc.StructEncoderBuilder(Self);
    pub const max_encoded_size = Engine.max_encoded_size;

    state: TransactionState,
    record: SequenceRecord,

    pub fn Encode(self: Self) ![]const u8 {
        var buffer: [max_encoded_size]u8 = undefined;
        return try Engine.Encode(self, &buffer);
    }

    pub fn Decode(slice: []const u8) !henc.DecodeResult(Self) {
        return try Engine.Decode(slice);
    }
};

pub const Index = struct {
    const Self = @This();
    const Engine = henc.StructEncoderBuilder(Self);
    pub const max_encoded_size = Engine.max_encoded_size;

    id: SequenceId,
    offset: u64,
    length: u32,

    pub fn Encode(self: Self) ![]const u8 {
        var buffer: [max_encoded_size]u8 = undefined;
        return try Engine.Encode(self, &buffer);
    }

    pub fn Decode(slice: []const u8) !henc.DecodeResult(Self) {
        return try Engine.Decode(slice);
    }
};
