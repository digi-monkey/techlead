const std = @import("std");
const config = @import("../config.zig");
const git = @import("../git.zig");
const ui = @import("../ui.zig");
const utils = @import("../utils.zig");
const pool_service = @import("pool_service.zig");
const event_store = @import("../storage/store.zig");
const acpx_provider = @import("../providers/acpx_provider.zig");

pub const ExecutionMode = enum {
    project,
};

pub fn validateRunEnvironment(cfg: config.Config, allocator: std.mem.Allocator) !void {
    ui.logInfo("检查运行环境...", .{});

    const abs_work_dir = try std.fs.cwd().realpathAlloc(allocator, cfg.work_dir);
    defer allocator.free(abs_work_dir);
    ui.logInfo("工作目录: {s}", .{abs_work_dir});

    const program_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.work_dir, cfg.program_file });
    defer allocator.free(program_path);

    std.fs.cwd().access(program_path, .{}) catch {
        ui.logError("找不到 {s}", .{program_path});
        return error.MissingProgramFile;
    };

    try git.verifyGitRepo(cfg.work_dir, allocator);
    ui.logSuccess("环境检查通过", .{});
    std.debug.print("\n", .{});
}

pub fn validatePoolRunEnvironment(cfg: config.Config, allocator: std.mem.Allocator) !void {
    ui.logInfo("检查 project 运行环境...", .{});

    const abs_work_dir = try std.fs.cwd().realpathAlloc(allocator, cfg.work_dir);
    defer allocator.free(abs_work_dir);
    ui.logInfo("工作目录: {s}", .{abs_work_dir});

    try git.verifyGitRepo(cfg.work_dir, allocator);
    ui.logSuccess("project 环境检查通过", .{});
    std.debug.print("\n", .{});
}

pub fn executeWithProvider(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    provider: anytype,
    provider_name: []const u8,
    primary_es: event_store.EventStore,
    mirror_es: ?event_store.EventStore,
    run_id: []const u8,
) !void {
    const start_payload = try std.fmt.allocPrint(allocator, "{{\"iterations\":{d},\"mode\":\"project\"}}", .{cfg.iterations});
    defer allocator.free(start_payload);
    appendRunEvent(primary_es, mirror_es, run_id, .system, "run.started", start_payload);

    try pool_service.run(cfg, allocator, provider, provider_name, primary_es, mirror_es, run_id, cfg.project_test_cmd, cfg.project_lint_cmd);
    appendRunEvent(primary_es, mirror_es, run_id, .system, "run.completed", "{\"status\":\"completed\"}");
    ui.logSuccess("project 模式完成", .{});
}

pub fn executeConfiguredRun(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    _: ExecutionMode,
    primary_es: event_store.EventStore,
    mirror_es: ?event_store.EventStore,
    run_id: []const u8,
) !void {
    var acpx_p = acpx_provider.AcpxProvider{};
    return executeWithProvider(cfg, allocator, acpx_p.asProvider(), cfg.provider, primary_es, mirror_es, run_id);
}

fn appendRunEvent(
    primary_es: event_store.EventStore,
    mirror_es: ?event_store.EventStore,
    run_id: []const u8,
    source: event_store.EventSource,
    event_type: []const u8,
    payload: []const u8,
) void {
    const e: event_store.Event = .{
        .run_id = run_id,
        .source = source,
        .event_type = event_type,
        .ts = std.time.timestamp(),
        .payload = payload,
    };
    primary_es.appendEvent(e) catch |err| {
        ui.logWarn("写入事件失败: {any}", .{err});
    };
    if (mirror_es) |mirror| {
        mirror.appendEvent(e) catch |err| {
            ui.logWarn("写入镜像事件失败: {any}", .{err});
        };
    }
}
