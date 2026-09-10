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
pub const Database = struct {
    const Self = @This();

    root: std.Io.Dir,

    meta_file: managers.MetaFile,
    index_file: managers.IndexFile,
    sequence_file: managers.SequenceFile,
    alignment_file: void,
    cold_file: void,
    transactions_file: managers.TransactionFile,

    next_sequence_id: headers.SequenceId,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, root: std.Io.Dir) !Self {
        const file_sequence = try managers.SequenceFile.init(io, allocator, root, SequenceFile);
        errdefer file_sequence.deinit(io);

        const file_meta = try managers.MetaFile.init(io, allocator, root, MetaFile);
        errdefer file_meta.deinit(io);

        const file_meta_index = try managers.IndexFile.init(io, allocator, root, MetaIndexFile);
        errdefer file_meta_index.deinit(io);

        const file_transaction = try managers.TransactionFile.init(io, allocator, root, TransactionsFile);
        errdefer file_transaction.deinit(io);

        return .{
            .root = root,
            .meta_file = file_meta,
            .index_file = file_meta_index,
            .sequence_file = file_sequence,
            .alignment_file = void,
            .cold_file = void,
            .transactions_file = file_transaction,
            .next_sequence_id = file_meta_index.GetNextId(),
        };
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        self.meta_file.deinit(io);
        self.sequence_file.deinit(io);
        self.index_file.deinit(io);
        self.transactions_file.deinit(io);
    }

    pub fn ReadSequence(self: *const Self, io: std.Io, id: headers.SequenceId) ![]const u8 {
        const index = try self.index_file.GetRecordIndex(id);
        const meta = try self.meta_file.GetRecordById(io, index);
        const sequence = try self.sequence_file.ReadSequence(io, meta.payload);

        return sequence;
    }

    pub fn WriteSequence(self: *Self, io: std.Io, data: []const u8, real_length: u64, encoding: *const headers.SequenceEncoding, reference_id: ?headers.SequenceId) !managers.TransactionIndex {
        const data_length = data.len;

        const reserved_id = self.index_file.TakeNextId();
        const reserved_seq_space = try self.sequence_file.Reserve(io, data_length);

        const calculated_offset = self.sequence_file.CalcOffset(data_length, reserved_seq_space.length);
        var record: headers.SequenceRecord = .{
            .id = reserved_id,
            .payload = .{
                .first_page = reserved_seq_space.start,
                .page_length = reserved_seq_space.length,
                .page_unused = calculated_offset,
            },
            .length = real_length,
            .state = .RESERVED,
            .encoding = encoding.*,
            .reference = reference_id,
        };

        const transaction: headers.Transaction = .{
            .state = .TRANSACTION,
            .record = record,
        };
        var transaction_index = try self.transactions_file.WriteTransaction(io, &transaction);

        const encoded = try record.Encode();
        const reserved_meta_space = try self.meta_file.Reserve(encoded.len);

        if (reserved_meta_space.length != encoded.len) {
            unreachable;
        }

        const index: headers.Index = .{
            .id = reserved_id,
            .length = reserved_meta_space.length,
            .offset = reserved_meta_space.offset,
        };
        try self.index_file.WriteRecordIndex(&index);
        transaction_index = try self.transactions_file.UpdateTransaction(io, &transaction_index, .INDEXED);

        try self.meta_file.WriteToReservation(io, reserved_meta_space, &encoded.slice());
        transaction_index = try self.transactions_file.UpdateTransaction(io, &transaction_index, .RECORDED);

        try self.sequence_file.WriteSequence(io, data, reserved_seq_space);
        transaction_index = try self.transactions_file.UpdateTransaction(io, &transaction_index, .CREATED);
        // update the meta here
        record.state = .ACTIVE;
        try self.meta_file.UpdateMetaWithReservation(io, reserved_meta_space, &record);
        transaction_index = try self.transactions_file.UpdateTransaction(io, &transaction_index, .DONE);

        return transaction_index;
    }
};
