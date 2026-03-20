const std = @import("std");
const domain = @import("domain.zig");

pub const SchedulerMode = enum {
    optimize,
    pool,
};

pub fn claimNextQueuedTask(tasks: []domain.Task) ?*domain.Task {
    for (tasks) |*t| {
        if (t.status == .queued) {
            t.status = .claimed;
            return t;
        }
    }
    return null;
}

test "claimNextQueuedTask claims first queued task" {
    var tasks = [_]domain.Task{
        .{ .id = "a", .title = "A", .status = .done },
        .{ .id = "b", .title = "B", .status = .queued },
        .{ .id = "c", .title = "C", .status = .queued },
    };
    const claimed = claimNextQueuedTask(&tasks).?;
    try std.testing.expectEqualStrings("b", claimed.id);
    try std.testing.expect(claimed.status == .claimed);
}

