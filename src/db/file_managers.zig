const std = @import("std");
const headers = @import("headers.zig");

pub const TransactionIndex = struct {
    transaction: *headers.Transaction,
    start: u32,
    len: u32,
};

pub const TransactionFile = struct {
    const Self = @This();

    file: std.Io.File,
    header: headers.FileHeader,

    pub fn UpdateTransaction(self: Self, io: std.Io, index: TransactionIndex, new_state: headers.TransactionState) !TransactionIndex {
        index.transaction.*.state = new_state;

        const new_buffer = try index.transaction.Encode();

        if (new_buffer.len != index.len) {
            return error.TransactionSizeChanged;
        }

        _ = try self.file.writePositional(io, &.{new_buffer[0..]}, index.start);

        return index;
    }

    pub fn WriteTransaction(self: Self, io: std.Io, transaction: *headers.Transaction) !TransactionIndex {
        const current_length = self.file.length(io);

        const buffer = try transaction.Encode();

        const write_size = try self.file.writePositional(io, &.{buffer[0..]}, current_length);

        return .{
            .len = write_size,
            .start = current_length,
            .transaction = transaction,
        };
    }

    pub fn CleanTransactions(self: Self) !void {
        _ = self;
        return error.NotImplemented;
    }
};

pub const MetaFile = struct {
    const Self = @This();

    file: std.Io.File,
    header: headers.FileHeader,
    header_offset: usize,

    pub fn init(io: std.Io, file: std.Io.File) !Self {
        const max_header_size = headers.FileHeader.max_encoded_size;

        var file_buff: [max_header_size]u8 = undefined;
        const init_read_size = try file.readPositional(io, &.{file_buff[0..]}, 0);

        const header_info = try headers.FileHeader.Decode(&file_buff[0..init_read_size]);

        if (header_info.value.kind != .META_DATA) {
            return error.FileHeaderKindMismatch;
        }

        return .{
            .file = file,
            .header = header_info.value,
            .header_offset = header_info.cursor,
        };
    }

    pub fn GetRecordById(self: Self, io: std.Io, index: *IndexFile, id: headers.SequenceId) !headers.SequenceRecord {
        const max_sequence_length = headers.SequenceRecord.max_encoded_size;
        const idx = try index.GetRecordIndex(id);

        if (idx.offset < self.header_offset or idx.length > max_sequence_length) {
            unreachable;
        }

        var read_buffer: [max_sequence_length]u8 = undefined;
        const read_size = try self.file.readPositional(io, &.{read_buffer[0..]}, 0);

        const meta_info = try headers.SequenceRecord.Decode(&read_buffer[0..read_size]);
        return meta_info.value;
    }
};

const IndexEntry = struct {
    offset: u32,
    length: u32,
};

pub const IndexFile = struct {
    const Self = @This();

    file: std.Io.File,
    header: headers.FileHeader,

    state: std.AutoHashMap(headers.SequenceId, IndexEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !Self {
        const file_length = try file.length(io);
        const max_read_size: usize = @max(
            headers.FileHeader.max_encoded_size,
            headers.Index.max_encoded_size,
        );

        var file_buff: [max_read_size]u8 = undefined;
        const init_read_size = try file.readPositional(io, &.{file_buff[0..]}, 0);

        const header_info = try headers.FileHeader.Decode(&file_buff[0..init_read_size]);

        if (header_info.value.kind != .INDEX_DATA) {
            return error.FileHeaderKindMismatch;
        }

        var current_cursor = header_info.cursor;

        var map = std.AutoHashMap(headers.SequenceId, IndexEntry).init(allocator);
        errdefer map.deinit();

        while (current_cursor < file_length) {
            const read_size = try file.readPositional(io, &.{file_buff}, current_cursor);

            const index_info = try headers.Index.Decode(&file_buff[0..read_size]);
            try map.put(index_info.value.id, .{ .length = index_info.value.offset, .offset = index_info.value.offset });

            current_cursor += index_info.cursor;
        }

        return .{
            .file = file,
            .header = header_info.value,
            .allocator = allocator,
            .state = map,
        };
    }

    pub fn deinit(self: Self) void {
        self.state.deinit();
    }

    pub fn GetRecordIndex(self: Self, id: headers.SequenceId) !headers.Index {
        const entry = self.state.get(id);

        if (entry == null) {
            return error.SequenceDoesNotExist;
        }

        return .{ .id = id, .offset = entry.?.offset, .length = entry.?.length };
    }

    pub fn WriteRecordIndex(self: Self, index: headers.Index) !void {
        if (self.state.get(index.id) != null) {
            return error.SequenceAlreadyExists;
        }

        try self.state.put(index.id, .{ .length = index.length, .offset = index.offset });
    }
};
