const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn readEventsJsonl(allocator: Allocator, work_dir: []const u8, log_dir: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, log_dir, "events.jsonl" });
    defer allocator.free(path);

    const raw = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "{\"events\":[]}"),
        else => return err,
    };
    defer allocator.free(raw);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"events\":[");

    var first = true;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, trimmed);
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

pub fn readEventsAfter(allocator: Allocator, work_dir: []const u8, log_dir: []const u8, after: usize) ![]u8 {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, log_dir, "events.jsonl" });
    defer allocator.free(path);

    const raw = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "{\"events\":[],\"last_event_id\":0}"),
        else => return err,
    };
    defer allocator.free(raw);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"events\":[");

    var first = true;
    var event_id: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        event_id += 1;
        if (event_id <= after) continue;

        if (!first) try out.append(allocator, ',');
        first = false;
        try out.writer(allocator).print(
            "{{\"event_id\":{d},\"event_jsonl\":{f}}}",
            .{ event_id, std.json.fmt(trimmed, .{}) },
        );
    }
    try out.writer(allocator).print("],\"last_event_id\":{d}}}", .{event_id});
    return out.toOwnedSlice(allocator);
}

test "readEventsJsonl handles missing file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(work_dir);
    const got = try readEventsJsonl(allocator, work_dir, ".techlead/iteration-logs");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("{\"events\":[]}", got);
}

test "readEventsAfter returns filtered events with event ids" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(work_dir);

    const dir_path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, ".techlead/iteration-logs" });
    defer allocator.free(dir_path);
    try std.fs.cwd().makePath(dir_path);

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, "events.jsonl" });
    defer allocator.free(file_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = file_path,
        .data = "{\"a\":1}\n{\"a\":2}\n",
    });

    const got = try readEventsAfter(allocator, work_dir, ".techlead/iteration-logs", 1);
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"event_id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"last_event_id\":2") != null);
}
