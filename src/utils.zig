const std = @import("std");

const Allocator = std.mem.Allocator;

/// Run a command and capture its output.
/// Returns the full stdout, stderr, and termination status.
pub fn runCommandCapture(allocator: Allocator, cwd: ?[]const u8, argv: []const []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 64 * 1024 * 1024,
    });
}

/// Run a shell command and capture its output.
/// Uses /bin/sh -lc to execute the command string.
pub fn runShellCapture(allocator: Allocator, cwd: ?[]const u8, cmd: []const u8) !std.process.Child.RunResult {
    const argv = [_][]const u8{ "/bin/sh", "-lc", cmd };
    return runCommandCapture(allocator, cwd, &argv);
}

/// Check if a child process terminated with exit code 0.
/// Returns false for signals or non-zero exit codes.
pub fn isExitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Run a shell command and return its stdout as a trimmed string.
/// Returns error.CommandFailed if the command exits non-zero.
pub fn runShellStdout(allocator: Allocator, cwd: ?[]const u8, cmd: []const u8) ![]u8 {
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

/// Check if a command exists in PATH.
/// Uses `which` to test for command availability.
pub fn commandExists(allocator: Allocator, cmd: []const u8) bool {
    const shell_cmd = std.fmt.allocPrint(allocator, "which {s} >/dev/null 2>&1", .{cmd}) catch return false;
    defer allocator.free(shell_cmd);

    const result = runShellCapture(allocator, null, shell_cmd) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return isExitedZero(result.term);
}

/// Check if an HTTP service is available.
/// Uses curl to test connectivity (returns true for 2xx responses).
pub fn checkHttpService(allocator: Allocator, url: []const u8) bool {
    const shell_cmd = std.fmt.allocPrint(allocator, "curl -fsSI {s} >/dev/null 2>&1", .{url}) catch return false;
    defer allocator.free(shell_cmd);

    const result = runShellCapture(allocator, null, shell_cmd) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return isExitedZero(result.term);
}

/// Check if a file exists at the given path.
pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Write content to a file, with optional force overwrite.
/// Returns error.FileAlreadyExists if file exists and force is false.
pub fn writeFileWithPolicy(path: []const u8, content: []const u8, force: bool) !void {
    if (fileExists(path) and !force) {
        return error.FileAlreadyExists;
    }

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}
