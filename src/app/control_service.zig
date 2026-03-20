const std = @import("std");
const config = @import("../config.zig");
const ui = @import("../ui.zig");

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

fn getControlPath(allocator: std.mem.Allocator, work_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ work_dir, ".techlead/control.json" });
}

pub fn consumeControlCommand(allocator: std.mem.Allocator, cfg: config.Config) !Command {
    const control_path = try getControlPath(allocator, cfg.work_dir);
    defer allocator.free(control_path);

    const content = std.fs.cwd().readFileAlloc(allocator, control_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(content);

    if (std.mem.trim(u8, content, " \t\r\n").len == 0) return .{};

    const FileControl = struct {
        action: []const u8 = "none",
        prompt: ?[]const u8 = null,
        operator: ?[]const u8 = null,
        request_id: ?[]const u8 = null,
        source: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(FileControl, allocator, content, .{}) catch return .{};
    defer parsed.deinit();

    const action = if (std.mem.eql(u8, parsed.value.action, "pause"))
        Action.pause
    else if (std.mem.eql(u8, parsed.value.action, "resume"))
        Action.resume_run
    else if (std.mem.eql(u8, parsed.value.action, "abort"))
        Action.abort
    else if (std.mem.eql(u8, parsed.value.action, "inject_prompt"))
        Action.inject_prompt
    else
        Action.none;

    // one-shot consume
    try std.fs.cwd().writeFile(.{ .sub_path = control_path, .data = "{}\n" });

    return .{
        .action = action,
        .prompt = if (parsed.value.prompt) |p| try allocator.dupe(u8, p) else null,
        .operator = if (parsed.value.operator) |p| try allocator.dupe(u8, p) else null,
        .request_id = if (parsed.value.request_id) |p| try allocator.dupe(u8, p) else null,
        .source = if (parsed.value.source) |p| try allocator.dupe(u8, p) else null,
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
    const control_path = try getControlPath(allocator, cfg.work_dir);
    defer allocator.free(control_path);

    const dir_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.work_dir, ".techlead" });
    defer allocator.free(dir_path);
    try std.fs.cwd().makePath(dir_path);

    const body = if (prompt) |p|
        try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"{s}\",\"prompt\":{f},\"operator\":{f},\"source\":{f},\"request_id\":{f}}}\n",
            .{ action, std.json.fmt(p, .{}), std.json.fmt(operator, .{}), std.json.fmt(source, .{}), std.json.fmt(request_id, .{}) },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{{\"action\":\"{s}\",\"operator\":{f},\"source\":{f},\"request_id\":{f}}}\n",
            .{ action, std.json.fmt(operator, .{}), std.json.fmt(source, .{}), std.json.fmt(request_id, .{}) },
        );
    defer allocator.free(body);

    try std.fs.cwd().writeFile(.{ .sub_path = control_path, .data = body });
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
