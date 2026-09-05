const std = @import("std");

// accept struct containing uints, uint enums, or structs of the same pattern
// and deterministically encodes them
//
// input `struct` -> checked that each field is allowed and builds order
// optional fields are encoded at the start, as a length in binary bits
//
// independent positions must be accessible independently - i.e var chars can be checked fast

const FieldContext = struct {
    type: type,
    name: []const u8,
    optional: bool,
    is_enum: bool,
    shape: ?[]const FieldContext,
};

pub fn StructEncoderBuilder(
    comptime Struct: type,
) type {
    // Type check and collect struct fields, to build an encoder.
    const meta = evalutateFields(Struct);

    // Calculate the number of optional fields, and calculate its byte aligned length.
    const optional_count = comptime blk: {
        var count: usize = 0;
        for (meta) |f| {
            if (f.optional) count += 1;
        }
        break :blk count;
    };
    const bitmask_bytes_len = (optional_count + 7) / 8;

    return struct {
        /// Encode a struct of uints, unint enums, and structs of the same form using ULEB128,
        /// with byte aligned optional marks (whether the optional fields are set) appended to the end.
        pub fn Encode(instance: Struct, out_buffer: []u8) ![]const u8 {
            var cursor: usize = 0;

            // Create a bitmask representing optional fields where 1 is value set, and 0 is value null
            var bitmask_buff = [_]u8{0} ** ((optional_count + 7) / 8);
            var bit_idx: usize = 0;

            inline for (meta) |field| {
                field_blk: {
                    // Get the value for the field defined in meta
                    const value = @field(instance, field.name);

                    // If the value is optional, we need to flip the bit within the mask
                    // to represent its set.
                    // Always increment, and skip rest if value is null
                    if (field.optional) {
                        if (value != null) {
                            const byte_pos = bit_idx / 8;
                            const bit_pos = @as(u3, @intCast(bit_idx % 8));
                            // in current mask byte, set the bit at bit_pos to a 1
                            bitmask_buff[byte_pos] |= (@as(u8, 1) << bit_pos);
                        }
                        bit_idx += 1;

                        if (value == null) break :field_blk;
                    }

                    // Get optional values from their unions
                    const clean_value = if (field.optional) value.? else value;

                    // For enums and u*, write the bits using ULEB128
                    // (u7 chunks of data, in u8, where [0] is the continue bit, with 1 representing the start of a new block)
                    // For child structs, create and call its encoder within the a slice of out_buffer, starting at current position
                    // This is designed to pack all information optimally, in varints.
                    if (field.is_enum) {
                        try write(out_buffer, &cursor, @intFromEnum(clean_value));
                    } else if (field.shape != null) {
                        // create child struct
                        const ChildEncoder = StructEncoderBuilder(unwrapOptional(field.type));
                        // write child from current position
                        const remaining = out_buffer[cursor..];
                        const written = try ChildEncoder.Encode(clean_value, remaining);
                        // move to position written to
                        cursor += written.len;
                    } else {
                        try write(out_buffer, &cursor, clean_value);
                    }
                }
            }

            // Append the optional marker bytes to the end of the buffer (ensuring it fits)
            const payload_len = cursor;
            if (payload_len + bitmask_bytes_len > out_buffer.len) return error.NoSpaceLeft;
            @memcpy(out_buffer[payload_len .. payload_len + bitmask_bytes_len], &bitmask_buff);

            return out_buffer[0 .. payload_len + bitmask_bytes_len];
        }

        pub fn Decode(bytes: []const u8) !Struct {
            var cursor: usize = 0;
            return try decodeInternal(bytes, &cursor);
        }

        fn decodeInternal(bytes: []const u8, shared_cursor: *usize) !Struct {
            if (bytes.len < bitmask_bytes_len) return error.InputTooShort;

            const current_payloads = bytes[shared_cursor.*..];

            // Find the end of the encoded data / start of the optional markers,
            // and split `payload <> optional_markers` into their own slices.
            const payload_end = current_payloads.len - bitmask_bytes_len;
            const bitmask_slice = current_payloads[payload_end..];
            const payload_bytes = current_payloads[0..payload_end];

            // We build a set of flags for fields that are set, to rebuild against.
            // Non-optional data are considered always present.
            var presence_flags: [meta.len]bool = undefined;
            var bit_idx: usize = 0;

            // Walk over our optional marker bits, and check if the current optional field is set.
            inline for (meta, 0..) |field, idx| {
                if (field.optional) {
                    // Get the current u8 index and position in the u8
                    const byte_pos = bit_idx / 8;
                    const bit_pos = @as(u3, @intCast(bit_idx % 8));
                    // Create a mask of the current optional idx (say 1 -> 0b0000_0010), and AND against
                    // that position in the encoded data to see if its set.
                    presence_flags[idx] = (bitmask_slice[byte_pos] & @as(u8, 1) << bit_pos) != 0;
                    bit_idx += 1;
                } else {
                    presence_flags[idx] = true;
                }
            }

            // We keep a local cursor over our current payload to append and return to the shared one (for recusive structs)
            var local_cursor: usize = 0;
            var instance: Struct = undefined;

            // Build the struct, collecting types for enums and uints and decoding the with ULEB128,
            // and recursing down structs with a child_cursor.
            inline for (meta, 0..) |field, idx| {
                field_blk: {
                    const is_present = presence_flags[idx];

                    // Set optional and null fields accordingly
                    if (field.optional and !is_present) {
                        @field(instance, field.name) = null;
                        break :field_blk;
                    }

                    if (field.is_enum) {
                        // For enums, get their tag type, and decode against their tag types (i.e. u4), and set the field
                        const T = unwrapOptional(field.type);
                        const tag_type = @typeInfo(T).@"enum".tag_type;
                        const tag_value = try read(tag_type, payload_bytes, &local_cursor);
                        @field(instance, field.name) = @as(T, @enumFromInt(tag_value));
                    } else if (field.shape != null) {
                        // For child structs, we need to get an encoder for their type, get the slice from current position onwards,
                        // and then provide the child with its own cursor.
                        const ChildEncoder = StructEncoderBuilder(unwrapOptional(field.type));
                        const remaining_payloads = payload_bytes[local_cursor..];

                        var child_cursor: usize = 0;
                        const child_instance = try ChildEncoder.decodeInternal(remaining_payloads, &child_cursor);
                        @field(instance, field.name) = child_instance;

                        // Once the child instance is created, we can take add its relative position to this callers current
                        // to continue from the correct point. This is done since the child has an abitrary size when encoded.
                        local_cursor += child_cursor;
                    } else {
                        // For all others (uints), we just decode and set
                        const T = unwrapOptional(field.type);
                        @field(instance, field.name) = try read(T, payload_bytes, &local_cursor);
                    }
                }
            }

            // update our shared pointer so any parents can continue from the correct position
            shared_cursor.* += local_cursor + bitmask_bytes_len;

            return instance;
        }

        /// Intermidate writer, that either calls writeULEB on T with >7 bits,
        /// or encodes the value as a u8 directly with a its leading 0.
        ///
        /// TODO: Change to a direct encoding strategy for u8s or smaller.
        /// Currently, u8s larger than 127 use 2 bytes, and smaller ones use a full byte.
        fn write(buffer: []u8, cursor: *usize, value: anytype) !void {
            const T = @TypeOf(value);

            if (@bitSizeOf(T) <= 7) {
                const as: u8 = @as(u8, @intCast(value));

                if (cursor.* >= buffer.len) return error.NoSpaceLeft;
                buffer[cursor.*] = as;
                cursor.* += 1;
            } else {
                return writeULEB(buffer, cursor, value);
            }
        }

        /// Intermidate reader, that either calls readULEB on T with >7 bits,
        /// or truncates it directly from its u8 form to T.
        fn read(comptime T: type, buffer: []const u8, cursor: *usize) !T {
            const TSize = @bitSizeOf(T);
            if (@bitSizeOf(T) <= 7) {
                if (cursor.* >= buffer.len) return error.EndOfStream;

                const byte = buffer[cursor.*];
                cursor.* += 1;

                if (byte > std.math.pow(u8, TSize - 1, 2)) {
                    return error.EncodedValueTooWide;
                }

                const chunk: T = @intCast(byte & 0b0111_1111); // 0x7F
                return chunk;
            } else {
                return readULEB(T, buffer, cursor);
            }
        }

        /// Writes a uint of abitrary size, as a series of unsigned length encoded bytes (VarInt), to a buffer from cursor.
        ///
        /// Data (value) is chunked into 8 bits, where the 0th marks start (1) or continuation (0), and the
        /// following 7 contain data.
        fn writeULEB(buffer: []u8, cursor: *usize, value: anytype) !void {
            var mut_value = value;

            while (true) {
                var chunk = @as(u8, @intCast(mut_value & 0b0111_1111));
                mut_value >>= 7;

                if (mut_value != 0) {
                    chunk |= 0b1000_0000;
                }

                if (cursor.* >= buffer.len) return error.NoSpaceLeft;
                buffer[cursor.*] = chunk;
                cursor.* += 1;

                if (mut_value == 0) break;
            }
        }

        /// Reads bits from a buffer from cursor, decoding the VarInt (unsigned length encoded bytes) and returning
        /// the reconstructed uint (of any value).
        fn readULEB(comptime T: type, buffer: []const u8, cursor: *usize) !T {
            var result: T = 0;
            var shift: usize = 0;

            while (true) {
                if (cursor.* >= buffer.len) return error.EndOfStream;

                const byte = buffer[cursor.*];
                cursor.* += 1;

                const chunk = @as(T, (byte & 0b0111_1111)); // 0x7F
                result |= chunk << @intCast(shift);
                shift += 7;

                if (byte & 0b1000_0000 == 0) break; //0x80
            }
            return result;
        }
    };
}

fn evalutateFields(comptime hdr_raw: type) [@typeInfo(unwrapOptional(hdr_raw)).@"struct".fields.len]FieldContext {
    const hdr = unwrapOptional(hdr_raw);
    const hdr_info = @typeInfo(hdr);

    if (hdr_info != .@"struct") {
        @compileError("Expected header to be struct, found " ++ @typeName(hdr));
    }

    const fields = hdr_info.@"struct".fields;
    var field_list: [fields.len]FieldContext = undefined;

    inline for (fields, 0..) |field, idx| {
        var current_type = field.type;
        var field_info = @typeInfo(field.type);
        var optional = false;

        if (field_info == .optional) {
            optional = true;
            current_type = field_info.optional.child;
            field_info = @typeInfo(field_info.optional.child);
        }

        if (field_info == .int and field_info.int.signedness == .unsigned) {
            field_list[idx] = .{
                .type = field.type,
                .name = field.name,
                .optional = optional,
                .is_enum = false,
                .shape = null,
            };
            continue;
        }

        if (field_info == .@"enum") {
            const tag_type = field_info.@"enum".tag_type;
            const tag_info = @typeInfo(tag_type);

            if (tag_info != .int or tag_info.int.signedness != .unsigned) {
                @compileError("Expected header enum '" ++ field.name ++ "' to have tag_type of uint, found: " ++ @typeName(tag_type));
            }

            field_list[idx] = .{
                .type = field.type,
                .name = field.name,
                .optional = optional,
                .is_enum = true,
                .shape = null,
            };
            continue;
        }

        if (field_info == .@"struct") {
            const nested_fields = evalutateFields(field.type);
            // reallocate under comptime and return pointer to stop struct being removed
            // from the stack.
            const static_shape = comptime blk: {
                const allocated = nested_fields;
                break :blk &allocated;
            };

            field_list[idx] = .{
                .type = field.type,
                .name = field.name,
                .optional = optional,
                .is_enum = false,
                .shape = static_shape,
            };
            continue;
        }

        @compileError("Expected field of type uint, enum(uint), or struct, found: " ++ @typeName(field_info));
    }

    return field_list;
}

/// Retrieve the type from an optional field, or return the type.
fn unwrapOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => T,
    };
}
