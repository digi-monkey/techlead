const std = @import("std");
const config = @import("../config.zig");
const provider_api = @import("provider.zig");

/// Placeholder provider for future Claude CLI integration.
pub const ClaudeCliProvider = struct {
    pub fn asProvider(self: *ClaudeCliProvider) provider_api.Provider {
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
        _ = cfg;
        _ = allocator;
        _ = iteration;
        _ = experiment_branch;
        _ = prompt_patch;
        return error.ProviderNotImplemented;
    }

    fn runPrompt(
        ctx: *anyopaque,
        cfg: config.Config,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        log_label: []const u8,
    ) !provider_api.ExecutionResult {
        _ = ctx;
        _ = cfg;
        _ = allocator;
        _ = prompt;
        _ = log_label;
        return error.ProviderNotImplemented;
    }

    const vtable = provider_api.Provider.VTable{
        .runIteration = runIteration,
        .runPrompt = runPrompt,
    };
};
