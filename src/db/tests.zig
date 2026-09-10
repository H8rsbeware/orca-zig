const std = @import("std");
const headers = @import("headers.zig");
const encoder = @import("header_encoder.zig");

test {
    _ = headers;
}

fn enc_dec_test_printer(before: anytype, encoded: []const u8, after: anytype) void {
    std.debug.print("pre: {any} \nencoded: ", .{before});

    for (encoded) |byte| {
        std.debug.print("{b:0>8} ", .{byte});
    }

    std.debug.print("\npost: {any}\n", .{after});
}

// -- Actual header type checks

test "FileHeader_encodes_and_decodes_same" {
    var fh: headers.FileHeader = .{ .version = 10, .kind = headers.DBFileType.SEQUENCE_DATA, .page_shift = 12, .generation = 3 };

    const enc: []const u8 = try fh.Encode();
    const dec_union = try headers.FileHeader.Decode(enc);
    const dec = dec_union.value;

    try std.testing.expectEqualDeep(fh, dec);
}

// -- StructEncoderBuilder test

const SimpleStruct: type = struct {
    id: u32,
    length: u128,
    big: u256,
    small: u8,
    tiny: u2,
};

test "header_encoder_encodes_and_decodes_simple" {
    const Encoder = encoder.StructEncoderBuilder(SimpleStruct);

    const my_s: SimpleStruct = .{
        .id = 12345,
        .length = 12345678910,
        .big = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
        .small = 255,
        .tiny = 1,
    };

    var memory_pool: [Encoder.max_encoded_size]u8 = undefined;
    // truncated view of the memory pool
    const encoded_slice = try Encoder.Encode(my_s, &memory_pool);

    // assert slice and memory are share the same address
    try std.testing.expectEqual(@intFromPtr(&memory_pool[0]), @intFromPtr(&encoded_slice[0]));

    // assert size is expected from encoding
    try std.testing.expectEqual(@as(usize, 47), encoded_slice.len);

    const decoded_data = try Encoder.Decode(encoded_slice);
    const decoded_value = decoded_data.value;

    try std.testing.expectEqual(my_s.id, decoded_value.id);
    try std.testing.expectEqual(my_s.length, decoded_value.length);
    try std.testing.expectEqual(my_s.big, decoded_value.big);
    try std.testing.expectEqual(my_s.small, decoded_value.small);

    std.debug.print("SIMPLE E-D TEST\n-----------\n", .{});
    enc_dec_test_printer(my_s, encoded_slice, decoded_value);
}

const ComplexStruct = struct {
    id: u32,
    child: ?ChildStruct,
};

const ChildStruct = struct {
    id: u32,
    child: ?ChildChildStruct,
};

const ChildChildStruct = struct {
    id: u32,
    child: ?ChildChildChildStruct,
};

const ChildChildChildStruct = struct {
    id: u32,
};

test "header_encoder_encodes_and_decodes_optional_recursive" {
    const Encoder = encoder.StructEncoderBuilder(ComplexStruct);

    const my_s: ComplexStruct = .{ .id = 10001, .child = .{ .id = 10002, .child = .{ .id = 10003, .child = null } } };

    var memory_pool: [126 / 3]u8 = undefined;
    const encoded_slice = try Encoder.Encode(my_s, &memory_pool);

    try std.testing.expectEqual(@intFromPtr(&memory_pool[0]), @intFromPtr(&encoded_slice[0]));

    const decoded_data = try Encoder.Decode(encoded_slice);
    const decoded_value = decoded_data.value;

    try std.testing.expectEqualDeep(my_s, decoded_value);

    std.debug.print("RECURSIVE E-D TEST\n-----------\n", .{});
    enc_dec_test_printer(my_s, encoded_slice, decoded_value);
}
