const std = @import("std");

const utils = @import("utils.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");
const server = @import("server.zig");

const Allocator = std.mem.Allocator;

const TECHLEAD_DIR_NAME = ".techlead";
const CONFIG_FILE_NAME = "techlead.json";
const DEFAULT_PROGRAM_FILE = "program.md";
const CONFIG_REL_PATH = ".techlead/techlead.json";
const DEFAULT_PROGRAM_REL_PATH = ".techlead/program.md";
const DEFAULT_LOG_DIR = ".techlead/iteration-logs";
const DEFAULT_OPCENCODE_PORT = 4096;

fn capitalizeFirstLetter(allocator: Allocator, str: []const u8) ![]u8 {
    if (str.len == 0) return allocator.dupe(u8, str);

    var result = try allocator.alloc(u8, str.len);
    errdefer allocator.free(result);

    // 复制原字符串
    @memcpy(result, str);

    // 首字母大写
    result[0] = std.ascii.toUpper(result[0]);

    return result;
}

fn buildProgramTemplate(allocator: Allocator, goal: []const u8) ![]u8 {
    // Try to read local program.md file
    const max_file_size = 1024 * 1024; // 1MB max
    const local_template = std.fs.cwd().readFileAlloc(allocator, "program.md", max_file_size) catch |err| {
        // Fallback to hardcoded template if file doesn't exist or read fails
        std.log.warn("Failed to read local program.md ({}), using default template", .{err});
        return buildDefaultProgramTemplate(allocator, goal);
    };
    defer allocator.free(local_template);

    // Find the GOAL markers in the template
    const begin_marker = "<!-- TECHLEAD:GOAL:BEGIN -->";
    const end_marker = "<!-- TECHLEAD:GOAL:END -->";

    const begin_index = std.mem.indexOf(u8, local_template, begin_marker) orelse {
        // Fallback if markers not found
        std.log.warn("GOAL markers not found in local program.md, using default template", .{});
        return buildDefaultProgramTemplate(allocator, goal);
    };

    const begin_content = begin_index + begin_marker.len;
    const rest = local_template[begin_content..];
    const end_rel = std.mem.indexOf(u8, rest, end_marker) orelse {
        // Fallback if end marker not found
        std.log.warn("GOAL end marker not found in local program.md, using default template", .{});
        return buildDefaultProgramTemplate(allocator, goal);
    };

    // Build the new content: before marker + new goal + after marker
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    // Add content before the GOAL section (including the begin marker)
    try out.appendSlice(allocator, local_template[0..begin_content]);

    // Add newline and the new goal
    try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, goal);
    try out.appendSlice(allocator, "\n");

    // Add content from end marker onwards
    try out.appendSlice(allocator, rest[end_rel..]);

    return out.toOwnedSlice(allocator);
}

fn buildDefaultProgramTemplate(allocator: Allocator, goal: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "# program.md - Techlead Prompt Template\n\n");
    try out.appendSlice(allocator, "<!-- TECHLEAD:GOAL:BEGIN -->\n");
    try out.appendSlice(allocator, goal);
    try out.appendSlice(allocator, "\n<!-- TECHLEAD:GOAL:END -->\n\n");

    try out.appendSlice(allocator, "<!-- TECHLEAD:CONSTRAINTS:BEGIN -->\n");
    try out.appendSlice(
        allocator,
        "- 保持改动聚焦，不要一次改太多。\n" ++
            "- 优先保证可运行和可回滚。\n" ++
            "- 当不确定收益时，倾向舍弃。\n",
    );
    try out.appendSlice(allocator, "<!-- TECHLEAD:CONSTRAINTS:END -->\n\n");

    try out.appendSlice(allocator, "<!-- TECHLEAD:CRITERIA:BEGIN -->\n");
    try out.appendSlice(
        allocator,
        "- 是否更接近 Goal。\n" ++
            "- 代码可读性和复杂度是否更合理。\n" ++
            "- 若可验证，测试和性能是否改善。\n",
    );
    try out.appendSlice(allocator, "<!-- TECHLEAD:CRITERIA:END -->\n\n");

    try out.appendSlice(allocator, "<!-- TECHLEAD:MODE_A:BEGIN -->\n");
    try out.appendSlice(
        allocator,
        "当前处于评估模式（experiment 分支）。\n" ++
            "1. 查看差异：git diff <MAIN_BRANCH>..HEAD\n" ++
            "2. 依据 Goal/Criteria 评估收益。\n" ++
            "3. 若有收益：git checkout <MAIN_BRANCH> && git merge <分支名>，并输出 DECISION: KEEP\n" ++
            "4. 若无收益：git branch -D <分支名>，并输出 DECISION: DISCARD\n" ++
            "5. 简要说明理由。\n",
    );
    try out.appendSlice(allocator, "<!-- TECHLEAD:MODE_A:END -->\n\n");

    try out.appendSlice(allocator, "<!-- TECHLEAD:MODE_B:BEGIN -->\n");
    try out.appendSlice(
        allocator,
        "当前处于新实验模式（主分支）。\n" ++
            "1. 基于 Goal 提出一个可验证的小改进。\n" ++
            "2. 执行：git checkout <MAIN_BRANCH> && git checkout -b experiment-<描述>\n" ++
            "3. 实现改进并提交：git add . && git commit -m \"迭代X: 描述\"\n" ++
            "4. 输出 DECISION: EXPERIMENT_CREATED 与简要说明。\n" ++
            "5. 不要 merge 回主分支。\n",
    );
    try out.appendSlice(allocator, "<!-- TECHLEAD:MODE_B:END -->\n");

    return out.toOwnedSlice(allocator);
}

fn extractTemplateBlock(allocator: Allocator, content: []const u8, block_name: []const u8) ?[]const u8 {
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

fn appendSection(writer: anytype, title: []const u8, body: []const u8) !void {
    try writer.print("=== {s} ===\n{s}\n\n", .{ title, body });
}

fn valueAsString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn valueAsI64(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn appendToolDetail(msg_buf: *std.ArrayList(u8), allocator: Allocator, key: []const u8, raw_value: []const u8) !void {
    const value = std.mem.trim(u8, raw_value, " \t\r\n");
    if (value.len == 0) return;
    try msg_buf.writer(allocator).print(" | {s}: {s}", .{ key, ui.truncateForLog(value, 88) });
}

fn simplifyShellCommand(raw: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, raw, ';');
    var best = std.mem.trim(u8, raw, " \t\r\n");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len > 0) best = trimmed;
    }
    return best;
}

fn getCurrentExperimentBranch(cfg: config.Config, allocator: Allocator) ?[]u8 {
    const current = utils.runShellStdout(allocator, cfg.work_dir, "git branch --show-current") catch return null;
    if (std.mem.startsWith(u8, current, "experiment-")) {
        return current;
    }
    allocator.free(current);
    return null;
}

fn renderModeInstructions(allocator: Allocator, template_mode: []const u8, main_branch: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const replaced_1 = try std.mem.replaceOwned(u8, allocator, template_mode, "<MAIN_BRANCH>", main_branch);
    defer allocator.free(replaced_1);

    try out.appendSlice(allocator, replaced_1);
    return out.toOwnedSlice(allocator);
}

fn preparePrompt(cfg: config.Config, allocator: Allocator, iteration: usize, experiment_branch: ?[]const u8) ![]u8 {
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

fn findDecision(text: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, text, "DECISION: KEEP") != null) return "DECISION: KEEP";
    if (std.mem.indexOf(u8, text, "DECISION: DISCARD") != null) return "DECISION: DISCARD";
    if (std.mem.indexOf(u8, text, "DECISION: EXPERIMENT_CREATED") != null) return "DECISION: EXPERIMENT_CREATED";
    return null;
}

fn invokeOpencode(cfg: config.Config, allocator: Allocator, iteration: usize, prompt: []const u8) !bool {
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
    if (cfg.agent.len > 0) {
        try argv.append(allocator, "--agent");
        // oh-my-opencode 使用首字母大写的 agent 名称
        const capitalized_agent = try capitalizeFirstLetter(allocator, cfg.agent);
        defer allocator.free(capitalized_agent);
        try argv.append(allocator, capitalized_agent);
    }
    // prompt 必须放在最后
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

    var merged: std.ArrayList(u8) = .empty;
    defer merged.deinit(allocator);

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

fn cleanupOldBranches(cfg: config.Config, allocator: Allocator) void {
    const output = utils.runShellStdout(allocator, cfg.work_dir, "git branch --list 'experiment-*'") catch return;
    defer allocator.free(output);

    var branches: std.ArrayList([]const u8) = .empty;
    defer {
        for (branches.items) |item| allocator.free(item);
        branches.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n*");
        if (trimmed.len == 0) continue;
        const owned = allocator.dupe(u8, trimmed) catch continue;
        branches.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }

    if (branches.items.len <= cfg.max_branches) return;

    ui.logWarn("experiment 分支数量 ({d}) 超过限制 ({d})", .{ branches.items.len, cfg.max_branches });
    ui.logInfo("清理旧分支...", .{});

    const to_delete = branches.items.len - cfg.max_branches;
    var i: usize = 0;
    while (i < to_delete) : (i += 1) {
        const cmd = std.fmt.allocPrint(allocator, "git branch -D {s}", .{branches.items[i]}) catch continue;
        defer allocator.free(cmd);

        const result = utils.runShellCapture(allocator, cfg.work_dir, cmd) catch {
            ui.logWarn("无法删除分支 {s}", .{branches.items[i]});
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (utils.isExitedZero(result.term)) {
            ui.logInfo("已删除分支: {s}", .{branches.items[i]});
        } else {
            ui.logWarn("无法删除分支 {s}", .{branches.items[i]});
        }
    }
}

fn verifyGitRepo(cwd: []const u8, allocator: Allocator) !void {
    const git_check = utils.runShellCapture(allocator, cwd, "git rev-parse --git-dir") catch {
        return error.NotGitRepo;
    };
    defer allocator.free(git_check.stdout);
    defer allocator.free(git_check.stderr);

    if (!utils.isExitedZero(git_check.term)) {
        return error.NotGitRepo;
    }
}

fn validateRunEnvironment(cfg: config.Config, allocator: Allocator) !void {
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

    try verifyGitRepo(cfg.work_dir, allocator);
    ui.logSuccess("环境检查通过", .{});
    std.debug.print("\n", .{});
}

fn checkOpencode(cfg: config.Config, allocator: Allocator) !void {
    ui.logInfo("检查 OpenCode server...", .{});
    if (!utils.checkHttpService(allocator, cfg.opencode_url)) {
        ui.logError("无法连接到 OpenCode server at {s}", .{cfg.opencode_url});
        ui.logInfo("请确保 OpenCode serve 正在运行: opencode serve", .{});
        return error.OpencodeUnavailable;
    }

    ui.logSuccess("OpenCode server 连接正常", .{});
    std.debug.print("\n", .{});
}

fn runCommand(cfg: config.Config, allocator: Allocator) !void {
    if (!utils.commandExists(allocator, "opencode")) {
        ui.logError("找不到 opencode CLI，请确保已安装", .{});
        return error.MissingOpencode;
    }

    try validateRunEnvironment(cfg, allocator);
    try checkOpencode(cfg, allocator);

    var i: usize = 1;
    while (i <= cfg.iterations) : (i += 1) {
        std.debug.print("========================================\n", .{});
        ui.logInfo("第 {d} / {d} 次迭代", .{ i, cfg.iterations });
        std.debug.print("========================================\n\n", .{});

        const experiment_branch = getCurrentExperimentBranch(cfg, allocator);
        defer if (experiment_branch) |b| allocator.free(b);

        const prompt = try preparePrompt(cfg, allocator, i, experiment_branch);
        defer allocator.free(prompt);

        const success = try invokeOpencode(cfg, allocator, i, prompt);
        if (!success) {
            ui.logError("第 {d} 次迭代失败，跳过...", .{i});
            continue;
        }

        cleanupOldBranches(cfg, allocator);

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

fn runInitCommand(allocator: Allocator, goal: []const u8, force: bool, target_dir: []const u8) !void {
    try verifyGitRepo(target_dir, allocator);

    const techlead_dir = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, TECHLEAD_DIR_NAME });
    defer allocator.free(techlead_dir);
    try std.fs.cwd().makePath(techlead_dir);

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, CONFIG_REL_PATH });
    defer allocator.free(config_path);
    const program_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, DEFAULT_PROGRAM_REL_PATH });
    defer allocator.free(program_path);

    if (!force) {
        if (utils.fileExists(config_path)) {
            ui.logError("{s} 已存在，使用 --force 覆盖", .{config_path});
            return error.FileAlreadyExists;
        }
        if (utils.fileExists(program_path)) {
            ui.logError("{s} 已存在，使用 --force 覆盖", .{program_path});
            return error.FileAlreadyExists;
        }
    }

    const template = try buildProgramTemplate(allocator, goal);
    defer allocator.free(template);

    try config.writeDefaultConfig(allocator, force, target_dir);
    try utils.writeFileWithPolicy(program_path, template, force);

    ui.logSuccess("初始化完成", .{});
    ui.logInfo("目标目录: {s}", .{target_dir});
    ui.logInfo("已生成: {s}", .{config_path});
    ui.logInfo("已生成: {s}", .{program_path});
    ui.logInfo("下一步执行: zig build run -- run --dir {s}", .{target_dir});
}

fn parseInitGoalAndForce(allocator: Allocator, args: []const []const u8) !struct { goal: []u8, force: bool } {
    var force = false;
    var goal_parts: std.ArrayList(u8) = .empty;
    defer goal_parts.deinit(allocator);

    var has_goal_token = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
            continue;
        }

        if (arg.len > 0 and arg[0] == '-') {
            return error.InvalidInitArguments;
        }

        if (has_goal_token) try goal_parts.append(allocator, ' ');
        try goal_parts.appendSlice(allocator, arg);
        has_goal_token = true;
    }

    if (!has_goal_token) {
        return error.MissingGoal;
    }

    return .{ .goal = try goal_parts.toOwnedSlice(allocator), .force = force };
}

fn showHelp() void {
    std.debug.print(
        "\nTechlead 持续迭代 CLI (Zig)\n\n" ++
            "用法:\n" ++
            "    zig build run -- init [--dir 目录] \"你的目标描述\" [--force]\n" ++
            "    zig build run -- run [--dir 目录]\n" ++
            "    zig build run -- server start [--daemon]\n" ++
            "    zig build run -- server stop\n\n" ++
            "说明:\n" ++
            "    - init: 在目标目录生成 .techlead/techlead.json 和 .techlead/program.md（默认当前目录）\n" ++
            "    - run: 从目标目录读取 .techlead/techlead.json 并执行迭代（默认当前目录）\n" ++
            "    - server start: 在前台启动 opencode serve 服务\n" ++
            "    - server start --daemon: 在后台启动 opencode serve 服务\n" ++
            "    - server stop: 停止 opencode serve 服务（发送 SIGTERM，超时后发送 SIGKILL）\n" ++
            "\n" ++
            "文件位置:\n" ++
            "    - PID 文件: ~/.config/techlead/server.pid\n" ++
            "    - 日志文件: ~/.config/techlead/server.log\n" ++
            "\n" ++
            "    - run 阶段只读取 JSON 配置，不读取环境变量\n\n",
        .{},
    );
}

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa_impl.deinit();
        if (leaked == .leak) {
            std.debug.print("warning: memory leak detected\n", .{});
        }
    }

    const allocator = gpa_impl.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        showHelp();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        showHelp();
        return;
    }

    if (std.mem.eql(u8, command, "init")) {
        var target_dir: []const u8 = ".";
        var init_args = args[2..];
        if (init_args.len >= 2 and std.mem.eql(u8, init_args[0], "--dir")) {
            target_dir = init_args[1];
            init_args = init_args[2..];
        }

        const parsed = parseInitGoalAndForce(allocator, init_args) catch |err| {
            switch (err) {
                error.MissingGoal => ui.logError("init 需要 Goal 参数", .{}),
                error.InvalidInitArguments => ui.logError("init 参数无效，只支持 --force（以及命令后的可选 --dir 目录）", .{}),
                else => ui.logError("无法解析 init 参数", .{}),
            }
            showHelp();
            return;
        };
        defer allocator.free(parsed.goal);

        runInitCommand(allocator, parsed.goal, parsed.force, target_dir) catch |err| {
            switch (err) {
                error.NotGitRepo => ui.logError("目标目录不是 git 仓库: {s}", .{target_dir}),
                error.FileAlreadyExists => {},
                else => ui.logError("init 执行失败: {any}", .{err}),
            }
            return;
        };
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        var target_dir: []const u8 = ".";
        var run_args = args[2..];
        if (run_args.len >= 2 and std.mem.eql(u8, run_args[0], "--dir")) {
            target_dir = run_args[1];
            run_args = run_args[2..];
        }
        if (run_args.len > 0) {
            ui.logError("run 参数无效，仅支持可选 --dir 目录", .{});
            showHelp();
            return;
        }

        const cfg = config.loadConfigFromJson(allocator, target_dir) catch |err| {
            switch (err) {
                error.ConfigFileNotFound => ui.logError("找不到 {s}，请先执行 init", .{CONFIG_REL_PATH}),
                error.ConfigParseFailed => ui.logError("{s} 解析失败，请检查 JSON 格式", .{CONFIG_REL_PATH}),
                error.InvalidConfig => ui.logError("{s} 字段无效或缺失", .{CONFIG_REL_PATH}),
                else => ui.logError("读取配置失败: {any}", .{err}),
            }
            return;
        };
        defer config.deinitConfig(allocator, &cfg);

        std.debug.print("========================================\n", .{});
        std.debug.print("  Techlead 持续迭代系统\n", .{});
        std.debug.print("========================================\n\n", .{});
        ui.logInfo("配置:", .{});
        ui.logInfo("  - 配置文件: {s}", .{CONFIG_REL_PATH});
        ui.logInfo("  - 迭代次数: {d}", .{cfg.iterations});
        ui.logInfo("  - Program 文件: {s}", .{cfg.program_file});
        ui.logInfo("  - OpenCode URL: {s}", .{cfg.opencode_url});
        ui.logInfo("  - 主分支: {s}", .{cfg.main_branch});
        ui.logInfo("  - 日志目录: {s}", .{cfg.log_dir});
        if (cfg.model.len > 0) {
            ui.logInfo("  - 模型: {s}", .{cfg.model});
        }
        std.debug.print("\n", .{});

        runCommand(cfg, allocator) catch |err| {
            switch (err) {
                error.MissingProgramFile => ui.logError(".techlead/program.md 缺失，请重新执行 init --force", .{}),
                error.InvalidProgramTemplate => ui.logError(".techlead/program.md 模板块缺失，请重新执行 init --force", .{}),
                error.NotGitRepo => ui.logError("work_dir 不是 git 仓库", .{}),
                error.OpencodeUnavailable => {},
                error.MissingOpencode => {},
                else => ui.logError("run 失败: {any}", .{err}),
            }
            return;
        };
        return;
    }

    if (std.mem.eql(u8, command, "server")) {
        if (args.len < 3) {
            ui.logError("server 需要子命令: start, stop", .{});
            showHelp();
            return;
        }
        const subcommand = args[2];

        if (std.mem.eql(u8, subcommand, "start")) {
            // Parse optional --daemon flag
            var daemon_mode = false;
            for (args[3..]) |arg| {
                if (std.mem.eql(u8, arg, "--daemon")) {
                    daemon_mode = true;
                    break;
                }
            }

            server.runServerStartCommand(allocator, daemon_mode) catch |err| {
                switch (err) {
                    error.ServerAlreadyRunning => ui.logError("服务已在运行", .{}),
                    error.ServerStartFailed => ui.logError("启动服务失败", .{}),
                    error.MissingOpencode => ui.logError("找不到 opencode CLI，请确保已安装", .{}),
                    else => ui.logError("启动服务失败: {any}", .{err}),
                }
            };
            return;
        }

        if (std.mem.eql(u8, subcommand, "stop")) {
            server.runServerStopCommand(allocator) catch |err| {
                switch (err) {
                    error.ServerNotRunning => ui.logError("服务未运行", .{}),
                    error.ServerStopFailed => ui.logError("停止服务失败", .{}),
                    else => ui.logError("停止服务失败: {any}", .{err}),
                }
            };
            return;
        }

        ui.logError("未知的 server 子命令: {s}", .{subcommand});
        showHelp();
        return;
    }

    ui.logError("未知命令: {s}", .{command});
    showHelp();
}
