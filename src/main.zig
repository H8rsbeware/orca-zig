const std = @import("std");

const config = @import("config.zon");
const DBConfig = @import("config.zig").DBConfig;

const dbStartup = @import("db/startup.zig");

const CONFIG: DBConfig = .{config.db_location};

pub fn main() !void {
    std.debug.print("Hello, World!\n", .{});

    const ok: bool = try dbStartup.EnsureDB(CONFIG);
    if (!ok) {
        return;
    }
}

test {
    _ = @import("encoding/tests.zig");
    _ = @import("db/tests.zig");
}
