const std = @import("std");

const utils = @import("utils.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");
const server = @import("server.zig");
const git = @import("git.zig");
const opencode = @import("opencode.zig");

const Allocator = std.mem.Allocator;

const TECHLEAD_DIR_NAME = ".techlead";
const CONFIG_FILE_NAME = "techlead.json";
const DEFAULT_PROGRAM_FILE = "program.md";
const CONFIG_REL_PATH = ".techlead/techlead.json";
const DEFAULT_PROGRAM_REL_PATH = ".techlead/program.md";
const DEFAULT_LOG_DIR = ".techlead/iteration-logs";
const DEFAULT_OPCENCODE_PORT = 4096;

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

    try git.verifyGitRepo(cfg.work_dir, allocator);
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

        const experiment_branch = git.getCurrentExperimentBranch(cfg, allocator);
        defer if (experiment_branch) |b| allocator.free(b);

        const prompt = try opencode.preparePrompt(cfg, allocator, i, experiment_branch);
        defer allocator.free(prompt);

        const success = try opencode.invokeOpencode(cfg, allocator, i, prompt);
        if (!success) {
            ui.logError("第 {d} 次迭代失败，跳过...", .{i});
            continue;
        }

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
    try git.verifyGitRepo(target_dir, allocator);

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
