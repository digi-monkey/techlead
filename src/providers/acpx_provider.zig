const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const provider_api = @import("provider.zig");
const ui = @import("../ui.zig");
const utils = @import("../utils.zig");

const ACPX_EXEC_TIMEOUT_SECONDS: u64 = 2 * 60 * 60;
const WATCHDOG_POLL_NS: u64 = 250 * std.time.ns_per_ms;

const ProcessWatchdogState = struct {
    mutex: std.Thread.Mutex = .{},
    done: bool = false,
    timed_out: bool = false,
};

const ProcessWatchdogArgs = struct {
    child_id: std.process.Child.Id,
    timeout_seconds: u64,
    state: *ProcessWatchdogState,
};

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
        .runPrompt = runPrompt,
    };

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

    // Build argv: acpx --approve-all --cwd <work_dir> <agent> exec --file <prompt_file>
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "acpx");
    try argv.append(allocator, "--approve-all");
    try argv.append(allocator, "--cwd");
    try argv.append(allocator, cfg.work_dir);
    try argv.append(allocator, cfg.provider); // agent name: codex, claude, opencode, etc.
    try argv.append(allocator, "exec");
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

    try child.spawn();

    var watchdog_state = ProcessWatchdogState{};
    const watchdog_thread = if (ACPX_EXEC_TIMEOUT_SECONDS > 0)
        std.Thread.spawn(.{}, killChildAfterTimeout, .{ProcessWatchdogArgs{
            .child_id = child.id,
            .timeout_seconds = ACPX_EXEC_TIMEOUT_SECONDS,
            .state = &watchdog_state,
        }}) catch null
    else
        null;

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

    watchdog_state.mutex.lock();
    watchdog_state.done = true;
    const timed_out = watchdog_state.timed_out;
    watchdog_state.mutex.unlock();
    if (watchdog_thread) |thread| thread.join();

    const success = (term == .Exited and term.Exited == 0);
    if (!success) {
        if (timed_out) {
            ui.logError("acpx 执行超时并已终止 (label={s}, timeout={d}s)", .{ log_label, ACPX_EXEC_TIMEOUT_SECONDS });
        } else {
            ui.logError("acpx 执行失败 (label={s})", .{log_label});
        }
    }
    return .{ .success = success };
}

fn killChildAfterTimeout(args: ProcessWatchdogArgs) void {
    const timeout_ns = args.timeout_seconds * std.time.ns_per_s;
    var elapsed_ns: u64 = 0;

    while (elapsed_ns < timeout_ns) {
        args.state.mutex.lock();
        const done = args.state.done;
        args.state.mutex.unlock();
        if (done) return;

        const remaining = timeout_ns - elapsed_ns;
        const sleep_ns = @min(remaining, WATCHDOG_POLL_NS);
        std.Thread.sleep(sleep_ns);
        elapsed_ns += sleep_ns;
    }

    args.state.mutex.lock();
    const already_done = args.state.done;
    args.state.mutex.unlock();
    if (already_done) return;

    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return;
    }

    std.posix.kill(args.child_id, std.posix.SIG.KILL) catch {};

    args.state.mutex.lock();
    args.state.timed_out = true;
    args.state.mutex.unlock();
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

    const filename = try std.fmt.allocPrint(allocator, "{s}.log", .{sanitized});
    defer allocator.free(filename);

    return std.fs.path.join(allocator, &[_][]const u8{
        cfg.work_dir,
        cfg.log_dir,
        filename,
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
