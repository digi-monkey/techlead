const std = @import("std");
const config = @import("../config.zig");
const opencode = @import("../opencode.zig");
const provider_api = @import("provider.zig");

/// Default provider backed by existing opencode invocation logic.
pub const OpencodeProvider = struct {
    pub fn asProvider(self: *OpencodeProvider) provider_api.Provider {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    fn runIteration(
        ctx: *anyopaque,
        cfg: config.Config,
        allocator: std.mem.Allocator,
        iteration: usize,
        experiment_branch: ?[]const u8,
        prompt_patch: ?[]const u8,
    ) !provider_api.ExecutionResult {
        _ = ctx;

        const base_prompt = try opencode.preparePrompt(cfg, allocator, iteration, experiment_branch);
        defer allocator.free(base_prompt);

        const prompt = if (prompt_patch) |patch|
            try std.fmt.allocPrint(allocator, "{s}\n\n=== 运行中追加指令 ===\n{s}\n", .{ base_prompt, patch })
        else
            try allocator.dupe(u8, base_prompt);
        defer allocator.free(prompt);

        const success = try opencode.invokeOpencode(cfg, allocator, iteration, prompt);
        return .{ .success = success };
    }

    const vtable = provider_api.Provider.VTable{
        .runIteration = runIteration,
    };
};
