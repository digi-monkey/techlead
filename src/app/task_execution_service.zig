//! Task Execution Service - AI prompt execution and gate command runner
//!
//! This module handles the core task execution phases:
//! - Implement phase: Running AI prompts to implement tasks
//! - Review phase: Running correctness and maintainability reviews
//! - Gate commands: Executing test/lint commands as quality gates
//!
//! All functions are designed to be provider-agnostic via the `anytype` provider parameter.

const std = @import("std");
const config = @import("../config.zig");
const task_store = @import("../storage/task_store.zig");
const result_parser = @import("../pool/result_parser.zig");

const IMPLEMENT_PROMPT_TEMPLATE = @embedFile("../pool/prompts/implement.md");
const REVIEW_CORRECTNESS_TEMPLATE = @embedFile("../pool/prompts/review_correctness.md");
const REVIEW_MAINTAINABILITY_TEMPLATE = @embedFile("../pool/prompts/review_maintainability.md");

/// Maximum bytes to read from gate command output (1MB)
const MAX_GATE_OUTPUT_BYTES: usize = 1024 * 1024;

/// Maximum bytes to read from prompt log files (64MB)
const MAX_LOG_READ_BYTES: usize = 64 * 1024 * 1024;

/// Gate command execution result
///
/// Captures the outcome of running a shell command (typically test or lint)
/// as a quality gate before allowing code to proceed to review or merge.
pub const GateResult = struct {
    /// Whether the command exited successfully (exit code 0)
    success: bool,
    /// Combined stdout and stderr output, null if no output captured
    output: ?[]u8 = null,
    /// The original command string that was executed
    command: []const u8,

    /// Free allocated memory for output
    pub fn deinit(self: *GateResult, allocator: std.mem.Allocator) void {
        if (self.output) |o| allocator.free(o);
    }
};

/// Result of the implement phase (AI code generation)
///
/// Contains the parsed outcome of running the implement prompt,
/// including a human-readable summary and the implementation status.
pub const ImplementResult = struct {
    /// Human-readable summary of what was implemented
    summary: []u8,
    /// Status indicating whether implementation succeeded, was blocked, or needs retry
    status: result_parser.ImplementStatus,

    /// Free allocated memory for summary
    pub fn deinit(self: *ImplementResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
    }
};

/// Result of a review phase (correctness or maintainability)
///
/// Contains the parsed outcome of running a review prompt,
/// including verdict, score, blockers, and suggestions.
pub const ReviewResult = struct {
    /// Which review role produced this result
    role: task_store.TaskReviewRole,
    /// Final verdict: approve, request_changes, or block
    verdict: task_store.TaskReviewVerdict,
    /// Optional numeric score (typically 1-5 for maintainability)
    score: ?i32,
    /// Human-readable summary of the review
    summary: []u8,
    /// JSON array of blocking issues that must be resolved
    blockers_json: []u8,
    /// JSON array of non-blocking suggestions for improvement
    suggestions_json: []u8,
    /// Confidence level of the reviewer (0.0 to 1.0)
    confidence: ?f64,

    /// Free all allocated memory
    pub fn deinit(self: *ReviewResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.blockers_json);
        allocator.free(self.suggestions_json);
    }
};

/// Internal struct for parsed review JSON metadata
pub const ReviewJsonMeta = struct {
    blockers_json: []u8,
    suggestions_json: []u8,
    confidence: ?f64,

    /// Free allocated memory
    pub fn deinit(self: *const ReviewJsonMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.blockers_json);
        allocator.free(self.suggestions_json);
    }
};

/// Errors that can occur during result JSON parsing
pub const ParseError = error{
    ResultJsonInvalid,
    ResultJsonMissingBlockers,
    ResultJsonBlockersNotArray,
    ResultJsonMissingSuggestions,
    ResultJsonSuggestionsNotArray,
    ResultJsonMissingConfidence,
    ResultJsonConfidenceInvalid,
};

/// Internal struct for prompt variable substitution
const PromptVar = struct {
    key: []const u8,
    value: []const u8,
};

/// Run the implement phase for a task.
///
/// This function executes the AI implement prompt to generate code changes
/// for the given task. It reads the task title, prompt, and any previous review
/// feedback to guide the implementation.
///
/// Parameters:
///   - cfg: Application configuration including work directory and settings
///   - allocator: Memory allocator for all dynamic allocations
///   - provider: AI provider implementation for running prompts (anytype for polymorphism)
///   - provider_name: Name of the AI provider for log labeling
///   - task: The task to implement, containing title, prompt, and feedback
///   - base_branch: The base branch to implement against
///   - head_branch: The head branch for the implementation
///   - review_round: Current review round (1 for first attempt, >1 for retries)
///
/// Returns: ImplementResult containing summary and status
///
/// Errors:
///   - error.ProviderFailed: If the AI provider fails to execute
///   - error.OutOfMemory: If allocation fails
///   - Various file system errors if log reading fails
pub fn runImplementPhase(
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

    const log_label = try sanitizeLogLabel(allocator, provider_name, review_round, "implement");
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

/// Run a gate command (test_cmd or lint_cmd) and return the result.
///
/// Gate commands are shell commands that act as quality gates in the pipeline.
/// If a gate command fails (non-zero exit), the task is typically requeued
/// for another attempt with the command output as feedback.
///
/// Parameters:
///   - allocator: Memory allocator for output capture
///   - cwd: Working directory to run the command in
///   - cmd: Shell command string to execute
///
/// Returns: GateResult containing success status and combined output
///
/// Errors:
///   - error.OutOfMemory: If allocation fails
///   - Various process execution errors
pub fn runGateCommand(allocator: std.mem.Allocator, cwd: []const u8, cmd: []const u8) !GateResult {
    // Split command by shell
    const argv = &[_][]const u8{ "sh", "-c", cmd };
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = MAX_GATE_OUTPUT_BYTES,
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

/// Run a review phase (correctness or maintainability) for a task.
///
/// This function executes an AI review prompt to evaluate the code changes
/// produced during the implement phase. It supports both correctness reviews
/// (checking for bugs and logic errors) and maintainability reviews
/// (checking code quality and style).
///
/// Parameters:
///   - cfg: Application configuration including work directory and settings
///   - allocator: Memory allocator for all dynamic allocations
///   - provider: AI provider implementation for running prompts (anytype for polymorphism)
///   - provider_name: Name of the AI provider for log labeling
///   - task: The task being reviewed
///   - base_branch: The base branch (before changes)
///   - head_branch: The head branch (after changes)
///   - diff_summary: Git diff statistics summary for context
///   - kind: Type of review (.review_correctness or .review_maintainability)
///   - review_round: Current review round number
///
/// Returns: ReviewResult containing verdict, score, summary, and structured feedback
///
/// Errors:
///   - error.ProviderFailed: If the AI provider fails to execute
///   - error.InvalidReviewKind: If kind is not a valid review type
///   - error.OutOfMemory: If allocation fails
///   - Various JSON parsing errors from parseReviewJsonMeta
pub fn runReviewPhase(
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
    const log_label = try sanitizeLogLabel(allocator, provider_name, review_round, role_label);
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

/// Parse review JSON metadata from the raw result JSON.
///
/// Extracts structured fields (blockers, suggestions, confidence) from the
/// AI review result JSON. These fields are stored separately for querying
/// and analysis.
///
/// Parameters:
///   - allocator: Memory allocator for JSON strings
///   - raw_json: Raw JSON string from the AI provider
///
/// Returns: ReviewJsonMeta containing extracted fields
///
/// Errors:
///   - ResultJsonInvalid: If JSON is not a valid object
///   - ResultJsonMissingBlockers: If blockers field is missing
///   - ResultJsonBlockersNotArray: If blockers is not an array
///   - ResultJsonMissingSuggestions: If suggestions field is missing
///   - ResultJsonSuggestionsNotArray: If suggestions is not an array
///   - ResultJsonMissingConfidence: If confidence field is missing
///   - ResultJsonConfidenceInvalid: If confidence is not a valid number
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

/// Render a prompt template by substituting variables.
///
/// Replaces all occurrences of each variable key with its corresponding value
/// in the template string. Variables are processed in order.
///
/// Parameters:
///   - allocator: Memory allocator for the result string
///   - template: The template string containing placeholder keys
///   - vars: Array of key-value pairs to substitute
///
/// Returns: Allocated string with all substitutions applied
///
/// Errors:
///   - error.OutOfMemory: If allocation fails
fn renderPrompt(allocator: std.mem.Allocator, template: []const u8, vars: []const PromptVar) ![]u8 {
    var current = try allocator.dupe(u8, template);
    for (vars) |pair| {
        const next = try std.mem.replaceOwned(u8, allocator, current, pair.key, pair.value);
        allocator.free(current);
        current = next;
    }
    return current;
}

/// Read the log file for a completed prompt execution.
///
/// Reads the log file generated by the AI provider after running a prompt.
/// The log contains both the raw output and any structured result JSON.
///
/// Parameters:
///   - allocator: Memory allocator for the file content
///   - cfg: Configuration containing work_dir and log_dir paths
///   - log_label: Log file label (without .log extension)
///
/// Returns: Allocated string containing the log file contents
///
/// Errors:
///   - Various file system errors if the log cannot be read
fn readPromptLog(allocator: std.mem.Allocator, cfg: config.Config, log_label: []const u8) ![]u8 {
    const log_name = try std.fmt.allocPrint(allocator, "{s}.log", .{log_label});
    defer allocator.free(log_name);

    const log_path = try buildLogPath(allocator, cfg.work_dir, cfg.log_dir, log_name);
    defer allocator.free(log_path);

    return std.fs.cwd().readFileAlloc(allocator, log_path, MAX_LOG_READ_BYTES);
}

/// Build a sanitized log label for prompt execution.
///
/// Creates a standardized log label in the format: "pool-{provider}-r{round}-{phase}"
/// This label is used for both logging and identifying output files.
///
/// Parameters:
///   - allocator: Memory allocator for the result string
///   - provider_name: Name of the AI provider
///   - review_round: Review round number
///   - phase: Phase identifier (e.g., "implement", "correctness", "maintainability")
///
/// Returns: Allocated log label string
///
/// Errors:
///   - error.OutOfMemory: If allocation fails
pub fn sanitizeLogLabel(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    review_round: u32,
    phase: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "pool-{s}-r{d}-{s}", .{ provider_name, review_round, phase });
}

/// Build the full log file path.
///
/// Constructs the absolute path to a log file by joining work_dir, log_dir, and log_name.
///
/// Parameters:
///   - allocator: Memory allocator for the path string
///   - work_dir: Base working directory
///   - log_dir: Log subdirectory (typically ".techlead/iteration-logs")
///   - log_name: Log filename
///
/// Returns: Allocated full path string
///
/// Errors:
///   - error.OutOfMemory: If allocation fails
pub fn buildLogPath(
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    log_dir: []const u8,
    log_name: []const u8,
) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ work_dir, log_dir, log_name });
}

/// Write a prompt to a temporary file for debugging.
///
/// Writes the rendered prompt to a temporary file in the system's temp directory.
/// This is useful for debugging prompt issues or manual inspection.
///
/// Parameters:
///   - allocator: Memory allocator for path operations
///   - log_label: Label to use in the filename
///   - prompt: Prompt content to write
///
/// Returns: The path to the created file (caller must free)
///
/// Errors:
///   - Various file system errors if writing fails
pub fn writePromptTempFile(
    allocator: std.mem.Allocator,
    log_label: []const u8,
    prompt: []const u8,
) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "techlead-prompt-{s}.txt", .{log_label});
    defer allocator.free(filename);

    const path = try std.fs.path.join(allocator, &[_][]const u8{ "/tmp", filename });
    errdefer allocator.free(path);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(prompt);

    return path;
}

/// Convert a JSON value to a string representation.
///
/// Helper function to serialize JSON values back to strings for storage.
///
/// Parameters:
///   - allocator: Memory allocator for the output string
///   - value: JSON value to stringify
///
/// Returns: Allocated JSON string
///
/// Errors:
///   - error.OutOfMemory: If allocation fails
fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}
