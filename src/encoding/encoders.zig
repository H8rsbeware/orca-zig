const std = @import("std");
const errs = @import("errors.zig");

pub fn encodeChar(c: u8) errs.EncodingError!u3 {
    return switch (c) {
        'a' => 0b000,
        't' => 0b001,
        'c' => 0b010,
        'g' => 0b011,
        else => error.CharacterCannotBeConvertedToU3,
    };
}

pub fn decodeU3(u: u3) errs.EncodingError!u8 {
    return switch (u) {
        0b000 => 'a',
        0b001 => 't',
        0b010 => 'c',
        0b011 => 'g',
        else => error.U3CannotBeConvertedToCharacter,
    };
}

test "ensure_encoding_order" {
    const a = try encodeChar('a');
    try std.testing.expect(a == 0b000);

    const t = try encodeChar('t');
    try std.testing.expect(t == 0b001);

    const c = try encodeChar('c');
    try std.testing.expect(c == 0b010);

    const g = try encodeChar('g');
    try std.testing.expect(g == 0b011);

    const err = encodeChar('x');

    try std.testing.expectError(errs.EncodingError.CharacterCannotBeConvertedToU3, err);
}

test "ensure_decoding_order" {
    const a = try decodeU3(0b000);
    try std.testing.expect(a == 'a');

    const t = try decodeU3(0b001);
    try std.testing.expect(t == 't');

    const c = try decodeU3(0b010);
    try std.testing.expect(c == 'c');

    const g = try decodeU3(0b011);
    try std.testing.expect(g == 'g');

    const err = decodeU3(0b111);

    try std.testing.expectError(errs.EncodingError.U3CannotBeConvertedToCharacter, err);
}
