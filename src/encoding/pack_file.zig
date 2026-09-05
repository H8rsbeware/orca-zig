const std = @import("std");
const packer = @import("packer.zig");
const encoders = @import("encoders.zig");

const chunk_size = 64 * 1024;

pub fn packFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    const file_size = try file.length(io);
    const packed_capacity: usize =
        @intCast((file_size * 3 + 7) / 8);

    // Explicitly no internal buffering.
    var reader_buffer: [0]u8 = .{};
    var file_reader = file.reader(io, &reader_buffer);

    return packReader(
        &file_reader.interface,
        allocator,
        packed_capacity,
    ) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        else => return err,
    };
}

pub fn packReader(
    comptime PackerType: type,
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    packed_capacity: usize,
) ![]u8 {
    var chunk: [chunk_size]u8 = undefined;

    var p: PackerType = .{};

    var out = try std.ArrayList(u8).initCapacity(
        allocator,
        @intCast(packed_capacity),
    );
    errdefer out.deinit(allocator);

    while (true) {
        const n = try reader.readSliceShort(&chunk);

        for (chunk[0..n]) |byte| {
            try p.push(allocator, &out, byte);
        }

        if (n < chunk.len) {
            break;
        }
    }

    try p.finish(allocator, &out);

    return try out.toOwnedSlice(allocator);
}
