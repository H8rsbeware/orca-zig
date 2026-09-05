//! This file contains a function for generating generic packer types at compile time.
//! These are for converting uX (x <= 8) into array of u8s, using some encode fn.
//
//! Also contains unit tests for a u3 packer.

const std = @import("std");

/// U8Packer produces a struct that packs `Symbol` into an ArrayList(u8), where
/// `encode` is a function that converts `Symbol` -> u8.
///
/// `Symbol` must be unsigned int, less than or equal to u8
/// `encode` must have signature fn(u8) !Symbol or fn(u8) Symbol
///
/// Returns struct with `push` and `finalise` methods, where:
///     `push(3) !void` takes Allocator, *ArrayList(u8), and u8
///     `finish(2) !void` takes Allocator, and *ArrayList(u8)
///
/// The ArrayList will contain all converted u8s packed MSB first.
pub fn U8Packer(
    comptime Symbol: type,
    comptime encode: anytype,
) type {
    // enforce Symbol us uX, where X <= 8;
    comptime {
        const info = @typeInfo(Symbol);

        if (info != .int or info.int.signedness != .unsigned) {
            @compileError("Packer Symbol must be unsigned int");
        }

        if (@bitSizeOf(Symbol) > 8) {
            @compileError("Packer currently supports symbols up to u8");
        }
    }

    return struct {
        const Self = @This();
        const symbol_bits = @bitSizeOf(Symbol);

        scratch: u16 = 0,
        bit_count: u4 = 0,

        // Calls `encode` with or without try depending on return type.
        // Allows try to always be used in `push`.
        //
        // Returns Symbol
        fn encodeValue(
            in: u8,
        ) !Symbol {
            const ReturnType = @typeInfo(@TypeOf(encode)).@"fn".return_type.?;

            return switch (@typeInfo(ReturnType)) {
                .error_union => try encode(in),
                else => encode(in),
            };
        }

        /// push encodes and "appends" the `Symbol` onto `scratch`, MSB first.
        ///
        /// When `scratch` holds more than 8 bits, it takes each u8 and appends to `out`.
        pub fn push(
            self: *Self,
            allocator: std.mem.Allocator,
            out: *std.ArrayList(u8),
            in: u8,
        ) !void {
            const symbol: Symbol = try encodeValue(in);

            // shift current bits by length of `Symbol` and append encoded `in` with binary or
            self.scratch = (self.scratch << symbol_bits) | @as(u16, symbol);
            self.bit_count += symbol_bits;

            while (self.bit_count >= 8) {
                // create a shift to take the top 8
                const shift = self.bit_count - 8;

                // shift the `scratch`, and truncate to u8. Then append.
                const byte: u8 = @truncate(self.scratch >> shift);
                try out.append(allocator, byte);

                self.bit_count -= 8;

                // if bit_count is 0, ensure the scratch is 0 too.
                // otherwise, mask the top 8 away
                if (self.bit_count == 0) {
                    self.scratch = 0;
                } else {
                    // create a mask for remaining bits, to remove the taken bits
                    const mask = (@as(u16, 1) << @intCast(self.bit_count)) - 1;

                    self.scratch &= mask;
                }
            }
        }

        /// finish takes and appends all remaining bits in `scratch` to `out`.
        ///
        /// Resets `scratch` and `bit_count`, ready for reuse.
        pub fn finish(
            self: *Self,
            allocator: std.mem.Allocator,
            out: *std.ArrayList(u8),
        ) !void {
            if (self.bit_count == 0)
                return;

            // create a shift of all remaining bits (guaranteed under <=8)
            const shift = 8 - self.bit_count;

            // shift those bits up to top of u8 and append
            const byte: u8 = @truncate(self.scratch << shift);
            try out.append(allocator, byte);

            // reset
            self.scratch = 0;
            self.bit_count = 0;
        }
    };
}

test "ensure_packing_static" {
    const expected = [_]u8{
        0b00101101,
        0b00000000,
    };

    const allocator = std.testing.allocator;

    const TestPacker = U8Packer(u3, struct {
        fn encode(value: u8) u3 {
            return @intCast(value);
        }
    }.encode);
    var p: TestPacker = .{};

    var out = try std.ArrayList(u8).initCapacity(
        allocator,
        32,
    );
    defer out.deinit(allocator);

    try p.push(allocator, &out, 0b001);
    try p.push(allocator, &out, 0b011);
    try p.push(allocator, &out, 0b010);

    try p.finish(allocator, &out);

    try std.testing.expectEqualSlices(
        u8,
        expected[0..],
        out.items,
    );
}
