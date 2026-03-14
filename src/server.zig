const std = @import("std");
const posix = std.posix;

const utils = @import("utils.zig");
const ui = @import("ui.zig");

const Allocator = std.mem.Allocator;

/// Configuration directory for server files (relative to HOME)
pub const SERVER_CONFIG_DIR = ".config/techlead";

/// Filename for the PID file
pub const SERVER_PID_FILENAME = "server.pid";

/// Filename for the server log file
pub const SERVER_LOG_FILENAME = "server.log";

/// Timeout in milliseconds for graceful server shutdown
pub const SERVER_SHUTDOWN_TIMEOUT_MS = 5000;

/// Error set for server lifecycle operations
pub const ServerError = error{
    ServerAlreadyRunning,
    ServerNotRunning,
    ServerStartFailed,
    ServerStopFailed,
    InvalidPidFile,
    PidFileLocked,
};

/// Get the server configuration directory path (~/.config/techlead)
/// Caller owns the returned memory.
pub fn getServerConfigDir(allocator: Allocator) ![]u8 {
    const home_dir = posix.getenv("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(allocator, &[_][]const u8{ home_dir, SERVER_CONFIG_DIR });
}

/// Get the full path to the PID file
/// Caller owns the returned memory.
pub fn getPidFilePath(allocator: Allocator) ![]u8 {
    const config_dir = try getServerConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &[_][]const u8{ config_dir, SERVER_PID_FILENAME });
}

/// Check if a process with the given PID is currently running
/// Uses kill(pid, 0) to test process existence without sending a signal.
pub fn isServerRunning(pid: posix.pid_t) bool {
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

/// Read the PID from the PID file and verify the process is running
/// Returns ServerNotRunning if file doesn't exist or PID is stale.
/// Caller does not own the returned PID (it's a value type).
pub fn readPidFile(allocator: Allocator) !posix.pid_t {
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

/// Write the PID to the PID file atomically
/// Creates config directory if needed. Uses temp file + rename for atomicity.
pub fn writePidFile(allocator: Allocator, pid: posix.pid_t) !void {
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

/// Delete the PID file if it exists
/// Does not error if file doesn't exist.
pub fn deletePidFile() !void {
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

/// Get the full path to the server log file
/// Caller owns the returned memory.
pub fn getServerLogPath(allocator: Allocator) ![]u8 {
    const home_dir = posix.getenv("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(allocator, &[_][]const u8{ home_dir, SERVER_CONFIG_DIR, SERVER_LOG_FILENAME });
}

/// Redirect stdout and stderr to the log file
/// Returns the log file handle. Used in daemon mode.
pub fn redirectToLogFile(allocator: Allocator) !std.fs.File {
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

/// Stop the running OpenCode server
/// Sends SIGTERM first, waits up to 5 seconds, then SIGKILL if needed.
pub fn runServerStopCommand(allocator: Allocator) !void {
    // 1. Read PID file to get the process ID
    const pid = readPidFile(allocator) catch |err| {
        switch (err) {
            error.ServerNotRunning => {
                ui.logError("服务未运行", .{});
                return error.ServerNotRunning;
            },
            error.InvalidPidFile => {
                ui.logError("PID 文件无效", .{});
                // Try to clean up invalid PID file
                deletePidFile() catch {};
                return error.ServerNotRunning;
            },
            else => return err,
        }
    };

    ui.logInfo("正在停止服务 (PID: {d})...", .{pid});

    // 2. Send SIGTERM for graceful shutdown
    posix.kill(pid, posix.SIG.TERM) catch |err| {
        ui.logError("发送 SIGTERM 信号失败: {any}", .{err});
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
        ui.logWarn("服务未能在 5 秒内退出，发送 SIGKILL...", .{});

        // Send SIGKILL to force terminate
        posix.kill(pid, posix.SIG.KILL) catch |err| {
            ui.logError("发送 SIGKILL 信号失败: {any}", .{err});
            // Still try to clean up PID file
            deletePidFile() catch {};
            return error.ServerStopFailed;
        };

        // Wait a bit more for SIGKILL to take effect
        std.Thread.sleep(500 * std.time.ns_per_ms);

        // Check if it's still running after SIGKILL
        if (isServerRunning(pid)) {
            ui.logError("无法终止服务进程 (PID: {d})", .{pid});
            return error.ServerStopFailed;
        }
    }

    // 5. Clean up PID file
    deletePidFile() catch |err| {
        ui.logWarn("清理 PID 文件失败: {any}", .{err});
    };

    ui.logSuccess("服务已停止", .{});
}

/// Start the OpenCode server
/// Supports foreground and daemon modes. Writes PID file on success.
pub fn runServerStartCommand(allocator: Allocator, daemon_mode: bool) !void {
    // 1. Check if opencode CLI exists
    if (!utils.commandExists(allocator, "opencode")) {
        ui.logError("找不到 opencode CLI，请确保已安装", .{});
        return error.MissingOpencode;
    }

    // 2. Check if server is already running
    const existing_pid = readPidFile(allocator) catch |err| switch (err) {
        error.ServerNotRunning => null,
        else => return err,
    };

    if (existing_pid) |pid| {
        ui.logError("服务已在运行 (PID: {d})", .{pid});
        return error.ServerAlreadyRunning;
    }

    if (daemon_mode) {
        // Daemon mode: fork and create new session
        ui.logInfo("正在后台启动 opencode serve...", .{});

        const pid = try posix.fork();
        if (pid < 0) {
            return error.ServerStartFailed;
        }

        if (pid > 0) {
            // Parent process: write child PID and exit quickly
            writePidFile(allocator, pid) catch |err| {
                ui.logError("写入 PID 文件失败: {any}", .{err});
                // Try to kill the child process
                _ = posix.kill(@intCast(pid), posix.SIG.TERM) catch {};
                return error.ServerStartFailed;
            };

            ui.logSuccess("服务已在后台启动 (PID: {d})", .{pid});
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
        ui.logInfo("正在启动 opencode serve...", .{});

        const argv = [_][]const u8{ "opencode", "serve" };

        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        // Write PID file
        writePidFile(allocator, child.id) catch |err| {
            ui.logError("写入 PID 文件失败: {any}", .{err});
            _ = child.kill() catch {};
            return error.ServerStartFailed;
        };

        ui.logSuccess("服务已启动 (PID: {d})", .{child.id});

        // Ensure PID file cleanup on error
        errdefer deletePidFile() catch {};

        // Wait for process to end (foreground mode)
        const term = child.wait() catch |err| {
            ui.logError("等待进程失败: {any}", .{err});
            deletePidFile() catch {};
            return error.ServerStartFailed;
        };

        // Cleanup PID file when process exits
        deletePidFile() catch |err| {
            ui.logWarn("清理 PID 文件失败: {any}", .{err});
        };

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    ui.logInfo("服务已正常退出", .{});
                } else {
                    ui.logWarn("服务异常退出 (code: {d})", .{code});
                }
            },
            .Signal => |sig| {
                ui.logInfo("服务被信号终止 (signal: {d})", .{sig});
            },
            .Stopped => |sig| {
                ui.logInfo("服务被停止 (signal: {d})", .{sig});
            },
            .Unknown => |code| {
                ui.logWarn("服务以未知状态退出 (code: {d})", .{code});
            },
        }
    }
}
