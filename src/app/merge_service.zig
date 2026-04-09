const std = @import("std");
const utils = @import("../utils.zig");

const MAX_GIT_LOG_SNIPPET: usize = 1024;

/// Result of a merge operation
pub const MergeResult = struct {
    success: bool,
    merge_commit: ?[]u8 = null,
    detail: ?[]u8 = null,

    pub fn deinit(self: *MergeResult, allocator: std.mem.Allocator) void {
        if (self.merge_commit) |v| allocator.free(v);
        if (self.detail) |v| allocator.free(v);
    }
};

/// Merge a feature branch into main with file-based locking.
/// Creates a merge commit (--no-ff) and updates the base branch ref.
/// Returns the merge commit SHA on success.
pub fn mergeToMain(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    base_branch: []const u8,
    head_branch: []const u8,
    task_id: []const u8,
) !MergeResult {
    const lock_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".techlead" });
    defer allocator.free(lock_dir);
    try std.fs.cwd().makePath(lock_dir);

    const lock_path = try std.fs.path.join(allocator, &[_][]const u8{ lock_dir, "pool-merge.lock" });
    defer allocator.free(lock_path);

    var lock_file: ?std.fs.File = null;
    defer {
        if (lock_file) |f| f.close();
        std.fs.cwd().deleteFile(lock_path) catch {};
    }

    // Acquire exclusive lock
    while (true) {
        lock_file = std.fs.cwd().createFile(lock_path, .{ .truncate = true, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.Thread.sleep(200 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        break;
    }

    const base_sha_before = try gitRevParse(allocator, cwd, base_branch);
    defer allocator.free(base_sha_before);

    const merge_branch_component = try sanitizeBranchComponent(allocator, task_id);
    defer allocator.free(merge_branch_component);
    const merge_branch = try std.fmt.allocPrint(allocator, "pool/merge-{s}", .{merge_branch_component});
    defer allocator.free(merge_branch);
    runGitBestEffort(allocator, cwd, &[_][]const u8{ "branch", "-D", merge_branch });

    try runGitChecked(allocator, cwd, &[_][]const u8{ "checkout", "-B", merge_branch, base_branch });

    const merge_message = try std.fmt.allocPrint(allocator, "task({s}): merge", .{task_id});
    defer allocator.free(merge_message);

    const merge_capture = try runGitCapture(allocator, cwd, &[_][]const u8{ "merge", "--no-ff", head_branch, "-m", merge_message });
    defer allocator.free(merge_capture.stdout);
    defer allocator.free(merge_capture.stderr);

    if (!utils.isExitedZero(merge_capture.term)) {
        runGitBestEffort(allocator, cwd, &[_][]const u8{ "merge", "--abort" });

        var detail = std.ArrayList(u8).empty;
        defer detail.deinit(allocator);
        try detail.appendSlice(allocator, std.mem.trim(u8, merge_capture.stdout, " \t\r\n"));
        if (merge_capture.stderr.len > 0) {
            if (detail.items.len > 0) try detail.appendSlice(allocator, "\n");
            try detail.appendSlice(allocator, std.mem.trim(u8, merge_capture.stderr, " \t\r\n"));
        }

        const detail_text = if (detail.items.len > 0)
            try detail.toOwnedSlice(allocator)
        else
            try allocator.dupe(u8, "merge conflict");

        return .{ .success = false, .detail = detail_text };
    }

    const merge_commit = try gitRevParse(allocator, cwd, "HEAD");
    errdefer allocator.free(merge_commit);

    const base_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{base_branch});
    defer allocator.free(base_ref);
    try runGitChecked(allocator, cwd, &[_][]const u8{ "update-ref", base_ref, merge_commit, base_sha_before });
    runGitBestEffort(allocator, cwd, &[_][]const u8{ "checkout", "--detach", merge_commit });
    runGitBestEffort(allocator, cwd, &[_][]const u8{ "branch", "-D", merge_branch });
    return .{ .success = true, .merge_commit = merge_commit };
}

/// Squash merge a feature branch into main with file-based locking.
/// Creates a single squashed commit and updates the base branch ref.
/// Returns the merge commit SHA on success.
pub fn squashMerge(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    base_branch: []const u8,
    head_branch: []const u8,
    task_id: []const u8,
) !MergeResult {
    const lock_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".techlead" });
    defer allocator.free(lock_dir);
    try std.fs.cwd().makePath(lock_dir);

    const lock_path = try std.fs.path.join(allocator, &[_][]const u8{ lock_dir, "pool-merge.lock" });
    defer allocator.free(lock_path);

    var lock_file: ?std.fs.File = null;
    defer {
        if (lock_file) |f| f.close();
        std.fs.cwd().deleteFile(lock_path) catch {};
    }

    // Acquire exclusive lock
    while (true) {
        lock_file = std.fs.cwd().createFile(lock_path, .{ .truncate = true, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.Thread.sleep(200 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        break;
    }

    const base_sha_before = try gitRevParse(allocator, cwd, base_branch);
    defer allocator.free(base_sha_before);

    const merge_branch_component = try sanitizeBranchComponent(allocator, task_id);
    defer allocator.free(merge_branch_component);
    const merge_branch = try std.fmt.allocPrint(allocator, "pool/squash-{s}", .{merge_branch_component});
    defer allocator.free(merge_branch);
    runGitBestEffort(allocator, cwd, &[_][]const u8{ "branch", "-D", merge_branch });

    try runGitChecked(allocator, cwd, &[_][]const u8{ "checkout", "-B", merge_branch, base_branch });

    const merge_message = try std.fmt.allocPrint(allocator, "task({s}): squash merge", .{task_id});
    defer allocator.free(merge_message);

    const merge_capture = try runGitCapture(allocator, cwd, &[_][]const u8{ "merge", "--squash", head_branch });
    defer allocator.free(merge_capture.stdout);
    defer allocator.free(merge_capture.stderr);

    if (!utils.isExitedZero(merge_capture.term)) {
        runGitBestEffort(allocator, cwd, &[_][]const u8{ "merge", "--abort" });
        runGitBestEffort(allocator, cwd, &[_][]const u8{ "checkout", base_branch });
        runGitBestEffort(allocator, cwd, &[_][]const u8{ "branch", "-D", merge_branch });

        var detail = std.ArrayList(u8).empty;
        defer detail.deinit(allocator);
        try detail.appendSlice(allocator, std.mem.trim(u8, merge_capture.stdout, " \t\r\n"));
        if (merge_capture.stderr.len > 0) {
            if (detail.items.len > 0) try detail.appendSlice(allocator, "\n");
            try detail.appendSlice(allocator, std.mem.trim(u8, merge_capture.stderr, " \t\r\n"));
        }

        const detail_text = if (detail.items.len > 0)
            try detail.toOwnedSlice(allocator)
        else
            try allocator.dupe(u8, "merge conflict");

        return .{ .success = false, .detail = detail_text };
    }

    // Commit the squashed changes
    const commit_capture = try runGitCapture(allocator, cwd, &[_][]const u8{ "commit", "-m", merge_message });
    defer allocator.free(commit_capture.stdout);
    defer allocator.free(commit_capture.stderr);

    if (!utils.isExitedZero(commit_capture.term)) {
        runGitBestEffort(allocator, cwd, &[_][]const u8{ "reset", "--hard", base_branch });
        runGitBestEffort(allocator, cwd, &[_][]const u8{ "checkout", base_branch });
        runGitBestEffort(allocator, cwd, &[_][]const u8{ "branch", "-D", merge_branch });

        const detail_text = if (commit_capture.stderr.len > 0)
            try allocator.dupe(u8, std.mem.trim(u8, commit_capture.stderr, " \t\r\n"))
        else
            try allocator.dupe(u8, "commit failed after squash");

        return .{ .success = false, .detail = detail_text };
    }

    const merge_commit = try gitRevParse(allocator, cwd, "HEAD");
    errdefer allocator.free(merge_commit);

    const base_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{base_branch});
    defer allocator.free(base_ref);
    try runGitChecked(allocator, cwd, &[_][]const u8{ "update-ref", base_ref, merge_commit, base_sha_before });
    runGitBestEffort(allocator, cwd, &[_][]const u8{ "checkout", "--detach", merge_commit });
    runGitBestEffort(allocator, cwd, &[_][]const u8{ "branch", "-D", merge_branch });
    return .{ .success = true, .merge_commit = merge_commit };
}

// Helper functions

fn sanitizeBranchComponent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0) return allocator.dupe(u8, "task");
    var out = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(out);

    for (raw, 0..) |ch, i| {
        const is_safe = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.';
        out[i] = if (is_safe) ch else '-';
    }
    return out;
}

fn gitRevParse(allocator: std.mem.Allocator, cwd: []const u8, revision: []const u8) ![]u8 {
    return runGitStdout(allocator, cwd, &[_][]const u8{ "rev-parse", revision });
}

fn runGitStdout(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    const cap = try runGitCapture(allocator, cwd, args);
    defer allocator.free(cap.stdout);
    defer allocator.free(cap.stderr);

    if (!utils.isExitedZero(cap.term)) return error.GitCommandFailed;
    return allocator.dupe(u8, std.mem.trim(u8, cap.stdout, " \t\r\n"));
}

fn runGitCapture(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !std.process.Child.RunResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);
    return utils.runCommandCapture(allocator, cwd, argv.items);
}

fn runGitBestEffort(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) void {
    const cap = runGitCapture(allocator, cwd, args) catch return;
    allocator.free(cap.stdout);
    allocator.free(cap.stderr);
}

fn runGitChecked(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const cap = try runGitCapture(allocator, cwd, args);
    defer allocator.free(cap.stdout);
    defer allocator.free(cap.stderr);
    if (!utils.isExitedZero(cap.term)) {
        return error.GitCommandFailed;
    }
}
