const std = @import("std");
const config = @import("../config.zig");
const git = @import("../git.zig");
const ui = @import("../ui.zig");
const utils = @import("../utils.zig");
const control_service = @import("control_service.zig");
const task_service = @import("task_service.zig");
const event_store = @import("../storage/store.zig");
const opencode_provider = @import("../providers/opencode_provider.zig");
const codex_cli_provider = @import("../providers/codex_cli_provider.zig");
const claude_cli_provider = @import("../providers/claude_cli_provider.zig");

pub const ExecutionMode = enum {
    optimize,
    pool,
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

pub fn checkOpencode(cfg: config.Config, allocator: std.mem.Allocator) !void {
    ui.logInfo("检查 OpenCode server...", .{});
    if (!utils.checkHttpService(allocator, cfg.opencode_url)) {
        ui.logError("无法连接到 OpenCode server at {s}", .{cfg.opencode_url});
        ui.logInfo("请确保 OpenCode serve 正在运行: opencode serve", .{});
        return error.OpencodeUnavailable;
    }

    ui.logSuccess("OpenCode server 连接正常", .{});
    std.debug.print("\n", .{});
}

pub fn executeWithProvider(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    mode: ExecutionMode,
    provider: anytype,
    provider_name: []const u8,
    primary_es: event_store.EventStore,
    mirror_es: ?event_store.EventStore,
    run_id: []const u8,
) !void {
    const start_payload = try std.fmt.allocPrint(allocator, "{{\"iterations\":{d},\"mode\":\"{s}\"}}", .{ cfg.iterations, @tagName(mode) });
    defer allocator.free(start_payload);
    appendRunEvent(primary_es, mirror_es, run_id, .system, "run.started", start_payload);
    writeRunState(allocator, cfg, run_id, mode, "running");

    if (mode == .pool) {
        try runPoolMode(cfg, allocator, provider, provider_name, primary_es, mirror_es, run_id);
        appendRunEvent(primary_es, mirror_es, run_id, .system, "run.completed", "{\"status\":\"completed\"}");
        writeRunState(allocator, cfg, run_id, mode, "completed");
        ui.logSuccess("pool 模式完成", .{});
        return;
    }

    var i: usize = 1;
    var pending_patch: ?[]u8 = null;
    var successful_iterations: usize = 0;
    var aborted_by_control = false;
    defer if (pending_patch) |p| allocator.free(p);

    while (i <= cfg.iterations) : (i += 1) {
        std.debug.print("========================================\n", .{});
        ui.logInfo("第 {d} / {d} 次迭代", .{ i, cfg.iterations });
        std.debug.print("========================================\n\n", .{});

        const experiment_branch = git.getCurrentExperimentBranch(cfg, allocator);
        defer if (experiment_branch) |b| allocator.free(b);

        var iter_buf: [512]u8 = undefined;
        const iter_payload = if (experiment_branch) |branch|
            std.fmt.bufPrint(&iter_buf, "{{\"iteration\":{d},\"experiment_branch\":\"{s}\"}}", .{ i, branch }) catch "{\"iteration\":0}"
        else
            std.fmt.bufPrint(&iter_buf, "{{\"iteration\":{d},\"experiment_branch\":null}}", .{i}) catch "{\"iteration\":0}";
        appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "iteration.started", iter_payload);

        var cmd = try control_service.consumeControlCommand(allocator, cfg);
        defer cmd.deinit(allocator);

        switch (cmd.action) {
            .abort => {
                var abort_buf: [512]u8 = undefined;
                const abort_payload = std.fmt.bufPrint(
                    &abort_buf,
                    "{{\"operator\":{f},\"source\":{f},\"request_id\":{f}}}",
                    .{
                        std.json.fmt(cmd.operator orelse "unknown", .{}),
                        std.json.fmt(cmd.source orelse "unknown", .{}),
                        std.json.fmt(cmd.request_id orelse "unknown", .{}),
                    },
                ) catch "{}";
                appendRunEvent(primary_es, mirror_es, run_id, .control, "control.abort", abort_payload);
                appendRunEvent(primary_es, mirror_es, run_id, .system, "run.aborted", "{}");
                writeRunState(allocator, cfg, run_id, mode, "aborted");
                ui.logWarn("收到 abort 指令，停止运行", .{});
                aborted_by_control = true;
                break;
            },
            .pause => {
                var pause_buf: [512]u8 = undefined;
                const pause_payload = std.fmt.bufPrint(
                    &pause_buf,
                    "{{\"operator\":{f},\"source\":{f},\"request_id\":{f}}}",
                    .{
                        std.json.fmt(cmd.operator orelse "unknown", .{}),
                        std.json.fmt(cmd.source orelse "unknown", .{}),
                        std.json.fmt(cmd.request_id orelse "unknown", .{}),
                    },
                ) catch "{}";
                appendRunEvent(primary_es, mirror_es, run_id, .control, "control.pause", pause_payload);
                ui.logWarn("收到 pause 指令，等待 resume/abort...", .{});
                while (true) {
                    std.Thread.sleep(500 * std.time.ns_per_ms);
                    var wait_cmd = try control_service.consumeControlCommand(allocator, cfg);
                    defer wait_cmd.deinit(allocator);
                    switch (wait_cmd.action) {
                        .resume_run => {
                            var resume_buf: [512]u8 = undefined;
                            const resume_payload = std.fmt.bufPrint(
                                &resume_buf,
                                "{{\"operator\":{f},\"source\":{f},\"request_id\":{f}}}",
                                .{
                                    std.json.fmt(wait_cmd.operator orelse "unknown", .{}),
                                    std.json.fmt(wait_cmd.source orelse "unknown", .{}),
                                    std.json.fmt(wait_cmd.request_id orelse "unknown", .{}),
                                },
                            ) catch "{}";
                            appendRunEvent(primary_es, mirror_es, run_id, .control, "control.resume", resume_payload);
                            break;
                        },
                        .abort => {
                            var wait_abort_buf: [512]u8 = undefined;
                            const wait_abort_payload = std.fmt.bufPrint(
                                &wait_abort_buf,
                                "{{\"operator\":{f},\"source\":{f},\"request_id\":{f}}}",
                                .{
                                    std.json.fmt(wait_cmd.operator orelse "unknown", .{}),
                                    std.json.fmt(wait_cmd.source orelse "unknown", .{}),
                                    std.json.fmt(wait_cmd.request_id orelse "unknown", .{}),
                                },
                            ) catch "{}";
                            appendRunEvent(primary_es, mirror_es, run_id, .control, "control.abort", wait_abort_payload);
                            appendRunEvent(primary_es, mirror_es, run_id, .system, "run.aborted", "{}");
                            writeRunState(allocator, cfg, run_id, mode, "aborted");
                            ui.logWarn("暂停期间收到 abort 指令，停止运行", .{});
                            return;
                        },
                        .inject_prompt => {
                            if (wait_cmd.prompt) |p| {
                                if (pending_patch) |old| allocator.free(old);
                                pending_patch = try allocator.dupe(u8, p);
                                var inject_pause_buf: [512]u8 = undefined;
                                const inject_pause_payload = std.fmt.bufPrint(
                                    &inject_pause_buf,
                                    "{{\"queued\":true,\"operator\":{f},\"source\":{f},\"request_id\":{f}}}",
                                    .{
                                        std.json.fmt(wait_cmd.operator orelse "unknown", .{}),
                                        std.json.fmt(wait_cmd.source orelse "unknown", .{}),
                                        std.json.fmt(wait_cmd.request_id orelse "unknown", .{}),
                                    },
                                ) catch "{\"queued\":true}";
                                appendRunEvent(primary_es, mirror_es, run_id, .control, "control.inject_prompt", inject_pause_payload);
                            }
                        },
                        else => {},
                    }
                }
            },
            .inject_prompt => {
                if (cmd.prompt) |p| {
                    if (pending_patch) |old| allocator.free(old);
                    pending_patch = try allocator.dupe(u8, p);
                    var inject_buf: [512]u8 = undefined;
                    const inject_payload = std.fmt.bufPrint(
                        &inject_buf,
                        "{{\"queued\":true,\"operator\":{f},\"source\":{f},\"request_id\":{f}}}",
                        .{
                            std.json.fmt(cmd.operator orelse "unknown", .{}),
                            std.json.fmt(cmd.source orelse "unknown", .{}),
                            std.json.fmt(cmd.request_id orelse "unknown", .{}),
                        },
                    ) catch "{\"queued\":true}";
                    appendRunEvent(primary_es, mirror_es, run_id, .control, "control.inject_prompt", inject_payload);
                }
            },
            else => {},
        }

        var provider_started_buf: [128]u8 = undefined;
        const provider_started_payload = std.fmt.bufPrint(&provider_started_buf, "{{\"provider\":\"{s}\"}}", .{provider_name}) catch "{\"provider\":\"unknown\"}";
        appendRunEvent(primary_es, mirror_es, run_id, .provider, "provider.invoke.started", provider_started_payload);

        const patch_view: ?[]const u8 = if (pending_patch) |p| p else null;
        const exec_result = try provider.runIteration(cfg, allocator, i, experiment_branch, patch_view);
        if (pending_patch) |p| {
            allocator.free(p);
            pending_patch = null;
        }
        if (!exec_result.success) {
            var provider_failed_buf: [128]u8 = undefined;
            const provider_failed_payload = std.fmt.bufPrint(&provider_failed_buf, "{{\"provider\":\"{s}\"}}", .{provider_name}) catch "{\"provider\":\"unknown\"}";
            appendRunEvent(primary_es, mirror_es, run_id, .provider, "provider.invoke.failed", provider_failed_payload);
            appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "iteration.failed", "{\"reason\":\"provider_failed\"}");
            ui.logError("第 {d} 次迭代失败，跳过...", .{i});
            continue;
        }

        var provider_ok_buf: [128]u8 = undefined;
        const provider_ok_payload = std.fmt.bufPrint(&provider_ok_buf, "{{\"provider\":\"{s}\"}}", .{provider_name}) catch "{\"provider\":\"unknown\"}";
        appendRunEvent(primary_es, mirror_es, run_id, .provider, "provider.invoke.succeeded", provider_ok_payload);

        var iter_ok_buf: [128]u8 = undefined;
        const iter_ok_payload = std.fmt.bufPrint(&iter_ok_buf, "{{\"iteration\":{d}}}", .{i}) catch "{\"iteration\":0}";
        appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "iteration.succeeded", iter_ok_payload);
        successful_iterations += 1;

        git.cleanupOldBranches(cfg, allocator);

        std.debug.print("\n", .{});
        ui.logInfo("当前 git 状态:", .{});
        const branch_output = utils.runShellStdout(allocator, cfg.work_dir, "git branch -v") catch {
            std.debug.print("\n", .{});
            if (i < cfg.iterations) {
                ui.logInfo("等待 2 秒后开始下一次迭代...", .{});
                std.Thread.sleep(2 * std.time.ns_per_s);
            }
            std.debug.print("\n", .{});
            continue;
        };
        defer allocator.free(branch_output);

        var bit = std.mem.splitScalar(u8, branch_output, '\n');
        while (bit.next()) |line| {
            if (std.mem.indexOf(u8, line, cfg.main_branch) != null or std.mem.indexOf(u8, line, "experiment-") != null) {
                std.debug.print("{s}\n", .{line});
            }
        }
        std.debug.print("\n", .{});

        if (i < cfg.iterations) {
            ui.logInfo("等待 2 秒后开始下一次迭代...", .{});
            std.Thread.sleep(2 * std.time.ns_per_s);
        }

        std.debug.print("\n", .{});
    }

    if (aborted_by_control) {
        std.debug.print("========================================\n", .{});
        ui.logWarn("运行已中断", .{});
        std.debug.print("========================================\n\n", .{});
        return;
    }

    if (cfg.iterations > 0 and successful_iterations == 0) {
        appendRunEvent(primary_es, mirror_es, run_id, .system, "run.failed", "{\"status\":\"failed\",\"reason\":\"all_iterations_failed\"}");
        writeRunState(allocator, cfg, run_id, mode, "failed");
        std.debug.print("========================================\n", .{});
        ui.logError("运行失败：没有任何成功迭代", .{});
        std.debug.print("========================================\n\n", .{});
        return error.AllIterationsFailed;
    }

    appendRunEvent(primary_es, mirror_es, run_id, .system, "run.completed", "{\"status\":\"completed\"}");
    writeRunState(allocator, cfg, run_id, mode, "completed");

    std.debug.print("========================================\n", .{});
    ui.logSuccess("迭代完成！", .{});
    std.debug.print("========================================\n\n", .{});
    ui.logInfo("总结:", .{});
    ui.logInfo("  - 总迭代次数: {d}", .{cfg.iterations});
    ui.logInfo("  - 日志目录: {s}", .{cfg.log_dir});

    const current_branch = utils.runShellStdout(allocator, cfg.work_dir, "git branch --show-current") catch "unknown";
    defer if (!std.mem.eql(u8, current_branch, "unknown")) allocator.free(current_branch);
    ui.logInfo("  - 当前分支: {s}", .{current_branch});
    std.debug.print("\n", .{});

    ui.logInfo("保留的 experiment 分支:", .{});
    const experiment_branches = utils.runShellStdout(allocator, cfg.work_dir, "git branch -v | grep experiment- || true") catch "";
    defer if (experiment_branches.len > 0) allocator.free(experiment_branches);

    if (experiment_branches.len > 0) {
        std.debug.print("{s}\n", .{experiment_branches});
    } else {
        ui.logInfo("  无", .{});
    }
    std.debug.print("\n", .{});
}

pub fn executeConfiguredRun(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    mode: ExecutionMode,
    primary_es: event_store.EventStore,
    mirror_es: ?event_store.EventStore,
    run_id: []const u8,
) !void {
    var opencode_p = opencode_provider.OpencodeProvider{};
    var codex_p = codex_cli_provider.CodexCliProvider{};
    var claude_p = claude_cli_provider.ClaudeCliProvider{};

    if (std.mem.eql(u8, cfg.provider, "opencode")) {
        if (!utils.commandExists(allocator, "opencode")) {
            ui.logError("找不到 opencode CLI，请确保已安装", .{});
            return error.MissingOpencode;
        }
        try checkOpencode(cfg, allocator);
        return executeWithProvider(cfg, allocator, mode, opencode_p.asProvider(), "opencode", primary_es, mirror_es, run_id);
    }
    if (std.mem.eql(u8, cfg.provider, "codex")) {
        return executeWithProvider(cfg, allocator, mode, codex_p.asProvider(), "codex", primary_es, mirror_es, run_id);
    }
    if (std.mem.eql(u8, cfg.provider, "claude")) {
        return executeWithProvider(cfg, allocator, mode, claude_p.asProvider(), "claude", primary_es, mirror_es, run_id);
    }

    ui.logError("未知 provider: {s}", .{cfg.provider});
    return error.InvalidConfig;
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

fn writeRunState(allocator: std.mem.Allocator, cfg: config.Config, run_id: []const u8, mode: ExecutionMode, status: []const u8) void {
    const state_path = std.fs.path.join(allocator, &[_][]const u8{ cfg.work_dir, ".techlead/run_state.json" }) catch return;
    defer allocator.free(state_path);

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"run_id\":{f},\"mode\":{f},\"status\":{f},\"updated_at\":{d}}}\n",
        .{ std.json.fmt(run_id, .{}), std.json.fmt(@tagName(mode), .{}), std.json.fmt(status, .{}), std.time.timestamp() },
    ) catch return;
    defer allocator.free(body);

    std.fs.cwd().writeFile(.{ .sub_path = state_path, .data = body }) catch |err| {
        ui.logWarn("写入 run_state 失败: {any}", .{err});
    };
}

fn runPoolMode(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    provider: anytype,
    provider_name: []const u8,
    primary_es: event_store.EventStore,
    mirror_es: ?event_store.EventStore,
    run_id: []const u8,
) !void {
    var loaded = try task_service.loadOrInitTasks(allocator, cfg.work_dir);
    defer loaded.deinit();

    var iteration: usize = 1;
    while (true) {
        const now = std.time.timestamp();
        var claimed_any = false;
        for (loaded.parsed.value.tasks) |*t| {
            const task_max_retries = t.max_retries orelse cfg.pool_max_retries;
            var claimable = std.mem.eql(u8, t.status, "queued");
            if (!claimable and (std.mem.eql(u8, t.status, "claimed") or std.mem.eql(u8, t.status, "running"))) {
                if (t.lease_until) |until| {
                    if (until <= now) claimable = true;
                }
            }
            if (!claimable and std.mem.eql(u8, t.status, "failed") and t.retry_count < task_max_retries) {
                claimable = true;
            }
            if (!claimable) continue;

            claimed_any = true;
            t.status = "claimed";
            t.lease_owner = run_id;
            t.lease_until = now + @as(i64, @intCast(cfg.pool_lease_seconds));

            var claim_buf: [384]u8 = undefined;
            const claim_payload = std.fmt.bufPrint(
                &claim_buf,
                "{{\"task_id\":{f},\"status\":\"claimed\",\"lease_until\":{d},\"retry_count\":{d}}}",
                .{ std.json.fmt(t.id, .{}), t.lease_until.?, t.retry_count },
            ) catch "{\"status\":\"claimed\"}";
            appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "task.claimed", claim_payload);

            t.status = "running";
            t.lease_until = std.time.timestamp() + @as(i64, @intCast(cfg.pool_lease_seconds));
            var run_buf: [384]u8 = undefined;
            const run_payload = std.fmt.bufPrint(
                &run_buf,
                "{{\"task_id\":{f},\"status\":\"running\",\"lease_until\":{d}}}",
                .{ std.json.fmt(t.id, .{}), t.lease_until.? },
            ) catch "{\"status\":\"running\"}";
            appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "task.running", run_payload);

            var provider_started_buf: [128]u8 = undefined;
            const provider_started_payload = std.fmt.bufPrint(&provider_started_buf, "{{\"provider\":\"{s}\"}}", .{provider_name}) catch "{\"provider\":\"unknown\"}";
            appendRunEvent(primary_es, mirror_es, run_id, .provider, "provider.invoke.started", provider_started_payload);
            const exec_result = try provider.runIteration(cfg, allocator, iteration, null, t.prompt);
            iteration += 1;

            if (exec_result.success) {
                t.status = "done";
                t.lease_owner = null;
                t.lease_until = null;
                var done_buf: [256]u8 = undefined;
                const done_payload = std.fmt.bufPrint(&done_buf, "{{\"task_id\":{f},\"status\":\"done\"}}", .{std.json.fmt(t.id, .{})}) catch "{\"status\":\"done\"}";
                appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "task.done", done_payload);
            } else {
                t.retry_count += 1;
                t.lease_owner = null;
                t.lease_until = null;
                if (t.retry_count < task_max_retries) {
                    t.status = "queued";
                    var requeue_buf: [256]u8 = undefined;
                    const requeue_payload = std.fmt.bufPrint(
                        &requeue_buf,
                        "{{\"task_id\":{f},\"status\":\"queued\",\"retry_count\":{d},\"max_retries\":{d}}}",
                        .{ std.json.fmt(t.id, .{}), t.retry_count, task_max_retries },
                    ) catch "{\"status\":\"queued\"}";
                    appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "task.requeued", requeue_payload);
                } else {
                    t.status = "failed";
                    var failed_buf: [256]u8 = undefined;
                    const failed_payload = std.fmt.bufPrint(
                        &failed_buf,
                        "{{\"task_id\":{f},\"status\":\"failed\",\"retry_count\":{d},\"max_retries\":{d}}}",
                        .{ std.json.fmt(t.id, .{}), t.retry_count, task_max_retries },
                    ) catch "{\"status\":\"failed\"}";
                    appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "task.failed", failed_payload);
                }
            }
        }
        if (!claimed_any) break;
    }

    try task_service.saveTasks(allocator, &loaded);
}
