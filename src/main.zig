const std = @import("std");
const db = @import("db/db.zig");
const app_c = @import("config.zig");
const config: app_c.DBConfig = @import("config.zon");

pub fn main(init: std.process.Init) !void {
    std.debug.print("Hello, World!\n", .{});

    const io = init.io;
    const database = try db.Database.init(io, config);
    defer database.deinit(io);
}

test {
    _ = @import("encoding/tests.zig");
    _ = @import("db/tests.zig");
}
