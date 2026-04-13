//! Pool Service - Main task orchestration and workflow engine
//!
//! Implements the claim → implement → review → merge workflow:
//! 1. Claims next available task from control plane
//! 2. Runs implement phase via AI provider
//! 3. Runs gate commands (test/lint) if configured
//! 4. Runs correctness review
//! 5. Runs maintainability review
//! 6. Merges to main if approved, or re-queues for retry
//!
//! This module coordinates multiple phases of task execution using
//! the worktree pattern for isolation.

const std = @import("std");
const config = @import("../config.zig");
const ui = @import("../ui.zig");
const utils = @import("../utils.zig");
const event_store = @import("../storage/store.zig");
const task_store = @import("../storage/task_store.zig");
const sqlite_controlplane_store = @import("../storage/sqlite_controlplane_store.zig");
const controlplane_store = @import("../storage/controlplane_store.zig");
const provider_api = @import("../providers/provider.zig");
const result_parser = @import("../pool/result_parser.zig");
const worktree_service = @import("worktree_service.zig");
const task_execution_service = @import("task_execution_service.zig");

const MAX_GIT_LOG_SNIPPET: usize = 1024;

/// Final disposition of a task after processing
const TaskOutcome = enum {
    /// Task completed successfully and was merged
    done,
    /// Task was re-queued for another attempt (changes requested, gate failure, or transient error)
    requeued,
    /// Task failed permanently and will not be retried
    failed,
};

const MergeResult = struct {
    success: bool,
    merge_commit: ?[]u8 = null,
    detail: ?[]u8 = null,

    fn deinit(self: *MergeResult, allocator: std.mem.Allocator) void {
        if (self.merge_commit) |v| allocator.free(v);
        if (self.detail) |v| allocator.free(v);
    }
};

/// Main entry point for the pool service task processing loop.
///
/// Runs an infinite loop that continuously claims and processes tasks from the
/// control plane. Each task goes through the full workflow: implement, gate checks,
/// correctness review, maintainability review, and merge.
///
/// Parameters:
///   - cfg: Application configuration including work directory, branch names, and pool settings
///   - allocator: Memory allocator for all dynamic allocations
///   - provider: AI provider implementation for running prompts (anytype for polymorphism)
///   - provider_name: Name of the AI provider for logging purposes
///   - primary_es: Primary event store for recording run events
///   - mirror_es: Optional secondary event store for event mirroring/redundancy
///   - run_id: Unique identifier for this pool service run instance
///   - project_test_cmd: Optional shell command to run tests (gate check)
///   - project_lint_cmd: Optional shell command to run linting (gate check)
///
/// Returns: void on successful operation (never returns normally due to infinite loop)
///
/// Errors:
///   - Returns errors from git operations, provider failures, or control plane issues.
///     Individual task failures are handled internally and do not cause the function to return.
pub fn run(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    provider: anytype,
    provider_name: []const u8,
    primary_es: event_store.EventStore,
    mirror_es: ?event_store.EventStore,
    run_id: []const u8,
    project_test_cmd: ?[]const u8,
    project_lint_cmd: ?[]const u8,
) !void {
    const pool_work_dir = try worktree_service.ensurePoolWorktree(allocator, cfg.work_dir, cfg.main_branch);
    defer allocator.free(pool_work_dir);

    var pool_cfg = cfg;
    pool_cfg.work_dir = pool_work_dir;
    ui.logInfo("pool 使用 git worktree: {s}", .{pool_cfg.work_dir});

    // Extract project_id from original work_dir for controlplane store operations
    // cfg.work_dir here is the original project directory (e.g., /tmp/test-repos/p-limit)
    // NOT the pool worktree (that's pool_cfg.work_dir)
    const project_id = std.fs.path.basename(cfg.work_dir);
    ui.logInfo("pool project_id: {s}", .{project_id});

    var sqlite = try sqlite_controlplane_store.SqliteControlPlaneStore.init(allocator);
    defer sqlite.deinit();
    const cps = sqlite.asControlPlaneStore();

    while (true) {
        const claimed_task = try cps.claimNext(.{
            .owner = run_id,
            .lease_seconds = cfg.pool_lease_seconds,
            .default_max_retries = cfg.pool_max_retries,
        }, allocator);
        if (claimed_task == null) {
            std.Thread.sleep(2 * std.time.ns_per_s);
            continue;
        }

        var task = claimed_task.?;
        defer task.deinit(allocator);

        var claim_buf: [384]u8 = undefined;
        const claim_payload = std.fmt.bufPrint(
            &claim_buf,
            "{{\"task_id\":{f},\"status\":\"claimed\",\"lease_until\":{d},\"retry_count\":{d}}}",
            .{ std.json.fmt(task.task_id, .{}), task.lease_until orelse 0, task.retry_count },
        ) catch "{\"status\":\"claimed\"}";
        appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "task.claimed", claim_payload);

        const outcome = processClaimedTask(pool_cfg, allocator, provider, provider_name, run_id, cps, &task, project_test_cmd, project_lint_cmd, project_id) catch |err| blk: {
            const err_msg = @errorName(err);
            const git_context = if (err == error.GitCommandFailed)
                collectGitFailureContext(allocator, pool_cfg.work_dir) catch try allocator.dupe(u8, "(git context unavailable)")
            else
                try allocator.dupe(u8, "");
            defer allocator.free(git_context);

            const detailed_msg = if (git_context.len == 0)
                try std.fmt.allocPrint(
                    allocator,
                    "task processing failed: phase=processClaimedTask error={s} task_id={s}",
                    .{ err_msg, task.task_id },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "task processing failed: phase=processClaimedTask error={s} task_id={s} git_context={s}",
                    .{ err_msg, task.task_id, git_context },
                );
            defer allocator.free(detailed_msg);

            ui.logError("pool task {s} failed: {s}", .{ task.task_id, detailed_msg });

            // Log detailed error event to task_events table
            logTaskError(allocator, cps, task.task_id, run_id, "processClaimedTask", err, detailed_msg);

            // Also log to run events for backward compatibility
            var error_payload_buf: [512]u8 = undefined;
            const error_payload = std.fmt.bufPrint(
                &error_payload_buf,
                "{{\"task_id\":{f},\"phase\":\"processClaimedTask\",\"error\":{f},\"error_type\":{f}}}",
                .{ std.json.fmt(task.task_id, .{}), std.json.fmt(err_msg, .{}), std.json.fmt(err_msg, .{}) },
            ) catch "{\"status\":\"error\"}";
            appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "task.error", error_payload);

            _ = try cps.markFailedOrRequeue(project_id, task.task_id, run_id, run_id, detailed_msg, cfg.pool_max_retries);
            break :blk null;
        };

        if (outcome == null) continue;

        switch (outcome.?) {
            .done => {
                var done_buf: [256]u8 = undefined;
                const done_payload = std.fmt.bufPrint(&done_buf, "{{\"task_id\":{f},\"status\":\"done\"}}", .{std.json.fmt(task.task_id, .{})}) catch "{\"status\":\"done\"}";
                appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "task.done", done_payload);
            },
            .requeued => {
                var req_buf: [256]u8 = undefined;
                const req_payload = std.fmt.bufPrint(&req_buf, "{{\"task_id\":{f},\"status\":\"queued\"}}", .{std.json.fmt(task.task_id, .{})}) catch "{\"status\":\"queued\"}";
                appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "task.requeued", req_payload);
            },
            .failed => {
                var failed_buf: [256]u8 = undefined;
                const failed_payload = std.fmt.bufPrint(&failed_buf, "{{\"task_id\":{f},\"status\":\"failed\"}}", .{std.json.fmt(task.task_id, .{})}) catch "{\"status\":\"failed\"}";
                appendRunEvent(primary_es, mirror_es, run_id, .scheduler, "task.failed", failed_payload);
            },
        }
    }
}

fn processClaimedTask(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    provider: anytype,
    provider_name: []const u8,
    run_id: []const u8,
    cps: controlplane_store.ControlPlaneStore,
    task: *task_store.Task,
    project_test_cmd: ?[]const u8,
    project_lint_cmd: ?[]const u8,
    project_id: []const u8,
) !TaskOutcome {
    try cps.markRunning(project_id, task.task_id, run_id, cfg.pool_lease_seconds, run_id);
    try worktree_service.prepareWorktreeForTask(allocator, cfg.work_dir);

    const review_round = task.review_round + 1;
    const base_branch = cfg.main_branch;
    const head_branch = try buildHeadBranch(allocator, task.task_id, review_round);
    defer allocator.free(head_branch);

    try worktree_service.checkoutImplementationBranch(allocator, cfg.work_dir, base_branch, head_branch);
    const base_sha = try worktree_service.gitRevParse(allocator, cfg.work_dir, base_branch);
    defer allocator.free(base_sha);

    var implement_result = try task_execution_service.runImplementPhase(cfg, allocator, provider, provider_name, task, base_branch, head_branch, review_round);
    defer implement_result.deinit(allocator);

    if (implement_result.status != .implemented) {
        ui.logWarn("task {s} implement phase blocked: status={s} summary={s}", .{ task.task_id, @tagName(implement_result.status), implement_result.summary });
        const blocked_msg = try std.fmt.allocPrint(
            allocator,
            "implement blocked (status={s}): {s}",
            .{ @tagName(implement_result.status), implement_result.summary },
        );
        defer allocator.free(blocked_msg);
        const fail_result = try cps.markFailedOrRequeue(project_id, task.task_id, run_id, run_id, blocked_msg, cfg.pool_max_retries);
        return failResultToOutcome(fail_result);
    }

    try ensureImplementationCommit(allocator, cfg.work_dir, task.task_id, review_round);

    const head_sha = try worktree_service.gitRevParse(allocator, cfg.work_dir, "HEAD");
    defer allocator.free(head_sha);
    if (std.mem.eql(u8, base_sha, head_sha)) {
        ui.logWarn("task {s} no commit produced: base_sha equals head_sha", .{task.task_id});
        return error.NoCommitProduced;
    }

    try cps.markReviewOpen(project_id, task.task_id, run_id, run_id, review_round, base_branch, head_branch, head_sha);

    // Run gate commands (test_cmd and lint_cmd) before review
    if (project_test_cmd) |test_cmd| {
        ui.logInfo("task {s} running test_cmd: {s}", .{ task.task_id, test_cmd });
        var gate_result = try task_execution_service.runGateCommand(allocator, cfg.work_dir, test_cmd);
        defer gate_result.deinit(allocator);
        if (!gate_result.success) {
            const feedback = gate_result.output orelse "test_cmd failed";
            ui.logError("task {s} test_cmd failed: {s}", .{ task.task_id, feedback });
            const retry_result = try cps.markReviewChangesRequestedAndRequeue(
                project_id,
                task.task_id,
                run_id,
                run_id,
                review_round,
                feedback,
                "test_gate_blocked",
                cfg.pool_max_retries,
            );
            return failResultToOutcome(retry_result);
        }
    }

    if (project_lint_cmd) |lint_cmd| {
        ui.logInfo("task {s} running lint_cmd: {s}", .{ task.task_id, lint_cmd });
        var gate_result = try task_execution_service.runGateCommand(allocator, cfg.work_dir, lint_cmd);
        defer gate_result.deinit(allocator);
        if (!gate_result.success) {
            const feedback = gate_result.output orelse "lint_cmd failed";
            ui.logError("task {s} lint_cmd failed: {s}", .{ task.task_id, feedback });
            const retry_result = try cps.markReviewChangesRequestedAndRequeue(
                project_id,
                task.task_id,
                run_id,
                run_id,
                review_round,
                feedback,
                "lint_gate_blocked",
                cfg.pool_max_retries,
            );
            return failResultToOutcome(retry_result);
        }
    }

    const diff_summary = try collectDiffSummary(allocator, cfg.work_dir, base_branch, head_branch);
    defer allocator.free(diff_summary);

    var correctness = task_execution_service.runReviewPhase(
        cfg,
        allocator,
        provider,
        provider_name,
        task,
        base_branch,
        head_branch,
        diff_summary,
        .review_correctness,
        review_round,
    ) catch |err| {
        const err_name = @errorName(err);
        ui.logError("task {s} correctness review failed: error={s} round={d}", .{ task.task_id, err_name, review_round });
        logTaskError(allocator, cps, task.task_id, run_id, "runReviewPhase.correctness", err, @errorName(err));

        const feedback = try std.fmt.allocPrint(allocator, "correctness review failed: error={s}", .{err_name});
        defer allocator.free(feedback);
        const retry_result = try cps.markReviewChangesRequestedAndRequeue(
            project_id,
            task.task_id,
            run_id,
            run_id,
            review_round,
            feedback,
            "review_failed",
            cfg.pool_max_retries,
        );
        return failResultToOutcome(retry_result);
    };
    defer correctness.deinit(allocator);

    try cps.createTaskReview(project_id, .{
        .task_id = task.task_id,
        .review_round = review_round,
        .role = correctness.role,
        .verdict = correctness.verdict,
        .score = correctness.score,
        .summary = correctness.summary,
        .blockers_json = correctness.blockers_json,
        .suggestions_json = correctness.suggestions_json,
        .confidence = correctness.confidence,
        .reviewer_run_id = run_id,
    });

    var maintainability = task_execution_service.runReviewPhase(
        cfg,
        allocator,
        provider,
        provider_name,
        task,
        base_branch,
        head_branch,
        diff_summary,
        .review_maintainability,
        review_round,
    ) catch |err| {
        const err_name = @errorName(err);
        ui.logError("task {s} maintainability review failed: error={s} round={d}", .{ task.task_id, err_name, review_round });
        logTaskError(allocator, cps, task.task_id, run_id, "runReviewPhase.maintainability", err, @errorName(err));

        const feedback = try std.fmt.allocPrint(allocator, "maintainability review failed: error={s}", .{err_name});
        defer allocator.free(feedback);
        const retry_result = try cps.markReviewChangesRequestedAndRequeue(
            project_id,
            task.task_id,
            run_id,
            run_id,
            review_round,
            feedback,
            "review_failed",
            cfg.pool_max_retries,
        );
        return failResultToOutcome(retry_result);
    };
    defer maintainability.deinit(allocator);

    try cps.createTaskReview(project_id, .{
        .task_id = task.task_id,
        .review_round = review_round,
        .role = maintainability.role,
        .verdict = maintainability.verdict,
        .score = maintainability.score,
        .summary = maintainability.summary,
        .blockers_json = maintainability.blockers_json,
        .suggestions_json = maintainability.suggestions_json,
        .confidence = maintainability.confidence,
        .reviewer_run_id = run_id,
    });

    // Check qa_force_reject_once: first round always returns changes_requested
    if (task.qa_force_reject_once and review_round == 1) {
        ui.logInfo("task {s} qa_force_reject_once triggered: forcing changes_requested for round 1", .{task.task_id});
        const feedback = "qa_force_reject_once: automatic changes requested for testing purposes";
        const retry_result = try cps.markReviewChangesRequestedAndRequeue(
            project_id,
            task.task_id,
            run_id,
            run_id,
            review_round,
            feedback,
            "qa_force_reject_once",
            cfg.pool_max_retries,
        );
        return failResultToOutcome(retry_result);
    }

    if (shouldRequestChanges(
        correctness.verdict,
        maintainability.verdict,
        maintainability.score,
        correctness.suggestions_json,
        maintainability.suggestions_json,
    )) {
        const feedback = try aggregateReviewFeedback(allocator, correctness, maintainability);
        defer allocator.free(feedback);
        const retry_result = try cps.markReviewChangesRequestedAndRequeue(
            project_id,
            task.task_id,
            run_id,
            run_id,
            review_round,
            feedback,
            "review_gate_blocked",
            cfg.pool_max_retries,
        );
        return failResultToOutcome(retry_result);
    }

    try cps.markReviewApproved(project_id, task.task_id, run_id, run_id, review_round);

    var merge_result = try mergeWithLock(allocator, cfg.work_dir, base_branch, head_branch, task.task_id);
    defer merge_result.deinit(allocator);
    if (!merge_result.success) {
        const feedback = merge_result.detail orelse "merge_failed";
        ui.logError("task {s} merge failed: {s} round={d}", .{ task.task_id, feedback, review_round });
        const retry_result = try cps.markReviewChangesRequestedAndRequeue(
            project_id,
            task.task_id,
            run_id,
            run_id,
            review_round,
            feedback,
            "merge_failed",
            cfg.pool_max_retries,
        );
        return failResultToOutcome(retry_result);
    }

    try cps.markMergedDone(project_id, task.task_id, run_id, run_id, review_round, merge_result.merge_commit.?);
    return .done;
}

fn aggregateReviewFeedback(allocator: std.mem.Allocator, correctness: task_execution_service.ReviewResult, maintainability: task_execution_service.ReviewResult) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "correctness verdict={s}\nsummary={s}\nblockers={s}\nsuggestions={s}\n\nmaintainability verdict={s}, score={any}\nsummary={s}\nblockers={s}\nsuggestions={s}",
        .{
            task_store.taskReviewVerdictToString(correctness.verdict),
            correctness.summary,
            correctness.blockers_json,
            correctness.suggestions_json,
            task_store.taskReviewVerdictToString(maintainability.verdict),
            maintainability.score,
            maintainability.summary,
            maintainability.blockers_json,
            maintainability.suggestions_json,
        },
    );
}

fn buildHeadBranch(allocator: std.mem.Allocator, task_id: []const u8, review_round: u32) ![]u8 {
    const sanitized = try sanitizeBranchComponent(allocator, task_id);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "task/{s}/r{d}", .{ sanitized, review_round });
}

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

fn collectDiffSummary(allocator: std.mem.Allocator, cwd: []const u8, base_branch: []const u8, head_branch: []const u8) ![]u8 {
    const revspec = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base_branch, head_branch });
    defer allocator.free(revspec);

    const output = worktree_service.runGitStdout(allocator, cwd, &[_][]const u8{ "--no-pager", "diff", "--stat", revspec }) catch |err| switch (err) {
        error.GitCommandFailed => return allocator.dupe(u8, "(diff unavailable)"),
        else => return err,
    };
    if (output.len == 0) {
        allocator.free(output);
        return allocator.dupe(u8, "(no diff)");
    }

    if (output.len <= 4000) return output;
    defer allocator.free(output);
    return std.fmt.allocPrint(allocator, "{s}\n...(truncated)", .{output[0..4000]});
}

fn ensureImplementationCommit(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    task_id: []const u8,
    review_round: u32,
) !void {
    const status_output = try worktree_service.runGitStdout(allocator, cwd, &[_][]const u8{ "status", "--porcelain" });
    defer allocator.free(status_output);
    if (status_output.len == 0) return;

    // Stage changed tracked/untracked/deleted files one-by-one to avoid
    // `git add .` failures caused by ignored runtime dirs (e.g. `.techlead`).
    try stageEligibleWorkspaceChanges(allocator, cwd);

    const staged_output = try worktree_service.runGitStdout(allocator, cwd, &[_][]const u8{ "diff", "--cached", "--name-only" });
    defer allocator.free(staged_output);
    if (staged_output.len == 0) return;

    const message = try std.fmt.allocPrint(allocator, "task({s}): implement round {d}", .{ task_id, review_round });
    defer allocator.free(message);
    try worktree_service.runGitChecked(allocator, cwd, &[_][]const u8{ "commit", "-m", message });
}

fn stageEligibleWorkspaceChanges(allocator: std.mem.Allocator, cwd: []const u8) !void {
    const changed = try worktree_service.runGitStdout(allocator, cwd, &[_][]const u8{ "ls-files", "-m", "-o", "-d", "--exclude-standard" });
    defer allocator.free(changed);
    if (changed.len == 0) return;

    var it = std.mem.splitScalar(u8, changed, '\n');
    while (it.next()) |line_raw| {
        const path = std.mem.trim(u8, line_raw, " \t\r\n");
        if (path.len == 0) continue;
        if (shouldSkipAutoStage(path)) continue;
        try worktree_service.runGitChecked(allocator, cwd, &[_][]const u8{ "add", "--", path });
    }
}

fn shouldSkipAutoStage(path: []const u8) bool {
    if (std.mem.eql(u8, path, ".techlead") or std.mem.startsWith(u8, path, ".techlead/")) return true;
    if (std.mem.eql(u8, path, "node_modules") or std.mem.startsWith(u8, path, "node_modules/")) return true;
    return std.mem.indexOf(u8, path, "/node_modules/") != null;
}

fn mergeWithLock(
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

    const base_sha_before = try worktree_service.gitRevParse(allocator, cwd, base_branch);
    defer allocator.free(base_sha_before);

    const merge_branch_component = try sanitizeBranchComponent(allocator, task_id);
    defer allocator.free(merge_branch_component);
    const merge_branch = try std.fmt.allocPrint(allocator, "pool/merge-{s}", .{merge_branch_component});
    defer allocator.free(merge_branch);
    worktree_service.runGitBestEffort(allocator, cwd, &[_][]const u8{ "branch", "-D", merge_branch });

    try worktree_service.runGitChecked(allocator, cwd, &[_][]const u8{ "checkout", "-B", merge_branch, base_branch });

    const merge_message = try std.fmt.allocPrint(allocator, "task({s}): merge", .{task_id});
    defer allocator.free(merge_message);

    const merge_capture = try worktree_service.runGitCapture(allocator, cwd, &[_][]const u8{ "merge", "--no-ff", head_branch, "-m", merge_message });
    defer allocator.free(merge_capture.stdout);
    defer allocator.free(merge_capture.stderr);

    if (!utils.isExitedZero(merge_capture.term)) {
        worktree_service.runGitBestEffort(allocator, cwd, &[_][]const u8{ "merge", "--abort" });

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

    const merge_commit = try worktree_service.gitRevParse(allocator, cwd, "HEAD");
    errdefer allocator.free(merge_commit);

    const base_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{base_branch});
    defer allocator.free(base_ref);
    try worktree_service.runGitChecked(allocator, cwd, &[_][]const u8{ "update-ref", base_ref, merge_commit, base_sha_before });
    worktree_service.runGitBestEffort(allocator, cwd, &[_][]const u8{ "checkout", "--detach", merge_commit });
    worktree_service.runGitBestEffort(allocator, cwd, &[_][]const u8{ "branch", "-D", merge_branch });
    return .{ .success = true, .merge_commit = merge_commit };
}

fn collectGitFailureContext(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const branch = worktree_service.runGitStdout(allocator, cwd, &[_][]const u8{ "branch", "--show-current" }) catch try allocator.dupe(u8, "(branch unavailable)");
    defer allocator.free(branch);
    const status = worktree_service.runGitStdout(allocator, cwd, &[_][]const u8{ "status", "--short", "--branch" }) catch try allocator.dupe(u8, "(status unavailable)");
    defer allocator.free(status);
    const staged = worktree_service.runGitStdout(allocator, cwd, &[_][]const u8{ "diff", "--cached", "--name-only" }) catch try allocator.dupe(u8, "(staged unavailable)");
    defer allocator.free(staged);
    const branch_snippet = try worktree_service.trimAndLimit(allocator, branch, 240);
    defer allocator.free(branch_snippet);
    const status_snippet = try worktree_service.trimAndLimit(allocator, status, 800);
    defer allocator.free(status_snippet);
    const staged_snippet = try worktree_service.trimAndLimit(allocator, staged, 800);
    defer allocator.free(staged_snippet);
    return std.fmt.allocPrint(
        allocator,
        "cwd={s}; branch={s}; status={s}; staged={s}",
        .{ cwd, branch_snippet, status_snippet, staged_snippet },
    );
}

fn appendRunEvent(
    primary_es: event_store.EventStore,
    mirror_es: ?event_store.EventStore,
    run_id: []const u8,
    source: event_store.EventSource,
    event_type: []const u8,
    payload: []const u8,
) void {
    const e: event_store.Event = .{
        .run_id = run_id,
        .source = source,
        .event_type = event_type,
        .ts = std.time.timestamp(),
        .payload = payload,
    };
    primary_es.appendEvent(e) catch {};
    if (mirror_es) |mirror| {
        mirror.appendEvent(e) catch {};
    }
}

fn shouldRequestChanges(
    correctness_verdict: task_store.TaskReviewVerdict,
    maintainability_verdict: task_store.TaskReviewVerdict,
    maintainability_score: ?i32,
    _: []const u8,
    _: []const u8,
) bool {
    const score = maintainability_score orelse 0;
    return correctness_verdict != .approve or maintainability_verdict != .approve or score < 3;
}

fn failResultToOutcome(result: task_store.FailResult) TaskOutcome {
    return if (result.status == .failed) .failed else .requeued;
}

test "review gate approves when both approve and score >= 3" {
    try std.testing.expect(!shouldRequestChanges(.approve, .approve, 3, "[]", "[]"));
    try std.testing.expect(!shouldRequestChanges(.approve, .approve, 5, "[]", "[]"));
}

test "review gate requests changes when any verdict is not approve" {
    try std.testing.expect(shouldRequestChanges(.request_changes, .approve, 5, "[]", "[]"));
    try std.testing.expect(shouldRequestChanges(.approve, .block, 5, "[]", "[]"));
}

test "review gate requests changes when maintainability score < 3" {
    try std.testing.expect(shouldRequestChanges(.approve, .approve, 2, "[]", "[]"));
    try std.testing.expect(shouldRequestChanges(.approve, .approve, null, "[]", "[]"));
}

test "review gate approves with suggestions when verdicts and score are OK" {
    try std.testing.expect(!shouldRequestChanges(.approve, .approve, 5, "[\"improve naming\"]", "[]"));
    try std.testing.expect(!shouldRequestChanges(.approve, .approve, 5, "[]", "[\"extract helper\"]"));
}

test "parseReviewJsonMeta requires blockers suggestions confidence fields" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.ResultJsonMissingBlockers,
        task_execution_service.parseReviewJsonMeta(allocator, "{\"summary\":\"ok\",\"suggestions\":[],\"confidence\":0.7}"),
    );
    try std.testing.expectError(
        error.ResultJsonMissingSuggestions,
        task_execution_service.parseReviewJsonMeta(allocator, "{\"summary\":\"ok\",\"blockers\":[],\"confidence\":0.7}"),
    );
    try std.testing.expectError(
        error.ResultJsonMissingConfidence,
        task_execution_service.parseReviewJsonMeta(allocator, "{\"summary\":\"ok\",\"blockers\":[],\"suggestions\":[]}"),
    );
}

test "parseReviewJsonMeta requires array types for blockers and suggestions" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.ResultJsonBlockersNotArray,
        task_execution_service.parseReviewJsonMeta(allocator, "{\"blockers\":{},\"suggestions\":[],\"confidence\":0.8}"),
    );
    try std.testing.expectError(
        error.ResultJsonSuggestionsNotArray,
        task_execution_service.parseReviewJsonMeta(allocator, "{\"blockers\":[],\"suggestions\":{},\"confidence\":0.8}"),
    );
}

test "parseReviewJsonMeta parses valid object" {
    const allocator = std.testing.allocator;
    var meta = try task_execution_service.parseReviewJsonMeta(
        allocator,
        "{\"blockers\":[],\"suggestions\":[\"a\"],\"confidence\":0.75}",
    );
    defer meta.deinit(allocator);

    try std.testing.expectEqualStrings("[]", meta.blockers_json);
    try std.testing.expectEqualStrings("[\"a\"]", meta.suggestions_json);
    try std.testing.expectApproxEqRel(@as(f64, 0.75), meta.confidence.?, 1e-9);
}

fn logTaskError(
    allocator: std.mem.Allocator,
    cps: controlplane_store.ControlPlaneStore,
    task_id: []const u8,
    run_id: []const u8,
    phase: []const u8,
    err: anyerror,
    details: ?[]const u8,
) void {
    _ = allocator;
    _ = cps;
    _ = run_id;
    const err_msg = @errorName(err);
    const detail_str = details orelse "";
    ui.logError(
        "task error: task_id={s} phase={s} error={s} details={s}",
        .{ task_id, phase, err_msg, detail_str },
    );
}

const E2EScenario = enum {
    approve_and_merge,
    approve_and_merge_without_commit,
    low_score_requeue,
    suggestion_requeue_then_approve,
    merge_conflict_requeue,
};

const MockPoolProvider = struct {
    scenario: E2EScenario,
    base_diverged: bool = false,
    maintainability_calls: u32 = 0,

    pub fn runPrompt(
        self: *MockPoolProvider,
        cfg: config.Config,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        log_label: []const u8,
    ) !provider_api.ExecutionResult {
        _ = prompt;

        if (std.mem.endsWith(u8, log_label, "implement")) {
            try writeRepoFile(allocator, cfg.work_dir, "src.txt", "head-change\n");
            if (self.scenario != .approve_and_merge_without_commit) {
                try worktree_service.runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "add", "src.txt" });
                try worktree_service.runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "commit", "-m", "implement commit" });
            }
            try writeMockLog(allocator, cfg, log_label, "RESULT_JSON: {\"role\":\"implementer\",\"status\":\"implemented\",\"summary\":\"implemented\"}\n");
            return .{ .success = true };
        }

        if (std.mem.endsWith(u8, log_label, "correctness")) {
            try writeMockLog(allocator, cfg, log_label, "RESULT_JSON: {\"role\":\"correctness_reviewer\",\"verdict\":\"approve\",\"summary\":\"ok\",\"blockers\":[],\"suggestions\":[],\"confidence\":0.9}\n");
            return .{ .success = true };
        }

        if (std.mem.endsWith(u8, log_label, "maintainability")) {
            if (self.scenario == .merge_conflict_requeue and !self.base_diverged) {
                const head_branch = try worktree_service.runGitStdout(allocator, cfg.work_dir, &[_][]const u8{ "branch", "--show-current" });
                defer allocator.free(head_branch);

                try worktree_service.runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "checkout", cfg.main_branch });
                try writeRepoFile(allocator, cfg.work_dir, "src.txt", "base-change\n");
                try worktree_service.runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "add", "src.txt" });
                try worktree_service.runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "commit", "-m", "base conflict change" });
                try worktree_service.runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "checkout", head_branch });
                self.base_diverged = true;
            }

            const score: i32 = blk: {
                if (self.scenario == .low_score_requeue) break :blk 2;
                if (self.scenario == .suggestion_requeue_then_approve and self.maintainability_calls == 0) break :blk 2;
                break :blk 4;
            };
            const suggestions: []const u8 = blk: {
                if (self.scenario == .suggestion_requeue_then_approve and self.maintainability_calls == 0) {
                    break :blk "[\"please refine\"]";
                }
                break :blk "[]";
            };
            self.maintainability_calls += 1;
            const log_line = try std.fmt.allocPrint(
                allocator,
                "RESULT_JSON: {{\"role\":\"maintainability_reviewer\",\"verdict\":\"approve\",\"score\":{d},\"summary\":\"ok\",\"blockers\":[],\"suggestions\":{s},\"confidence\":0.9}}\n",
                .{ score, suggestions },
            );
            defer allocator.free(log_line);
            try writeMockLog(allocator, cfg, log_label, log_line);
            return .{ .success = true };
        }

        return .{ .success = false };
    }
};

test "pool e2e: approve -> merge -> done" {
    const allocator = std.testing.allocator;
    var setup = try setupPoolE2E(allocator);
    defer setup.deinit();

    var mock = MockPoolProvider{ .scenario = .approve_and_merge };
    const outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.done, outcome);

    const detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.project_id, "task-e2e", allocator);
    defer allocator.free(detail_json);
    try expectTaskState(detail_json, "done", "merged");
}

test "pool e2e: implement writes uncommitted changes -> auto-commit -> done" {
    const allocator = std.testing.allocator;
    var setup = try setupPoolE2E(allocator);
    defer setup.deinit();

    var mock = MockPoolProvider{ .scenario = .approve_and_merge_without_commit };
    const outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.done, outcome);

    const detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.project_id, "task-e2e", allocator);
    defer allocator.free(detail_json);
    try expectTaskState(detail_json, "done", "merged");
}

test "pool e2e: maintainability score=2 -> changes_requested -> queued" {
    const allocator = std.testing.allocator;
    var setup = try setupPoolE2E(allocator);
    defer setup.deinit();

    var mock = MockPoolProvider{ .scenario = .low_score_requeue };
    const outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.requeued, outcome);

    const detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.project_id, "task-e2e", allocator);
    defer allocator.free(detail_json);
    try expectTaskState(detail_json, "queued", "changes_requested");
}

test "pool e2e: suggestion -> changes_requested -> second round done" {
    const allocator = std.testing.allocator;
    var setup = try setupPoolE2E(allocator);
    defer setup.deinit();

    var mock = MockPoolProvider{ .scenario = .suggestion_requeue_then_approve };
    const first_outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.requeued, first_outcome);

    const first_detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.project_id, "task-e2e", allocator);
    defer allocator.free(first_detail_json);
    try expectTaskState(first_detail_json, "queued", "changes_requested");

    const second_outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.done, second_outcome);

    const second_detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.project_id, "task-e2e", allocator);
    defer allocator.free(second_detail_json);
    try expectTaskState(second_detail_json, "done", "merged");
}

test "pool e2e: merge conflict -> changes_requested -> queued" {
    const allocator = std.testing.allocator;
    var setup = try setupPoolE2E(allocator);
    defer setup.deinit();

    var mock = MockPoolProvider{ .scenario = .merge_conflict_requeue };
    const outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.requeued, outcome);

    const detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.project_id, "task-e2e", allocator);
    defer allocator.free(detail_json);
    try expectTaskState(detail_json, "queued", "changes_requested");
}

const PoolE2ESetup = struct {
    cfg: config.Config,
    store: sqlite_controlplane_store.SqliteControlPlaneStore,
    work_dir: []u8,
    project_id: []const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *PoolE2ESetup) void {
        self.store.deinit();
        config.deinitConfig(self.allocator, &self.cfg);
        std.fs.cwd().deleteTree(self.work_dir) catch {};
        self.allocator.free(self.work_dir);
    }
};

fn setupPoolE2E(allocator: std.mem.Allocator) !PoolE2ESetup {
    const work_dir = try std.fmt.allocPrint(
        allocator,
        "/tmp/techlead-pool-e2e-{d}-{d}",
        .{ std.time.timestamp(), std.crypto.random.int(u32) },
    );
    errdefer allocator.free(work_dir);
    try std.fs.cwd().makePath(work_dir);

    try worktree_service.runGitChecked(allocator, work_dir, &[_][]const u8{ "init", "-b", "main" });
    try worktree_service.runGitChecked(allocator, work_dir, &[_][]const u8{ "config", "user.email", "pool-test@example.com" });
    try worktree_service.runGitChecked(allocator, work_dir, &[_][]const u8{ "config", "user.name", "pool-test" });
    try writeRepoFile(allocator, work_dir, "src.txt", "base\n");
    try worktree_service.runGitChecked(allocator, work_dir, &[_][]const u8{ "add", "src.txt" });
    try worktree_service.runGitChecked(allocator, work_dir, &[_][]const u8{ "commit", "-m", "baseline" });

    const log_dir = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, ".techlead", "iteration-logs" });
    defer allocator.free(log_dir);
    try std.fs.cwd().makePath(log_dir);

    const cfg = config.Config{
        .iterations = 1,
        .opencode_url = try allocator.dupe(u8, "http://127.0.0.1:4096"),
        .work_dir = try allocator.dupe(u8, work_dir),
        .log_dir = try allocator.dupe(u8, ".techlead/iteration-logs"),
        .model = try allocator.dupe(u8, ""),
        .agent = try allocator.dupe(u8, "test"),
        .provider = try allocator.dupe(u8, "mock"),
        .main_branch = try allocator.dupe(u8, "main"),
        .max_branches = 10,
        .pool_lease_seconds = 300,
        .pool_max_retries = 2,
    };

    var store = try sqlite_controlplane_store.SqliteControlPlaneStore.initInMemory(allocator);
    const project_id = std.fs.path.basename(work_dir);
    try store.asControlPlaneStore().registerProject(.{
        .project_id = project_id,
        .work_dir = work_dir,
    });
    try store.asControlPlaneStore().createTask(project_id, .{
        .task_id = "task-e2e",
        .title = "pool e2e",
        .prompt = "implement feature",
        .priority = 1,
        .max_retries = 2,
    }, .{});

    return .{
        .cfg = cfg,
        .store = store,
        .work_dir = work_dir,
        .project_id = project_id,
        .allocator = allocator,
    };
}

fn runSingleTaskForScenario(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    cps: controlplane_store.ControlPlaneStore,
    mock: *MockPoolProvider,
) !TaskOutcome {
    const claimed = (try cps.claimNext(.{
        .owner = "runner-e2e",
        .lease_seconds = cfg.pool_lease_seconds,
        .default_max_retries = cfg.pool_max_retries,
    }, allocator)) orelse return error.TaskNotFound;
    var task = claimed;
    defer task.deinit(allocator);
    const project_id = std.fs.path.basename(cfg.work_dir);
    return processClaimedTask(cfg, allocator, mock, "mock", "runner-e2e", cps, &task, null, null, project_id);
}

fn writeRepoFile(allocator: std.mem.Allocator, cwd: []const u8, rel_path: []const u8, content: []const u8) !void {
    const abs_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, rel_path });
    defer allocator.free(abs_path);
    var file = try std.fs.cwd().createFile(abs_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn writeMockLog(allocator: std.mem.Allocator, cfg: config.Config, label: []const u8, content: []const u8) !void {
    const log_name = try std.fmt.allocPrint(allocator, "{s}.log", .{label});
    defer allocator.free(log_name);
    const log_path = try task_execution_service.buildLogPath(allocator, cfg.work_dir, cfg.log_dir, log_name);
    defer allocator.free(log_path);
    var file = try std.fs.cwd().createFile(log_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn expectTaskState(detail_json: []const u8, status: []const u8, review_stage: []const u8) !void {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, detail_json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const task_obj = (root.get("task") orelse return error.TestExpectedEqual).object;
    try std.testing.expectEqualStrings(status, (task_obj.get("status") orelse return error.TestExpectedEqual).string);
    try std.testing.expectEqualStrings(review_stage, (task_obj.get("review_stage") orelse return error.TestExpectedEqual).string);
}

fn expectEvent(detail_json: []const u8, event_type: []const u8) !void {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, detail_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const events = (root.get("events") orelse return error.TestExpectedEqual).array;
    for (events.items) |evt| {
        const evt_obj = evt.object;
        if (std.mem.eql(u8, (evt_obj.get("event_type") orelse continue).string, event_type)) return;
    }
    return error.TestExpectedEqual;
}
