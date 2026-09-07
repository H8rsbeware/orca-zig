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

    pub fn GetRecordById(self: Self, index: *IndexFile, id: headers.SequenceId) !headers.SequenceRecord {
        _ = self;
        _ = index;
        _ = id;
        return error.NotImplemented;
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) Self {
        var file_buff: [1028]u8 = undefined;
        _ = try file.file.readPositional(io, &.{file_buff[0..]}, 0);

        // Decode should fail once magic exists
        const decode = try headers.FileHeader.Decode(&file_buff);

        // TODO: continue

        return .{
            .file = file,
            .header = decode.value,
            .allocator = allocator,
            .state = std.AutoHashMap(headers.SequenceId, IndexEntry).init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.state.deinit();
    }

    pub fn GetRecordOffset(self: Self, id: headers.SequenceId) !headers.SequenceRecord {
        _ = self;
        _ = id;
        return error.NotImplemented;
    }
};
