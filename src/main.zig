const std = @import("std");

const Allocator = std.mem.Allocator;

const TECHLEAD_DIR_NAME = ".techlead";
const CONFIG_FILE_NAME = "techlead.json";
const DEFAULT_PROGRAM_FILE = "program.md";
const CONFIG_REL_PATH = ".techlead/techlead.json";
const DEFAULT_PROGRAM_REL_PATH = ".techlead/program.md";
const DEFAULT_LOG_DIR = ".techlead/iteration-logs";
const SERVER_CONFIG_DIR = ".config/techlead";
const SERVER_PID_FILENAME = "server.pid";
const SERVER_LOG_FILENAME = "server.log";
const DEFAULT_OPCENCODE_PORT = 4096;
const SERVER_SHUTDOWN_TIMEOUT_MS = 5000;

const Colors = struct {
    const red = "\x1b[0;31m";
    const green = "\x1b[0;32m";
    const yellow = "\x1b[1;33m";
    const blue = "\x1b[0;34m";
    const nc = "\x1b[0m";
};

// 将字符串首字母大写（用于 oh-my-opencode agent 名称）
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

const ConfigFile = struct {
    iterations: usize,
    program_file: []const u8,
    opencode_url: []const u8,
    work_dir: []const u8,
    log_dir: []const u8,
    model: []const u8,
    agent: []const u8,
    main_branch: []const u8,
    max_branches: usize,
};

const Config = struct {
    iterations: usize,
    program_file: []u8,
    opencode_url: []u8,
    work_dir: []u8,
    log_dir: []u8,
    model: []u8,
    agent: []u8,
    main_branch: []u8,
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

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn writeFileWithPolicy(path: []const u8, content: []const u8, force: bool) !void {
    if (fileExists(path) and !force) {
        return error.FileAlreadyExists;
    }

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

// PID file management utilities
const posix = std.posix;

fn getServerConfigDir(allocator: Allocator) ![]u8 {
    const home_dir = posix.getenv("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(allocator, &[_][]const u8{ home_dir, SERVER_CONFIG_DIR });
}

fn getPidFilePath(allocator: Allocator) ![]u8 {
    const config_dir = try getServerConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &[_][]const u8{ config_dir, SERVER_PID_FILENAME });
}

fn isServerRunning(pid: posix.pid_t) bool {
    // Use kill(pid, 0) to check if process exists
    // kill returns 0 if process exists and we have permission to send signals
    // returns ESRCH if process doesn't exist
    const result = posix.kill(pid, 0);
    if (result) {
        return true;
    } else |err| {
        return err != error.ProcessNotFound;
    }
}

fn readPidFile(allocator: Allocator) !posix.pid_t {
    const pid_path = try getPidFilePath(allocator);
    defer allocator.free(pid_path);

    const content = std.fs.cwd().readFileAlloc(allocator, pid_path, 256) catch |err| {
        switch (err) {
            error.FileNotFound => return error.ServerNotRunning,
            else => return err,
        }
    };
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) {
        return error.InvalidPidFile;
    }

    const pid = std.fmt.parseInt(posix.pid_t, trimmed, 10) catch {
        return error.InvalidPidFile;
    };

    // Check if PID is stale (process no longer exists)
    if (!isServerRunning(pid)) {
        // Stale PID file, try to clean it up
        deletePidFile() catch {};
        return error.ServerNotRunning;
    }

    return pid;
}

fn writePidFile(allocator: Allocator, pid: posix.pid_t) !void {
    const pid_path = try getPidFilePath(allocator);
    defer allocator.free(pid_path);

    const config_dir = try getServerConfigDir(allocator);
    defer allocator.free(config_dir);

    // Ensure config directory exists
    std.fs.cwd().makePath(config_dir) catch |err| {
        return err;
    };

    // Create temp file in same directory for atomic write
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ pid_path, std.time.timestamp() });
    defer allocator.free(temp_path);

    const content = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(content);

    // Write to temp file
    var temp_file = try std.fs.cwd().createFile(temp_path, .{ .truncate = true });
    defer temp_file.close();
    try temp_file.writeAll(content);
    temp_file.close();

    // Atomic rename
    try std.fs.cwd().rename(temp_path, pid_path);
}

fn deletePidFile() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    const pid_path = try getPidFilePath(allocator);
    defer allocator.free(pid_path);

    std.fs.cwd().deleteFile(pid_path) catch |err| {
        switch (err) {
            error.FileNotFound => {}, // Already deleted, that's fine
            else => return err,
        }
    };
}

fn deinitConfig(allocator: Allocator, config: *const Config) void {
    allocator.free(config.program_file);
    allocator.free(config.opencode_url);
    allocator.free(config.work_dir);
    allocator.free(config.log_dir);
    allocator.free(config.model);
    allocator.free(config.agent);
    allocator.free(config.main_branch);
}

fn resolveConfigPath(allocator: Allocator, base_dir: []const u8) ![]u8 {
    const new_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, CONFIG_REL_PATH });
    if (fileExists(new_path)) {
        return new_path;
    }
    allocator.free(new_path);

    const legacy_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, CONFIG_FILE_NAME });
    if (fileExists(legacy_path)) {
        logWarn("检测到旧版配置路径: {s}", .{legacy_path});
        return legacy_path;
    }
    allocator.free(legacy_path);

    return error.ConfigFileNotFound;
}

fn loadConfigFromJson(allocator: Allocator, base_dir: []const u8) !Config {
    const config_path = resolveConfigPath(allocator, base_dir) catch |err| switch (err) {
        error.ConfigFileNotFound => return error.ConfigFileNotFound,
        else => return err,
    };
    defer allocator.free(config_path);

    const config_bytes = std.fs.cwd().readFileAlloc(allocator, config_path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.ConfigFileNotFound,
        else => return err,
    };
    defer allocator.free(config_bytes);

    const parsed = std.json.parseFromSlice(ConfigFile, allocator, config_bytes, .{}) catch {
        return error.ConfigParseFailed;
    };
    defer parsed.deinit();

    const value = parsed.value;
    if (value.program_file.len == 0 or value.opencode_url.len == 0 or value.work_dir.len == 0 or value.log_dir.len == 0 or value.main_branch.len == 0) {
        return error.InvalidConfig;
    }

    return .{
        .iterations = value.iterations,
        .program_file = try allocator.dupe(u8, value.program_file),
        .opencode_url = try allocator.dupe(u8, value.opencode_url),
        .work_dir = try allocator.dupe(u8, value.work_dir),
        .log_dir = try allocator.dupe(u8, value.log_dir),
        .model = try allocator.dupe(u8, value.model),
        .agent = try allocator.dupe(u8, value.agent),
        .main_branch = try allocator.dupe(u8, value.main_branch),
        .max_branches = value.max_branches,
    };
}

fn writeDefaultConfig(allocator: Allocator, force: bool, target_dir: []const u8) !void {
    const abs_work_dir = try std.fs.cwd().realpathAlloc(allocator, target_dir);
    defer allocator.free(abs_work_dir);

    const cfg = ConfigFile{
        .iterations = 20,
        .program_file = DEFAULT_PROGRAM_REL_PATH,
        .opencode_url = "http://localhost:4096",
        .work_dir = abs_work_dir,
        .log_dir = DEFAULT_LOG_DIR,
        .model = "",
        .agent = "Prometheus",
        .main_branch = "master",
        .max_branches = 10,
    };

    const final_text = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(cfg, .{ .whitespace = .indent_2 })});
    defer allocator.free(final_text);

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, CONFIG_REL_PATH });
    defer allocator.free(config_path);

    try writeFileWithPolicy(config_path, final_text, force);
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

fn truncateForLog(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    return text[0..limit];
}

fn printEventLine(comptime label: []const u8, comptime color: []const u8, msg: []const u8) void {
    std.debug.print("{s}[{s}]{s} {s}\n", .{ color, label, Colors.nc, msg });
}

const AI_SPINNER_FRAMES = [_][]const u8{ "|", "/", "-", "\\" };

const SpinnerRuntime = struct {
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};

fn renderAiLoader(spinner_index: usize) void {
    const frame = AI_SPINNER_FRAMES[spinner_index % AI_SPINNER_FRAMES.len];
    std.debug.print("\r\x1b[2K{s}[AI]{s} 正在工作 {s}", .{ Colors.blue, Colors.nc, frame });
}

fn spinnerThreadMain(runtime: *SpinnerRuntime) void {
    var spinner_index: usize = 0;
    while (runtime.running.load(.seq_cst)) {
        renderAiLoader(spinner_index);
        spinner_index = (spinner_index + 1) % AI_SPINNER_FRAMES.len;
        std.Thread.sleep(120 * std.time.ns_per_ms);
    }
}

fn startAiLoader(runtime: *SpinnerRuntime) void {
    runtime.running.store(true, .seq_cst);
    runtime.thread = std.Thread.spawn(.{}, spinnerThreadMain, .{runtime}) catch {
        runtime.running.store(false, .seq_cst);
        renderAiLoader(0);
        return;
    };
}

fn stopAiLoader(runtime: *SpinnerRuntime) void {
    runtime.running.store(false, .seq_cst);
    if (runtime.thread) |thread| {
        thread.join();
        runtime.thread = null;
    }
    std.debug.print("\r\x1b[2K", .{});
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
    try msg_buf.writer(allocator).print(" | {s}: {s}", .{ key, truncateForLog(value, 88) });
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

fn emitOpencodeEventSummary(allocator: Allocator, line: []const u8, seen_session: *bool, ai_loader_active: *bool, spinner_runtime: *SpinnerRuntime) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    const root_obj = switch (root) {
        .object => |obj| obj,
        else => return,
    };

    const event_type = if (root_obj.get("type")) |v| switch (v) {
        .string => |s| s,
        else => return,
    } else return;

    if (!seen_session.*) {
        if (root_obj.get("sessionID")) |v| {
            if (v == .string) {
                if (ai_loader_active.*) {
                    stopAiLoader(spinner_runtime);
                    ai_loader_active.* = false;
                }
                const sid = truncateForLog(v.string, 40);
                printEventLine("SESSION", Colors.blue, sid);
                seen_session.* = true;
            }
        }
    }

    if (std.mem.eql(u8, event_type, "step_start")) {
        if (!ai_loader_active.*) {
            startAiLoader(spinner_runtime);
            ai_loader_active.* = true;
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "step_finish")) {
        if (ai_loader_active.*) {
            stopAiLoader(spinner_runtime);
            ai_loader_active.* = false;
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "tool_use")) {
        if (root_obj.get("part")) |part_v| {
            if (part_v == .object) {
                const tool_name = if (part_v.object.get("tool")) |tv| switch (tv) {
                    .string => |s| s,
                    else => "unknown",
                } else "unknown";

                var status: []const u8 = "unknown";
                if (part_v.object.get("state")) |state_v| {
                    if (state_v == .object) {
                        if (state_v.object.get("status")) |sv| {
                            if (sv == .string) status = sv.string;
                        }
                    }
                }

                var msg_buf: std.ArrayList(u8) = .empty;
                defer msg_buf.deinit(allocator);
                msg_buf.writer(allocator).print("{s} ({s})", .{ tool_name, status }) catch return;

                if (part_v.object.get("state")) |state_v| {
                    if (state_v == .object) {
                        if (state_v.object.get("input")) |input_v| {
                            if (input_v == .object) {
                                if (input_v.object.get("command")) |cv| {
                                    if (valueAsString(cv)) |command| {
                                        const concise = simplifyShellCommand(command);
                                        appendToolDetail(&msg_buf, allocator, "cmd", concise) catch {};
                                    }
                                } else if (input_v.object.get("filePath")) |fv| {
                                    if (valueAsString(fv)) |file_path| {
                                        appendToolDetail(&msg_buf, allocator, "file", file_path) catch {};
                                    }
                                } else if (input_v.object.get("path")) |pv| {
                                    if (valueAsString(pv)) |path| {
                                        appendToolDetail(&msg_buf, allocator, "path", path) catch {};
                                    }
                                } else if (input_v.object.get("query")) |qv| {
                                    if (valueAsString(qv)) |query| {
                                        appendToolDetail(&msg_buf, allocator, "query", query) catch {};
                                    }
                                }
                            }
                        }

                        if (state_v.object.get("metadata")) |metadata_v| {
                            if (metadata_v == .object) {
                                if (metadata_v.object.get("title")) |title_v| {
                                    if (valueAsString(title_v)) |title| {
                                        appendToolDetail(&msg_buf, allocator, "target", title) catch {};
                                    }
                                }
                            }
                        }

                        if (state_v.object.get("time")) |time_v| {
                            if (time_v == .object) {
                                if (time_v.object.get("start")) |start_v| {
                                    if (time_v.object.get("end")) |end_v| {
                                        if (valueAsI64(start_v)) |start_ms| {
                                            if (valueAsI64(end_v)) |end_ms| {
                                                if (end_ms >= start_ms) {
                                                    msg_buf.writer(allocator).print(" | {d}ms", .{end_ms - start_ms}) catch {};
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if (ai_loader_active.*) {
                    stopAiLoader(spinner_runtime);
                    ai_loader_active.* = false;
                }
                printEventLine("TOOL", Colors.yellow, msg_buf.items);
                if (!ai_loader_active.*) {
                    startAiLoader(spinner_runtime);
                    ai_loader_active.* = true;
                }
                return;
            }
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "text")) {
        if (root_obj.get("part")) |part_v| {
            if (part_v == .object) {
                if (part_v.object.get("text")) |text_v| {
                    if (text_v == .string) {
                        var first_line_it = std.mem.splitScalar(u8, text_v.string, '\n');
                        const first_line = std.mem.trim(u8, first_line_it.next() orelse "", " \t\r\n");
                        if (first_line.len == 0) return;
                        if (ai_loader_active.*) {
                            stopAiLoader(spinner_runtime);
                            ai_loader_active.* = false;
                        }
                        const clipped = truncateForLog(first_line, 180);
                        printEventLine("AI", Colors.green, clipped);
                    }
                }
            }
        }
    }
}

fn getCurrentExperimentBranch(config: Config, allocator: Allocator) ?[]u8 {
    const current = runShellStdout(allocator, config.work_dir, "git branch --show-current") catch return null;
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

fn preparePrompt(config: Config, allocator: Allocator, iteration: usize, experiment_branch: ?[]const u8) ![]u8 {
    const program_path = try std.fs.path.join(allocator, &[_][]const u8{ config.work_dir, config.program_file });
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

    const mode_instructions = try renderModeInstructions(allocator, mode_template, config.main_branch);
    defer allocator.free(mode_instructions);

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
        try prompt.appendSlice(allocator, "- 工作模式: EVALUATE_EXPERIMENT\n\n");
    } else {
        try prompt.writer(allocator).print("- 当前分支: {s}（需要开始新的实验）\n", .{config.main_branch});
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

    const session_title = try std.fmt.allocPrint(allocator, "techlead-iter-{d}-{d}", .{ iteration, std.time.timestamp() });
    defer allocator.free(session_title);

    // 使用 oh-my-opencode run 替代 opencode run
    // oh-my-opencode run 不支持 --title 参数
    try argv.appendSlice(allocator, &[_][]const u8{ "oh-my-opencode", "run", "--attach", config.opencode_url, "--directory", config.work_dir, "--json" });

    if (config.model.len > 0) {
        try argv.append(allocator, "--model");
        try argv.append(allocator, config.model);
    }
    if (config.agent.len > 0) {
        try argv.append(allocator, "--agent");
        // oh-my-opencode 使用首字母大写的 agent 名称
        const capitalized_agent = try capitalizeFirstLetter(allocator, config.agent);
        defer allocator.free(capitalized_agent);
        try argv.append(allocator, capitalized_agent);
    }
    // prompt 必须放在最后
    try argv.append(allocator, prompt);

    logInfo("执行: oh-my-opencode run --attach {s} --directory {s} --json", .{ config.opencode_url, config.work_dir });

    var log_file = try std.fs.cwd().createFile(log_file_path, .{ .truncate = true });
    defer log_file.close();

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.cwd = config.work_dir;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    var merged: std.ArrayList(u8) = .empty;
    defer merged.deinit(allocator);

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    var seen_session = false;
    var ai_loader_active = false;
    var spinner_runtime = SpinnerRuntime{};

    var buf: [4096]u8 = undefined;
    const child_stdout = child.stdout orelse return error.CommandFailed;
    while (true) {
        const n = try child_stdout.read(&buf);
        if (n == 0) break;

        const chunk = buf[0..n];
        try log_file.writeAll(chunk);
        try merged.appendSlice(allocator, chunk);

        try line_buf.appendSlice(allocator, chunk);
        while (std.mem.indexOfScalar(u8, line_buf.items, '\n')) |nl| {
            const line = std.mem.trimRight(u8, line_buf.items[0..nl], "\r\n");
            if (line.len > 0) {
                emitOpencodeEventSummary(allocator, line, &seen_session, &ai_loader_active, &spinner_runtime);
            }

            const remain = line_buf.items[nl + 1 ..];
            std.mem.copyForwards(u8, line_buf.items[0..remain.len], remain);
            line_buf.items.len = remain.len;
        }
    }

    if (line_buf.items.len > 0) {
        const tail_line = std.mem.trimRight(u8, line_buf.items, "\r\n");
        if (tail_line.len > 0) emitOpencodeEventSummary(allocator, tail_line, &seen_session, &ai_loader_active, &spinner_runtime);
    }

    if (ai_loader_active) {
        stopAiLoader(&spinner_runtime);
        ai_loader_active = false;
    }

    const term = try child.wait();
    if (!isExitedZero(term)) {
        logError("调用 OpenCode 失败", .{});
        logInfo("日志保存在: {s}", .{log_file_path});
        return false;
    }

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

fn verifyGitRepo(cwd: []const u8, allocator: Allocator) !void {
    const git_check = runShellCapture(allocator, cwd, "git rev-parse --git-dir") catch {
        return error.NotGitRepo;
    };
    defer allocator.free(git_check.stdout);
    defer allocator.free(git_check.stderr);

    if (!isExitedZero(git_check.term)) {
        return error.NotGitRepo;
    }
}

fn validateRunEnvironment(config: Config, allocator: Allocator) !void {
    logInfo("检查运行环境...", .{});

    const abs_work_dir = try std.fs.cwd().realpathAlloc(allocator, config.work_dir);
    defer allocator.free(abs_work_dir);
    logInfo("工作目录: {s}", .{abs_work_dir});

    const program_path = try std.fs.path.join(allocator, &[_][]const u8{ config.work_dir, config.program_file });
    defer allocator.free(program_path);

    std.fs.cwd().access(program_path, .{}) catch {
        logError("找不到 {s}", .{program_path});
        return error.MissingProgramFile;
    };

    try verifyGitRepo(config.work_dir, allocator);
    logSuccess("环境检查通过", .{});
    std.debug.print("\n", .{});
}

fn checkOpencode(config: Config, allocator: Allocator) !void {
    logInfo("检查 OpenCode server...", .{});
    if (!checkHttpService(allocator, config.opencode_url)) {
        logError("无法连接到 OpenCode server at {s}", .{config.opencode_url});
        logInfo("请确保 OpenCode serve 正在运行: opencode serve", .{});
        return error.OpencodeUnavailable;
    }

    logSuccess("OpenCode server 连接正常", .{});
    std.debug.print("\n", .{});
}

fn runCommand(config: Config, allocator: Allocator) !void {
    if (!commandExists(allocator, "opencode")) {
        logError("找不到 opencode CLI，请确保已安装", .{});
        return error.MissingOpencode;
    }

    try validateRunEnvironment(config, allocator);
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
            if (std.mem.indexOf(u8, line, config.main_branch) != null or std.mem.indexOf(u8, line, "experiment-") != null) {
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
        if (fileExists(config_path)) {
            logError("{s} 已存在，使用 --force 覆盖", .{config_path});
            return error.FileAlreadyExists;
        }
        if (fileExists(program_path)) {
            logError("{s} 已存在，使用 --force 覆盖", .{program_path});
            return error.FileAlreadyExists;
        }
    }

    const template = try buildProgramTemplate(allocator, goal);
    defer allocator.free(template);

    try writeDefaultConfig(allocator, force, target_dir);
    try writeFileWithPolicy(program_path, template, force);

    logSuccess("初始化完成", .{});
    logInfo("目标目录: {s}", .{target_dir});
    logInfo("已生成: {s}", .{config_path});
    logInfo("已生成: {s}", .{program_path});
    logInfo("下一步执行: zig build run -- run --dir {s}", .{target_dir});
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
                error.MissingGoal => logError("init 需要 Goal 参数", .{}),
                error.InvalidInitArguments => logError("init 参数无效，只支持 --force（以及命令后的可选 --dir 目录）", .{}),
                else => logError("无法解析 init 参数", .{}),
            }
            showHelp();
            return;
        };
        defer allocator.free(parsed.goal);

        runInitCommand(allocator, parsed.goal, parsed.force, target_dir) catch |err| {
            switch (err) {
                error.NotGitRepo => logError("目标目录不是 git 仓库: {s}", .{target_dir}),
                error.FileAlreadyExists => {},
                else => logError("init 执行失败: {any}", .{err}),
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
            logError("run 参数无效，仅支持可选 --dir 目录", .{});
            showHelp();
            return;
        }

        const config = loadConfigFromJson(allocator, target_dir) catch |err| {
            switch (err) {
                error.ConfigFileNotFound => logError("找不到 {s}，请先执行 init", .{CONFIG_REL_PATH}),
                error.ConfigParseFailed => logError("{s} 解析失败，请检查 JSON 格式", .{CONFIG_REL_PATH}),
                error.InvalidConfig => logError("{s} 字段无效或缺失", .{CONFIG_REL_PATH}),
                else => logError("读取配置失败: {any}", .{err}),
            }
            return;
        };
        defer deinitConfig(allocator, &config);

        std.debug.print("========================================\n", .{});
        std.debug.print("  Techlead 持续迭代系统\n", .{});
        std.debug.print("========================================\n\n", .{});
        logInfo("配置:", .{});
        logInfo("  - 配置文件: {s}", .{CONFIG_REL_PATH});
        logInfo("  - 迭代次数: {d}", .{config.iterations});
        logInfo("  - Program 文件: {s}", .{config.program_file});
        logInfo("  - OpenCode URL: {s}", .{config.opencode_url});
        logInfo("  - 主分支: {s}", .{config.main_branch});
        logInfo("  - 日志目录: {s}", .{config.log_dir});
        if (config.model.len > 0) {
            logInfo("  - 模型: {s}", .{config.model});
        }
        std.debug.print("\n", .{});

        runCommand(config, allocator) catch |err| {
            switch (err) {
                error.MissingProgramFile => logError(".techlead/program.md 缺失，请重新执行 init --force", .{}),
                error.InvalidProgramTemplate => logError(".techlead/program.md 模板块缺失，请重新执行 init --force", .{}),
                error.NotGitRepo => logError("work_dir 不是 git 仓库", .{}),
                error.OpencodeUnavailable => {},
                error.MissingOpencode => {},
                else => logError("run 失败: {any}", .{err}),
            }
            return;
        };
        return;
    }

    if (std.mem.eql(u8, command, "server")) {
        if (args.len < 3) {
            logError("server 需要子命令: start, stop", .{});
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

            runServerStartCommand(allocator, daemon_mode) catch |err| {
                switch (err) {
                    error.ServerAlreadyRunning => logError("服务已在运行", .{}),
                    error.ServerStartFailed => logError("启动服务失败", .{}),
                    error.MissingOpencode => logError("找不到 opencode CLI，请确保已安装", .{}),
                    else => logError("启动服务失败: {any}", .{err}),
                }
            };
            return;
        }

        if (std.mem.eql(u8, subcommand, "stop")) {
            runServerStopCommand(allocator) catch |err| {
                switch (err) {
                    error.ServerNotRunning => logError("服务未运行", .{}),
                    error.ServerStopFailed => logError("停止服务失败", .{}),
                    else => logError("停止服务失败: {any}", .{err}),
                }
            };
            return;
        }

        logError("未知的 server 子命令: {s}", .{subcommand});
        showHelp();
        return;
    }

    logError("未知命令: {s}", .{command});
    showHelp();
}

fn getServerLogPath(allocator: Allocator) ![]u8 {
    const home_dir = posix.getenv("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(allocator, &[_][]const u8{ home_dir, SERVER_CONFIG_DIR, SERVER_LOG_FILENAME });
}

fn redirectToLogFile(allocator: Allocator) !std.fs.File {
    const log_path = try getServerLogPath(allocator);
    defer allocator.free(log_path);

    // Ensure config directory exists
    const config_dir = try getServerConfigDir(allocator);
    defer allocator.free(config_dir);
    std.fs.cwd().makePath(config_dir) catch |err| {
        return err;
    };

    // Open log file for writing (create if not exists, append if exists)
    const log_file = std.fs.cwd().openFile(log_path, .{ .mode = .write_only }) catch |err| {
        if (err == error.FileNotFound) {
            // Create the file
            return try std.fs.cwd().createFile(log_path, .{ .truncate = false });
        }
        return err;
    };

    return log_file;
}

fn runServerStopCommand(allocator: Allocator) !void {
    // 1. Read PID file to get the process ID
    const pid = readPidFile(allocator) catch |err| {
        switch (err) {
            error.ServerNotRunning => {
                logError("服务未运行", .{});
                return error.ServerNotRunning;
            },
            error.InvalidPidFile => {
                logError("PID 文件无效", .{});
                // Try to clean up invalid PID file
                deletePidFile() catch {};
                return error.ServerNotRunning;
            },
            else => return err,
        }
    };

    logInfo("正在停止服务 (PID: {d})...", .{pid});

    // 2. Send SIGTERM for graceful shutdown
    posix.kill(pid, posix.SIG.TERM) catch |err| {
        logError("发送 SIGTERM 信号失败: {any}", .{err});
        // Try to clean up PID file since we can't signal the process
        deletePidFile() catch {};
        return error.ServerStopFailed;
    };

    // 3. Wait for process to exit (up to 5 seconds)
    const timeout_ms = SERVER_SHUTDOWN_TIMEOUT_MS; // 5000
    const poll_interval_ms = 100;
    var waited_ms: usize = 0;

    while (waited_ms < timeout_ms) {
        if (!isServerRunning(pid)) break;
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
        waited_ms += poll_interval_ms;
    }

    // 4. Check if process is still running
    if (isServerRunning(pid)) {
        logWarn("服务未能在 5 秒内退出，发送 SIGKILL...", .{});

        // Send SIGKILL to force terminate
        posix.kill(pid, posix.SIG.KILL) catch |err| {
            logError("发送 SIGKILL 信号失败: {any}", .{err});
            // Still try to clean up PID file
            deletePidFile() catch {};
            return error.ServerStopFailed;
        };

        // Wait a bit more for SIGKILL to take effect
        std.Thread.sleep(500 * std.time.ns_per_ms);

        // Check if it's still running after SIGKILL
        if (isServerRunning(pid)) {
            logError("无法终止服务进程 (PID: {d})", .{pid});
            return error.ServerStopFailed;
        }
    }

    // 5. Clean up PID file
    deletePidFile() catch |err| {
        logWarn("清理 PID 文件失败: {any}", .{err});
    };

    logSuccess("服务已停止", .{});
}

fn runServerStartCommand(allocator: Allocator, daemon_mode: bool) !void {
    // 1. Check if opencode CLI exists
    if (!commandExists(allocator, "opencode")) {
        logError("找不到 opencode CLI，请确保已安装", .{});
        return error.MissingOpencode;
    }

    // 2. Check if server is already running
    const existing_pid = readPidFile(allocator) catch |err| switch (err) {
        error.ServerNotRunning => null,
        else => return err,
    };

    if (existing_pid) |pid| {
        logError("服务已在运行 (PID: {d})", .{pid});
        return error.ServerAlreadyRunning;
    }

    if (daemon_mode) {
        // Daemon mode: fork and create new session
        logInfo("正在后台启动 opencode serve...", .{});

        const pid = try posix.fork();
        if (pid < 0) {
            return error.ServerStartFailed;
        }

        if (pid > 0) {
            // Parent process: write child PID and exit quickly
            writePidFile(allocator, pid) catch |err| {
                logError("写入 PID 文件失败: {any}", .{err});
                // Try to kill the child process
                _ = posix.kill(@intCast(pid), posix.SIG.TERM) catch {};
                return error.ServerStartFailed;
            };

            logSuccess("服务已在后台启动 (PID: {d})", .{pid});
            // Parent exits with success
            std.process.exit(0);
        }

        // Child process: become daemon
        // Create new session, detach from terminal
        _ = try posix.setsid();

        // Ignore SIGHUP signal
        const act = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.HUP, &act, null);

        // Redirect stdout/stderr to log file
        const log_file = redirectToLogFile(allocator) catch |err| {
            // Log to stderr before redirect (will go to terminal briefly)
            std.debug.print("重定向日志失败: {any}\n", .{err});
            return error.ServerStartFailed;
        };

        // Duplicate file descriptor to stdout and stderr
        posix.dup2(log_file.handle, posix.STDOUT_FILENO) catch {};
        posix.dup2(log_file.handle, posix.STDERR_FILENO) catch {};

        // We don't close log_file here since stdout/stderr now use it
        // The file will be closed when the process exits

        // Get our new PID after setsid and update PID file
        const new_pid = std.c.getpid();
        writePidFile(allocator, new_pid) catch |err| {
            // Log to file now
            std.log.err("更新 PID 文件失败: {any}", .{err});
        };

        // Start opencode serve in daemon mode
        const argv = [_][]const u8{ "opencode", "serve" };

        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        // Ensure PID file cleanup on error
        errdefer deletePidFile() catch {};

        // Wait for process to end
        const term = child.wait() catch |err| {
            std.log.err("等待进程失败: {any}", .{err});
            deletePidFile() catch {};
            std.process.exit(1);
        };

        // Cleanup PID file when process exits
        deletePidFile() catch |err| {
            std.log.warn("清理 PID 文件失败: {any}", .{err});
        };

        // Log exit status
        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    std.log.info("服务已正常退出", .{});
                } else {
                    std.log.warn("服务异常退出 (code: {d})", .{code});
                }
            },
            .Signal => |sig| {
                std.log.info("服务被信号终止 (signal: {d})", .{sig});
            },
            .Stopped => |sig| {
                std.log.info("服务被停止 (signal: {d})", .{sig});
            },
            .Unknown => |code| {
                std.log.warn("服务以未知状态退出 (code: {d})", .{code});
            },
        }

        std.process.exit(0);
    } else {
        // Foreground mode (existing behavior)
        logInfo("正在启动 opencode serve...", .{});

        const argv = [_][]const u8{ "opencode", "serve" };

        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        // Write PID file
        writePidFile(allocator, child.id) catch |err| {
            logError("写入 PID 文件失败: {any}", .{err});
            _ = child.kill() catch {};
            return error.ServerStartFailed;
        };

        logSuccess("服务已启动 (PID: {d})", .{child.id});

        // Ensure PID file cleanup on error
        errdefer deletePidFile() catch {};

        // Wait for process to end (foreground mode)
        const term = child.wait() catch |err| {
            logError("等待进程失败: {any}", .{err});
            deletePidFile() catch {};
            return error.ServerStartFailed;
        };

        // Cleanup PID file when process exits
        deletePidFile() catch |err| {
            logWarn("清理 PID 文件失败: {any}", .{err});
        };

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    logInfo("服务已正常退出", .{});
                } else {
                    logWarn("服务异常退出 (code: {d})", .{code});
                }
            },
            .Signal => |sig| {
                logInfo("服务被信号终止 (signal: {d})", .{sig});
            },
            .Stopped => |sig| {
                logInfo("服务被停止 (signal: {d})", .{sig});
            },
            .Unknown => |code| {
                logWarn("服务以未知状态退出 (code: {d})", .{code});
            },
        }
    }
}

const ServerError = error{
    ServerAlreadyRunning,
    ServerNotRunning,
    ServerStartFailed,
    ServerStopFailed,
    InvalidPidFile,
    PidFileLocked,
};
