const std = @import("std");
const utils = @import("../utils.zig");
const ui = @import("../ui.zig");

/// Relative path to the pool worktree directory within a repository.
///
/// This is the default location where the pool service creates and manages
/// its git worktree for isolated task execution.
pub const POOL_WORKTREE_REL = ".techlead/pool-worktree";

/// Maximum number of bytes to capture from git command output in error logs.
const MAX_GIT_LOG_SNIPPET: usize = 1024;

/// Ensures the pool worktree exists and is properly configured.
///
/// Creates the pool worktree directory if it doesn't exist, or validates
/// an existing worktree. The worktree is set to a detached HEAD state
/// on the specified main branch and cleaned for immediate use.
///
/// Parameters:
/// - allocator: Memory allocator for string operations
/// - repo_dir: Path to the root of the git repository
/// - main_branch: Name of the main branch to checkout (e.g., "main", "master")
///
/// Returns: Allocated string containing the absolute path to the worktree directory.
/// Caller must free the returned memory.
///
/// Errors:
/// - error.PoolWorktreeInvalid: Existing directory is not a valid git worktree
/// - error.GitCommandFailed: A git command failed during setup
/// - Other std.mem.Allocator errors
pub fn ensurePoolWorktree(allocator: std.mem.Allocator, repo_dir: []const u8, main_branch: []const u8) ![]u8 {
    const worktree_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_dir, POOL_WORKTREE_REL });
    errdefer allocator.free(worktree_dir);

    const runtime_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_dir, ".techlead" });
    defer allocator.free(runtime_dir);
    try std.fs.cwd().makePath(runtime_dir);

    if (utils.fileExists(worktree_dir)) {
        if (!isGitWorktree(allocator, worktree_dir)) {
            ui.logError("pool worktree directory exists but is not a valid git worktree: {s}", .{worktree_dir});
            return error.PoolWorktreeInvalid;
        }
    } else {
        try runGitChecked(allocator, repo_dir, &[_][]const u8{ "worktree", "prune" });
        try runGitChecked(allocator, repo_dir, &[_][]const u8{ "worktree", "add", "--force", "--detach", worktree_dir, main_branch });
    }

    try runGitChecked(allocator, worktree_dir, &[_][]const u8{ "checkout", "--detach", main_branch });
    try prepareWorktreeForTask(allocator, worktree_dir);
    return worktree_dir;
}

/// Cleans up the pool worktree directory.
///
/// Removes the git worktree entry and deletes the worktree directory.
/// This is a best-effort operation - failures are logged but not returned.
///
/// Parameters:
/// - allocator: Memory allocator for string operations
/// - repo_dir: Path to the root of the git repository
///
/// Returns: void (always succeeds, failures are silently ignored)
pub fn cleanupWorktree(allocator: std.mem.Allocator, repo_dir: []const u8) void {
    const worktree_dir = std.fs.path.join(allocator, &[_][]const u8{ repo_dir, POOL_WORKTREE_REL }) catch return;
    defer allocator.free(worktree_dir);
    runGitBestEffort(allocator, repo_dir, &[_][]const u8{ "worktree", "remove", "--force", worktree_dir });
    std.fs.cwd().deleteTree(worktree_dir) catch {};
}

/// Prepares a worktree directory for task execution.
///
/// Resets the worktree to a clean state by performing a hard reset to HEAD
/// and cleaning untracked files. Preserves the .techlead directory which may
/// contain runtime data.
///
/// Parameters:
/// - allocator: Memory allocator for string operations
/// - cwd: Path to the worktree directory
///
/// Errors:
/// - error.GitCommandFailed: The git reset or clean command failed
/// - Other std.mem.Allocator errors
pub fn prepareWorktreeForTask(allocator: std.mem.Allocator, cwd: []const u8) !void {
    try runGitChecked(allocator, cwd, &[_][]const u8{ "reset", "--hard", "HEAD" });
    try runGitChecked(allocator, cwd, &[_][]const u8{ "clean", "-fd", "-e", ".techlead", "--", "." });
}

/// Checks if a directory is inside a valid git worktree.
///
/// Runs `git rev-parse --is-inside-work-tree` to verify the directory
/// is part of a git worktree. Returns false if the command fails or
/// returns anything other than "true".
///
/// Parameters:
/// - allocator: Memory allocator for string operations
/// - cwd: Path to the directory to check
///
/// Returns: true if the directory is inside a git worktree, false otherwise
pub fn isGitWorktree(allocator: std.mem.Allocator, cwd: []const u8) bool {
    const cap = runGitCapture(allocator, cwd, &[_][]const u8{ "rev-parse", "--is-inside-work-tree" }) catch return false;
    defer allocator.free(cap.stdout);
    defer allocator.free(cap.stderr);
    if (!utils.isExitedZero(cap.term)) return false;
    const out = std.mem.trim(u8, cap.stdout, " \t\r\n");
    return std.mem.eql(u8, out, "true");
}

/// Creates and checks out a new implementation branch.
///
/// Creates a new branch named `head_branch` starting from `base_branch`
/// and checks it out. Uses `git checkout -B` which creates the branch if
/// it doesn't exist or resets it if it does.
///
/// Parameters:
/// - allocator: Memory allocator for string operations
/// - cwd: Path to the git worktree directory
/// - base_branch: Name of the branch to base the new branch on
/// - head_branch: Name of the new branch to create and checkout
///
/// Errors:
/// - error.GitCommandFailed: The git checkout command failed
/// - Other std.mem.Allocator errors
pub fn checkoutImplementationBranch(allocator: std.mem.Allocator, cwd: []const u8, base_branch: []const u8, head_branch: []const u8) !void {
    try runGitChecked(allocator, cwd, &[_][]const u8{ "checkout", "-B", head_branch, base_branch });
}

/// Collects git context information after a failure.
///
/// Gathers diagnostic information about the current git state including
/// the current branch, status, and staged files. Useful for debugging
/// git command failures.
///
/// Parameters:
/// - allocator: Memory allocator for string operations
/// - cwd: Path to the git worktree directory
///
/// Returns: Allocated string containing context information.
/// Caller must free the returned memory.
///
/// Errors:
/// - Any std.mem.Allocator errors
pub fn collectGitFailureContext(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const branch = runGitStdout(allocator, cwd, &[_][]const u8{ "branch", "--show-current" }) catch try allocator.dupe(u8, "(branch unavailable)");
    defer allocator.free(branch);
    const status = runGitStdout(allocator, cwd, &[_][]const u8{ "status", "--short", "--branch" }) catch try allocator.dupe(u8, "(status unavailable)");
    defer allocator.free(status);
    const staged = runGitStdout(allocator, cwd, &[_][]const u8{ "diff", "--cached", "--name-only" }) catch try allocator.dupe(u8, "(staged unavailable)");
    defer allocator.free(staged);
    const branch_snippet = try trimAndLimit(allocator, branch, 240);
    defer allocator.free(branch_snippet);
    const status_snippet = try trimAndLimit(allocator, status, 800);
    defer allocator.free(status_snippet);
    const staged_snippet = try trimAndLimit(allocator, staged, 800);
    defer allocator.free(staged_snippet);
    return std.fmt.allocPrint(
        allocator,
        "cwd={s}; branch={s}; status={s}; staged={s}",
        .{ cwd, branch_snippet, status_snippet, staged_snippet },
    );
}

/// Runs a git command and fails if the command exits non-zero.
///
/// Executes a git command and returns an error if it fails.
/// On failure, logs detailed error information including the command,
/// working directory, and output snippets.
///
/// Parameters:
/// - allocator: Memory allocator for string operations
/// - cwd: Working directory for the git command
/// - args: Array of git command arguments (e.g., &["status", "--short"])
///
/// Errors:
/// - error.GitCommandFailed: The git command exited with non-zero status
/// - Other errors from runGitCapture or std.mem.Allocator
pub fn runGitChecked(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const cap = try runGitCapture(allocator, cwd, args);
    defer allocator.free(cap.stdout);
    defer allocator.free(cap.stderr);
    if (!utils.isExitedZero(cap.term)) {
        const cmd = try renderGitCommand(allocator, args);
        defer allocator.free(cmd);
        const stdout_snippet = try trimAndLimit(allocator, cap.stdout, MAX_GIT_LOG_SNIPPET);
        defer allocator.free(stdout_snippet);
        const stderr_snippet = try trimAndLimit(allocator, cap.stderr, MAX_GIT_LOG_SNIPPET);
        defer allocator.free(stderr_snippet);

        ui.logError("git command failed: cwd={s} cmd={s} term={any}", .{ cwd, cmd, cap.term });
        if (stdout_snippet.len > 0) ui.logError("git stdout: {s}", .{stdout_snippet});
        if (stderr_snippet.len > 0) ui.logError("git stderr: {s}", .{stderr_snippet});
        return error.GitCommandFailed;
    }
}

/// Runs a git command and captures all output.
///
/// Executes a git command and returns the complete result including
/// stdout, stderr, and exit status. Caller is responsible for freeing
/// the stdout and stderr strings in the returned RunResult.
///
/// Parameters:
/// - allocator: Memory allocator for capturing output
/// - cwd: Working directory for the git command
/// - args: Array of git command arguments
///
/// Returns: std.process.Child.RunResult containing stdout, stderr, and term
/// Caller must free stdout and stderr from the result.
///
/// Errors:
/// - Any errors from std.process.Child.run or std.mem.Allocator
pub fn runGitCapture(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !std.process.Child.RunResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);
    return utils.runCommandCapture(allocator, cwd, argv.items);
}

/// Runs a git command and returns the trimmed stdout output.
///
/// Executes a git command and returns the stdout output as a string,
/// with whitespace trimmed from both ends. Returns an error if the
/// command exits non-zero.
///
/// Parameters:
/// - allocator: Memory allocator for capturing output
/// - cwd: Working directory for the git command
/// - args: Array of git command arguments
///
/// Returns: Allocated string containing trimmed stdout.
/// Caller must free the returned memory.
///
/// Errors:
/// - error.GitCommandFailed: The git command exited with non-zero status
/// - Other errors from runGitCapture or std.mem.Allocator
pub fn runGitStdout(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    const cap = try runGitCapture(allocator, cwd, args);
    defer allocator.free(cap.stdout);
    defer allocator.free(cap.stderr);

    if (!utils.isExitedZero(cap.term)) return error.GitCommandFailed;
    return allocator.dupe(u8, std.mem.trim(u8, cap.stdout, " \t\r\n"));
}

/// Runs a git command and ignores all failures.
///
/// Executes a git command in best-effort mode. Any errors, including
/// command failures or memory allocation issues, are silently ignored.
/// Useful for cleanup operations where failure is acceptable.
///
/// Parameters:
/// - allocator: Memory allocator for capturing output
/// - cwd: Working directory for the git command
/// - args: Array of git command arguments
///
/// Returns: void (always succeeds, failures are silently ignored)
pub fn runGitBestEffort(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) void {
    const cap = runGitCapture(allocator, cwd, args) catch return;
    allocator.free(cap.stdout);
    allocator.free(cap.stderr);
}

/// Resolves a git revision to its full SHA.
///
/// Uses `git rev-parse` to convert any valid git revision (branch name,
/// tag, short SHA, etc.) to its full 40-character SHA hash.
///
/// Parameters:
/// - allocator: Memory allocator for capturing output
/// - cwd: Working directory for the git command
/// - revision: Git revision to resolve (branch name, tag, or SHA)
///
/// Returns: Allocated string containing the full 40-character SHA.
/// Caller must free the returned memory.
///
/// Errors:
/// - error.GitCommandFailed: The revision could not be resolved
/// - Other errors from runGitStdout or std.mem.Allocator
pub fn gitRevParse(allocator: std.mem.Allocator, cwd: []const u8, revision: []const u8) ![]u8 {
    return runGitStdout(allocator, cwd, &[_][]const u8{ "rev-parse", revision });
}

/// Renders git arguments into a human-readable command string.
///
/// Concatenates the git arguments into a single string prefixed with "git".
/// Useful for logging and error messages.
///
/// Parameters:
/// - allocator: Memory allocator for building the string
/// - args: Array of git command arguments
///
/// Returns: Allocated string containing the rendered command.
/// Caller must free the returned memory.
///
/// Errors:
/// - Any std.mem.Allocator errors
pub fn renderGitCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "git");
    for (args) |arg| {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

/// Trims whitespace and limits text length.
///
/// Removes leading and trailing whitespace from the input text.
/// If the text exceeds max_len, truncates it and appends "...(truncated)".
///
/// Parameters:
/// - allocator: Memory allocator for the result string
/// - text: Input text to process
/// - max_len: Maximum length of the output (not including truncation marker)
///
/// Returns: Allocated string containing trimmed and possibly truncated text.
/// Caller must free the returned memory.
///
/// Errors:
/// - Any std.mem.Allocator errors
pub fn trimAndLimit(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    if (trimmed.len <= max_len) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}...(truncated)", .{trimmed[0..max_len]});
}
