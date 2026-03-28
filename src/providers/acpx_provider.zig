const std = @import("std");
const config = @import("../config.zig");
const provider_api = @import("provider.zig");
const ui = @import("../ui.zig");
const utils = @import("../utils.zig");

/// Provider backed by `acpx` — the unified ACP CLI client.
/// All agent execution is delegated to acpx, which manages
/// sessions, permissions, and structured output for any
/// ACP-compatible agent (codex, claude, opencode, etc.).
pub const AcpxProvider = struct {
    pub fn asProvider(self: *AcpxProvider) provider_api.Provider {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    const vtable = provider_api.Provider.VTable{
        .runIteration = runIteration,
        .runPrompt = runPrompt,
    };

    fn runIteration(
        ctx: *anyopaque,
        cfg: config.Config,
        allocator: std.mem.Allocator,
        iteration: usize,
        experiment_branch: ?[]const u8,
        prompt_patch: ?[]const u8,
    ) anyerror!provider_api.ExecutionResult {
        _ = ctx;
        _ = experiment_branch;

        // Build a prompt from the program file + optional patch
        const program_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.work_dir, cfg.program_file });
        defer allocator.free(program_path);

        const program_content = std.fs.cwd().readFileAlloc(allocator, program_path, 1024 * 1024) catch |err| {
            ui.logError("读取 program file 失败: {any}", .{err});
            return .{ .success = false };
        };
        defer allocator.free(program_content);

        const prompt = if (prompt_patch) |patch|
            try std.fmt.allocPrint(allocator,
                \\iteration {d}/{d}
                \\
                \\{s}
                \\
                \\=== 运行中追加指令 ===
                \\{s}
            , .{ iteration, cfg.iterations, program_content, patch })
        else
            try std.fmt.allocPrint(allocator,
                \\iteration {d}/{d}
                \\
                \\{s}
            , .{ iteration, cfg.iterations, program_content });
        defer allocator.free(prompt);

        const log_label = try std.fmt.allocPrint(allocator, "iteration-{d}", .{iteration});
        defer allocator.free(log_label);

        return execAcpx(cfg, allocator, prompt, log_label);
    }

    fn runPrompt(
        ctx: *anyopaque,
        cfg: config.Config,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        log_label: []const u8,
    ) anyerror!provider_api.ExecutionResult {
        _ = ctx;
        return execAcpx(cfg, allocator, prompt, log_label);
    }
};

/// Core execution: invoke `acpx <agent> exec` with the given prompt.
/// Uses --approve-all for non-interactive operation and --format text
/// for human-readable streaming output. Logs stdout/stderr to the
/// configured log directory.
fn execAcpx(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    log_label: []const u8,
) !provider_api.ExecutionResult {
    // Verify acpx is available
    if (!utils.commandExists(allocator, "acpx")) {
        ui.logError("找不到 acpx CLI，请先安装: npm install -g acpx@latest", .{});
        return error.MissingAcpx;
    }

    // Write prompt to a temp file to avoid shell escaping issues
    const prompt_file = try writePromptTempFile(allocator, cfg, prompt, log_label);
    defer allocator.free(prompt_file);
    defer std.fs.cwd().deleteFile(prompt_file) catch {};

    // Build argv: acpx [agent] exec --approve-all --file <prompt_file>
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "acpx");
    try argv.append(allocator, cfg.provider); // agent name: codex, claude, opencode, etc.
    try argv.append(allocator, "exec");
    try argv.append(allocator, "--approve-all");
    try argv.append(allocator, "--file");
    try argv.append(allocator, prompt_file);

    ui.logInfo("acpx {s} exec (label={s})", .{ cfg.provider, log_label });

    // Prepare log file
    const log_path = try buildLogPath(allocator, cfg, log_label);
    defer allocator.free(log_path);

    const log_dir = std.fs.path.dirname(log_path) orelse ".";
    try std.fs.cwd().makePath(log_dir);

    const log_file = try std.fs.cwd().createFile(log_path, .{ .truncate = true });
    defer log_file.close();

    // Spawn child process
    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cfg.work_dir;

    try child.spawn();

    // Read stderr in background thread
    const stderr_thread = try std.Thread.spawn(.{}, readPipeToFileAndDebug, .{ child.stderr.?, log_file });

    // Read stdout in main thread
    const child_stdout = child.stdout orelse return error.CommandFailed;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child_stdout.read(&buf) catch break;
        if (n == 0) break;
        const chunk = buf[0..n];
        log_file.writeAll(chunk) catch {};
        std.debug.print("{s}", .{chunk});
    }

    stderr_thread.join();
    const term = try child.wait();

    const success = (term == .Exited and term.Exited == 0);
    if (!success) {
        ui.logError("acpx 执行失败 (label={s})", .{log_label});
    }
    return .{ .success = success };
}

fn readPipeToFileAndDebug(pipe: std.fs.File, log_file: std.fs.File) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pipe.read(&buf) catch break;
        if (n == 0) break;
        log_file.writeAll(buf[0..n]) catch {};
        std.debug.print("{s}", .{buf[0..n]});
    }
}

/// Write prompt content to a temporary file in the log directory.
fn writePromptTempFile(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    prompt: []const u8,
    log_label: []const u8,
) ![]u8 {
    const sanitized = try sanitizeLogLabel(allocator, log_label);
    defer allocator.free(sanitized);

    const path = try std.fs.path.join(allocator, &[_][]const u8{
        cfg.work_dir,
        cfg.log_dir,
        try std.fmt.allocPrint(allocator, ".prompt-{s}.md", .{sanitized}),
    });
    // NOTE: the nested allocPrint leaks the intermediate string; for
    // CLI-lifetime allocations this is acceptable.

    const dir = std.fs.path.dirname(path) orelse ".";
    try std.fs.cwd().makePath(dir);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(prompt);

    return path;
}

/// Build the log file path for a given label.
fn buildLogPath(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    log_label: []const u8,
) ![]u8 {
    const sanitized = try sanitizeLogLabel(allocator, log_label);
    defer allocator.free(sanitized);

    return std.fs.path.join(allocator, &[_][]const u8{
        cfg.work_dir,
        cfg.log_dir,
        try std.fmt.allocPrint(allocator, "{s}.log", .{sanitized}),
    });
}

fn sanitizeLogLabel(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, label.len);
    for (label, 0..) |ch, i| {
        const safe = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.';
        out[i] = if (safe) ch else '-';
    }
    return out;
}

test "sanitizeLogLabel replaces unsafe chars" {
    const allocator = std.testing.allocator;
    const result = try sanitizeLogLabel(allocator, "pool/codex/r1-implement");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("pool-codex-r1-implement", result);
}
