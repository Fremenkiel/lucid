const std = @import("std");

const lucid = @import("lucid");

pub fn main() !void {
    std.debug.print("Starting iPad Streamer UI...\n", .{});
    lucid.run_mac_app();
}
