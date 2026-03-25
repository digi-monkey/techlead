const std = @import("std");

pub const RESULT_JSON_PREFIX = "RESULT_JSON:";

pub const ResultKind = enum {
    implement,
    review_correctness,
    review_maintainability,
};

pub const Verdict = enum {
    approve,
    request_changes,
    block,
};

pub const ImplementStatus = enum {
    implemented,
    blocked,
};

pub const ParsedResult = struct {
    role: []u8,
    summary: []u8,
    status: ?ImplementStatus = null,
    verdict: ?Verdict = null,
    score: ?i64 = null,
    raw_json: []u8,

    pub fn deinit(self: *ParsedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        allocator.free(self.summary);
        allocator.free(self.raw_json);
        self.* = undefined;
    }
};

pub const ParseError = error{
    ResultJsonPrefixNotFound,
    ResultJsonPayloadEmpty,
    ResultJsonInvalid,
    ResultJsonNotObject,
    ResultJsonMissingRole,
    ResultJsonRoleNotString,
    ResultJsonRoleMismatch,
    ResultJsonMissingSummary,
    ResultJsonSummaryNotString,
    ResultJsonMissingStatus,
    ResultJsonStatusNotString,
    ResultJsonStatusInvalid,
    ResultJsonMissingVerdict,
    ResultJsonVerdictNotString,
    ResultJsonVerdictInvalid,
    ResultJsonMissingScore,
    ResultJsonScoreInvalid,
};

pub fn parseResultFromMergedOutput(
    allocator: std.mem.Allocator,
    merged_output: []const u8,
    kind: ResultKind,
) (ParseError || error{OutOfMemory})!ParsedResult {
    const raw_json_line = try extractResultJsonLine(merged_output);
    var parsed_json = std.json.parseFromSlice(std.json.Value, allocator, raw_json_line, .{}) catch {
        return error.ResultJsonInvalid;
    };
    defer parsed_json.deinit();

    if (parsed_json.value != .object) return error.ResultJsonNotObject;
    const object = parsed_json.value.object;

    const role = try readRole(allocator, object, kind);
    errdefer allocator.free(role);

    const summary = try readSummary(allocator, object);
    errdefer allocator.free(summary);
    const status = switch (kind) {
        .implement => try readStatus(object),
        else => null,
    };
    const verdict = switch (kind) {
        .implement => null,
        .review_correctness, .review_maintainability => try readVerdict(object),
    };
    const score = switch (kind) {
        .review_maintainability => try readScore(object),
        else => null,
    };

    return .{
        .role = role,
        .summary = summary,
        .status = status,
        .verdict = verdict,
        .score = score,
        .raw_json = try allocator.dupe(u8, raw_json_line),
    };
}

fn extractResultJsonLine(merged_output: []const u8) ParseError![]const u8 {
    // 支持 `RESULT_JSON: 和 RESULT_JSON: 两种格式
    const result_prefixes = [_][]const u8{ "`RESULT_JSON:", "RESULT_JSON:" };

    var prefix_idx: ?usize = null;
    var prefix_len: usize = 0;
    var has_backtick = false;

    for (result_prefixes) |prefix| {
        if (std.mem.lastIndexOf(u8, merged_output, prefix)) |idx| {
            prefix_idx = idx;
            prefix_len = prefix.len;
            has_backtick = (prefix[0] == '`');
            break;
        }
    }

    const start_idx = prefix_idx orelse {
        return error.ResultJsonPrefixNotFound;
    };

    const after_prefix = merged_output[start_idx + prefix_len ..];
    var line_end = after_prefix.len;

    // 根据格式确定结束符
    if (has_backtick) {
        // 查找结束反引号
        if (std.mem.indexOfScalar(u8, after_prefix, '`')) |idx| line_end = idx;
    } else {
        // 纯文本格式，查找换行
        if (std.mem.indexOfScalar(u8, after_prefix, '\n')) |idx| line_end = @min(line_end, idx);
        if (std.mem.indexOfScalar(u8, after_prefix, '\r')) |idx| line_end = @min(line_end, idx);
    }

    const line = std.mem.trim(u8, after_prefix[0..line_end], " \t");
    if (line.len == 0) return error.ResultJsonPayloadEmpty;
    return line;
}

fn readRole(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    kind: ResultKind,
) (ParseError || error{OutOfMemory})![]u8 {
    const role_value = object.get("role") orelse return error.ResultJsonMissingRole;
    const role_slice = switch (role_value) {
        .string => |v| v,
        else => return error.ResultJsonRoleNotString,
    };

    const expected_role = switch (kind) {
        .implement => "implementer",
        .review_correctness => "correctness_reviewer",
        .review_maintainability => "maintainability_reviewer",
    };
    if (!std.mem.eql(u8, role_slice, expected_role)) return error.ResultJsonRoleMismatch;

    return try allocator.dupe(u8, role_slice);
}

fn readSummary(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) (ParseError || error{OutOfMemory})![]u8 {
    const summary_value = object.get("summary") orelse return error.ResultJsonMissingSummary;
    const summary_slice = switch (summary_value) {
        .string => |v| v,
        else => return error.ResultJsonSummaryNotString,
    };
    return allocator.dupe(u8, summary_slice);
}

fn readStatus(object: std.json.ObjectMap) ParseError!ImplementStatus {
    const status_value = object.get("status") orelse return error.ResultJsonMissingStatus;
    const status_slice = switch (status_value) {
        .string => |v| v,
        else => return error.ResultJsonStatusNotString,
    };

    if (std.mem.eql(u8, status_slice, "implemented")) return .implemented;
    if (std.mem.eql(u8, status_slice, "blocked")) return .blocked;
    return error.ResultJsonStatusInvalid;
}

fn readVerdict(object: std.json.ObjectMap) ParseError!Verdict {
    const verdict_value = object.get("verdict") orelse return error.ResultJsonMissingVerdict;
    const verdict_slice = switch (verdict_value) {
        .string => |v| v,
        else => return error.ResultJsonVerdictNotString,
    };

    if (std.mem.eql(u8, verdict_slice, "approve")) return .approve;
    if (std.mem.eql(u8, verdict_slice, "request_changes")) return .request_changes;
    if (std.mem.eql(u8, verdict_slice, "block")) return .block;
    return error.ResultJsonVerdictInvalid;
}

fn readScore(object: std.json.ObjectMap) ParseError!i64 {
    const score_value = object.get("score") orelse return error.ResultJsonMissingScore;
    return switch (score_value) {
        .integer => |v| v,
        .number_string => |v| std.fmt.parseInt(i64, v, 10) catch return error.ResultJsonScoreInvalid,
        else => error.ResultJsonScoreInvalid,
    };
}

test "parseResultFromMergedOutput: success" {
    const allocator = std.testing.allocator;
    const merged =
        \\info: running reviewer
        \\warn: stderr line
        \\RESULT_JSON: {"role":"maintainability_reviewer","verdict":"approve","score":4,"summary":"结构清晰，维护成本可控"}
        \\done
    ;

    var parsed = try parseResultFromMergedOutput(allocator, merged, .review_maintainability);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("maintainability_reviewer", parsed.role);
    try std.testing.expectEqual(.approve, parsed.verdict.?);
    try std.testing.expectEqual(@as(i64, 4), parsed.score.?);
    try std.testing.expectEqualStrings("结构清晰，维护成本可控", parsed.summary);
}

test "parseResultFromMergedOutput: missing field" {
    const allocator = std.testing.allocator;
    const merged =
        \\RESULT_JSON: {"role":"correctness_reviewer","summary":"缺少 verdict 字段"}
    ;

    try std.testing.expectError(
        error.ResultJsonMissingVerdict,
        parseResultFromMergedOutput(allocator, merged, .review_correctness),
    );
}

test "parseResultFromMergedOutput: invalid json" {
    const allocator = std.testing.allocator;
    const merged =
        \\prefix text
        \\RESULT_JSON: {"role":"correctness_reviewer","verdict":"approve","summary":"oops"
    ;

    try std.testing.expectError(
        error.ResultJsonInvalid,
        parseResultFromMergedOutput(allocator, merged, .review_correctness),
    );
}
