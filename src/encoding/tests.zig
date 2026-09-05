const std = @import("std");

const packer = @import("packer.zig");
const encoders = @import("encoders.zig");
const pack_file = @import("pack_file.zig");

// units
test {
    _ = packer;
    _ = encoders;
}

test "ensure_encoding_reversable" {
    const input = "atcggctaa";

    for (input) |c| {
        const enc = try encoders.encodeChar(c);
        const dec = try encoders.decodeU3(enc);

        try std.testing.expect(dec == c);
    }
}

test "ensure_packing_with_encoding_u3" {
    const input = "atcggctaa";
    const expected = [_]u8{
        0b00000101,
        0b00110110,
        0b10001000,
        0b00000000,
    };

    const allocator = std.testing.allocator;

    const Packer = packer.U8Packer(u3, encoders.encodeChar);
    var p: Packer = .{};

    var out = try std.ArrayList(u8).initCapacity(allocator, 32);
    defer out.deinit(allocator);

    for (input) |c| {
        try p.push(allocator, &out, c);
    }

    try p.finish(allocator, &out);

    try std.testing.expectEqualSlices(
        u8,
        expected[0..],
        out.items,
    );
}

test "packs_DNA_stream_u3" {
    var reader = std.Io.Reader.fixed("atcggctaa");
    const Packer = packer.U8Packer(u3, encoders.encodeChar);

    const actual = try pack_file.packReader(
        Packer,
        &reader,
        std.testing.allocator,
        9 * 8,
    );
    defer std.testing.allocator.free(actual);

    const expected = [_]u8{
        0b00000101,
        0b00110110,
        0b10001000,
        0b00000000,
    };

    try std.testing.expectEqualSlices(
        u8,
        expected[0..],
        actual,
    );
}
