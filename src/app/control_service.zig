const std = @import("std");
const config = @import("../config.zig");
const ui = @import("../ui.zig");
const sqlite_runtime_store = @import("../storage/sqlite_runtime_store.zig");

pub const Action = enum {
    none,
    pause,
    resume_run,
    abort,
    inject_prompt,
};

pub const Command = struct {
    action: Action = .none,
    prompt: ?[]u8 = null,
    operator: ?[]u8 = null,
    request_id: ?[]u8 = null,
    source: ?[]u8 = null,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        if (self.prompt) |p| allocator.free(p);
        if (self.operator) |p| allocator.free(p);
        if (self.request_id) |p| allocator.free(p);
        if (self.source) |p| allocator.free(p);
        self.* = .{};
    }
};

pub fn consumeControlCommand(allocator: std.mem.Allocator, cfg: config.Config) !Command {
    var store = try sqlite_runtime_store.SqliteRuntimeStore.init(allocator, cfg.work_dir);
    defer store.deinit();

    const rec = try store.consumeControl();
    if (rec == null) return .{};
    var row = rec.?;
    defer row.deinit(store.allocator);

    const action = if (std.mem.eql(u8, row.action, "pause"))
        Action.pause
    else if (std.mem.eql(u8, row.action, "resume"))
        Action.resume_run
    else if (std.mem.eql(u8, row.action, "abort"))
        Action.abort
    else if (std.mem.eql(u8, row.action, "inject_prompt"))
        Action.inject_prompt
    else
        Action.none;

    return .{
        .action = action,
        .prompt = if (row.prompt) |p| try allocator.dupe(u8, p) else null,
        .operator = if (row.operator) |p| try allocator.dupe(u8, p) else null,
        .request_id = if (row.request_id) |p| try allocator.dupe(u8, p) else null,
        .source = if (row.source) |p| try allocator.dupe(u8, p) else null,
    };
}

pub fn writeControlCommand(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    action: []const u8,
    prompt: ?[]const u8,
    operator: []const u8,
    source: []const u8,
    request_id: []const u8,
) !void {
    var store = try sqlite_runtime_store.SqliteRuntimeStore.init(allocator, cfg.work_dir);
    defer store.deinit();
    try store.enqueueControl(action, prompt, operator, source, request_id);
}

pub fn sendControl(allocator: std.mem.Allocator, target_dir: []const u8, action: []const u8, prompt: ?[]const u8) !void {
    return sendControlWithMeta(allocator, target_dir, action, prompt, "cli", "cli");
}

pub fn sendControlWithMeta(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    action: []const u8,
    prompt: ?[]const u8,
    operator: []const u8,
    source: []const u8,
) !void {
    return sendControlWithMetaAndRequestId(allocator, target_dir, action, prompt, operator, source, null);
}

pub fn sendControlWithMetaAndRequestId(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    action: []const u8,
    prompt: ?[]const u8,
    operator: []const u8,
    source: []const u8,
    request_id_opt: ?[]const u8,
) !void {
    const cfg = try config.loadConfigFromJson(allocator, target_dir);
    defer config.deinitConfig(allocator, &cfg);
    const request_id = if (request_id_opt) |rid|
        try allocator.dupe(u8, rid)
    else
        try std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()});
    defer allocator.free(request_id);
    try writeControlCommand(allocator, cfg, action, prompt, operator, source, request_id);
    ui.logSuccess("控制命令已写入: {s}", .{action});
}
