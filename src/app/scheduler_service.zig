const std = @import("std");
const controlplane_store = @import("../storage/controlplane_store.zig");
const task_store = @import("../storage/task_store.zig");

/// SchedulerService provides task scheduling with WRR (Weighted Round Robin) + Aging algorithm.
/// It manages task claiming, lease management, and project weight distribution.
pub const SchedulerService = struct {
    allocator: std.mem.Allocator,
    store: controlplane_store.ControlPlaneStore,

    // WRR + Aging state (protected by mutex)
    mutex: std.Thread.Mutex = .{},
    project_weights: std.StringHashMap(ProjectWeightState),
    last_schedule_time: i64 = 0,

    // Configuration
    config: SchedulerConfig = .{},

    /// Weight state for a single project
    pub const ProjectWeightState = struct {
        project_id: []u8, // owned copy
        base_weight: u32,
        current_weight: i32,
        last_scheduled_at: i64,
        running_tasks: u32,
    };

    /// Scheduler configuration
    pub const SchedulerConfig = struct {
        /// WRR enabled
        wrr_enabled: bool = true,
        /// Aging enabled
        aging_enabled: bool = true,
        /// Aging threshold in milliseconds (60 seconds default)
        aging_threshold_ms: u64 = 60000,
        /// Aging boost per cycle
        aging_boost_per_cycle: i32 = 1,
        /// Maximum aging boost
        max_aging_boost: i32 = 10,
        /// Default lease duration in seconds
        default_lease_seconds: u64 = 300,
        /// Per-project maximum concurrent workers
        per_project_max_workers: u32 = 1,
    };

    /// Initialize a new SchedulerService
    pub fn init(allocator: std.mem.Allocator, store: controlplane_store.ControlPlaneStore) SchedulerService {
        return .{
            .allocator = allocator,
            .store = store,
            .project_weights = std.StringHashMap(ProjectWeightState).init(allocator),
        };
    }

    /// Deinitialize the scheduler service
    pub fn deinit(self: *SchedulerService) void {
        var it = self.project_weights.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.project_id);
        }
        self.project_weights.deinit();
    }

    /// Claim the next task using WRR + Aging scheduling algorithm
    /// Returns null if no tasks are available
    pub fn claimNextTask(self: *SchedulerService, worker_id: []const u8) !?TaskClaim {
        if (worker_id.len == 0) return error.InvalidWorkerId;

        // Get list of enabled projects
        const projects = try self.store.listProjects(.{ .enabled_only = true }, self.allocator);
        defer {
            for (projects) |*p| p.deinit(self.allocator);
            self.allocator.free(projects);
        }

        if (projects.len == 0) return null;

        // Select project using WRR + Aging
        const selected_project_id = self.selectProjectWRR(projects) orelse return null;

        // Try to claim a task from the selected project
        const options = controlplane_store.MultiProjectClaimOptions{
            .owner = worker_id,
            .lease_seconds = self.config.default_lease_seconds,
            .default_max_retries = 3,
            .project_id = selected_project_id,
        };

        const task = try self.store.claimNext(options, self.allocator) orelse return null;

        // Update weight state for the selected project
        self.updateWeightStateAfterSchedule(selected_project_id);

        // Create lease record
        const lease_id = try generateLeaseId(self.allocator);
        defer self.allocator.free(lease_id);

        const now = std.time.timestamp();
        const expires_at = now + @as(i64, @intCast(self.config.default_lease_seconds));

        try self.store.acquireLease(lease_id, task.task_id, selected_project_id, worker_id, expires_at);

        // Get project details for work_dir
        const project = try self.store.getProject(selected_project_id, self.allocator) orelse {
            task.deinit(self.allocator);
            return error.ProjectNotFound;
        };
        defer project.deinit(self.allocator);

        return TaskClaim{
            .task_id = try self.allocator.dupe(u8, task.task_id),
            .project_id = try self.allocator.dupe(u8, selected_project_id),
            .title = try self.allocator.dupe(u8, task.title),
            .prompt = if (task.prompt) |p| try self.allocator.dupe(u8, p) else null,
            .lease_id = lease_id,
            .lease_expires_at = expires_at,
            .work_dir = try self.allocator.dupe(u8, project.work_dir),
            .task = task,
        };
    }

    /// Acquire a lease for a specific task
    pub fn acquireLease(
        self: *SchedulerService,
        task_id: []const u8,
        project_id: []const u8,
        owner: []const u8,
        seconds: u64,
    ) !Lease {
        if (task_id.len == 0) return error.InvalidTaskId;
        if (project_id.len == 0) return error.InvalidProjectId;
        if (owner.len == 0) return error.InvalidOwner;

        const lease_id = try generateLeaseId(self.allocator);
        errdefer self.allocator.free(lease_id);

        const now = std.time.timestamp();
        const expires_at = now + @as(i64, @intCast(seconds));

        try self.store.acquireLease(lease_id, task_id, project_id, owner, expires_at);

        return Lease{
            .lease_id = lease_id,
            .task_id = try self.allocator.dupe(u8, task_id),
            .project_id = try self.allocator.dupe(u8, project_id),
            .owner = try self.allocator.dupe(u8, owner),
            .expires_at = expires_at,
            .acquired_at = now,
        };
    }

    /// Renew an existing lease
    pub fn renewLease(self: *SchedulerService, lease_id: []const u8, seconds: u64) !void {
        if (lease_id.len == 0) return error.InvalidLeaseId;

        // Get existing lease
        const lease = try self.store.getLease(lease_id, self.allocator) orelse return error.LeaseNotFound;
        defer lease.deinit(self.allocator);

        // Release old lease
        try self.store.releaseLease(lease_id, lease.owner);

        // Create new lease with extended expiration
        const now = std.time.timestamp();
        const new_expires_at = now + @as(i64, @intCast(seconds));

        try self.store.acquireLease(lease_id, lease.task_id, lease.project_id, lease.owner, new_expires_at);
    }

    /// Release a lease
    pub fn releaseLease(self: *SchedulerService, lease_id: []const u8, owner: []const u8) !void {
        if (lease_id.len == 0) return error.InvalidLeaseId;
        try self.store.releaseLease(lease_id, owner);
    }

    /// Clean up expired leases and return count of cleaned leases
    pub fn cleanupExpiredLeases(self: *SchedulerService) !u32 {
        return self.store.cleanupExpiredLeases();
    }

    /// Get current weights for all projects (for monitoring/debugging)
    pub fn getProjectWeights(self: *SchedulerService, allocator: std.mem.Allocator) ![]ProjectWeight {
        self.mutex.lock();
        defer self.mutex.unlock();

        var weights = std.ArrayList(ProjectWeight).init(allocator);
        errdefer {
            for (weights.items) |*w| w.deinit(allocator);
            weights.deinit();
        }

        var it = self.project_weights.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.*;
            const now = std.time.milliTimestamp();
            const wait_time_ms = @as(u64, @intCast(@max(0, now - state.last_scheduled_at)));

            try weights.append(allocator, .{
                .project_id = try allocator.dupe(u8, state.project_id),
                .base_weight = state.base_weight,
                .current_weight = state.current_weight,
                .last_scheduled_at = state.last_scheduled_at,
                .wait_time_ms = wait_time_ms,
                .running_tasks = state.running_tasks,
            });
        }

        return weights.toOwnedSlice(allocator);
    }

    /// Update the base weight for a project
    pub fn updateProjectWeight(self: *SchedulerService, project_id: []const u8, weight: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.project_weights.getOrPut(project_id) catch |err| {
            // If key needs to be allocated, do so
            if (err == error.OutOfMemory) return err;
            return;
        };

        if (result.found_existing) {
            result.value_ptr.base_weight = weight;
        } else {
            result.key_ptr.* = try self.allocator.dupe(u8, project_id);
            result.value_ptr.* = .{
                .project_id = result.key_ptr.*,
                .base_weight = weight,
                .current_weight = @intCast(weight),
                .last_scheduled_at = std.time.milliTimestamp(),
                .running_tasks = 0,
            };
        }
    }

    /// Reset aging state for a project
    pub fn resetAging(self: *SchedulerService, project_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.project_weights.getPtr(project_id)) |state| {
            state.last_scheduled_at = std.time.milliTimestamp();
            state.current_weight = @intCast(state.base_weight);
        }
    }

    /// Get current scheduler configuration
    pub fn getConfig(self: *SchedulerService) SchedulerConfig {
        return self.config;
    }

    /// Update scheduler configuration
    pub fn updateConfig(self: *SchedulerService, config: SchedulerConfig) !void {
        self.config = config;
    }

    // === Internal Methods ===

    /// Select a project using WRR + Aging algorithm
    fn selectProjectWRR(self: *SchedulerService, projects: []controlplane_store.Project) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();

        // Initialize or update weight states for all projects
        for (projects) |project| {
            const result = self.project_weights.getOrPut(project.project_id) catch continue;

            if (!result.found_existing) {
                result.key_ptr.* = self.allocator.dupe(u8, project.project_id) catch continue;
                result.value_ptr.* = .{
                    .project_id = result.key_ptr.*,
                    .base_weight = @max(1, project.max_workers),
                    .current_weight = @intCast(@max(1, project.max_workers)),
                    .last_scheduled_at = now,
                    .running_tasks = 0,
                };
            } else {
                // Apply aging: increase weight for projects that haven't been scheduled recently
                if (self.config.aging_enabled) {
                    const wait_time_ms = @as(u64, @intCast(@max(0, now - result.value_ptr.last_scheduled_at)));
                    if (wait_time_ms >= self.config.aging_threshold_ms) {
                        const aging_cycles = @min(wait_time_ms / self.config.aging_threshold_ms, @as(u64, @intCast(self.config.max_aging_boost)));
                        const boost = @as(i32, @intCast(aging_cycles)) * self.config.aging_boost_per_cycle;
                        result.value_ptr.current_weight = @min(result.value_ptr.current_weight + boost, @as(i32, @intCast(result.value_ptr.base_weight)) + self.config.max_aging_boost);
                    }
                }
            }
        }

        // Find project with highest current weight that has available capacity
        var best_project_id: ?[]const u8 = null;
        var best_weight: i32 = -1;

        var it = self.project_weights.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.*;

            // Check if project is in the enabled list
            var project_enabled = false;
            for (projects) |p| {
                if (std.mem.eql(u8, p.project_id, state.project_id)) {
                    project_enabled = true;
                    break;
                }
            }
            if (!project_enabled) continue;

            // Check if project has capacity (per_project_max_workers)
            if (state.running_tasks >= self.config.per_project_max_workers) continue;

            if (state.current_weight > best_weight) {
                best_weight = state.current_weight;
                best_project_id = state.project_id;
            }
        }

        return best_project_id;
    }

    /// Update weight state after scheduling a task
    fn updateWeightStateAfterSchedule(self: *SchedulerService, project_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.project_weights.getPtr(project_id)) |state| {
            // Decrease current weight by base weight (WRR algorithm)
            state.current_weight -= @as(i32, @intCast(state.base_weight));
            state.last_scheduled_at = std.time.milliTimestamp();
            state.running_tasks += 1;
        }
    }

    /// Decrement running task count for a project (call when task completes)
    pub fn decrementRunningTasks(self: *SchedulerService, project_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.project_weights.getPtr(project_id)) |state| {
            if (state.running_tasks > 0) {
                state.running_tasks -= 1;
            }
        }
    }
};

/// Task claim result structure
pub const TaskClaim = struct {
    task_id: []u8,
    project_id: []u8,
    title: []u8,
    prompt: ?[]u8,
    lease_id: []u8,
    lease_expires_at: i64,
    work_dir: []u8,
    task: task_store.Task, // owned, must be freed

    pub fn deinit(self: *TaskClaim, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.project_id);
        allocator.free(self.title);
        if (self.prompt) |p| allocator.free(p);
        allocator.free(self.lease_id);
        allocator.free(self.work_dir);
        self.task.deinit(allocator);
    }
};

/// Lease information structure
pub const Lease = struct {
    lease_id: []u8,
    task_id: []u8,
    project_id: []u8,
    owner: []u8,
    expires_at: i64,
    acquired_at: i64,

    pub fn deinit(self: *Lease, allocator: std.mem.Allocator) void {
        allocator.free(self.lease_id);
        allocator.free(self.task_id);
        allocator.free(self.project_id);
        allocator.free(self.owner);
    }
};

/// Project weight information for monitoring
pub const ProjectWeight = struct {
    project_id: []u8,
    base_weight: u32,
    current_weight: i32,
    last_scheduled_at: i64,
    wait_time_ms: u64,
    running_tasks: u32,

    pub fn deinit(self: *ProjectWeight, allocator: std.mem.Allocator) void {
        allocator.free(self.project_id);
    }
};

/// Generate a unique lease ID
fn generateLeaseId(allocator: std.mem.Allocator) ![]u8 {
    const timestamp = std.time.timestamp();
    const random = std.crypto.random.int(u32);
    return std.fmt.allocPrint(allocator, "lease-{d}-{x}", .{ timestamp, random });
}

// Error types
pub const Error = error{
    InvalidWorkerId,
    InvalidTaskId,
    InvalidProjectId,
    InvalidOwner,
    InvalidLeaseId,
    LeaseNotFound,
    ProjectNotFound,
    TaskNotFound,
    TaskAlreadyClaimed,
};

// Tests
test "SchedulerService - WRR basic project selection" {
    const allocator = std.testing.allocator;

    // Create mock store (we can't easily mock, so we'll test the algorithm directly)
    // Create scheduler with a dummy store
    var scheduler = SchedulerService{
        .allocator = allocator,
        .store = undefined, // Won't be used in this test
        .project_weights = std.StringHashMap(SchedulerService.ProjectWeightState).init(allocator),
        .config = .{
            .wrr_enabled = true,
            .aging_enabled = false, // Disable aging for basic test
            .per_project_max_workers = 2,
        },
    };
    defer {
        var it = scheduler.project_weights.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        scheduler.project_weights.deinit();
    }

    // Create test projects with different weights
    const proj_a = try allocator.dupe(u8, "project-a");
    defer allocator.free(proj_a);
    const proj_b = try allocator.dupe(u8, "project-b");
    defer allocator.free(proj_b);

    const projects = [_]controlplane_store.Project{
        .{ .project_id = proj_a, .work_dir = try allocator.dupe(u8, "/tmp/a"), .enabled = true, .max_workers = 2, .created_at = 0, .updated_at = 0 },
        .{ .project_id = proj_b, .work_dir = try allocator.dupe(u8, "/tmp/b"), .enabled = true, .max_workers = 1, .created_at = 0, .updated_at = 0 },
    };
    defer {
        for (projects) |p| {
            allocator.free(p.project_id);
            allocator.free(p.work_dir);
        }
    }

    // First selection - should pick project-a (higher base weight)
    const first = scheduler.selectProjectWRR(&projects);
    try std.testing.expect(first != null);
    try std.testing.expect(std.mem.eql(u8, first.?, "project-a"));

    // Update weight after scheduling
    scheduler.updateWeightStateAfterSchedule("project-a");

    // Second selection - project-a weight decreased, project-b should win
    const second = scheduler.selectProjectWRR(&projects);
    try std.testing.expect(second != null);
    try std.testing.expect(std.mem.eql(u8, second.?, "project-b"));

    // Update weight after scheduling
    scheduler.updateWeightStateAfterSchedule("project-b");

    // Third selection - both have decreased weights, project-a has higher remaining
    const third = scheduler.selectProjectWRR(&projects);
    try std.testing.expect(third != null);
    try std.testing.expect(std.mem.eql(u8, third.?, "project-a"));
}

test "SchedulerService - WRR respects capacity limit" {
    const allocator = std.testing.allocator;

    var scheduler = SchedulerService{
        .allocator = allocator,
        .store = undefined,
        .project_weights = std.StringHashMap(SchedulerService.ProjectWeightState).init(allocator),
        .config = .{
            .wrr_enabled = true,
            .aging_enabled = false,
            .per_project_max_workers = 1, // Only 1 task per project
        },
    };
    defer {
        var it = scheduler.project_weights.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        scheduler.project_weights.deinit();
    }

    const proj_a = try allocator.dupe(u8, "project-a");
    defer allocator.free(proj_a);

    const projects = [_]controlplane_store.Project{
        .{ .project_id = proj_a, .work_dir = try allocator.dupe(u8, "/tmp/a"), .enabled = true, .max_workers = 1, .created_at = 0, .updated_at = 0 },
    };
    defer {
        for (projects) |p| {
            allocator.free(p.project_id);
            allocator.free(p.work_dir);
        }
    }

    // First selection should work
    const first = scheduler.selectProjectWRR(&projects);
    try std.testing.expect(first != null);

    // Mark as running
    scheduler.updateWeightStateAfterSchedule("project-a");

    // Second selection should return null (at capacity)
    const second = scheduler.selectProjectWRR(&projects);
    try std.testing.expect(second == null);
}

test "SchedulerService - weight state initialization" {
    const allocator = std.testing.allocator;

    var scheduler = SchedulerService{
        .allocator = allocator,
        .store = undefined,
        .project_weights = std.StringHashMap(SchedulerService.ProjectWeightState).init(allocator),
        .config = .{
            .wrr_enabled = true,
            .aging_enabled = false,
        },
    };
    defer {
        var it = scheduler.project_weights.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        scheduler.project_weights.deinit();
    }

    const proj = try allocator.dupe(u8, "test-project");
    defer allocator.free(proj);

    const projects = [_]controlplane_store.Project{
        .{ .project_id = proj, .work_dir = try allocator.dupe(u8, "/tmp/test"), .enabled = true, .max_workers = 5, .created_at = 0, .updated_at = 0 },
    };
    defer {
        for (projects) |p| {
            allocator.free(p.project_id);
            allocator.free(p.work_dir);
        }
    }

    // Trigger weight initialization via selection
    _ = scheduler.selectProjectWRR(&projects);

    // Verify weight state was created
    const state = scheduler.project_weights.get("test-project");
    try std.testing.expect(state != null);
    try std.testing.expectEqual(@as(u32, 5), state.?.base_weight);
    try std.testing.expectEqual(@as(i32, 5), state.?.current_weight);
}
