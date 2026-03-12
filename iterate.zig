const std = @import("std");

const Allocator = std.mem.Allocator;

const Colors = struct {
    const red = "\x1b[0;31m";
    const green = "\x1b[0;32m";
    const yellow = "\x1b[1;33m";
    const blue = "\x1b[0;34m";
    const nc = "\x1b[0m";
};

const Config = struct {
    iterations: usize,
    program_file: []const u8,
    opencode_url: []const u8,
    work_dir: []const u8,
    log_dir: []const u8,
    model: []const u8,
    max_branches: usize,
};

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[INFO]{s} " ++ fmt ++ "\n", .{ Colors.blue, Colors.nc } ++ args);
}

fn logSuccess(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[SUCCESS]{s} " ++ fmt ++ "\n", .{ Colors.green, Colors.nc } ++ args);
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[WARN]{s} " ++ fmt ++ "\n", .{ Colors.yellow, Colors.nc } ++ args);
}

fn logError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[ERROR]{s} " ++ fmt ++ "\n", .{ Colors.red, Colors.nc } ++ args);
}

fn parseUsizeOrDefault(value: ?[]const u8, default_value: usize) usize {
    if (value) |v| {
        return std.fmt.parseInt(usize, v, 10) catch default_value;
    }
    return default_value;
}

fn envOrDefault(name: []const u8, default_value: []const u8) []const u8 {
    return std.process.getEnvVarOwned(std.heap.page_allocator, name) catch default_value;
}

fn runCommandCapture(allocator: Allocator, cwd: ?[]const u8, argv: []const []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 64 * 1024 * 1024,
    });
}

fn runShellCapture(allocator: Allocator, cwd: ?[]const u8, cmd: []const u8) !std.process.Child.RunResult {
    const argv = [_][]const u8{ "/bin/sh", "-lc", cmd };
    return runCommandCapture(allocator, cwd, &argv);
}

fn isExitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn commandExists(allocator: Allocator, cmd: []const u8) bool {
    const shell_cmd = std.fmt.allocPrint(allocator, "which {s} >/dev/null 2>&1", .{cmd}) catch return false;
    defer allocator.free(shell_cmd);

    const result = runShellCapture(allocator, null, shell_cmd) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return isExitedZero(result.term);
}

fn checkHttpService(allocator: Allocator, url: []const u8) bool {
    const shell_cmd = std.fmt.allocPrint(allocator, "curl -fsSI {s} >/dev/null 2>&1", .{url}) catch return false;
    defer allocator.free(shell_cmd);

    const result = runShellCapture(allocator, null, shell_cmd) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return isExitedZero(result.term);
}

fn runShellStdout(allocator: Allocator, cwd: ?[]const u8, cmd: []const u8) ![]u8 {
    const result = try runShellCapture(allocator, cwd, cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!isExitedZero(result.term)) {
        if (result.stderr.len > 0) {
            std.debug.print("{s}\n", .{result.stderr});
        }
        return error.CommandFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn init(config: Config, allocator: Allocator) !void {
    logInfo("初始化迭代环境...", .{});
    const abs_work_dir = try std.fs.cwd().realpathAlloc(allocator, config.work_dir);
    defer allocator.free(abs_work_dir);
    logInfo("工作目录: {s}", .{abs_work_dir});

    const program_path = try std.fs.path.join(allocator, &[_][]const u8{ config.work_dir, config.program_file });
    defer allocator.free(program_path);

    std.fs.cwd().access(program_path, .{}) catch {
        logError("找不到 {s}", .{program_path});
        return error.MissingProgramFile;
    };

    const abs_program_path = try std.fs.cwd().realpathAlloc(allocator, program_path);
    defer allocator.free(abs_program_path);
    logInfo("Program 文件: {s}", .{abs_program_path});

    const log_path = try std.fs.path.join(allocator, &[_][]const u8{ config.work_dir, config.log_dir });
    defer allocator.free(log_path);
    try std.fs.cwd().makePath(log_path);

    const git_check = runShellCapture(allocator, config.work_dir, "git rev-parse --git-dir") catch {
        logError("当前目录不是 git 仓库", .{});
        return error.NotGitRepo;
    };
    defer allocator.free(git_check.stdout);
    defer allocator.free(git_check.stderr);

    if (!isExitedZero(git_check.term)) {
        logError("当前目录不是 git 仓库", .{});
        return error.NotGitRepo;
    }

    logInfo("Git 仓库检查通过", .{});
    logSuccess("初始化完成", .{});
    std.debug.print("\n", .{});
}

fn checkOpencode(config: Config, allocator: Allocator) !void {
    logInfo("检查 OpenCode server...", .{});
    if (!checkHttpService(allocator, config.opencode_url)) {
        logError("无法连接到 OpenCode server at {s}", .{config.opencode_url});
        logInfo("请确保 OpenCode serve 正在运行:", .{});
        logInfo("  opencode serve", .{});
        logInfo("或者指定其他地址:", .{});
        logInfo("  OPENCODE_URL=http://localhost:8080 zig run iterate.zig", .{});
        return error.OpencodeUnavailable;
    }

    logSuccess("OpenCode server 连接正常", .{});
    std.debug.print("\n", .{});
}

fn getCurrentExperimentBranch(config: Config, allocator: Allocator) ?[]u8 {
    const current = runShellStdout(allocator, config.work_dir, "git branch --show-current") catch return null;
    if (std.mem.startsWith(u8, current, "experiment-")) {
        return current;
    }
    allocator.free(current);
    return null;
}

fn preparePrompt(config: Config, allocator: Allocator, iteration: usize, experiment_branch: ?[]const u8) ![]u8 {
    const program_path = try std.fs.path.join(allocator, &[_][]const u8{ config.work_dir, config.program_file });
    defer allocator.free(program_path);

    const program_content = try std.fs.cwd().readFileAlloc(allocator, program_path, 16 * 1024 * 1024);
    defer allocator.free(program_content);

    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(allocator);

    try prompt.writer(allocator).print(
        "=== 系统消息 ===\n" ++
            "你是一个代码改进助手。这是第 {d} 次迭代。\n\n" ++
            "=== 当前状态 ===\n" ++
            "- 当前迭代: {d} / {d}\n",
        .{ iteration, iteration, config.iterations },
    );

    if (experiment_branch) |branch| {
        try prompt.writer(allocator).print("- 当前分支: {s}（需要评估）\n", .{branch});
        try prompt.appendSlice(allocator, "- 需要评估这个分支的工作是否值得保留\n");
    } else {
        try prompt.appendSlice(allocator, "- 当前分支: develop（需要开始新的实验）\n");
        try prompt.appendSlice(allocator, "- 需要创建新的 experiment-* 分支进行改进\n");
    }

    try prompt.appendSlice(
        allocator,
        "\n=== program.md 内容 ===\n",
    );
    try prompt.appendSlice(allocator, program_content);
    try prompt.appendSlice(allocator, "\n\n=== 任务指令 ===\n");

    if (experiment_branch != null) {
        try prompt.appendSlice(
            allocator,
            "\n当前有一个 experiment 分支需要评估。\n\n" ++
                "请执行以下操作：\n" ++
                "1. 查看当前分支的改动: git diff develop..HEAD\n" ++
                "2. 根据 program.md 中的评估标准判断这个改动是否有帮助\n" ++
                "3. 做出决策并执行：\n" ++
                "   - 如果有帮助：执行 `git checkout develop && git merge <分支名>`，然后输出 \"DECISION: KEEP\"\n" ++
                "   - 如果没帮助：执行 `git branch -D <分支名>`，然后输出 \"DECISION: DISCARD\"\n" ++
                "4. 简要说明你的判断理由\n\n" ++
                "请直接执行 git 命令，不要只输出命令。\n",
        );
    } else {
        try prompt.appendSlice(
            allocator,
            "\n当前在 develop 分支，需要开始新的实验。\n\n" ++
                "请执行以下操作：\n" ++
                "1. 根据 program.md 中的 Goal 和已有工作，提出一个改进想法\n" ++
                "2. 创建一个描述性的分支名（如 experiment-optimize-memory）\n" ++
                "3. 执行: `git checkout -b experiment-{你的描述}`\n" ++
                "4. 实现你的改进想法（编辑代码、添加功能、优化性能等）\n" ++
                "5. 执行: `git add . && git commit -m \"迭代X: 你的描述\"`\n" ++
                "6. 输出 \"DECISION: EXPERIMENT_CREATED\" 和简要的改进说明\n\n" ++
                "注意：不要 merge 到 develop，只 commit 到当前分支。\n",
        );
    }

    return prompt.toOwnedSlice(allocator);
}

fn findDecision(text: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, text, "DECISION: KEEP") != null) return "DECISION: KEEP";
    if (std.mem.indexOf(u8, text, "DECISION: DISCARD") != null) return "DECISION: DISCARD";
    if (std.mem.indexOf(u8, text, "DECISION: EXPERIMENT_CREATED") != null) return "DECISION: EXPERIMENT_CREATED";
    return null;
}

fn invokeOpencode(config: Config, allocator: Allocator, iteration: usize, prompt: []const u8) !bool {
    const log_name = try std.fmt.allocPrint(allocator, "iteration-{d}.log", .{iteration});
    defer allocator.free(log_name);

    const log_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ config.work_dir, config.log_dir });
    defer allocator.free(log_dir_path);
    try std.fs.cwd().makePath(log_dir_path);

    const log_file_path = try std.fs.path.join(allocator, &[_][]const u8{ log_dir_path, log_name });
    defer allocator.free(log_file_path);

    const current_branch = runShellStdout(allocator, config.work_dir, "git branch --show-current") catch "unknown";
    defer if (!std.mem.eql(u8, current_branch, "unknown")) allocator.free(current_branch);

    logInfo("第 {d} 次迭代：调用 OpenCode...", .{iteration});
    logInfo("当前分支: {s}", .{current_branch});

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &[_][]const u8{ "opencode", "run", "--attach", config.opencode_url });
    if (config.model.len > 0) {
        try argv.append(allocator, "--model");
        try argv.append(allocator, config.model);
    }
    try argv.append(allocator, prompt);

    logInfo("执行: opencode run --attach {s}", .{config.opencode_url});

    const result = try runCommandCapture(allocator, config.work_dir, argv.items);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var log_file = try std.fs.cwd().createFile(log_file_path, .{ .truncate = true });
    defer log_file.close();

    if (result.stdout.len > 0) {
        std.debug.print("{s}", .{result.stdout});
        try log_file.writeAll(result.stdout);
    }

    if (result.stderr.len > 0) {
        std.debug.print("{s}", .{result.stderr});
        try log_file.writeAll(result.stderr);
    }

    if (!isExitedZero(result.term)) {
        logError("调用 OpenCode 失败", .{});
        logInfo("日志保存在: {s}", .{log_file_path});
        return false;
    }

    var merged: std.ArrayList(u8) = .empty;
    defer merged.deinit(allocator);
    try merged.appendSlice(allocator, result.stdout);
    try merged.appendSlice(allocator, result.stderr);

    if (findDecision(merged.items)) |decision| {
        if (std.mem.eql(u8, decision, "DECISION: KEEP")) {
            logSuccess("决策: 保留分支", .{});
        } else if (std.mem.eql(u8, decision, "DECISION: DISCARD")) {
            logWarn("决策: 舍弃分支", .{});
        } else {
            logSuccess("决策: 创建了新实验分支", .{});
        }
    } else {
        logWarn("无法解析决策，请查看日志: {s}", .{log_file_path});
    }

    return true;
}

fn cleanupOldBranches(config: Config, allocator: Allocator) void {
    const output = runShellStdout(allocator, config.work_dir, "git branch --list 'experiment-*'") catch return;
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

    if (branches.items.len <= config.max_branches) return;

    logWarn("experiment 分支数量 ({d}) 超过限制 ({d})", .{ branches.items.len, config.max_branches });
    logInfo("清理旧分支...", .{});

    const to_delete = branches.items.len - config.max_branches;
    var i: usize = 0;
    while (i < to_delete) : (i += 1) {
        const cmd = std.fmt.allocPrint(allocator, "git branch -D {s}", .{branches.items[i]}) catch continue;
        defer allocator.free(cmd);

        const result = runShellCapture(allocator, config.work_dir, cmd) catch {
            logWarn("无法删除分支 {s}", .{branches.items[i]});
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (isExitedZero(result.term)) {
            logInfo("已删除分支: {s}", .{branches.items[i]});
        } else {
            logWarn("无法删除分支 {s}", .{branches.items[i]});
        }
    }
}

fn showHelp() void {
    std.debug.print(
        "\nOpenCode 持续迭代控制脚本 (Zig 版本)\n\n" ++
            "用法:\n" ++
            "    zig run iterate.zig -- [迭代次数]\n\n" ++
            "环境变量:\n" ++
            "    ITERATIONS      默认迭代次数 (默认: 20)\n" ++
            "    PROGRAM_FILE    program.md 文件路径 (默认: ./program.md)\n" ++
            "    OPENCODE_URL    OpenCode server URL (默认: http://localhost:4096)\n" ++
            "    WORK_DIR        工作目录 (默认: 当前目录)\n" ++
            "    LOG_DIR         日志目录 (默认: ./.iteration-logs)\n" ++
            "    MODEL           模型选择 (可选)\n" ++
            "    MAX_BRANCHES    最大保留分支数 (默认: 10)\n\n" ++
            "示例:\n" ++
            "    zig run iterate.zig\n" ++
            "    zig run iterate.zig -- 50\n\n",
        .{},
    );
}

fn buildConfig(allocator: Allocator, arg_iter: ?[]const u8) Config {
    const iterations = if (arg_iter) |arg| parseUsizeOrDefault(arg, parseUsizeOrDefault(std.process.getEnvVarOwned(allocator, "ITERATIONS") catch null, 20)) else parseUsizeOrDefault(std.process.getEnvVarOwned(allocator, "ITERATIONS") catch null, 20);

    const max_branches = parseUsizeOrDefault(std.process.getEnvVarOwned(allocator, "MAX_BRANCHES") catch null, 10);

    return .{
        .iterations = iterations,
        .program_file = envOrDefault("PROGRAM_FILE", "./program.md"),
        .opencode_url = envOrDefault("OPENCODE_URL", "http://localhost:4096"),
        .work_dir = envOrDefault("WORK_DIR", "."),
        .log_dir = envOrDefault("LOG_DIR", "./.iteration-logs"),
        .model = envOrDefault("MODEL", ""),
        .max_branches = max_branches,
    };
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

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            showHelp();
            return;
        }
    }

    const iter_arg = if (args.len > 1) args[1] else null;
    const config = buildConfig(allocator, iter_arg);

    std.debug.print("========================================\n", .{});
    std.debug.print("  OpenCode 持续迭代系统 (Zig)\n", .{});
    std.debug.print("========================================\n\n", .{});
    logInfo("配置:", .{});
    logInfo("  - 迭代次数: {d}", .{config.iterations});
    logInfo("  - Program 文件: {s}", .{config.program_file});
    logInfo("  - OpenCode URL: {s}", .{config.opencode_url});
    logInfo("  - 日志目录: {s}", .{config.log_dir});
    if (config.model.len > 0) {
        logInfo("  - 模型: {s}", .{config.model});
    }
    std.debug.print("\n", .{});

    if (!commandExists(allocator, "opencode")) {
        logError("找不到 opencode CLI，请确保已安装", .{});
        return error.MissingOpencode;
    }

    try init(config, allocator);
    try checkOpencode(config, allocator);

    var i: usize = 1;
    while (i <= config.iterations) : (i += 1) {
        std.debug.print("========================================\n", .{});
        logInfo("第 {d} / {d} 次迭代", .{ i, config.iterations });
        std.debug.print("========================================\n\n", .{});

        const experiment_branch = getCurrentExperimentBranch(config, allocator);
        defer if (experiment_branch) |b| allocator.free(b);

        const prompt = try preparePrompt(config, allocator, i, experiment_branch);
        defer allocator.free(prompt);

        const success = try invokeOpencode(config, allocator, i, prompt);
        if (!success) {
            logError("第 {d} 次迭代失败，跳过...", .{i});
            continue;
        }

        cleanupOldBranches(config, allocator);

        std.debug.print("\n", .{});
        logInfo("当前 git 状态:", .{});
        const branch_output = runShellStdout(allocator, config.work_dir, "git branch -v") catch {
            std.debug.print("\n", .{});
            if (i < config.iterations) {
                logInfo("等待 2 秒后开始下一次迭代...", .{});
                std.Thread.sleep(2 * std.time.ns_per_s);
            }
            std.debug.print("\n", .{});
            continue;
        };
        defer allocator.free(branch_output);

        var bit = std.mem.splitScalar(u8, branch_output, '\n');
        while (bit.next()) |line| {
            if (std.mem.indexOf(u8, line, "develop") != null or std.mem.indexOf(u8, line, "experiment-") != null) {
                std.debug.print("{s}\n", .{line});
            }
        }
        std.debug.print("\n", .{});

        if (i < config.iterations) {
            logInfo("等待 2 秒后开始下一次迭代...", .{});
            std.Thread.sleep(2 * std.time.ns_per_s);
        }

        std.debug.print("\n", .{});
    }

    std.debug.print("========================================\n", .{});
    logSuccess("迭代完成！", .{});
    std.debug.print("========================================\n\n", .{});
    logInfo("总结:", .{});
    logInfo("  - 总迭代次数: {d}", .{config.iterations});
    logInfo("  - 日志目录: {s}", .{config.log_dir});

    const current_branch = runShellStdout(allocator, config.work_dir, "git branch --show-current") catch "unknown";
    defer if (!std.mem.eql(u8, current_branch, "unknown")) allocator.free(current_branch);
    logInfo("  - 当前分支: {s}", .{current_branch});
    std.debug.print("\n", .{});

    logInfo("保留的 experiment 分支:", .{});
    const experiment_branches = runShellStdout(allocator, config.work_dir, "git branch -v | grep experiment- || true") catch "";
    defer if (experiment_branches.len > 0) allocator.free(experiment_branches);

    if (experiment_branches.len > 0) {
        std.debug.print("{s}\n", .{experiment_branches});
    } else {
        logInfo("  无", .{});
    }
    std.debug.print("\n", .{});
    logInfo("你可以手动评估这些分支，决定最终保留哪些改进。", .{});
}
