const std = @import("std");

pub const RunStatus = enum {
    created,
    running,
    paused,
    completed,
    failed,
    aborted,
};

pub const TaskStatus = enum {
    queued,
    claimed,
    running,
    review,
    done,
    failed,
};

pub const Task = struct {
    id: []const u8,
    title: []const u8,
    status: TaskStatus,
    prompt: ?[]const u8 = null,
};

pub fn taskStatusFromString(s: []const u8) TaskStatus {
    if (std.mem.eql(u8, s, "queued")) return .queued;
    if (std.mem.eql(u8, s, "claimed")) return .claimed;
    if (std.mem.eql(u8, s, "running")) return .running;
    if (std.mem.eql(u8, s, "review")) return .review;
    if (std.mem.eql(u8, s, "done")) return .done;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    return .queued;
}

pub fn taskStatusToString(status: TaskStatus) []const u8 {
    return @tagName(status);
}

test "task status parse/format roundtrip" {
    const s = taskStatusFromString("running");
    try std.testing.expectEqualStrings("running", taskStatusToString(s));
}

