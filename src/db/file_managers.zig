const std = @import("std");
const headers = @import("headers.zig");

const MaxFileHeaderSize = headers.FileHeader.max_encoded_size;

pub const TransactionIndex = struct {
    id: headers.SequenceId,
    start: usize,
    length: usize,
};

pub const TransactionFile = struct {
    const Self = @This();

    file: std.Io.File,
    header: headers.FileHeader,
    abs_path: []const u8,

    transactions: std.AutoHashMap(TransactionIndex, headers.Transaction),
    allocator: std.mem.Allocator,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, path: []const u8) !Self {
        // read the current file header and data into a map of transactions
        const file_length = try file.length(io);
        const max_buffer_size = @max(
            MaxFileHeaderSize,
            headers.Transaction.max_encoded_size,
        );

        var file_buff: [max_buffer_size]u8 = .undefined;
        const init_read_len = try file.readPositional(io, &.{file_buff[0..]}, 0);

        const header_info = try headers.FileHeader.Decode(&file_buff[0..init_read_len]);
        if (header_info.value.kind != .TRANSACTIONS_STATE) {
            return error.FileHeaderKindMismatch;
        }

        var current_cursor = header_info.cursor;

        var map = std.AutoHashMap(TransactionIndex, headers.Transaction).init(allocator);
        errdefer map.deinit();

        while (current_cursor < file_length) {
            const read_size = try file.readPositional(io, &.{file_buff}, current_cursor);

            const index_info = try headers.Transaction.Decode(&file_buff[0..read_size]);
            try map.put(.{ .id = index_info.value.record.id, .start = current_cursor, .length = index_info.cursor }, index_info.value);

            current_cursor += index_info.cursor;
        }

        // use the map to recreate the transaction file and map
        map = try CleanTransactions(io, allocator, path, header_info.value, map);
        file.close(io);
        const dir = try std.Io.Dir.openDirAbsolute(io, path, .{});
        defer dir.close(io);

        // reopen the file connection
        file = try dir.openFile(io, path, .{
            .mode = .read_write,
        });

        return .{
            .header = header_info.value,
            .file = file,
            .transaction = map,
            .allocator = allocator,
        };
    }

    pub fn UpdateTransaction(self: *Self, io: std.Io, index: *TransactionIndex, new_state: headers.TransactionState) !TransactionIndex {
        index.transaction.*.state = new_state;

        const new_buffer = try index.transaction.Encode();

        if (new_buffer.len != index.len) {
            return error.TransactionSizeChanged;
        }

        _ = try self.file.writePositional(io, &.{new_buffer[0..]}, index.start);

        return index;
    }

    pub fn WriteTransaction(self: *Self, io: std.Io, transaction: *const headers.Transaction) !TransactionIndex {
        const current_length = try self.file.length(io);

        const buffer = try transaction.Encode();

        const write_size = try self.file.writePositional(io, &.{buffer[0..]}, current_length);

        return .{
            .len = write_size,
            .start = current_length,
            .transaction = transaction,
        };
    }

    fn CleanTransactions(io: std.Io, allocator: std.mem.Allocator, path: []const u8, header: *const headers.FileHeader, transactions: *const std.AutoHashMap(TransactionIndex, headers.Transaction)) !std.AutoHashMap(TransactionIndex, headers.Transaction) {
        var iter = transactions.iterator();

        const parent_path = std.Io.Dir.path.dirname(path) orelse return error.InvalidPath;
        const file_name = std.Io.Dir.path.basename(path);

        var dir = try std.Io.Dir.openDirAbsolute(io, parent_path, .{});
        defer dir.close(io);

        var atomic = try dir.createFileAtomic(io, file_name, .{
            .replace = true,
        });
        defer atomic.deinit(io);

        const header_as_bytes = try header.Encode();
        const init_write_size = try atomic.writePositional(io, &.{header_as_bytes[0..]}, 0);

        var current_cursor = init_write_size;

        var new_map: std.AutoHashMap(TransactionIndex, headers.Transaction) = .init(allocator);

        while (iter.next()) |trans| {
            if (trans.value_ptr.state == .DONE) {
                continue;
            }
            const encoded = try trans.value_ptr.Encode();
            const write_size = try atomic.writePositional(io, encoded, current_cursor);

            try new_map.put(trans.key_ptr.*, trans.value_ptr.*);
            current_cursor += write_size;
        }

        atomic.replace(io);
        return new_map;
    }
};

pub const MetaFile = struct {
    const Self = @This();

    file: std.Io.File,
    header: headers.FileHeader,
    header_offset: usize,

    pub fn init(io: std.Io, file: std.Io.File) !Self {
        var file_buff: [MaxFileHeaderSize]u8 = undefined;
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

    pub fn GetRecordById(self: *Self, io: std.Io, index: *const IndexFile, id: headers.SequenceId) !headers.SequenceRecord {
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

    next_sequence_id: u64,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !Self {
        const file_length = try file.length(io);
        const max_read_size: usize = @max(
            MaxFileHeaderSize,
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

        var max_id: u64 = 0;

        while (current_cursor < file_length) {
            const read_size = try file.readPositional(io, &.{file_buff}, current_cursor);

            const index_info = try headers.Index.Decode(&file_buff[0..read_size]);
            try map.put(index_info.value.id, .{ .length = index_info.value.offset, .offset = index_info.value.offset });

            max_id = @max(max_id, index_info.value.id);
            current_cursor += index_info.cursor;
        }

        return .{
            .file = file,
            .header = header_info.value,
            .allocator = allocator,
            .state = map,
            .next_sequence_id = max_id + 1,
        };
    }

    pub fn deinit(self: *Self) void {
        self.state.deinit();
    }

    pub fn GetRecordIndex(self: *const Self, id: headers.SequenceId) !headers.Index {
        const entry = self.state.get(id);

        if (entry == null) {
            return error.SequenceDoesNotExist;
        }

        return .{ .id = id, .offset = entry.?.offset, .length = entry.?.length };
    }

    pub fn WriteRecordIndex(self: *Self, index: *const headers.Index) !void {
        if (self.state.get(index.id) != null) {
            return error.SequenceAlreadyExists;
        }

        try self.state.put(index.id, .{ .length = index.length, .offset = index.offset });
    }

    pub fn GetNextId(self: *const Self) u64 {
        return self.next_sequence_id;
    }
};

// Lifecycle
//  Transaction created
//  Space reserved in Meta, for Index
//  Index created for reference
//  Transaction Updated
//  Space reserved in Sequence, for Meta
//  Meta created for record
//  Transaction Updated
//  Sequence created with data
//  Transaction Updated
//
//  Transaction Cleared down.

const PageReservation = struct {
    start: usize,
    length: usize,
};

pub const SequenceFile = struct {
    const Self = @This();

    file: std.Io.File,
    header: headers.FileHeader,
    page_offset: usize,
    page_length: usize,

    reserved: std.AutoHashMap(PageReservation, void),
    allocator: std.mem.Allocator,
    current_next_page: usize,

    pub fn init(io: std.io, allocator: std.mem.Allocator, file: std.Io.File) !Self {
        var file_buff: [MaxFileHeaderSize]u8 = undefined;
        const init_read_size = try file.readPositional(io, &.{file_buff[0..]}, 0);

        const header_info = try headers.FileHeader.Decode(&file_buff[0..init_read_size]);
        if (header_info.value.kind != .SEQUENCE_DATA) {
            return error.FileHeaderKindMismatch;
        }

        const page_length = 1 << header_info.value.page_shift;
        const header_len_as_pages = try std.math.divCeil(usize, header_info.cursor, page_length);

        const file_length = try file.length(io);
        const file_len_as_pages = try std.math.divCeil(usize, file_length, page_length);

        return .{
            .file = file,
            .header = header_info.value,
            .page_offset = header_len_as_pages,
            .page_length = page_length,
            .current_next_page = file_len_as_pages - header_len_as_pages,
            .reserved = std.AutoHashMap(PageReservation, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.reserved.deinit();
    }

    pub fn NextPage(self: *const Self) u64 {
        return self.current_next_page;
    }

    pub fn Reserve(self: *Self, data_length: usize) !PageReservation {
        const as_pages = try std.math.divCeil(usize, data_length, self.page_length);
        const page_to_provide = self.current_next_page;

        const pr: PageReservation = .{
            .length = as_pages,
            .start = page_to_provide,
        };

        if (self.reserved.get(pr) != null) {
            return error.PageReservedAlready;
        }

        self.current_next_page += as_pages;
        return pr;
    }

    pub fn WriteSequence(self: *Self, io: std.Io, data: []const u8, reservation: *const PageReservation) !usize {
        if (self.reserved.get(reservation) == null) {
            return error.PageReservationNotFound;
        }

        const bit_from = self.page_length * (self.page_offset + reservation.start);
        const bit_length = self.page_length * reservation.length;

        if (bit_length < data.len) {
            return error.PageReservationTooSmall;
        }

        const write_len = try self.file.writePositional(io, &.{data[0..]}, bit_from);
        return write_len;
    }

    pub fn ReadSequenceWithReservation(self: *Self, io: std.Io, reservation: *const PageReservation, offset: usize) ![]const u8 {
        return try self.ReadSequence(
            io,
            .{
                .file_page = reservation.start,
                .page_length = reservation.length,
                .page_unused = offset,
            },
        );
    }

    pub fn ReadSequence(self: *const Self, io: std.Io, extent: *const headers.Extent) ![]const u8 {
        if (extent.first_page + extent.page_length > self.current_next_page) {
            return error.PageOutOfBounds;
        }

        const buffer_size = self.page_length * extent.page_length;
        const buffer: [buffer_size]u8 = undefined;

        const start = self.page_length * extent.first_page;
        const read_len = try self.file.readPositional(io, &.{buffer[0..]}, start);

        if (read_len < buffer_size - extent.page_unused) {
            return error.SequenceIncomplete;
        }

        return buffer[0..extent.page_unused];
    }
};
