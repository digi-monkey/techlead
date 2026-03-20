const std = @import("std");

pub const EventSource = enum {
    scheduler,
    provider,
    runtime,
    control,
    user,
    system,
};

pub const Event = struct {
    run_id: []const u8,
    task_id: ?[]const u8 = null,
    source: EventSource,
    event_type: []const u8,
    ts: i64,
    payload: []const u8,
};

/// EventStore is the abstraction boundary for structured event persistence.
pub const EventStore = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        appendEvent: *const fn (ctx: *anyopaque, event: Event) anyerror!void,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn appendEvent(self: EventStore, event: Event) !void {
        return self.vtable.appendEvent(self.ctx, event);
    }

    pub fn close(self: EventStore) void {
        self.vtable.close(self.ctx);
    }
};

