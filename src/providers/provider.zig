const std = @import("std");
const config = @import("../config.zig");

pub const ExecutionResult = struct {
    success: bool,
};

/// Provider is the abstraction boundary between scheduling logic and
/// platform-specific agent execution (opencode/codex/claude, etc.).
pub const Provider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        runPrompt: *const fn (
            ctx: *anyopaque,
            cfg: config.Config,
            allocator: std.mem.Allocator,
            prompt: []const u8,
            log_label: []const u8,
        ) anyerror!ExecutionResult,
    };

    pub fn runPrompt(
        self: Provider,
        cfg: config.Config,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        log_label: []const u8,
    ) !ExecutionResult {
        return self.vtable.runPrompt(self.ctx, cfg, allocator, prompt, log_label);
    }
};
