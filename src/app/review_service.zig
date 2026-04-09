const std = @import("std");
const config = @import("../config.zig");
const ui = @import("../ui.zig");
const task_store = @import("../storage/task_store.zig");
const result_parser = @import("../pool/result_parser.zig");

// Prompt templates
/// Template for correctness review prompts.
/// Contains instructions for reviewing code correctness, logic errors, and bugs.
const REVIEW_CORRECTNESS_TEMPLATE = @embedFile("../pool/prompts/review_correctness.md");

/// Template for maintainability review prompts.
/// Contains instructions for reviewing code quality, style, and maintainability.
const REVIEW_MAINTAINABILITY_TEMPLATE = @embedFile("../pool/prompts/review_maintainability.md");

/// Represents the result of a code review (correctness or maintainability)
pub const ReviewResult = struct {
    role: task_store.TaskReviewRole,
    verdict: task_store.TaskReviewVerdict,
    score: ?i32,
    summary: []u8,
    blockers_json: []u8,
    suggestions_json: []u8,
    confidence: ?f64,

    /// Free all allocated memory for the review result
    pub fn deinit(self: *ReviewResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.blockers_json);
        allocator.free(self.suggestions_json);
    }
};

/// Internal struct for holding parsed JSON metadata from review results.
/// Contains blockers array, suggestions array, and confidence score as parsed JSON.
pub const ReviewJsonMeta = struct {
    blockers_json: []u8,
    suggestions_json: []u8,
    confidence: ?f64,

    fn deinit(self: *const ReviewJsonMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.blockers_json);
        allocator.free(self.suggestions_json);
    }
};

/// Template variable for prompt rendering
const PromptVar = struct {
    key: []const u8,
    value: []const u8,
};

/// Provider interface requirement
const Provider = struct {
    pub const ExecutionResult = struct {
        success: bool,
    };
};

// =============================================================================
// REVIEW PHASE FUNCTIONS
// =============================================================================

/// Run a correctness review on the given implementation.
/// The correctness reviewer checks if the implementation is correct,
/// whether there are regression risks, and if there is supporting evidence.
///
/// Uses the review_correctness.md prompt template which expects these variables:
/// - {{TASK_TITLE}} - The task title
/// - {{TASK_PROMPT}} - The task description/prompt
/// - {{HEAD_BRANCH}} - The implementation branch being reviewed
/// - {{BASE_BRANCH}} - The base branch to compare against
/// - {{DIFF_SUMMARY}} - Summary of changes in the diff
pub fn correctnessReview(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    provider: anytype,
    provider_name: []const u8,
    task: *const task_store.Task,
    base_branch: []const u8,
    head_branch: []const u8,
    diff_summary: []const u8,
    review_round: u32,
) !ReviewResult {
    return runReviewPhase(
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
    );
}

/// Run a maintainability review on the given implementation.
/// The maintainability reviewer checks Clean Code principles including
/// naming, responsibilities, duplication, complexity, and readability.
///
/// Uses the review_maintainability.md prompt template which expects these variables:
/// - {{TASK_TITLE}} - The task title
/// - {{TASK_PROMPT}} - The task description/prompt
/// - {{HEAD_BRANCH}} - The implementation branch being reviewed
/// - {{BASE_BRANCH}} - The base branch to compare against
/// - {{DIFF_SUMMARY}} - Summary of changes in the diff
pub fn maintainabilityReview(
    cfg: config.Config,
    allocator: std.mem.Allocator,
    provider: anytype,
    provider_name: []const u8,
    task: *const task_store.Task,
    base_branch: []const u8,
    head_branch: []const u8,
    diff_summary: []const u8,
    review_round: u32,
) !ReviewResult {
    return runReviewPhase(
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
    );
}

/// Internal implementation for running a review phase
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

// =============================================================================
// REVIEW GATE FUNCTIONS
// =============================================================================

/// ReviewGateInput contains the results from both review passes for evaluation
pub const ReviewGateInput = struct {
    correctness: ReviewResult,
    maintainability: ReviewResult,
};

/// ReviewGateResult indicates the outcome of the review gate check
pub const ReviewGateResult = union(enum) {
    approved: void,
    changes_requested: []const u8, // Feedback message explaining why
};

/// Run the review gate check to determine if the implementation passes both reviews.
/// Returns .approved if both reviews approve and maintainability score >= 3.
/// Returns .changes_requested with aggregated feedback otherwise.
///
/// Example usage:
/// ```zig
/// const gate_result = try reviewGate(allocator, .{
///     .correctness = correctness_result,
///     .maintainability = maintainability_result,
/// });
/// switch (gate_result) {
///     .approved => try mergeChanges(),
///     .changes_requested => |feedback| try requestChanges(feedback),
/// }
/// ```
pub fn reviewGate(
    allocator: std.mem.Allocator,
    input: ReviewGateInput,
) !ReviewGateResult {
    if (shouldRequestChanges(
        input.correctness.verdict,
        input.maintainability.verdict,
        input.maintainability.score,
        input.correctness.suggestions_json,
        input.maintainability.suggestions_json,
    )) {
        const feedback = try aggregateReviewFeedback(allocator, input.correctness, input.maintainability);
        return .{ .changes_requested = feedback };
    }
    return .approved;
}

/// Check if changes should be requested based on review results.
/// Returns true if:
/// - Correctness verdict is not "approve"
/// - Maintainability verdict is not "approve"
/// - Maintainability score is less than 3
pub fn shouldRequestChanges(
    correctness_verdict: task_store.TaskReviewVerdict,
    maintainability_verdict: task_store.TaskReviewVerdict,
    maintainability_score: ?i32,
    _: []const u8,
    _: []const u8,
) bool {
    const score = maintainability_score orelse 0;
    return correctness_verdict != .approve or maintainability_verdict != .approve or score < 3;
}

/// Aggregate feedback from both reviews into a single string for requeue
fn aggregateReviewFeedback(
    allocator: std.mem.Allocator,
    correctness: ReviewResult,
    maintainability: ReviewResult,
) ![]u8 {
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

/// Free the feedback string returned by reviewGate when it returns .changes_requested
pub fn freeGateFeedback(allocator: std.mem.Allocator, feedback: []const u8) void {
    allocator.free(feedback);
}

// =============================================================================
// JSON PARSING
// =============================================================================

/// Parse review JSON metadata from the raw JSON result.
/// Expects JSON with fields: blockers (array), suggestions (array), confidence (number)
pub fn parseReviewJsonMeta(allocator: std.mem.Allocator, raw_json: []const u8) !ReviewJsonMeta {
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

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

/// Render a prompt template by replacing template variables with actual values
fn renderPrompt(allocator: std.mem.Allocator, template: []const u8, vars: []const PromptVar) ![]u8 {
    var current = try allocator.dupe(u8, template);
    for (vars) |pair| {
        const next = try std.mem.replaceOwned(u8, allocator, current, pair.key, pair.value);
        allocator.free(current);
        current = next;
    }
    return current;
}

/// Read the prompt execution log file
fn readPromptLog(allocator: std.mem.Allocator, cfg: config.Config, log_label: []const u8) ![]u8 {
    const log_name = try std.fmt.allocPrint(allocator, "{s}.log", .{log_label});
    defer allocator.free(log_name);

    const log_path = try std.fs.path.join(allocator, &[_][]const u8{ cfg.work_dir, cfg.log_dir, log_name });
    defer allocator.free(log_path);

    return std.fs.cwd().readFileAlloc(allocator, log_path, 64 * 1024 * 1024);
}

// =============================================================================
// ERROR DEFINITIONS
// =============================================================================

pub const ReviewError = error{
    InvalidReviewKind,
    ProviderFailed,
    ResultJsonInvalid,
    ResultJsonMissingBlockers,
    ResultJsonMissingSuggestions,
    ResultJsonMissingConfidence,
    ResultJsonBlockersNotArray,
    ResultJsonSuggestionsNotArray,
    ResultJsonConfidenceInvalid,
    OutOfMemory,
};

// =============================================================================
// TESTS
// =============================================================================

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
