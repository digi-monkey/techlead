//! Git Service - Core git operations
//!
//! Provides low-level git commands used by the pool service and other modules.
//! All functions are pure git operations without business logic.

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

/// Get a snippet of the git log for context.
/// Returns the last N commits (up to MAX_GIT_LOG_SNIPPET bytes).
///
/// Parameters:
///   - allocator: Memory allocator for the output string
///   - cwd: Working directory where git command is executed
///   - max_commits: Maximum number of commits to include in the snippet (default: 10)
///
/// Returns: A string containing the formatted git log output
///
/// Errors:
///   - Returns error.GitCommandFailed if git log fails
pub fn getGitLogSnippet(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    max_commits: u32,
) ![]u8 {
    const count = if (max_commits == 0) 10 else max_commits;
    const count_str = try std.fmt.allocPrint(allocator, "{d}", .{count});
    defer allocator.free(count_str);

    const output = runGitStdout(allocator, cwd, &[_][]const u8{
        "--no-pager", "log", "--oneline", "-n", count_str,
    }) catch |err| switch (err) {
        error.GitCommandFailed => return allocator.dupe(u8, "(git log unavailable)"),
        else => return err,
    };

    if (output.len == 0) {
        allocator.free(output);
        return allocator.dupe(u8, "(no commits)");
    }

    if (output.len <= MAX_GIT_LOG_SNIPPET) return output;
    defer allocator.free(output);
    return std.fmt.allocPrint(allocator, "{s}\n...(truncated)", .{output[0..MAX_GIT_LOG_SNIPPET]});
}

/// Create a new git branch from a base branch.
/// The branch name is sanitized to be git-safe.
///
/// Parameters:
///   - allocator: Memory allocator for strings
///   - cwd: Working directory where git command is executed
///   - branch_name: Name for the new branch
///   - base_branch: Branch to create from (e.g., "main")
///   - checkout: If true, checkout the new branch after creation
///
/// Returns: The sanitized branch name that was created
///
/// Errors:
///   - Returns error.GitCommandFailed if branch creation fails
pub fn createBranch(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    branch_name: []const u8,
    base_branch: []const u8,
    checkout: bool,
) ![]u8 {
    const sanitized = try sanitizeBranchComponent(allocator, branch_name);
    errdefer allocator.free(sanitized);

    if (checkout) {
        try runGitChecked(allocator, cwd, &[_][]const u8{ "checkout", "-B", sanitized, base_branch });
    } else {
        try runGitChecked(allocator, cwd, &[_][]const u8{ "branch", sanitized, base_branch });
    }

    return sanitized;
}

/// Squash merge a feature branch into a temporary branch with file-based locking.
/// Creates a single squashed commit without modifying the base branch directly.
/// Uses a lock file to prevent concurrent merge operations.
///
/// Parameters:
///   - allocator: Memory allocator for all dynamic allocations
///   - cwd: Working directory where git commands are executed
///   - base_branch: Target branch to merge into (e.g., "main")
///   - head_branch: Feature branch to merge
///   - task_id: Identifier for the task (used in commit message and lock naming)
///
/// Returns: MergeResult with success flag and optional merge commit SHA
///
/// Errors:
///   - Returns error.GitCommandFailed if any git operation fails
///   - May return filesystem errors for lock operations
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

/// Merge a feature branch into main with file-based locking.
/// Creates a merge commit (--no-ff) and updates the base branch ref.
/// Uses a lock file to prevent concurrent merge operations.
///
/// Parameters:
///   - allocator: Memory allocator for all dynamic allocations
///   - cwd: Working directory where git commands are executed
///   - base_branch: Target branch to merge into (e.g., "main")
///   - head_branch: Feature branch to merge
///   - task_id: Identifier for the task (used in commit message and lock naming)
///
/// Returns: MergeResult with success flag and optional merge commit SHA
///
/// Errors:
///   - Returns error.GitCommandFailed if any git operation fails
///   - May return filesystem errors for lock operations
pub fn mergeWithLock(
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

// Helper functions

/// Sanitize a string to be safe for use in git branch names.
/// Replaces unsafe characters with hyphens.
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

/// Resolve a git revision to its full SHA.
fn gitRevParse(allocator: std.mem.Allocator, cwd: []const u8, revision: []const u8) ![]u8 {
    return runGitStdout(allocator, cwd, &[_][]const u8{ "rev-parse", revision });
}

/// Run a git command and return the stdout output as a trimmed string.
/// Returns error.GitCommandFailed if the command exits non-zero.
fn runGitStdout(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    const cap = try runGitCapture(allocator, cwd, args);
    defer allocator.free(cap.stdout);
    defer allocator.free(cap.stderr);

    if (!utils.isExitedZero(cap.term)) return error.GitCommandFailed;
    return allocator.dupe(u8, std.mem.trim(u8, cap.stdout, " \t\r\n"));
}

/// Run a git command and capture both stdout and stderr.
fn runGitCapture(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !std.process.Child.RunResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);
    return utils.runCommandCapture(allocator, cwd, argv.items);
}

/// Run a git command, ignoring any errors.
fn runGitBestEffort(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) void {
    const cap = runGitCapture(allocator, cwd, args) catch return;
    allocator.free(cap.stdout);
    allocator.free(cap.stderr);
}

/// Run a git command and fail if it exits non-zero.
fn runGitChecked(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const cap = try runGitCapture(allocator, cwd, args);
    defer allocator.free(cap.stdout);
    defer allocator.free(cap.stderr);
    if (!utils.isExitedZero(cap.term)) {
        return error.GitCommandFailed;
    }
}
