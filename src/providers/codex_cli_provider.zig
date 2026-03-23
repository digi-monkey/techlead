const std = @import("std");
const config = @import("../config.zig");
const provider_api = @import("provider.zig");
const opencode = @import("../opencode.zig");
const ui = @import("../ui.zig");
const utils = @import("../utils.zig");

/// Provider backed by `codex exec` non-interactive CLI.
pub const CodexCliProvider = struct {
    const PromptRunOptions = struct {
        require_decision: bool,
        iteration: ?usize,
        log_label: []const u8,
    };

    pub fn asProvider(self: *CodexCliProvider) provider_api.Provider {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    fn runIteration(
        ctx: *anyopaque,
        cfg: config.Config,
        allocator: std.mem.Allocator,
        iteration: usize,
        experiment_branch: ?[]const u8,
        prompt_patch: ?[]const u8,
    ) !provider_api.ExecutionResult {
        _ = ctx;

        if (!utils.commandExists(allocator, "codex")) {
            ui.logError("找不到 codex CLI，请确保已安装", .{});
            return error.MissingCodex;
        }

        const base_prompt = try opencode.preparePrompt(cfg, allocator, iteration, experiment_branch);
        defer allocator.free(base_prompt);
        const prompt = if (prompt_patch) |patch|
            try std.fmt.allocPrint(allocator, "{s}\n\n=== 运行中追加指令 ===\n{s}\n", .{ base_prompt, patch })
        else
            try allocator.dupe(u8, base_prompt);
        defer allocator.free(prompt);

        const log_name = try std.fmt.allocPrint(allocator, "iteration-{d}.log", .{iteration});
        defer allocator.free(log_name);

        return runPromptInternal(cfg, allocator, prompt, log_name, .{
            .require_decision = true,
            .iteration = iteration,
            .log_label = log_name,
        });
    }

    fn runPrompt(
        ctx: *anyopaque,
        cfg: config.Config,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        log_label: []const u8,
    ) !provider_api.ExecutionResult {
        _ = ctx;

        const sanitized_label = try sanitizeLogLabel(allocator, log_label);
        defer allocator.free(sanitized_label);
        const log_name = try std.fmt.allocPrint(allocator, "{s}.log", .{sanitized_label});
        defer allocator.free(log_name);

        return runPromptInternal(cfg, allocator, prompt, log_name, .{
            .require_decision = false,
            .iteration = null,
            .log_label = log_label,
        });
    }

    fn runPromptInternal(
        cfg: config.Config,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        log_name: []const u8,
        options: PromptRunOptions,
    ) !provider_api.ExecutionResult {
        if (!utils.commandExists(allocator, "codex")) {
            ui.logError("找不到 codex CLI，请确保已安装", .{});
            return error.MissingCodex;
        }

        const log_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.work_dir, cfg.log_dir });
        defer allocator.free(log_dir_path);
        try std.fs.cwd().makePath(log_dir_path);
        const log_file_path = try std.fs.path.join(allocator, &[_][]const u8{ log_dir_path, log_name });
        defer allocator.free(log_file_path);

        if (options.iteration) |iter| {
            ui.logInfo("第 {d} 次迭代：调用 Codex CLI...", .{iter});
        } else {
            ui.logInfo("调用 Codex CLI ({s})...", .{options.log_label});
        }
        ui.logInfo("执行: codex exec --cd {s} --json --dangerously-bypass-approvals-and-sandbox", .{cfg.work_dir});

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &[_][]const u8{
            "codex",
            "exec",
            "--cd",
            cfg.work_dir,
            "--json",
            "--dangerously-bypass-approvals-and-sandbox",
        });
        if (cfg.model.len > 0) {
            try argv.append(allocator, "--model");
            try argv.append(allocator, cfg.model);
        }
        try argv.append(allocator, prompt);

        const run_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv.items,
            .cwd = cfg.work_dir,
            .max_output_bytes = 64 * 1024 * 1024,
        });
        defer allocator.free(run_result.stdout);
        defer allocator.free(run_result.stderr);

        var log_file = try std.fs.cwd().createFile(log_file_path, .{ .truncate = true });
        defer log_file.close();
        try log_file.writeAll(run_result.stdout);
        if (run_result.stderr.len > 0) try log_file.writeAll(run_result.stderr);

        std.debug.print("{s}", .{run_result.stdout});
        if (run_result.stderr.len > 0) std.debug.print("{s}", .{run_result.stderr});

        if (!utils.isExitedZero(run_result.term)) {
            ui.logError("调用 Codex CLI 失败", .{});
            ui.logInfo("日志保存在: {s}", .{log_file_path});
            return .{ .success = false };
        }

        var merged: std.ArrayList(u8) = .empty;
        defer merged.deinit(allocator);
        try merged.appendSlice(allocator, run_result.stdout);
        try merged.appendSlice(allocator, run_result.stderr);

        const decision = opencode.findDecision(merged.items);
        if (options.require_decision and decision == null) {
            ui.logWarn("未解析到标准 DECISION，判定为失败，请查看日志: {s}", .{log_file_path});
            return .{ .success = false };
        }

        if (containsFatalRuntimeError(merged.items)) {
            ui.logError("检测到执行环境致命错误，判定为失败", .{});
            ui.logInfo("日志保存在: {s}", .{log_file_path});
            return .{ .success = false };
        }

        if (decision) |d| {
            if (std.mem.eql(u8, d, "DECISION: KEEP")) {
                ui.logSuccess("决策: 保留分支", .{});
            } else if (std.mem.eql(u8, d, "DECISION: DISCARD")) {
                ui.logWarn("决策: 舍弃分支", .{});
            } else {
                ui.logSuccess("决策: 创建了新实验分支", .{});
            }
        }

        return .{ .success = true };
    }

    fn sanitizeLogLabel(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
        if (label.len == 0) return allocator.dupe(u8, "prompt");

        var out = try allocator.alloc(u8, label.len);
        errdefer allocator.free(out);

        for (label, 0..) |ch, i| {
            const is_safe = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.';
            out[i] = if (is_safe) ch else '_';
        }

        return out;
    }

    fn containsFatalRuntimeError(text: []const u8) bool {
        const fatal_markers = [_][]const u8{
            "bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted",
            "Operation not permitted",
            "无法继续执行",
            "cannot execute",
        };
        for (fatal_markers) |m| {
            if (std.mem.indexOf(u8, text, m) != null) return true;
        }
        return false;
    }

    const vtable = provider_api.Provider.VTable{
        .runIteration = runIteration,
        .runPrompt = runPrompt,
    };
};

test "containsFatalRuntimeError detects sandbox permission failure" {
    try std.testing.expect(CodexCliProvider.containsFatalRuntimeError("...Operation not permitted..."));
    try std.testing.expect(!CodexCliProvider.containsFatalRuntimeError("normal output with DECISION: KEEP"));
}
