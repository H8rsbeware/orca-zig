const std = @import("std");
const headers = @import("headers.zig");
const app_c = @import("../config.zig");
const managers = @import("file_managers.zig");

const DefaultPageShift: usize = 12;

const SequenceFile = "sequence.dat";
const MetaFile = "metadata.db";
const MetaIndexFile = "metadata.idx";
const AlignmentFile = "alignment.dat";
const ColdFile = "cold.dat";
const TransactionsFile = "transactions.dat";

pub const Database = struct {
    const Self = @This();

    root: []const u8,

    meta_file: managers.MetaFile,
    index_file: managers.IndexFile,
    sequence_file: managers.SequenceFile,
    alignment_file: type,
    cold_file: type,
    transactions_file: managers.TransactionFile,

    next_sequence_id: u64,

    pub fn init(io: std.Io, comptime config: app_c.DBConfig) !Self {
        const db_root = config.db_location;

        comptime if (db_root[db_root.len - 1] != '/') {
            @compileError("config.db_location must be a directory end with a '/'");
        };

        const file_sequence = try initDbFile(io, db_root ++ SequenceFile, headers.DBFileType.SEQUENCE_DATA, DefaultPageShift);
        const file_meta = try initDbFile(io, db_root ++ MetaFile, headers.DBFileType.META_DATA, DefaultPageShift);
        const file_meta_index = try initDbFile(io, db_root ++ MetaIndexFile, headers.DBFileType.INDEX_DATA, DefaultPageShift);
        const file_alignment = try initDbFile(io, db_root ++ AlignmentFile, headers.DBFileType.ALIGNMENT_DATA, DefaultPageShift);
        const file_cold = try initDbFile(io, db_root ++ ColdFile, headers.DBFileType.COLD_DATA, DefaultPageShift);
        const file_transactions = try initDbFile(io, db_root ++ TransactionsFile, headers.DBFileType.TRANSACTIONS_STATE, DefaultPageShift);

        return .{
            .root = db_root,
            .meta_file = file_meta,
            .index_file = file_meta_index,
            .sequence_file = file_sequence,
            .alignment_file = file_alignment,
            .cold_file = file_cold,
            .transactions_file = file_transactions,
            .next_sequence_id = file_meta_index.GetNextId(),
        };
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        self.alignment_file.close(io);
        self.cold_file.close(io);
        self.sequence_file.close(io);
        self.meta_file.close(io);
        self.transactions_file.file.close(io);
    }

    pub fn ReadSequence(self: *const Self, io: std.Io, id: headers.SequenceId) ![]const u8 {
        const meta = try self.meta_file.GetRecordById(io, &self.meta_file, id);
        const sequence = try self.sequence_file.ReadSequence(io, meta.payload);

        return sequence;
    }

    pub fn WriteSequence(self: *Self, io: std.Io, data: []const u8, real_length: u64, encoding: *const headers.SequenceEncoding, reference_id: ?headers.SequenceId) !void {
        _ = self;
        _ = io;
        _ = data;
        _ = real_length;
        _ = encoding;
        _ = reference_id;
    }

    /// Initialises (opens or creates) a database file, and builds its corrosponding file_manager;
    /// file managers check whether files are correct, and perform their own initialisation.
    ///
    /// i.e. the TranasactionFile manager checks its header, builds a map to cache transactions,
    /// and then walks the transactions, recovering, reverting, or removing records depending on state.
    fn initDbFile(io: std.Io, path: []const u8, file_type: headers.DBFileType, default_page_shift: u8) !type {
        const opened_file = try openOrCreate(io, path);
        errdefer opened_file.file.close(io);

        // if the file is newly created, write the default header to it
        if (opened_file.created) {
            const file_header: headers.FileHeader = .{
                .page_shift = default_page_shift,
                .generation = 0,
                .kind = file_type,
                .version = 1,
            };

            const encoded = try file_header.Encode();
            try opened_file.file.writePositionalAll(io, encoded, 0);
        }

        // file managers are responsible for ensuring initialisation is correct.
        return switch (file_type) {
            .META_DATA => try managers.MetaFile.init(io, opened_file.file),
            .INDEX_DATA => try managers.IndexFile.init(io, std.heap.page_allocator, opened_file.file),
            .TRANSACTIONS_STATE => try managers.TransactionFile.init(io, std.heap.page_allocator, opened_file.file, path),
            .SEQUENCE_DATA => try managers.SequenceFile.init(io, std.heap.page_allocator, opened_file.file),
            .ALIGNMENT_DATA => return {},
            .COLD_DATA => return {},
        };
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
