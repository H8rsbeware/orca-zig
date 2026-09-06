const std = @import("std");
const headers = @import("headers.zig");
const app_c = @import("../config.zig");

const PageShift: usize = 12;

const SequenceFile = "sequence.dat";
const MetaFile = "metadata.db";
const AlignmentFile = "alignment.dat";
const ColdFile = "cold.dat";

pub const Database = struct {
    const Self = @This();

    root: []const u8,

    meta_file: std.Io.File,
    sequence_file: std.Io.File,
    alignment_file: std.Io.File,
    cold_file: std.Io.File,

    pub fn init(io: std.Io, comptime config: app_c.DBConfig) !Self {
        const db_root = config.db_location;

        comptime if (db_root[db_root.len - 1] != '/') {
            @compileError("config.db_location must be a directory end with a '/'");
        };

        const f_seq = try openOrCreate(io, db_root ++ SequenceFile);
        errdefer f_seq.file.close(io);
        try validate_or_instanciate_file(io, f_seq, headers.DBFileType.SEQUENCE_DATA);

        const f_meta = try openOrCreate(io, db_root ++ MetaFile);
        errdefer f_meta.file.close(io);
        try validate_or_instanciate_file(io, f_meta, headers.DBFileType.META_DATA);

        const f_align = try openOrCreate(io, db_root ++ AlignmentFile);
        errdefer f_align.file.close(io);
        try validate_or_instanciate_file(io, f_align, headers.DBFileType.ALIGNMENT_DATA);

        const f_cold = try openOrCreate(io, db_root ++ ColdFile);
        errdefer f_cold.file.close(io);
        try validate_or_instanciate_file(io, f_cold, headers.DBFileType.COLD_DATA);

        return .{
            .root = db_root,
            .meta_file = f_meta.file,
            .sequence_file = f_seq.file,
            .alignment_file = f_align.file,
            .cold_file = f_cold.file,
        };
    }

    pub fn deinit(self: Self, io: std.Io) void {
        self.alignment_file.close(io);
        self.cold_file.close(io);
        self.sequence_file.close(io);
        self.meta_file.close(io);
    }

    fn validate_or_instanciate_file(io: std.Io, file_ptr: OpenedFile, header_type: headers.DBFileType) !void {
        if (file_ptr.created) {
            const file_type: headers.FileHeader = .{
                .page_shift = PageShift,
                .generation = 0,
                .kind = header_type,
                .version = 1,
            };

            const encoded = try file_type.Encode();
            try file_ptr.file.writePositionalAll(io, encoded, 0);
            return;
        }

        var file_buff: [1028]u8 = undefined;
        _ = try file_ptr.file.readPositional(io, &.{file_buff[0..]}, 0);

        // Decode should fail once magic exists
        _ = try headers.FileHeader.Decode(&file_buff);
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
