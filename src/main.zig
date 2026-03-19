const std = @import("std");
const utils = @import("utils.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");
const server = @import("server.zig");
const runner = @import("runner.zig");

const Allocator = std.mem.Allocator;
const CONFIG_REL_PATH = ".techlead/techlead.json";

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
        if (arg.len > 0 and arg[0] == '-') return error.InvalidInitArguments;
        if (has_goal_token) try goal_parts.append(allocator, ' ');
        try goal_parts.appendSlice(allocator, arg);
        has_goal_token = true;
    }
    if (!has_goal_token) return error.MissingGoal;
    return .{ .goal = try goal_parts.toOwnedSlice(allocator), .force = force };
}

fn showHelp() void {
    std.debug.print(
        "\nTechlead 持续迭代 CLI (Zig)\n\n" ++
            "用法:\n" ++
            "    zig build run -- init [--dir 目录] \"你的目标描述\" [--force]\n" ++
            "    zig build run -- init-agent \"目标描述\" [--dir 目录]\n" ++
            "    zig build run -- run [--dir 目录]\n" ++
            "    zig build run -- server start [--daemon]\n" ++
            "    zig build run -- server stop\n\n" ++
            "说明:\n" ++
            "    - init: 在目标目录生成 .techlead/techlead.json 和 .techlead/program.md\n" ++
            "    - init-agent: 创建目标目录下的 sisyphus 代理项目\n" ++
            "    - run: 从目标目录读取配置并执行迭代\n" ++
            "    - server start: 在前台启动 opencode serve 服务\n" ++
            "    - server start --daemon: 在后台启动 opencode serve 服务\n" ++
            "    - server stop: 停止 opencode serve 服务\n\n" ++
            "文件位置:\n" ++
            "    - PID 文件: ~/.config/techlead/server.pid\n" ++
            "    - 日志文件: ~/.config/techlead/server.log\n\n",
        .{},
    );
}

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa_impl.deinit();
        if (leaked == .leak) std.debug.print("warning: memory leak detected\n", .{});
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
                error.InvalidInitArguments => ui.logError("init 参数无效，只支持 --force", .{}),
                else => ui.logError("无法解析 init 参数", .{}),
            }
            showHelp();
            return;
        };
        defer allocator.free(parsed.goal);
        runner.runInitCommand(allocator, parsed.goal, parsed.force, target_dir) catch |err| {
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
        if (cfg.model.len > 0) ui.logInfo("  - 模型: {s}", .{cfg.model});
        std.debug.print("\n", .{});
        runner.runCommand(cfg, allocator) catch |err| {
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

    if (std.mem.eql(u8, command, "init-agent")) {
        runner.runInitAgentCommand(allocator, args[2..]) catch |err| {
            switch (err) {
                error.MissingGoal => {
                    ui.logError("缺少目标参数", .{});
                    std.process.exit(1);
                },
                error.InvalidPath => {
                    ui.logError("无效的路径参数", .{});
                    std.process.exit(1);
                },
                error.PathNotAccessible => {
                    ui.logError("路径无法访问", .{});
                    std.process.exit(1);
                },
                error.GitRepoRequired => {
                    ui.logError("目标目录必须是 git 仓库", .{});
                    std.process.exit(1);
                },
                error.OutOfMemory => {
                    ui.logError("内存不足", .{});
                    std.process.exit(1);
                },
                error.MarkerNotFound => {
                    ui.logError("模板标记未找到", .{});
                    std.process.exit(1);
                },
            }
        };
        return;
    }

    ui.logError("未知命令: {s}", .{command});
    showHelp();
}
