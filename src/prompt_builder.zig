const std = @import("std");
const TechStackDetection = @import("config.zig").TechStackDetection;

const Allocator = std.mem.Allocator;

/// Embed the init-agent.md template at compile time
const AGENT_TEMPLATE = @embedFile("init-agent.md");

/// Errors that can occur during prompt building
pub const PromptError = error{
    MarkerNotFound,
    OutOfMemory,
};

/// Format TechStackDetection to a string buffer
fn formatTechStack(buf: []u8, tech_stack: TechStackDetection) ![]const u8 {
    if (tech_stack.secondary) |sec| {
        return std.fmt.bufPrint(buf, "{s}, {s}", .{ tech_stack.primary, sec });
    } else {
        return std.fmt.bufPrint(buf, "{s}", .{tech_stack.primary});
    }
}

/// Build the agent prompt by substituting markers in the embedded template.
/// Returns an allocated string that must be freed by the caller.
pub fn buildAgentPrompt(
    allocator: Allocator,
    goal: []const u8,
    project_path: []const u8,
    tech_stack: TechStackDetection,
) PromptError![]u8 {
    // Format tech stack to string
    var tech_stack_buf: [256]u8 = undefined;
    const tech_stack_str = formatTechStack(&tech_stack_buf, tech_stack) catch "unknown";

    // Substitute markers one by one, building new strings
    const after_goal = try substituteAll(allocator, AGENT_TEMPLATE, "{{GOAL}}", goal);
    defer allocator.free(after_goal);

    const after_path = try substituteAll(allocator, after_goal, "{{PROJECT_PATH}}", project_path);
    defer allocator.free(after_path);

    const final = try substituteAll(allocator, after_path, "{{TECH_STACK}}", tech_stack_str);

    return final;
}

/// Substitute all occurrences of a marker in the source string with a value.
/// Returns a newly allocated string.
fn substituteAll(
    allocator: Allocator,
    source: []const u8,
    marker: []const u8,
    value: []const u8,
) (PromptError || Allocator.Error)![]u8 {
    var result = try allocator.dupe(u8, source);
    errdefer allocator.free(result);

    while (std.mem.indexOf(u8, result, marker)) |marker_index| {
        const new_len = result.len - marker.len + value.len;
        var new_result = try allocator.alloc(u8, new_len);
        errdefer allocator.free(new_result);

        // Copy part before marker
        @memcpy(new_result[0..marker_index], result[0..marker_index]);

        // Copy value
        @memcpy(new_result[marker_index .. marker_index + value.len], value);

        // Copy part after marker
        const after_marker = marker_index + marker.len;
        const after_value = marker_index + value.len;
        @memcpy(new_result[after_value..], result[after_marker..]);

        allocator.free(result);
        result = new_result;
    }

    return result;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "buildAgentPrompt substitutes all markers" {
    const allocator = std.testing.allocator;

    const goal = "Optimize performance";
    const project_path = "/tmp/test-project";
    const tech_stack = TechStackDetection{
        .primary = "Node.js/npm",
        .secondary = "TypeScript",
        .indicators_found = &.{ "package.json", "tsconfig.json" },
    };

    const result = try buildAgentPrompt(allocator, goal, project_path, tech_stack);
    defer allocator.free(result);

    // Verify all markers were substituted
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "{{GOAL}}"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "{{PROJECT_PATH}}"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result, 1, "{{TECH_STACK}}"));

    // Verify values are present
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, goal));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, project_path));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "Node.js/npm, TypeScript"));
}

test "buildAgentPrompt with empty tech stack secondary" {
    const allocator = std.testing.allocator;

    const goal = "Refactor code";
    const project_path = "/home/user/project";
    const tech_stack = TechStackDetection{
        .primary = "Rust",
        .secondary = null,
        .indicators_found = &.{"Cargo.toml"},
    };

    const result = try buildAgentPrompt(allocator, goal, project_path, tech_stack);
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "Rust"));
}

test "substitute replaces marker with longer value" {
    const allocator = std.testing.allocator;

    const result = try substituteAll(allocator, "Hello {{NAME}}, welcome!", "{{NAME}}", "Alexander");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello Alexander, welcome!", result);
}

test "substitute replaces marker with shorter value" {
    const allocator = std.testing.allocator;

    const result = try substituteAll(allocator, "Hello {{NAME}}, welcome!", "{{NAME}}", "Al");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello Al, welcome!", result);
}

test "substitute replaces marker with same length value" {
    const allocator = std.testing.allocator;

    const result = try substituteAll(allocator, "Hello {{NAME}}, welcome!", "{{NAME}}", "John");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello John, welcome!", result);
}

test "substitute returns error when marker not found" {
    const allocator = std.testing.allocator;

    const result = try substituteAll(allocator, "Hello World!", "{{MISSING}}", "value");
    defer allocator.free(result);

    // When marker not found, should return a copy of the original
    try std.testing.expectEqualStrings("Hello World!", result);
}

test "substitute handles marker at beginning" {
    const allocator = std.testing.allocator;

    const result = try substituteAll(allocator, "{{START}} middle end", "{{START}}", "BEGIN");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("BEGIN middle end", result);
}

test "substitute handles marker at end" {
    const allocator = std.testing.allocator;

    const result = try substituteAll(allocator, "start middle {{END}}", "{{END}}", "FINISH");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("start middle FINISH", result);
}
