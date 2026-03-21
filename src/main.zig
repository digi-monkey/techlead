const std = @import("std");
const utils = @import("utils.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");
const server = @import("server.zig");
const runner = @import("runner.zig");
const observe = @import("observe.zig");
const session_service = @import("app/session_service.zig");
const replay = @import("storage/replay.zig");
comptime {
    _ = @import("providers/provider_contract_test.zig");
    _ = @import("core/domain.zig");
    _ = @import("core/scheduler.zig");
}

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
            "    zig build run -- run [--dir 目录] [--mode optimize|pool]\n" ++
            "    zig build run -- control <pause|resume|abort|inject_prompt> [--dir 目录] [--prompt 文本]\n" ++
            "    zig build run -- observe start [--dir 目录] [--host 0.0.0.0] [--port 7788]\n" ++
            "    zig build run -- observe rotate-tokens [--dir 目录]\n" ++
            "    zig build run -- session process-message --dir 目录 --request-id 请求ID\n" ++
            "    zig build run -- trace show [--dir 目录]\n" ++
            "    zig build run -- server start [--daemon]\n" ++
            "    zig build run -- server stop\n\n" ++
            "说明:\n" ++
            "    - init: 在目标目录生成 .techlead/techlead.json 和 .techlead/program.md\n" ++
            "    - init-agent: 创建目标目录下的 sisyphus 代理项目\n" ++
            "    - run: 从目标目录读取配置并执行迭代（默认 mode=pool）\n" ++
            "    - control: 向正在运行的任务写入控制命令\n" ++
            "    - observe start: 启动 Web 观察与控制接口\n" ++
            "    - observe rotate-tokens: 轮换 observe/control token\n" ++
            "    - session process-message: 内部后台任务，处理 in-flight 会话消息\n" ++
            "    - trace show: 输出结构化 tracing 事件\n" ++
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
        var mode: runner.RunMode = .pool;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--dir")) {
                if (i + 1 >= args.len) {
                    ui.logError("run 参数无效，--dir 需要目录参数", .{});
                    showHelp();
                    return;
                }
                target_dir = args[i + 1];
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--mode")) {
                if (i + 1 >= args.len) {
                    ui.logError("run 参数无效，--mode 需要取值 optimize|pool", .{});
                    showHelp();
                    return;
                }
                const mode_str = args[i + 1];
                if (std.mem.eql(u8, mode_str, "optimize")) {
                    mode = .optimize;
                } else if (std.mem.eql(u8, mode_str, "pool")) {
                    mode = .pool;
                } else {
                    ui.logError("run 参数无效，--mode 仅支持 optimize|pool", .{});
                    showHelp();
                    return;
                }
                i += 1;
                continue;
            }
            ui.logError("run 参数无效，仅支持 --dir 目录 和 --mode optimize|pool", .{});
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
        ui.logInfo("  - 运行模式: {s}", .{@tagName(mode)});
        ui.logInfo("  - Provider: {s}", .{cfg.provider});
        ui.logInfo("  - Pool lease(s): {d}", .{cfg.pool_lease_seconds});
        ui.logInfo("  - Pool max retries: {d}", .{cfg.pool_max_retries});
        if (cfg.model.len > 0) ui.logInfo("  - 模型: {s}", .{cfg.model});
        std.debug.print("\n", .{});
        runner.runCommandWithMode(cfg, allocator, mode) catch |err| {
            switch (err) {
                error.MissingProgramFile => ui.logError(".techlead/program.md 缺失，请重新执行 init --force", .{}),
                error.InvalidProgramTemplate => ui.logError(".techlead/program.md 模板块缺失，请重新执行 init --force", .{}),
                error.NotGitRepo => ui.logError("work_dir 不是 git 仓库", .{}),
                error.OpencodeUnavailable => {},
                error.MissingOpencode => {},
                error.ModeNotImplemented => {},
                error.AllIterationsFailed => {},
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

    if (std.mem.eql(u8, command, "control")) {
        if (args.len < 3) {
            ui.logError("control 需要 action: pause|resume|abort|inject_prompt", .{});
            showHelp();
            return;
        }
        const action = args[2];
        var target_dir: []const u8 = ".";
        var prompt: ?[]const u8 = null;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--dir")) {
                if (i + 1 >= args.len) {
                    ui.logError("control 参数无效，--dir 需要目录参数", .{});
                    return;
                }
                target_dir = args[i + 1];
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--prompt")) {
                if (i + 1 >= args.len) {
                    ui.logError("control 参数无效，--prompt 需要文本参数", .{});
                    return;
                }
                prompt = args[i + 1];
                i += 1;
                continue;
            }
            ui.logError("control 参数无效", .{});
            showHelp();
            return;
        }
        runner.runControlCommand(allocator, target_dir, action, prompt) catch |err| {
            ui.logError("写入控制命令失败: {any}", .{err});
        };
        return;
    }

    if (std.mem.eql(u8, command, "observe")) {
        if (args.len < 3) {
            ui.logError("observe 需要子命令: start 或 rotate-tokens", .{});
            showHelp();
            return;
        }
        const observe_sub = args[2];
        var target_dir: []const u8 = ".";
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 7788;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--dir")) {
                if (i + 1 >= args.len) {
                    ui.logError("observe 参数无效，--dir 需要目录参数", .{});
                    return;
                }
                target_dir = args[i + 1];
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--host")) {
                if (i + 1 >= args.len) {
                    ui.logError("observe 参数无效，--host 需要参数", .{});
                    return;
                }
                host = args[i + 1];
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--port")) {
                if (i + 1 >= args.len) {
                    ui.logError("observe 参数无效，--port 需要参数", .{});
                    return;
                }
                port = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                    ui.logError("observe 参数无效，--port 需要数字", .{});
                    return;
                };
                i += 1;
                continue;
            }
            ui.logError("observe 参数无效", .{});
            showHelp();
            return;
        }
        if (std.mem.eql(u8, observe_sub, "start")) {
            observe.runObserveStartCommand(allocator, target_dir, host, port) catch |err| {
                ui.logError("observe 启动失败: {any}", .{err});
            };
            return;
        }
        if (std.mem.eql(u8, observe_sub, "rotate-tokens")) {
            observe.runObserveRotateTokensCommand(allocator, target_dir) catch |err| {
                ui.logError("token 轮换失败: {any}", .{err});
            };
            return;
        }
        ui.logError("observe 仅支持子命令: start 或 rotate-tokens", .{});
        return;
    }

    if (std.mem.eql(u8, command, "session")) {
        if (args.len < 3) {
            ui.logError("session 需要子命令: process-message", .{});
            showHelp();
            return;
        }
        const sub = args[2];
        if (!std.mem.eql(u8, sub, "process-message")) {
            ui.logError("session 仅支持子命令: process-message", .{});
            showHelp();
            return;
        }

        var target_dir: []const u8 = ".";
        var request_id: ?[]const u8 = null;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--dir")) {
                if (i + 1 >= args.len) {
                    ui.logError("session 参数无效，--dir 需要目录参数", .{});
                    return;
                }
                target_dir = args[i + 1];
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--request-id")) {
                if (i + 1 >= args.len) {
                    ui.logError("session 参数无效，--request-id 需要参数", .{});
                    return;
                }
                request_id = args[i + 1];
                i += 1;
                continue;
            }
            ui.logError("session 参数无效", .{});
            showHelp();
            return;
        }
        const rid = request_id orelse {
            ui.logError("session process-message 缺少 --request-id", .{});
            return;
        };
        _ = session_service.processInFlightMessage(allocator, target_dir, rid) catch |err| {
            ui.logWarn("session process-message failed: {any}", .{err});
            return;
        };
        return;
    }

    if (std.mem.eql(u8, command, "trace")) {
        if (args.len < 3 or !std.mem.eql(u8, args[2], "show")) {
            ui.logError("trace 仅支持子命令: show", .{});
            showHelp();
            return;
        }
        var target_dir: []const u8 = ".";
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--dir")) {
                if (i + 1 >= args.len) {
                    ui.logError("trace 参数无效，--dir 需要目录参数", .{});
                    return;
                }
                target_dir = args[i + 1];
                i += 1;
                continue;
            }
            ui.logError("trace 参数无效", .{});
            showHelp();
            return;
        }
        const cfg = config.loadConfigFromJson(allocator, target_dir) catch |err| {
            ui.logError("读取配置失败: {any}", .{err});
            return;
        };
        defer config.deinitConfig(allocator, &cfg);
        const events = replay.readEventsJsonl(allocator, cfg.work_dir, cfg.log_dir) catch |err| {
            ui.logError("读取 tracing 失败: {any}", .{err});
            return;
        };
        defer allocator.free(events);
        std.debug.print("{s}\n", .{events});
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
