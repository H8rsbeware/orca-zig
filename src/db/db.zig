const std = @import("std");
const headers = @import("headers.zig");
const app_c = @import("../config.zig");

const DefaultPageShift: usize = 12;

const SequenceFile = "sequence.dat";
const MetaFile = "metadata.db";
const MetaIndexFile = "metadata.idx";
const AlignmentFile = "alignment.dat";
const ColdFile = "cold.dat";
const TransactionsFile = "transactions.dat";

const DBFile = struct {
    file: std.Io.File,
    header: headers.FileHeader,

    /// Writes data from start - data.len, returning the remainder of the last page.
    /// Unsafe - overwrites any data currently at that position.
    fn WritePages(self: @This(), io: std.Io, start: usize, data: []const u8) !usize {
        const page_size = 1 << self.header.page_shift;

        const pages = try std.math.divCeil(usize, data.len, page_size);
        const max_size = pages * page_size;

        const write_size = try self.file.writePositional(io, &.{data[0..]}, page_size * start);
        return max_size - write_size;
    }

    fn GetNextPage(self: @This(), io: std.Io) !usize {
        const page_size = 1 << self.header.page_shift;
        const current_length = try self.file.length(io);

        const pages = try std.math.divCeil(usize, current_length, page_size);

        return pages;
    }
};

pub const Database = struct {
    const Self = @This();

    root: []const u8,

    meta_file: DBFile,
    index_file: DBFile,
    sequence_file: DBFile,
    alignment_file: DBFile,
    cold_file: DBFile,
    transactions_file: DBFile,

    // TODO: make this the current next sequence id to write.
    sequence_generation: u64,

    pub fn init(io: std.Io, comptime config: app_c.DBConfig) !Self {
        const db_root = config.db_location;

        comptime if (db_root[db_root.len - 1] != '/') {
            @compileError("config.db_location must be a directory end with a '/'");
        };

        const f_seq = try openOrCreate(io, db_root ++ SequenceFile);
        errdefer f_seq.file.close(io);
        const seq_header = try validateOrInstanciateFile(io, f_seq, headers.DBFileType.SEQUENCE_DATA);

        const f_meta = try openOrCreate(io, db_root ++ MetaFile);
        errdefer f_meta.file.close(io);
        const meta_header = try validateOrInstanciateFile(io, f_meta, headers.DBFileType.META_DATA);

        const f_index = try openOrCreate(io, db_root ++ MetaIndexFile);
        errdefer f_index.file.close(io);
        const index_header = try validateOrInstanciateFile(io, f_index, headers.DBFileType.INDEX_DATA);

        const f_align = try openOrCreate(io, db_root ++ AlignmentFile);
        errdefer f_align.file.close(io);
        const align_header = try validateOrInstanciateFile(io, f_align, headers.DBFileType.ALIGNMENT_DATA);

        const f_cold = try openOrCreate(io, db_root ++ ColdFile);
        errdefer f_cold.file.close(io);
        const cold_header = try validateOrInstanciateFile(io, f_cold, headers.DBFileType.COLD_DATA);

        const f_trans = try openOrCreate(io, db_root ++ TransactionsFile);
        errdefer f_trans.file.close(io);
        const trans_header = try validateOrInstanciateFile(io, f_trans, headers.DBFileType.TRANSACTIONS_STATE);

        return .{
            .root = db_root,
            .meta_file = .{ .file = f_meta.file, .header = meta_header },
            .index_file = .{ .file = f_index.file, .header = index_header },
            .sequence_file = .{ .file = f_seq.file, .header = seq_header },
            .alignment_file = .{ .file = f_align.file, .header = align_header },
            .cold_file = .{ .file = f_cold.file, .header = cold_header },
            .transactions_file = .{ .file = f_trans.file, .header = trans_header },
            .sequence_generation = seq_header.generation,
        };
    }

    pub fn deinit(self: Self, io: std.Io) void {
        self.alignment_file.close(io);
        self.cold_file.close(io);
        self.sequence_file.close(io);
        self.meta_file.close(io);
        self.transactions_file.file.close(io);
    }

    pub fn ReadSequence(self: Self, io: std.Io, allocator: std.mem.Allocator, record: headers.SequenceRecord) ![]u8 {
        const page_size = 1 << self.sequence_file.header.page_shift;

        const reserved_size = page_size * record.payload.page_length;
        const actual_size = reserved_size - record.payload.page_unused;

        const buffer = try allocator.alloc(u8, actual_size);
        errdefer allocator.free(buffer);

        const read_size = try self.sequence_file.file.readPositional(io, &.{buffer}, record.payload.first_page * page_size);

        if (read_size != actual_size) {
            return error.SequenceReadOutOfRange;
        }

        return buffer;
    }

    pub fn WriteSequence(self: Self, io: std.Io, data: []const u8, real_length: u64, encoding: headers.SequenceEncoding, reference_id: ?headers.SequenceId) !void {
        // not thread safe

        if (reference_id != null) {
            try self.EnsureReferenceExists(reference_id);
        }

        const this_id: u32 = @truncate(self.sequence_generation);
        self.sequence_generation += 1;

        const sequence_page_size = 1 << self.sequence_file.header.page_shift;

        const pages_needed = try std.math.divCeil(usize, data.len, sequence_page_size);
        const start_page = self.sequence_file.GetNextPage(io);
        const expected_remaining = (pages_needed * sequence_page_size) - data.len;

        var record: headers.SequenceRecord = .{
            .id = this_id,
            .encoding = encoding,
            .length = real_length,
            .state = headers.SequenceState.ACTIVE,
            .payload = .{
                .first_page = start_page,
                .page_length = pages_needed,
                .page_unused = expected_remaining,
            },
            .reference = reference_id,
        };

        const transaction: headers.Transaction = .{
            .state = .TRANSACTION,
            .record = record,
        };

        try self.WriteTransaction(transaction);

        const record_offset = self.index_file.file.length(io);
        const index: headers.Index = .{
            .id = this_id,
            .offset = record_offset,
        };
        try self.WriteIndex(index);
        try self.UpdateTransaction(&transaction, headers.TransactionState.INDEXED);

        try self.WriteRecord(io, record);
        try self.UpdateTransaction(&transaction, headers.TransactionState.RECORDED);

        const remaining = try self.sequence_file.WritePages(io, start_page, data);
        try self.UpdateTransaction(&transaction, headers.TransactionState.CREATED);

        if (expected_remaining != remaining) {
            record.payload.page_unused = remaining;
            try self.UpdateRecord(&index, record);
        }

        try self.UpdateTranasction(&transaction, headers.TransactionState.DONE);
    }

    // TODO: _
    pub fn WriteRecord(self: Self, io: std.Io, record: headers.SequenceRecord) !void {
        _ = io;
        _ = record;
        _ = self;

        return;
    }

    fn validateOrInstanciateFile(io: std.Io, file_ptr: OpenedFile, header_type: headers.DBFileType) !headers.FileHeader {
        if (file_ptr.created) {
            const file_type: headers.FileHeader = .{
                .page_shift = DefaultPageShift,
                .generation = 0,
                .kind = header_type,
                .version = 1,
            };

            const encoded = try file_type.Encode();
            try file_ptr.file.writePositionalAll(io, encoded, 0);
            return file_type;
        }

        var file_buff: [1028]u8 = undefined;
        _ = try file_ptr.file.readPositional(io, &.{file_buff[0..]}, 0);

        // Decode should fail once magic exists
        const h = try headers.FileHeader.Decode(&file_buff).value;

        if (h.kind != header_type) {
            return error.FileTypeDoesntMatchExpected;
        }

        return h;
    }
};

const OpenedFile = struct {
    file: std.Io.File,
    created: bool,
};

fn openOrCreate(
    io: std.Io,
    path: []const u8,
) !OpenedFile {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{
        .mode = .read_write,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            const created = try std.Io.Dir.createFileAbsolute(io, path, .{
                .exclusive = true,
                .read = true,
            });

            return .{
                .file = created,
                .created = true,
            };
        },
        else => return err,
    };

    return .{
        .file = file,
        .created = false,
    };
}
