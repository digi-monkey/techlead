const std = @import("std");
const store = @import("store.zig");

pub const JsonlEventStore = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    mutex: std.Thread.Mutex = .{},
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, work_dir: []const u8, log_dir: []const u8) !JsonlEventStore {
        const log_path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, log_dir });
        defer allocator.free(log_path);
        try std.fs.cwd().makePath(log_path);

        const event_file_path = try std.fs.path.join(allocator, &[_][]const u8{ log_path, "events.jsonl" });
        defer allocator.free(event_file_path);

        const file = try std.fs.cwd().createFile(event_file_path, .{
            .read = true,
            .truncate = false,
        });
        try file.seekFromEnd(0);

        return .{
            .allocator = allocator,
            .file = file,
        };
    }

    pub fn asEventStore(self: *JsonlEventStore) store.EventStore {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *JsonlEventStore) void {
        if (self.closed) return;
        self.file.close();
        self.closed = true;
    }

    fn appendEvent(ctx: *anyopaque, event: store.Event) !void {
        const self: *JsonlEventStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.closed) return error.StoreClosed;

        const row = DiskEvent{
            .run_id = event.run_id,
            .task_id = event.task_id,
            .source = @tagName(event.source),
            .event_type = event.event_type,
            .ts = event.ts,
            .payload = event.payload,
        };

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        try line.writer(self.allocator).print("{f}\n", .{std.json.fmt(row, .{})});
        try self.file.writeAll(line.items);
        try self.file.sync();
    }

    fn close(ctx: *anyopaque) void {
        const self: *JsonlEventStore = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    const DiskEvent = struct {
        run_id: []const u8,
        task_id: ?[]const u8,
        source: []const u8,
        event_type: []const u8,
        ts: i64,
        payload: []const u8,
    };

    const vtable = store.EventStore.VTable{
        .appendEvent = appendEvent,
        .close = close,
    };
};

test "jsonl event store writes events.jsonl rows" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(work_dir);

    var s = try JsonlEventStore.init(allocator, work_dir, ".techlead/iteration-logs");
    defer s.deinit();

    const es = s.asEventStore();
    try es.appendEvent(.{
        .run_id = "run-1",
        .source = .system,
        .event_type = "run.started",
        .ts = 1,
        .payload = "{\"iterations\":1}",
    });

    const event_file_path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, ".techlead/iteration-logs", "events.jsonl" });
    defer allocator.free(event_file_path);

    const content = try std.fs.cwd().readFileAlloc(allocator, event_file_path, 1024 * 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"run_id\":\"run-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"event_type\":\"run.started\"") != null);
}
