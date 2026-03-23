const std = @import("std");

const config = @import("config.zig");
const event_store = @import("storage/store.zig");
const sqlite_store = @import("storage/sqlite_store.zig");
const control_service = @import("app/control_service.zig");
const run_service = @import("app/run_service.zig");
const init_service = @import("app/init_service.zig");
const agent_service = @import("app/agent_service.zig");

const Allocator = std.mem.Allocator;

pub const RunMode = enum {
    optimize,
    pool,
};

/// Validates the runtime environment for the run command.
pub fn validateRunEnvironment(cfg: config.Config, allocator: Allocator) !void {
    return run_service.validateRunEnvironment(cfg, allocator);
}

/// Checks if OpenCode server is available.
pub fn checkOpencode(cfg: config.Config, allocator: Allocator) !void {
    return run_service.checkOpencode(cfg, allocator);
}

/// Runs the main iteration command.
pub fn runCommand(cfg: config.Config, allocator: Allocator) !void {
    return runCommandWithMode(cfg, allocator, .pool);
}

/// Runs the main command with explicit execution mode.
pub fn runCommandWithMode(cfg: config.Config, allocator: Allocator, mode: RunMode) !void {
    if (mode == .optimize) {
        try validateRunEnvironment(cfg, allocator);
    } else {
        try run_service.validatePoolRunEnvironment(cfg, allocator);
    }

    var sqlite = try sqlite_store.SqliteEventStore.init(allocator, cfg.work_dir, cfg.log_dir);
    defer sqlite.deinit();
    const primary_es: event_store.EventStore = sqlite.asEventStore();
    const mirror_es: ?event_store.EventStore = null;

    const run_id = try std.fmt.allocPrint(allocator, "run-{d}", .{std.time.timestamp()});
    defer allocator.free(run_id);

    const exec_mode: run_service.ExecutionMode = if (mode == .pool) .pool else .optimize;
    try run_service.executeConfiguredRun(
        cfg,
        allocator,
        exec_mode,
        primary_es,
        mirror_es,
        run_id,
    );
}

/// Runs the init command to set up a new project.
pub fn runInitCommand(allocator: Allocator, goal: []const u8, force: bool, target_dir: []const u8) !void {
    return init_service.runInitCommand(allocator, goal, force, target_dir);
}

pub fn runControlCommand(allocator: Allocator, target_dir: []const u8, action: []const u8, prompt: ?[]const u8) !void {
    return control_service.sendControl(allocator, target_dir, action, prompt);
}

pub fn runControlCommandWithMeta(
    allocator: Allocator,
    target_dir: []const u8,
    action: []const u8,
    prompt: ?[]const u8,
    operator: []const u8,
    source: []const u8,
) !void {
    return control_service.sendControlWithMeta(allocator, target_dir, action, prompt, operator, source);
}

pub fn runControlCommandWithMetaAndRequestId(
    allocator: Allocator,
    target_dir: []const u8,
    action: []const u8,
    prompt: ?[]const u8,
    operator: []const u8,
    source: []const u8,
    request_id: []const u8,
) !void {
    return control_service.sendControlWithMetaAndRequestId(allocator, target_dir, action, prompt, operator, source, request_id);
}

/// Runs the init-agent command to detect tech stack and generate agent prompt.
/// Detects technology stack, builds an agent prompt, and copies it to clipboard.
pub fn runInitAgentCommand(allocator: Allocator, args: []const []const u8) !void {
    return agent_service.runInitAgentCommand(allocator, args);
}
