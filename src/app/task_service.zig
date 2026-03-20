const std = @import("std");

pub const TasksFile = struct {
    tasks: []Task,

    pub const Task = struct {
        id: []const u8,
        title: []const u8,
        status: []const u8,
        prompt: ?[]const u8 = null,
        lease_owner: ?[]const u8 = null,
        lease_until: ?i64 = null,
        retry_count: u32 = 0,
        max_retries: ?u32 = null,
    };
};

pub const LoadedTasks = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    raw: []u8,
    parsed: std.json.Parsed(TasksFile),

    pub fn deinit(self: *LoadedTasks) void {
        self.parsed.deinit();
        self.allocator.free(self.raw);
        self.allocator.free(self.path);
    }
};

pub fn loadOrInitTasks(allocator: std.mem.Allocator, work_dir: []const u8) !LoadedTasks {
    const tasks_path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, ".techlead/tasks.json" });
    const empty_seed =
        \\{
        \\  "tasks": []
        \\}
        \\
    ;
    const raw = std.fs.cwd().readFileAlloc(allocator, tasks_path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try std.fs.cwd().writeFile(.{ .sub_path = tasks_path, .data = empty_seed });
            break :blk try allocator.dupe(u8, empty_seed);
        },
        else => {
            allocator.free(tasks_path);
            return err;
        },
    };

    const parsed = std.json.parseFromSlice(TasksFile, allocator, raw, .{}) catch |err| {
        allocator.free(raw);
        allocator.free(tasks_path);
        return err;
    };

    return .{
        .allocator = allocator,
        .path = tasks_path,
        .raw = raw,
        .parsed = parsed,
    };
}

pub fn saveTasks(allocator: std.mem.Allocator, loaded: *LoadedTasks) !void {
    const updated = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(loaded.parsed.value, .{ .whitespace = .indent_2 })});
    defer allocator.free(updated);
    try std.fs.cwd().writeFile(.{ .sub_path = loaded.path, .data = updated });
}
