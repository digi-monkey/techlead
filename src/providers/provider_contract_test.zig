const std = @import("std");
const provider_api = @import("provider.zig");
const config = @import("../config.zig");

const MockProvider = struct {
    should_succeed: bool = true,
    seen_iteration: usize = 0,
    saw_experiment_branch: bool = false,

    pub fn asProvider(self: *MockProvider) provider_api.Provider {
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
        _ = cfg;
        _ = allocator;
        _ = prompt_patch;

        const self: *MockProvider = @ptrCast(@alignCast(ctx));
        self.seen_iteration = iteration;
        self.saw_experiment_branch = experiment_branch != null;

        if (!self.should_succeed) return error.MockFailure;
        return .{ .success = true };
    }

    const vtable = provider_api.Provider.VTable{
        .runIteration = runIteration,
    };
};

fn buildDummyConfig(allocator: std.mem.Allocator) !config.Config {
    return .{
        .iterations = 1,
        .program_file = try allocator.dupe(u8, ".techlead/program.md"),
        .opencode_url = try allocator.dupe(u8, "http://localhost:4096"),
        .work_dir = try allocator.dupe(u8, "."),
        .log_dir = try allocator.dupe(u8, ".techlead/iteration-logs"),
        .model = try allocator.dupe(u8, ""),
        .agent = try allocator.dupe(u8, "Prometheus"),
        .provider = try allocator.dupe(u8, "opencode"),
        .main_branch = try allocator.dupe(u8, "master"),
        .max_branches = 10,
        .pool_lease_seconds = 300,
        .pool_max_retries = 2,
    };
}

test "provider contract: dispatches through vtable and returns success result" {
    const allocator = std.testing.allocator;
    var cfg = try buildDummyConfig(allocator);
    defer config.deinitConfig(allocator, &cfg);

    var mock = MockProvider{ .should_succeed = true };
    const provider = mock.asProvider();

    const result = try provider.runIteration(cfg, allocator, 7, "experiment-x", null);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 7), mock.seen_iteration);
    try std.testing.expect(mock.saw_experiment_branch);
}

test "provider contract: propagates provider error" {
    const allocator = std.testing.allocator;
    var cfg = try buildDummyConfig(allocator);
    defer config.deinitConfig(allocator, &cfg);

    var mock = MockProvider{ .should_succeed = false };
    const provider = mock.asProvider();

    try std.testing.expectError(error.MockFailure, provider.runIteration(cfg, allocator, 1, null, null));
}
