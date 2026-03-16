const std = @import("std");
const Allocator = std.mem.Allocator;

// Embed the program.md template at compile time
// This ensures the template is baked into the binary for distribution
const embedded_template = @embedFile("program.md");

/// Builds a program template by using the embedded program.md and injecting the goal.
/// Falls back to default template if embedded template markers not found.
pub fn buildProgramTemplate(allocator: Allocator, goal: []const u8) ![]u8 {
    const begin_marker = "<!-- TECHLEAD:GOAL:BEGIN -->";
    const end_marker = "<!-- TECHLEAD:GOAL:END -->";

    const begin_index = std.mem.indexOf(u8, embedded_template, begin_marker) orelse {
        std.log.warn("GOAL markers not found in embedded program.md, using default template", .{});
        return buildDefaultProgramTemplate(allocator, goal);
    };

    const begin_content = begin_index + begin_marker.len;
    const rest = embedded_template[begin_content..];
    const end_rel = std.mem.indexOf(u8, rest, end_marker) orelse {
        std.log.warn("GOAL end marker not found in embedded program.md, using default template", .{});
        return buildDefaultProgramTemplate(allocator, goal);
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, embedded_template[0..begin_content]);
    try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, goal);
    try out.appendSlice(allocator, "\n");
    try out.appendSlice(allocator, rest[end_rel..]);

    return out.toOwnedSlice(allocator);
}

/// Builds a default program template with embedded content.
pub fn buildDefaultProgramTemplate(allocator: Allocator, goal: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "# program.md - Techlead Prompt Template\n\n");
    try out.appendSlice(allocator, "<!-- TECHLEAD:GOAL:BEGIN -->\n");
    try out.appendSlice(allocator, goal);
    try out.appendSlice(allocator, "\n<!-- TECHLEAD:GOAL:END -->\n\n");

    try out.appendSlice(allocator, "<!-- TECHLEAD:CONSTRAINTS:BEGIN -->\n");
    try out.appendSlice(
        allocator,
        "- 保持改动聚焦，不要一次改太多。\n" ++
            "- 优先保证可运行和可回滚。\n" ++
            "- 当不确定收益时，倾向舍弃。\n",
    );
    try out.appendSlice(allocator, "<!-- TECHLEAD:CONSTRAINTS:END -->\n\n");

    try out.appendSlice(allocator, "<!-- TECHLEAD:CRITERIA:BEGIN -->\n");
    try out.appendSlice(
        allocator,
        "- 是否更接近 Goal。\n" ++
            "- 代码可读性和复杂度是否更合理。\n" ++
            "- 若可验证，测试和性能是否改善。\n",
    );
    try out.appendSlice(allocator, "<!-- TECHLEAD:CRITERIA:END -->\n\n");

    try out.appendSlice(allocator, "<!-- TECHLEAD:MODE_A:BEGIN -->\n");
    try out.appendSlice(
        allocator,
        "当前处于评估模式（experiment 分支）。\n" ++
            "1. 查看差异：git diff <MAIN_BRANCH>..HEAD\n" ++
            "2. 依据 Goal/Criteria 评估收益。\n" ++
            "3. 若有收益：git checkout <MAIN_BRANCH> && git merge <分支名>，并输出 DECISION: KEEP\n" ++
            "4. 若无收益：git branch -D <分支名>，并输出 DECISION: DISCARD\n" ++
            "5. 简要说明理由。\n",
    );
    try out.appendSlice(allocator, "<!-- TECHLEAD:MODE_A:END -->\n\n");

    try out.appendSlice(allocator, "<!-- TECHLEAD:MODE_B:BEGIN -->\n");
    try out.appendSlice(
        allocator,
        "当前处于新实验模式（主分支）。\n" ++
            "1. 基于 Goal 提出一个可验证的小改进。\n" ++
            "2. 执行：git checkout <MAIN_BRANCH> && git checkout -b experiment-<描述>\n" ++
            "3. 实现改进并提交：git add . && git commit -m \"迭代X: 描述\"\n" ++
            "4. 输出 DECISION: EXPERIMENT_CREATED 与简要说明。\n" ++
            "5. 不要 merge 回主分支。\n",
    );
    try out.appendSlice(allocator, "<!-- TECHLEAD:MODE_B:END -->\n");

    return out.toOwnedSlice(allocator);
}
