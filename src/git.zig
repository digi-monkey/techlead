const std = @import("std");

const utils = @import("utils.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");

/// Verifies that the given directory is a valid Git repository.
/// Returns error.NotGitRepo if the directory is not inside a git repository.
pub fn verifyGitRepo(cwd: []const u8, allocator: std.mem.Allocator) !void {
    const git_check = utils.runShellCapture(allocator, cwd, "git rev-parse --git-dir") catch {
        return error.NotGitRepo;
    };
    defer allocator.free(git_check.stdout);
    defer allocator.free(git_check.stderr);

    if (!utils.isExitedZero(git_check.term)) {
        return error.NotGitRepo;
    }
}

/// Gets the current Git branch name if it starts with "experiment-".
/// Returns the branch name if on an experiment branch, null otherwise.
/// Caller owns the returned memory.
pub fn getCurrentExperimentBranch(cfg: config.Config, allocator: std.mem.Allocator) ?[]u8 {
    const current = utils.runShellStdout(allocator, cfg.work_dir, "git branch --show-current") catch return null;
    if (std.mem.startsWith(u8, current, "experiment-")) {
        return current;
    }
    allocator.free(current);
    return null;
}

/// Cleans up old experiment branches if the count exceeds cfg.max_branches.
/// Deletes the oldest branches (by list order from git branch --list) first.
pub fn cleanupOldBranches(cfg: config.Config, allocator: std.mem.Allocator) void {
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
