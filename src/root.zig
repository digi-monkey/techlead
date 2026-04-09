//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

// Export storage modules for testing
pub const storage = struct {
    pub const sqlite_controlplane_store = @import("storage/sqlite_controlplane_store.zig");
    pub const controlplane_store = @import("storage/controlplane_store.zig");
    pub const task_store = @import("storage/task_store.zig");
};

// Export config module
pub const config = @import("config.zig");

// Export utils module
pub const utils = @import("utils.zig");

pub fn bufferedPrint() !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
