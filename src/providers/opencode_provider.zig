const std = @import("std");
const config = @import("../config.zig");
const opencode = @import("../opencode.zig");
const provider_api = @import("provider.zig");
const ui = @import("../ui.zig");
const utils = @import("../utils.zig");

/// Default provider backed by existing opencode invocation logic.
pub const OpencodeProvider = struct {
    pub fn asProvider(self: *OpencodeProvider) provider_api.Provider {
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

        const base_prompt = try opencode.preparePrompt(cfg, allocator, iteration, experiment_branch);
        defer allocator.free(base_prompt);

        const prompt = if (prompt_patch) |patch|
            try std.fmt.allocPrint(allocator, "{s}\n\n=== 运行中追加指令 ===\n{s}\n", .{ base_prompt, patch })
        else
            try allocator.dupe(u8, base_prompt);
        defer allocator.free(prompt);

        const success = try opencode.invokeOpencode(cfg, allocator, iteration, prompt);
        return .{ .success = success };
    }

    fn runPrompt(
        ctx: *anyopaque,
        cfg: config.Config,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        log_label: []const u8,
    ) !provider_api.ExecutionResult {
        _ = ctx;
        const success = try invokePrompt(cfg, allocator, prompt, log_label);
        return .{ .success = success };
    }

    fn invokePrompt(
        cfg: config.Config,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        log_label: []const u8,
    ) !bool {
        const sanitized_label = try sanitizeLogLabel(allocator, log_label);
        defer allocator.free(sanitized_label);

        const log_name = try std.fmt.allocPrint(allocator, "{s}.log", .{sanitized_label});
        defer allocator.free(log_name);
        const log_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.work_dir, cfg.log_dir });
        defer allocator.free(log_dir_path);
        try std.fs.cwd().makePath(log_dir_path);
        const log_file_path = try std.fs.path.join(allocator, &[_][]const u8{ log_dir_path, log_name });
        defer allocator.free(log_file_path);

        const current_branch = utils.runShellStdout(allocator, cfg.work_dir, "git branch --show-current") catch "unknown";
        defer if (!std.mem.eql(u8, current_branch, "unknown")) allocator.free(current_branch);

        ui.logInfo("调用 OpenCode ({s})...", .{log_label});
        ui.logInfo("当前分支: {s}", .{current_branch});

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &[_][]const u8{
            "oh-my-opencode",
            "run",
            "--attach",
            cfg.opencode_url,
            "--directory",
            cfg.work_dir,
            "--json",
        });

        if (cfg.model.len > 0) {
            try argv.append(allocator, "--model");
            try argv.append(allocator, cfg.model);
        }
        if (cfg.agent.len > 0) {
            try argv.append(allocator, "--agent");
            const capitalized_agent = try opencode.capitalizeFirstLetter(allocator, cfg.agent);
            defer allocator.free(capitalized_agent);
            try argv.append(allocator, capitalized_agent);
        }
        try argv.append(allocator, prompt);

        ui.logInfo("执行: oh-my-opencode run --attach {s} --directory {s} --json", .{ cfg.opencode_url, cfg.work_dir });

        var log_file = try std.fs.cwd().createFile(log_file_path, .{ .truncate = true });
        defer log_file.close();

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        child.cwd = cfg.work_dir;

        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
        }

        var buf: [4096]u8 = undefined;
        const child_stdout = child.stdout orelse return error.CommandFailed;
        while (true) {
            const n = try child_stdout.read(&buf);
            if (n == 0) break;

            const chunk = buf[0..n];
            try log_file.writeAll(chunk);
            std.debug.print("{s}", .{chunk});
        }

        const term = try child.wait();
        if (!utils.isExitedZero(term)) {
            ui.logError("调用 OpenCode 失败", .{});
            ui.logInfo("日志保存在: {s}", .{log_file_path});
            return false;
        }

        return true;
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

    const vtable = provider_api.Provider.VTable{
        .runIteration = runIteration,
        .runPrompt = runPrompt,
    };
};
