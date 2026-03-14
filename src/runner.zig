const std = @import("std");

const utils = @import("utils.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");
const git = @import("git.zig");
const opencode = @import("opencode.zig");
const template = @import("template.zig");

const Allocator = std.mem.Allocator;

const TECHLEAD_DIR_NAME = ".techlead";
const CONFIG_REL_PATH = ".techlead/techlead.json";
const DEFAULT_PROGRAM_REL_PATH = ".techlead/program.md";

/// Validates the runtime environment for the run command.
pub fn validateRunEnvironment(cfg: config.Config, allocator: Allocator) !void {
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

/// Checks if OpenCode server is available.
pub fn checkOpencode(cfg: config.Config, allocator: Allocator) !void {
    ui.logInfo("检查 OpenCode server...", .{});
    if (!utils.checkHttpService(allocator, cfg.opencode_url)) {
        ui.logError("无法连接到 OpenCode server at {s}", .{cfg.opencode_url});
        ui.logInfo("请确保 OpenCode serve 正在运行: opencode serve", .{});
        return error.OpencodeUnavailable;
    }

    ui.logSuccess("OpenCode server 连接正常", .{});
    std.debug.print("\n", .{});
}

/// Runs the main iteration command.
pub fn runCommand(cfg: config.Config, allocator: Allocator) !void {
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

/// Runs the init command to set up a new project.
pub fn runInitCommand(allocator: Allocator, goal: []const u8, force: bool, target_dir: []const u8) !void {
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

    const program_template = try template.buildProgramTemplate(allocator, goal);
    defer allocator.free(program_template);

    try config.writeDefaultConfig(allocator, force, target_dir);
    try utils.writeFileWithPolicy(program_path, program_template, force);

    ui.logSuccess("初始化完成", .{});
    ui.logInfo("目标目录: {s}", .{target_dir});
    ui.logInfo("已生成: {s}", .{config_path});
    ui.logInfo("已生成: {s}", .{program_path});
    ui.logInfo("下一步执行: zig build run -- run --dir {s}", .{target_dir});
}
