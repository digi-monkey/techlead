const std = @import("std");

const config = @import("config.zig");
const event_store = @import("storage/store.zig");
const sqlite_store = @import("storage/sqlite_store.zig");
const run_service = @import("app/run_service.zig");
const init_service = @import("app/init_service.zig");

const Allocator = std.mem.Allocator;

pub const RunMode = enum {
    session,
    project,
};

/// Runs the main command with explicit execution mode.
pub fn runCommandWithMode(cfg: config.Config, allocator: Allocator, mode: RunMode) !void {
    switch (mode) {
        .project => {
            try run_service.validatePoolRunEnvironment(cfg, allocator);

            var sqlite = try sqlite_store.SqliteEventStore.init(allocator, cfg.work_dir, cfg.log_dir);
            defer sqlite.deinit();
            const primary_es: event_store.EventStore = sqlite.asEventStore();
            const mirror_es: ?event_store.EventStore = null;

            const run_id = try std.fmt.allocPrint(allocator, "run-{d}", .{std.time.timestamp()});
            defer allocator.free(run_id);

            try run_service.executeConfiguredRun(
                cfg,
                allocator,
                .project,
                primary_es,
                mirror_es,
                run_id,
            );
        },
        .session => {
            // TODO: session mode via acpx persistent sessions
            @import("ui.zig").logError("session 模式尚未实现", .{});
            return error.ModeNotImplemented;
        },
    }
}

/// Runs the init command to set up a new project.
pub fn runInitCommand(allocator: Allocator, goal: []const u8, force: bool, target_dir: []const u8) !void {
    return init_service.runInitCommand(allocator, goal, force, target_dir);
}

