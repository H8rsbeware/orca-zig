const std = @import("std");
const headers = @import("headers.zig");

const MaxFileHeaderSize = headers.FileHeader.max_encoded_size;
const DefaultPageShift = 12;

pub const TransactionIndex = struct {
    id: headers.SequenceId,
    start: usize,
    length: usize,
};

pub const TransactionFile = struct {
    const Self = @This();

    file: std.Io.File,
    header: headers.FileHeader,

    transactions: std.AutoHashMap(TransactionIndex, headers.Transaction),
    allocator: std.mem.Allocator,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, file_name: []const u8) !Self {
        const file = try openOrCreateFile(io, dir, file_name, .TRANSACTIONS_STATE);
        errdefer file.close(io);

        const file_length = try file.length(io);
        const header_info = try decodeAndEnsureHeaderFile(io, file, .TRANSACTIONS_STATE);
        var current_cursor = header_info.cursor;

        var file_buff: [headers.Transaction.max_encoded_size]u8 = undefined;

        var map = std.AutoHashMap(TransactionIndex, headers.Transaction).init(allocator);
        errdefer map.deinit();

        while (current_cursor < file_length) {
            const read_size = try file.readPositional(io, &.{file_buff}, current_cursor);

            const index_info = try headers.Transaction.Decode(&file_buff[0..read_size]);
            try map.put(.{ .id = index_info.value.record.id, .start = current_cursor, .length = index_info.cursor }, index_info.value);

            current_cursor += index_info.cursor;
        }

        // use the map to recreate the transaction file and map
        map = try CleanTransactions(io, allocator, dir, file_name, header_info.value, map);
        file.close(io);

        // reopen the file connection
        file = try dir.openFile(io, file_name, .{
            .mode = .read_write,
        });

        return .{
            .header = header_info.value,
            .file = file,
            .transactions = map,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        self.close(io);
        self.transactions.deinit();
    }

    pub fn UpdateTransaction(self: *Self, io: std.Io, index: TransactionIndex, new_state: headers.TransactionState) !TransactionIndex {
        var transaction = self.transactions.get(index) orelse return error.TransactionDoesNotExist;

        transaction.state = new_state;

        const new_buffer = try transaction.Encode();

        if (new_buffer.len != index.length) {
            return error.TransactionSizeChanged;
        }

        _ = try self.writePositional(io, &.{new_buffer.slice()}, index.start);

        try self.transactions.put(index, transaction);
        return index;
    }

    pub fn WriteTransaction(self: *Self, io: std.Io, transaction: *const headers.Transaction) !TransactionIndex {
        if (self.transactions.get(transaction.*) != null) {
            return error.TransactionAlreadyExists;
        }

        const current_length = try self.length(io);

        const buffer = try transaction.Encode();
        const write_size = try self.writePositional(io, &.{buffer.slice()}, current_length);

        const index: TransactionIndex = .{
            .length = write_size,
            .start = current_length,
            .id = transaction.record.id,
        };

        try self.transactions.put(index, transaction);
        return index;
    }

    fn CleanTransactions(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, file_name: []const u8, header: *const headers.FileHeader, transactions: *const std.AutoHashMap(TransactionIndex, headers.Transaction)) !std.AutoHashMap(TransactionIndex, headers.Transaction) {
        var iter = transactions.iterator();
        defer transactions.deinit();

        var atomic = try dir.createFileAtomic(io, file_name, .{
            .replace = true,
        });
        defer atomic.deinit(io);

        const header_as_bytes = try header.Encode();
        const init_write_size = try atomic.writePositional(io, &.{header_as_bytes.slice()}, 0);

        var current_cursor = init_write_size;

        var new_map: std.AutoHashMap(TransactionIndex, headers.Transaction) = .init(allocator);

        while (iter.next()) |trans| {
            if (trans.value_ptr.state == .DONE) {
                continue;
            }

            const encoded = try trans.value_ptr.Encode();
            const write_size = try atomic.writePositional(io, encoded.slice(), current_cursor);

            const new_key: TransactionIndex = .{
                .id = trans.key_ptr.id,
                .length = encoded.len,
                .start = current_cursor,
            };

            try new_map.put(new_key, trans.value_ptr.*);
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

    reserved: std.AutoHashMap(IndexEntry, void),
    allocator: std.mem.Allocator,
    current_next: usize,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, file_name: []const u8) !Self {
        const file = try openOrCreateFile(io, dir, file_name, .META_DATA);
        errdefer file.close(io);

        const header_info = try decodeAndEnsureHeaderFile(io, file, .META_DATA);

        const file_length = try file.length(io);
        return .{
            .file = file,
            .header = header_info.value,
            .header_offset = header_info.cursor,
            .reserved = std.AutoHashMap(IndexEntry, void).init(allocator),
            .allocator = allocator,
            .current_next = file_length,
        };
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        self.close(io);
        self.reserved.deinit();
    }

    pub fn Reserve(self: *Self, record_length: usize) !IndexEntry {
        const start = self.current_next;

        const reservation: IndexEntry = .{ .length = record_length, .offset = start };

        if (self.reserved.get(reservation) != null) {
            return error.SpaceAlreadyReserved;
        }

        try self.reserved.put(reservation, void);
        self.current_next += record_length;
        return reservation;
    }

    pub fn WriteToReservation(self: *Self, io: std.Io, reservation: IndexEntry, enc_data: []const u8) !usize {
        if (self.reserved.get(reservation) == null) {
            return error.ReservationNotFound;
        }

        if (enc_data.len != reservation.length) {
            return error.ReservationTooSmall;
        }

        const write_size = try self.writePositional(io, &.{enc_data[0..]}, reservation.offset);
        _ = self.reserved.remove(reservation);

        return write_size;
    }

    pub fn UpdateMetaWithReservation(self: *Self, io: std.Io, reservation: IndexEntry, record: *const headers.SequenceRecord) !usize {
        // WARNING: cant check reservation, going to assume for now

        if (self.current_next < reservation.offset + reservation.length) {
            return error.ReservationOutOfBounds;
        }

        const max_sequence_length = headers.SequenceRecord.max_encoded_size;

        var read_buffer: [max_sequence_length]u8 = undefined;
        const read_size = try self.readPositional(io, &.{read_buffer[0..]}, reservation.offset);

        const meta_info = try headers.SequenceRecord.Decode(&read_buffer[0..read_size]);

        if (record.id != meta_info.value.id) {
            return error.CannotOverwriteDifferentMeta;
        }

        const encode = try record.Encode();
        if (encode.len != meta_info.cursor or encode.len != reservation.length) {
            return error.UpdateIsLargerThanInitialMeta;
        }

        const write_size = try self.writePositional(io, &.{encode.slice()}, reservation.offset);
        return write_size;
    }

    pub fn GetRecordById(self: *const Self, io: std.Io, index: headers.Index) !headers.SequenceRecord {
        const max_sequence_length = headers.SequenceRecord.max_encoded_size;

        if (index.offset < self.header_offset or index.length > max_sequence_length) {
            return error.CorruptionError;
        }

        var read_buffer: [max_sequence_length]u8 = undefined;
        const read_size = try self.readPositional(io, &.{read_buffer[0..]}, index.offset);

        const meta_info = try headers.SequenceRecord.Decode(&read_buffer[0..read_size]);
        return meta_info.value;
    }
};

const IndexEntry = struct {
    offset: u64,
    length: u32,
};

pub const IndexFile = struct {
    const Self = @This();

    file: std.Io.File,
    header: headers.FileHeader,

    state: std.AutoHashMap(headers.SequenceId, IndexEntry),
    allocator: std.mem.Allocator,

    next_sequence_id: headers.SequenceId,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, file_name: []const u8) !Self {
        const file = try openOrCreateFile(io, dir, file_name, .INDEX_DATA);
        errdefer file.close(io);

        const file_length = try file.length(io);

        const header_info = try decodeAndEnsureHeaderFile(io, file, .INDEX_DATA);
        var current_cursor = header_info.cursor;

        var map = std.AutoHashMap(headers.SequenceId, IndexEntry).init(allocator);
        errdefer map.deinit();

        var max_id: headers.SequenceId = 0;
        var file_buffer: [headers.Index.max_encoded_size]u8 = undefined;

        while (current_cursor < file_length) {
            const read_size = try file.readPositional(io, &.{file_buffer}, current_cursor);

            const index_info = try headers.Index.Decode(&file_buffer[0..read_size]);
            try map.put(index_info.value.id, .{ .length = index_info.cursor, .offset = index_info.value.offset });

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

    pub fn deinit(self: *Self, io: std.Io) void {
        self.close(io);
        self.state.deinit();
    }

    pub fn GetRecordIndex(self: *const Self, id: headers.SequenceId) !headers.Index {
        const entry = self.state.get(id);

        if (entry == null) {
            return error.SequenceDoesNotExist;
        }

        return .{ .id = id, .offset = entry.?.offset, .length = entry.?.length };
    }

    pub fn WriteRecordIndex(self: *Self, io: std.Io, index: *const headers.Index) !void {
        if (self.state.get(index.id) != null) {
            return error.SequenceAlreadyExists;
        }

        const encode = try index.Encode();

        const file_length = self.length(io);
        try self.writePositional(io, &.{encode.slice()}, file_length);

        try self.state.put(index.id, .{ .length = index.length, .offset = index.offset });
    }

    pub fn GetNextId(self: *const Self) headers.SequenceId {
        return self.next_sequence_id;
    }

    pub fn TakeNextId(self: *Self) headers.SequenceId {
        const taking = self.next_sequence_id;
        self.next_sequence_id += 1;
        return taking;
    }
};

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

    pub fn init(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, file_name: []const u8) !Self {
        const file = try openOrCreateFile(io, dir, file_name, .SEQUENCE_DATA);
        errdefer file.close(io);

        const header_info = try decodeAndEnsureHeaderFile(io, file, .SEQUENCE_DATA);

        const page_length: usize = 1 << header_info.value.page_shift;
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

    pub fn deinit(self: *Self, io: std.Io) void {
        self.close(io);
        self.reserved.deinit();
    }

    pub fn NextPage(self: *const Self) usize {
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

        try self.reserved.put(pr, void);
        self.current_next_page += as_pages;
        return pr;
    }

    pub fn WriteSequence(self: *Self, io: std.Io, data: []const u8, reservation: PageReservation) !usize {
        if (self.reserved.get(reservation) == null) {
            return error.PageReservationNotFound;
        }

        const bit_from = self.page_length * (self.page_offset + reservation.start);
        const bit_length = self.page_length * reservation.length;

        if (bit_length < data.len) {
            return error.PageReservationTooSmall;
        }

        const write_len = try self.writePositional(io, &.{data[0..]}, bit_from);
        _ = self.reserved.remove(reservation);
        return write_len;
    }

    pub fn ReadSequenceWithReservation(self: *Self, io: std.Io, reservation: *const PageReservation, offset: usize) ![]const u8 {
        return try self.ReadSequence(
            io,
            .{
                .first_page = reservation.start,
                .page_length = reservation.length,
                .page_unused = offset,
            },
        );
    }

    pub fn ReadSequence(self: *const Self, io: std.Io, extent: headers.Extent) ![]const u8 {
        if (extent.first_page + extent.page_length > self.current_next_page) {
            return error.PageOutOfBounds;
        }

        const buffer_size = self.page_length * (extent.page_length + self.page_offset);
        const buffer: [buffer_size]u8 = undefined;

        const start = self.page_length * extent.first_page;
        const read_len = try self.readPositional(io, &.{buffer[0..]}, start);

        if (read_len < buffer_size - extent.page_unused) {
            return error.SequenceIncomplete;
        }

        const actual_length = buffer_size - extent.page_unused;
        return buffer[0..actual_length];
    }

    pub fn CalcOffset(self: *const Self, data_length: u64, pages: usize) usize {
        const page_bits = self.page_length * pages;
        return page_bits - data_length;
    }
};

fn openOrCreateFile(io: std.Io, dir: std.Io.File, file_name: []const u8, fileType: headers.DBFileType) !std.Io.File {
    return dir.openFile(io, file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            var f = try dir.createFile(io, file_name, .{});

            const file_header: headers.FileHeader = .{
                .page_shift = DefaultPageShift,
                .generation = 0,
                .kind = fileType,
                .version = 1,
            };

            const encoded = try file_header.Encode();
            try f.writePositionalAll(io, encoded.slice(), 0);
            return f;
        },
        else => return err,
    };
}

fn decodeAndEnsureHeaderFile(io: std.Io, file: std.Io.File, expectedFileType: headers.DBFileType) !headers.FileHeader {
    var file_buff: [MaxFileHeaderSize]u8 = undefined;
    const init_read_size = try file.readPositional(io, &.{file_buff[0..]}, 0);

    const header_info = try headers.FileHeader.Decode(&file_buff[0..init_read_size]);

    if (header_info.value.kind != expectedFileType) {
        return error.FileHeaderKindMismatch;
    }

    return header_info;
}
