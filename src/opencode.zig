const std = @import("std");

const utils = @import("utils.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");

/// Capitalize the first letter of a string.
/// Returns an allocated string that must be freed by the caller.
pub fn capitalizeFirstLetter(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    if (str.len == 0) return allocator.dupe(u8, str);

    var result = try allocator.alloc(u8, str.len);
    errdefer allocator.free(result);

    // 复制原字符串
    @memcpy(result, str);

    // 首字母大写
    result[0] = std.ascii.toUpper(result[0]);

    return result;
}

/// Extract a string value from a JSON Value.
/// Returns null if the value is not a string.
pub fn valueAsString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Extract an i64 value from a JSON Value.
/// Handles both integer and number_string variants.
/// Returns null if the value cannot be converted.
pub fn valueAsI64(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Append a tool detail key-value pair to a message buffer.
/// The value is truncated for display purposes.
pub fn appendToolDetail(msg_buf: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, raw_value: []const u8) !void {
    const value = std.mem.trim(u8, raw_value, " \t\r\n");
    if (value.len == 0) return;
    try msg_buf.writer(allocator).print(" | {s}: {s}", .{ key, ui.truncateForLog(value, 88) });
}

/// Simplify a shell command by taking only the last command in a semicolon-separated chain.
/// Returns the trimmed last command or the original if no semicolons.
pub fn simplifyShellCommand(raw: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, raw, ';');
    var best = std.mem.trim(u8, raw, " \t\r\n");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len > 0) best = trimmed;
    }
    return best;
}

/// Render mode instructions by replacing <MAIN_BRANCH> placeholder.
/// Returns an allocated string that must be freed by the caller.
pub fn renderModeInstructions(allocator: std.mem.Allocator, template_mode: []const u8, main_branch: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const replaced_1 = try std.mem.replaceOwned(u8, allocator, template_mode, "<MAIN_BRANCH>", main_branch);
    defer allocator.free(replaced_1);

    try out.appendSlice(allocator, replaced_1);
    return out.toOwnedSlice(allocator);
}

/// Extract a template block from content by name.
/// Looks for <!-- TECHLEAD:<name>:BEGIN --> and <!-- TECHLEAD:<name>:END --> markers.
/// Returns the trimmed content between markers, or null if not found.
fn extractTemplateBlock(allocator: std.mem.Allocator, content: []const u8, block_name: []const u8) ?[]const u8 {
    const begin_marker = std.fmt.allocPrint(allocator, "<!-- TECHLEAD:{s}:BEGIN -->", .{block_name}) catch return null;
    defer allocator.free(begin_marker);

    const end_marker = std.fmt.allocPrint(allocator, "<!-- TECHLEAD:{s}:END -->", .{block_name}) catch return null;
    defer allocator.free(end_marker);

    const begin_index = std.mem.indexOf(u8, content, begin_marker) orelse return null;
    const begin_content = begin_index + begin_marker.len;

    const rest = content[begin_content..];
    const end_rel = std.mem.indexOf(u8, rest, end_marker) orelse return null;

    return std.mem.trim(u8, rest[0..end_rel], "\r\n \t");
}

/// Append a section with title and body to a writer.
fn appendSection(writer: anytype, title: []const u8, body: []const u8) !void {
    try writer.print("=== {s} ===\n{s}\n\n", .{ title, body });
}

/// Prepare the prompt for OpenCode invocation.
/// Reads program.md template and substitutes values based on current mode.
/// Returns an allocated prompt string that must be freed by the caller.
pub fn preparePrompt(cfg: config.Config, allocator: std.mem.Allocator, iteration: usize, experiment_branch: ?[]const u8) ![]u8 {
    const program_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.work_dir, cfg.program_file });
    defer allocator.free(program_path);

    const program_content = std.fs.cwd().readFileAlloc(allocator, program_path, 16 * 1024 * 1024) catch {
        return error.MissingProgramFile;
    };
    defer allocator.free(program_content);

    const goal = extractTemplateBlock(allocator, program_content, "GOAL") orelse return error.InvalidProgramTemplate;
    const constraints = extractTemplateBlock(allocator, program_content, "CONSTRAINTS") orelse return error.InvalidProgramTemplate;
    const criteria = extractTemplateBlock(allocator, program_content, "CRITERIA") orelse return error.InvalidProgramTemplate;

    const mode_template = if (experiment_branch != null)
        extractTemplateBlock(allocator, program_content, "MODE_A") orelse return error.InvalidProgramTemplate
    else
        extractTemplateBlock(allocator, program_content, "MODE_B") orelse return error.InvalidProgramTemplate;

    const mode_instructions = try renderModeInstructions(allocator, mode_template, cfg.main_branch);
    defer allocator.free(mode_instructions);

    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(allocator);

    try prompt.writer(allocator).print(
        "=== 系统消息 ===\n" ++
            "你是一个代码改进助手。这是第 {d} 次迭代。\n\n" ++
            "=== 当前状态 ===\n" ++
            "- 当前迭代: {d} / {d}\n",
        .{ iteration, iteration, cfg.iterations },
    );

    if (experiment_branch) |branch| {
        try prompt.writer(allocator).print("- 当前分支: {s}（需要评估）\n", .{branch});
        try prompt.appendSlice(allocator, "- 工作模式: EVALUATE_EXPERIMENT\n\n");
    } else {
        try prompt.writer(allocator).print("- 当前分支: {s}（需要开始新的实验）\n", .{cfg.main_branch});
        try prompt.appendSlice(allocator, "- 工作模式: CREATE_EXPERIMENT\n\n");
    }

    try appendSection(prompt.writer(allocator), "Goal", goal);
    try appendSection(prompt.writer(allocator), "重要约束", constraints);
    try appendSection(prompt.writer(allocator), "评估标准", criteria);

    try prompt.appendSlice(allocator, "=== 任务指令 ===\n");
    try prompt.appendSlice(allocator, mode_instructions);
    try prompt.appendSlice(allocator, "\n\n请直接执行 git 命令，不要只输出命令。\n");

    return prompt.toOwnedSlice(allocator);
}

/// Find a decision in the output text.
/// Looks for DECISION: KEEP, DECISION: DISCARD, or DECISION: EXPERIMENT_CREATED.
/// Returns the decision string or null if not found.
pub fn findDecision(text: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, text, "DECISION: KEEP") != null) return "DECISION: KEEP";
    if (std.mem.indexOf(u8, text, "DECISION: DISCARD") != null) return "DECISION: DISCARD";
    if (std.mem.indexOf(u8, text, "DECISION: EXPERIMENT_CREATED") != null) return "DECISION: EXPERIMENT_CREATED";
    return null;
}

/// Invoke OpenCode with the given prompt and iteration.
/// Logs output to a file and prints to console.
/// Returns true on success, false on failure.
pub fn invokeOpencode(cfg: config.Config, allocator: std.mem.Allocator, iteration: usize, prompt: []const u8) !bool {
    const log_name = try std.fmt.allocPrint(allocator, "iteration-{d}.log", .{iteration});
    defer allocator.free(log_name);

    const log_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.work_dir, cfg.log_dir });
    defer allocator.free(log_dir_path);
    try std.fs.cwd().makePath(log_dir_path);

    const log_file_path = try std.fs.path.join(allocator, &[_][]const u8{ log_dir_path, log_name });
    defer allocator.free(log_file_path);

    const current_branch = utils.runShellStdout(allocator, cfg.work_dir, "git branch --show-current") catch "unknown";
    defer if (!std.mem.eql(u8, current_branch, "unknown")) allocator.free(current_branch);

    ui.logInfo("第 {d} 次迭代：调用 OpenCode...", .{iteration});
    ui.logInfo("当前分支: {s}", .{current_branch});

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    const session_title = try std.fmt.allocPrint(allocator, "techlead-iter-{d}-{d}", .{ iteration, std.time.timestamp() });
    defer allocator.free(session_title);

    // 使用 oh-my-opencode run 替代 opencode run
    // oh-my-opencode run 不支持 --title 参数
    try argv.appendSlice(allocator, &[_][]const u8{ "oh-my-opencode", "run", "--attach", cfg.opencode_url, "--directory", cfg.work_dir, "--json" });

    if (cfg.model.len > 0) {
        try argv.append(allocator, "--model");
        try argv.append(allocator, cfg.model);
    }
    // 始终添加 agent 参数，为空时使用默认值
    const agent_name = if (cfg.agent.len > 0) cfg.agent else "Sisyphus";
    try argv.append(allocator, "--agent");
    // oh-my-opencode 使用首字母大写的 agent 名称
    const capitalized_agent = try capitalizeFirstLetter(allocator, agent_name);
    defer allocator.free(capitalized_agent);
    try argv.append(allocator, capitalized_agent);
    // prompt 必须放在最后
    try argv.append(allocator, prompt);

    ui.logInfo("执行: oh-my-opencode run --attach {s} --directory {s} --json", .{ cfg.opencode_url, cfg.work_dir });

    var log_file = try std.fs.cwd().createFile(log_file_path, .{ .truncate = true });
    defer log_file.close();

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe; // 修复：捕获 stderr
    child.cwd = cfg.work_dir;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    var merged: std.ArrayList(u8) = .empty;
    defer merged.deinit(allocator);

    // 创建线程读取 stderr 并写入日志
    const stderr_thread = try std.Thread.spawn(.{}, struct {
        fn readStderr(stderr: std.fs.File, log: std.fs.File, merge: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = try stderr.read(&buf);
                if (n == 0) break;
                try log.writeAll(buf[0..n]);
                try merge.appendSlice(alloc, buf[0..n]);
                std.debug.print("{s}", .{buf[0..n]});
            }
        }
    }.readStderr, .{ child.stderr.?, log_file, &merged, allocator });

    // 主线程读取 stdout
    var buf: [4096]u8 = undefined;
    const child_stdout = child.stdout orelse return error.CommandFailed;
    while (true) {
        const n = try child_stdout.read(&buf);
        if (n == 0) break;

        const chunk = buf[0..n];
        try log_file.writeAll(chunk);
        try merged.appendSlice(allocator, chunk);

        // Print directly to console (no JSON parsing)
        std.debug.print("{s}", .{chunk});
    }

    stderr_thread.join();

    const term = try child.wait();
    if (!utils.isExitedZero(term)) {
        ui.logError("调用 OpenCode 失败", .{});
        ui.logInfo("日志保存在: {s}", .{log_file_path});
        return false;
    }

    if (findDecision(merged.items)) |decision| {
        if (std.mem.eql(u8, decision, "DECISION: KEEP")) {
            ui.logSuccess("决策: 保留分支", .{});
        } else if (std.mem.eql(u8, decision, "DECISION: DISCARD")) {
            ui.logWarn("决策: 舍弃分支", .{});
        } else {
            ui.logSuccess("决策: 创建了新实验分支", .{});
        }
    } else {
        ui.logWarn("无法解析决策，请查看日志: {s}", .{log_file_path});
    }

    return true;
}
