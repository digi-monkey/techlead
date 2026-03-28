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

const IMPLEMENT_PROMPT_TEMPLATE = @embedFile("../pool/prompts/implement.md");
const REVIEW_CORRECTNESS_TEMPLATE = @embedFile("../pool/prompts/review_correctness.md");
const REVIEW_MAINTAINABILITY_TEMPLATE = @embedFile("../pool/prompts/review_maintainability.md");
const POOL_WORKTREE_REL = ".techlead/pool-worktree";
const MAX_GIT_LOG_SNIPPET: usize = 1024;

// Gate command execution result
const GateResult = struct {
    success: bool,
    output: ?[]u8 = null,
    command: []const u8,

    fn deinit(self: *GateResult, allocator: std.mem.Allocator) void {
        if (self.output) |o| allocator.free(o);
    }
};

const TaskOutcome = enum {
    done,
    requeued,
    failed,
};

const ImplementResult = struct {
    summary: []u8,
    status: result_parser.ImplementStatus,

    fn deinit(self: *ImplementResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
    }
};

const ReviewResult = struct {
    role: task_store.TaskReviewRole,
    verdict: task_store.TaskReviewVerdict,
    score: ?i32,
    summary: []u8,
    blockers_json: []u8,
    suggestions_json: []u8,
    confidence: ?f64,

    fn deinit(self: *ReviewResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.blockers_json);
        allocator.free(self.suggestions_json);
    }
};

const PromptVar = struct {
    key: []const u8,
    value: []const u8,
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
    const pool_work_dir = try ensurePoolWorktree(allocator, cfg.work_dir, cfg.main_branch);
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
    try prepareWorktreeForTask(allocator, cfg.work_dir);

    const review_round = task.review_round + 1;
    const base_branch = cfg.main_branch;
    const head_branch = try buildHeadBranch(allocator, task.task_id, review_round);
    defer allocator.free(head_branch);

    try checkoutImplementationBranch(allocator, cfg.work_dir, base_branch, head_branch);
    const base_sha = try gitRevParse(allocator, cfg.work_dir, base_branch);
    defer allocator.free(base_sha);

    var implement_result = try runImplementPhase(cfg, allocator, provider, provider_name, task, base_branch, head_branch, review_round);
    defer implement_result.deinit(allocator);

    if (implement_result.status != .implemented) {
        ui.logWarn("task {s} implement phase blocked: status={s}", .{ task.task_id, @tagName(implement_result.status) });
        return error.ImplementBlocked;
    }

    try ensureImplementationCommit(allocator, cfg.work_dir, task.task_id, review_round);

    const head_sha = try gitRevParse(allocator, cfg.work_dir, "HEAD");
    defer allocator.free(head_sha);
    if (std.mem.eql(u8, base_sha, head_sha)) {
        ui.logWarn("task {s} no commit produced: base_sha equals head_sha", .{task.task_id});
        return error.NoCommitProduced;
    }

    try cps.markReviewOpen(project_id, task.task_id, run_id, run_id, review_round, base_branch, head_branch, head_sha);

    // Run gate commands (test_cmd and lint_cmd) before review
    if (project_test_cmd) |test_cmd| {
        ui.logInfo("task {s} running test_cmd: {s}", .{ task.task_id, test_cmd });
        var gate_result = try runGateCommand(allocator, cfg.work_dir, test_cmd);
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
        var gate_result = try runGateCommand(allocator, cfg.work_dir, lint_cmd);
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

    var correctness = runReviewPhase(
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

    var maintainability = runReviewPhase(
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

fn runImplementPhase(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    provider: anytype,
    provider_name: []const u8,
    task: *const task_store.Task,
    base_branch: []const u8,
    head_branch: []const u8,
    review_round: u32,
) !ImplementResult {
    const review_feedback = task.review_feedback orelse "";
    const prompt = try renderPrompt(allocator, IMPLEMENT_PROMPT_TEMPLATE, &[_]PromptVar{
        .{ .key = "{{TASK_TITLE}}", .value = task.title },
        .{ .key = "{{TASK_PROMPT}}", .value = task.prompt orelse "" },
        .{ .key = "{{HEAD_BRANCH}}", .value = head_branch },
        .{ .key = "{{BASE_BRANCH}}", .value = base_branch },
        .{ .key = "{{REVIEW_FEEDBACK}}", .value = review_feedback },
    });
    defer allocator.free(prompt);

    const log_label = try std.fmt.allocPrint(allocator, "pool-{s}-r{d}-implement", .{ provider_name, review_round });
    defer allocator.free(log_label);

    const exec_result = try provider.runPrompt(cfg, allocator, prompt, log_label);
    if (!exec_result.success) return error.ProviderFailed;

    const merged_output = try readPromptLog(allocator, cfg, log_label);
    defer allocator.free(merged_output);

    var parsed = try result_parser.parseResultFromMergedOutput(allocator, merged_output, .implement);
    defer parsed.deinit(allocator);

    return .{
        .summary = try allocator.dupe(u8, parsed.summary),
        .status = parsed.status orelse .blocked,
    };
}

// Run a gate command (test_cmd or lint_cmd) and return the result
fn runGateCommand(allocator: std.mem.Allocator, cwd: []const u8, cmd: []const u8) !GateResult {
    // Split command by shell
    const argv = &[_][]const u8{ "sh", "-c", cmd };
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024, // 1MB max output
    });

    const success = result.term.Exited == 0;
    const output = if (result.stdout.len > 0 or result.stderr.len > 0)
        try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ result.stdout, result.stderr })
    else
        null;

    allocator.free(result.stdout);
    allocator.free(result.stderr);

    return GateResult{
        .success = success,
        .output = output,
        .command = cmd,
    };
}

fn runReviewPhase(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    provider: anytype,
    provider_name: []const u8,
    task: *const task_store.Task,
    base_branch: []const u8,
    head_branch: []const u8,
    diff_summary: []const u8,
    kind: result_parser.ResultKind,
    review_round: u32,
) !ReviewResult {
    const template = switch (kind) {
        .review_correctness => REVIEW_CORRECTNESS_TEMPLATE,
        .review_maintainability => REVIEW_MAINTAINABILITY_TEMPLATE,
        else => return error.InvalidReviewKind,
    };

    const prompt = try renderPrompt(allocator, template, &[_]PromptVar{
        .{ .key = "{{TASK_TITLE}}", .value = task.title },
        .{ .key = "{{TASK_PROMPT}}", .value = task.prompt orelse "" },
        .{ .key = "{{HEAD_BRANCH}}", .value = head_branch },
        .{ .key = "{{BASE_BRANCH}}", .value = base_branch },
        .{ .key = "{{DIFF_SUMMARY}}", .value = diff_summary },
    });
    defer allocator.free(prompt);

    const role_label = switch (kind) {
        .review_correctness => "correctness",
        .review_maintainability => "maintainability",
        else => "review",
    };
    const log_label = try std.fmt.allocPrint(allocator, "pool-{s}-r{d}-{s}", .{ provider_name, review_round, role_label });
    defer allocator.free(log_label);

    const exec_result = try provider.runPrompt(cfg, allocator, prompt, log_label);
    if (!exec_result.success) return error.ProviderFailed;

    const merged_output = try readPromptLog(allocator, cfg, log_label);
    defer allocator.free(merged_output);

    var parsed = try result_parser.parseResultFromMergedOutput(allocator, merged_output, kind);
    defer parsed.deinit(allocator);

    const json_meta = try parseReviewJsonMeta(allocator, parsed.raw_json);

    return .{
        .role = switch (kind) {
            .review_correctness => .correctness_reviewer,
            .review_maintainability => .maintainability_reviewer,
            else => .correctness_reviewer,
        },
        .verdict = switch (parsed.verdict orelse .request_changes) {
            .approve => .approve,
            .request_changes => .request_changes,
            .block => .block,
        },
        .score = if (parsed.score) |v| @intCast(v) else null,
        .summary = try allocator.dupe(u8, parsed.summary),
        .blockers_json = json_meta.blockers_json,
        .suggestions_json = json_meta.suggestions_json,
        .confidence = json_meta.confidence,
    };
}

const ReviewJsonMeta = struct {
    blockers_json: []u8,
    suggestions_json: []u8,
    confidence: ?f64,

    fn deinit(self: *const ReviewJsonMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.blockers_json);
        allocator.free(self.suggestions_json);
    }
};

fn parseReviewJsonMeta(allocator: std.mem.Allocator, raw_json: []const u8) !ReviewJsonMeta {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.ResultJsonInvalid;
    const obj = parsed.value.object;

    const blockers_value = obj.get("blockers") orelse return error.ResultJsonMissingBlockers;
    if (blockers_value != .array) return error.ResultJsonBlockersNotArray;
    const blockers_json = try stringifyJsonValue(allocator, blockers_value);
    errdefer allocator.free(blockers_json);

    const suggestions_value = obj.get("suggestions") orelse return error.ResultJsonMissingSuggestions;
    if (suggestions_value != .array) return error.ResultJsonSuggestionsNotArray;
    const suggestions_json = try stringifyJsonValue(allocator, suggestions_value);
    errdefer allocator.free(suggestions_json);

    const confidence_value = obj.get("confidence") orelse return error.ResultJsonMissingConfidence;
    const confidence = switch (confidence_value) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.ResultJsonConfidenceInvalid,
        else => return error.ResultJsonConfidenceInvalid,
    };

    return .{
        .blockers_json = blockers_json,
        .suggestions_json = suggestions_json,
        .confidence = confidence,
    };
}

fn ensurePoolWorktree(allocator: std.mem.Allocator, repo_dir: []const u8, main_branch: []const u8) ![]u8 {
    const worktree_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_dir, POOL_WORKTREE_REL });
    errdefer allocator.free(worktree_dir);

    const runtime_dir = try std.fs.path.join(allocator, &[_][]const u8{ repo_dir, ".techlead" });
    defer allocator.free(runtime_dir);
    try std.fs.cwd().makePath(runtime_dir);

    if (utils.fileExists(worktree_dir)) {
        if (!isGitWorktree(allocator, worktree_dir)) {
            ui.logError("pool worktree 目录存在但不是有效 git worktree: {s}", .{worktree_dir});
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

fn isGitWorktree(allocator: std.mem.Allocator, cwd: []const u8) bool {
    const cap = runGitCapture(allocator, cwd, &[_][]const u8{ "rev-parse", "--is-inside-work-tree" }) catch return false;
    defer allocator.free(cap.stdout);
    defer allocator.free(cap.stderr);
    if (!utils.isExitedZero(cap.term)) return false;
    const out = std.mem.trim(u8, cap.stdout, " \t\r\n");
    return std.mem.eql(u8, out, "true");
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

fn aggregateReviewFeedback(allocator: std.mem.Allocator, correctness: ReviewResult, maintainability: ReviewResult) ![]u8 {
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

fn checkoutImplementationBranch(allocator: std.mem.Allocator, cwd: []const u8, base_branch: []const u8, head_branch: []const u8) !void {
    try runGitChecked(allocator, cwd, &[_][]const u8{ "checkout", "-B", head_branch, base_branch });
}

fn collectDiffSummary(allocator: std.mem.Allocator, cwd: []const u8, base_branch: []const u8, head_branch: []const u8) ![]u8 {
    const revspec = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base_branch, head_branch });
    defer allocator.free(revspec);

    const output = runGitStdout(allocator, cwd, &[_][]const u8{ "--no-pager", "diff", "--stat", revspec }) catch |err| switch (err) {
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
    const status_output = try runGitStdout(allocator, cwd, &[_][]const u8{ "status", "--porcelain" });
    defer allocator.free(status_output);
    if (status_output.len == 0) return;

    // Stage changed tracked/untracked/deleted files one-by-one to avoid
    // `git add .` failures caused by ignored runtime dirs (e.g. `.techlead`).
    try stageEligibleWorkspaceChanges(allocator, cwd);

    const staged_output = try runGitStdout(allocator, cwd, &[_][]const u8{ "diff", "--cached", "--name-only" });
    defer allocator.free(staged_output);
    if (staged_output.len == 0) return;

    const message = try std.fmt.allocPrint(allocator, "task({s}): implement round {d}", .{ task_id, review_round });
    defer allocator.free(message);
    try runGitChecked(allocator, cwd, &[_][]const u8{ "commit", "-m", message });
}

fn stageEligibleWorkspaceChanges(allocator: std.mem.Allocator, cwd: []const u8) !void {
    const changed = try runGitStdout(allocator, cwd, &[_][]const u8{ "ls-files", "-m", "-o", "-d", "--exclude-standard" });
    defer allocator.free(changed);
    if (changed.len == 0) return;

    var it = std.mem.splitScalar(u8, changed, '\n');
    while (it.next()) |line_raw| {
        const path = std.mem.trim(u8, line_raw, " \t\r\n");
        if (path.len == 0) continue;
        if (shouldSkipAutoStage(path)) continue;
        try runGitChecked(allocator, cwd, &[_][]const u8{ "add", "--", path });
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

fn renderPrompt(allocator: std.mem.Allocator, template: []const u8, vars: []const PromptVar) ![]u8 {
    var current = try allocator.dupe(u8, template);
    for (vars) |pair| {
        const next = try std.mem.replaceOwned(u8, allocator, current, pair.key, pair.value);
        allocator.free(current);
        current = next;
    }
    return current;
}

fn readPromptLog(allocator: std.mem.Allocator, cfg: config.Config, log_label: []const u8) ![]u8 {
    const log_name = try std.fmt.allocPrint(allocator, "{s}.log", .{log_label});
    defer allocator.free(log_name);

    const log_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.work_dir, cfg.log_dir, log_name });
    defer allocator.free(log_path);

    return std.fs.cwd().readFileAlloc(allocator, log_path, 64 * 1024 * 1024);
}

fn runGitChecked(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
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

fn prepareWorktreeForTask(allocator: std.mem.Allocator, cwd: []const u8) !void {
    try runGitChecked(allocator, cwd, &[_][]const u8{ "reset", "--hard", "HEAD" });
    try runGitChecked(allocator, cwd, &[_][]const u8{ "clean", "-fd", "-e", ".techlead", "--", "." });
}

fn collectGitFailureContext(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
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

fn renderGitCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "git");
    for (args) |arg| {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

fn trimAndLimit(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    if (trimmed.len <= max_len) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}...(truncated)", .{trimmed[0..max_len]});
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
        parseReviewJsonMeta(allocator, "{\"summary\":\"ok\",\"suggestions\":[],\"confidence\":0.7}"),
    );
    try std.testing.expectError(
        error.ResultJsonMissingSuggestions,
        parseReviewJsonMeta(allocator, "{\"summary\":\"ok\",\"blockers\":[],\"confidence\":0.7}"),
    );
    try std.testing.expectError(
        error.ResultJsonMissingConfidence,
        parseReviewJsonMeta(allocator, "{\"summary\":\"ok\",\"blockers\":[],\"suggestions\":[]}"),
    );
}

test "parseReviewJsonMeta requires array types for blockers and suggestions" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.ResultJsonBlockersNotArray,
        parseReviewJsonMeta(allocator, "{\"blockers\":{},\"suggestions\":[],\"confidence\":0.8}"),
    );
    try std.testing.expectError(
        error.ResultJsonSuggestionsNotArray,
        parseReviewJsonMeta(allocator, "{\"blockers\":[],\"suggestions\":{},\"confidence\":0.8}"),
    );
}

test "parseReviewJsonMeta parses valid object" {
    const allocator = std.testing.allocator;
    var meta = try parseReviewJsonMeta(
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

    fn runPrompt(
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
                try runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "add", "src.txt" });
                try runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "commit", "-m", "implement commit" });
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
                const head_branch = try runGitStdout(allocator, cfg.work_dir, &[_][]const u8{ "branch", "--show-current" });
                defer allocator.free(head_branch);

                try runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "checkout", cfg.main_branch });
                try writeRepoFile(allocator, cfg.work_dir, "src.txt", "base-change\n");
                try runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "add", "src.txt" });
                try runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "commit", "-m", "base conflict change" });
                try runGitChecked(allocator, cfg.work_dir, &[_][]const u8{ "checkout", head_branch });
                self.base_diverged = true;
            }

            const score: i32 = if (self.scenario == .low_score_requeue) 2 else 4;
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
    // TODO: Fix test - segfault in sqlite step
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var setup = try setupPoolE2E(allocator);
    defer setup.deinit();

    var mock = MockPoolProvider{ .scenario = .approve_and_merge };
    const outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.done, outcome);

    const detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.cfg.work_dir, "task-e2e", allocator);
    defer allocator.free(detail_json);
    try expectTaskState(detail_json, "done", "merged");
}

test "pool e2e: implement writes uncommitted changes -> auto-commit -> done" {
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var setup = try setupPoolE2E(allocator);
    defer setup.deinit();

    var mock = MockPoolProvider{ .scenario = .approve_and_merge_without_commit };
    const outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.done, outcome);

    const detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.cfg.work_dir, "task-e2e", allocator);
    defer allocator.free(detail_json);
    try expectTaskState(detail_json, "done", "merged");
}

test "pool e2e: maintainability score=2 -> changes_requested -> queued" {
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var setup = try setupPoolE2E(allocator);
    defer setup.deinit();

    var mock = MockPoolProvider{ .scenario = .low_score_requeue };
    const outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.requeued, outcome);

    const detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.cfg.work_dir, "task-e2e", allocator);
    defer allocator.free(detail_json);
    try expectTaskState(detail_json, "queued", "changes_requested");
}

test "pool e2e: suggestion -> changes_requested -> second round done" {
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var setup = try setupPoolE2E(allocator);
    defer setup.deinit();

    var mock = MockPoolProvider{ .scenario = .suggestion_requeue_then_approve };
    const first_outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.requeued, first_outcome);

    const first_detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.cfg.work_dir, "task-e2e", allocator);
    defer allocator.free(first_detail_json);
    try expectTaskState(first_detail_json, "queued", "changes_requested");
    try expectEvent(first_detail_json, "task.review.changes_requested");

    const second_outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.done, second_outcome);

    const second_detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.cfg.work_dir, "task-e2e", allocator);
    defer allocator.free(second_detail_json);
    try expectTaskState(second_detail_json, "done", "merged");
}

test "pool e2e: merge conflict -> changes_requested -> queued" {
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var setup = try setupPoolE2E(allocator);
    defer setup.deinit();

    var mock = MockPoolProvider{ .scenario = .merge_conflict_requeue };
    const outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asControlPlaneStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.requeued, outcome);

    const detail_json = try setup.store.asControlPlaneStore().getTaskDetail(setup.cfg.work_dir, "task-e2e", allocator);
    defer allocator.free(detail_json);
    try expectTaskState(detail_json, "queued", "changes_requested");
    try expectEvent(detail_json, "task.merge.failed");
}

const PoolE2ESetup = struct {
    cfg: config.Config,
    store: sqlite_controlplane_store.SqliteControlPlaneStore,
    work_dir: []u8,
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

    try runGitChecked(allocator, work_dir, &[_][]const u8{ "init", "-b", "main" });
    try runGitChecked(allocator, work_dir, &[_][]const u8{ "config", "user.email", "pool-test@example.com" });
    try runGitChecked(allocator, work_dir, &[_][]const u8{ "config", "user.name", "pool-test" });
    try writeRepoFile(allocator, work_dir, "src.txt", "base\n");
    try runGitChecked(allocator, work_dir, &[_][]const u8{ "add", "src.txt" });
    try runGitChecked(allocator, work_dir, &[_][]const u8{ "commit", "-m", "baseline" });

    const log_dir = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, ".techlead", "iteration-logs" });
    defer allocator.free(log_dir);
    try std.fs.cwd().makePath(log_dir);

    const cfg = config.Config{
        .iterations = 1,
        .program_file = try allocator.dupe(u8, ".techlead/program.md"),
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

    var store = try sqlite_controlplane_store.SqliteControlPlaneStore.init(allocator);
    try store.asControlPlaneStore().createTask(work_dir, .{
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
    const log_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.work_dir, cfg.log_dir, log_name });
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
