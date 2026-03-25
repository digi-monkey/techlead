const std = @import("std");
const controlplane_store = @import("../storage/controlplane_store.zig");
const task_store = @import("../storage/task_store.zig");
const project_service = @import("project_service.zig");
const scheduler_service = @import("scheduler_service.zig");

/// MultiPoolService manages multiple project pools with worker coordination.
/// It provides the main entry point for running multi-project task processing.
pub const MultiPoolService = struct {
    allocator: std.mem.Allocator,
    project_svc: project_service.ProjectService,
    scheduler: scheduler_service.SchedulerService,
    store: controlplane_store.ControlPlaneStore,

    // Runtime state (protected by mutex)
    mutex: std.Thread.Mutex = .{},
    running: bool = false,
    stop_requested: bool = false,
    active_project_ids: std.StringHashMap(void), // Set of active project IDs
    active_runs: std.StringHashMap(RunInfo), // run_id -> RunInfo

    // Worker management
    worker_pool: WorkerPool,

    // Statistics
    stats: Stats = .{},

    /// Information about an active run
    const RunInfo = struct {
        run_id: []u8, // owned
        project_id: []u8, // owned
        worker_id: []u8, // owned
        started_at: i64,
        mode: []u8, // owned
    };

    /// Worker pool configuration
    const WorkerPool = struct {
        max_workers: u32,
        active_workers: u32 = 0,
    };

    /// Statistics
    const Stats = struct {
        total_tasks_claimed: u64 = 0,
        total_tasks_completed: u64 = 0,
        total_tasks_failed: u64 = 0,
    };

    /// Task execution result union
    const TaskExecutionResult = union(enum) {
        success: TaskSuccessResult,
        failure: TaskFailureResult,
    };

    const TaskSuccessResult = struct {
        needs_review: bool,
        review_round: u32,
        base_branch: ?[]const u8,
        head_branch: ?[]const u8,
        head_sha: ?[]const u8,
    };

    const TaskFailureResult = struct {
        message: []u8,
    };

    /// Pool status information
    pub const PoolStatus = struct {
        is_running: bool,
        active_runs: []RunStatus,
        total_projects: u32,
        active_projects: u32,
        total_queued_tasks: u32,
        total_running_tasks: u32,

        pub fn deinit(self: *PoolStatus, allocator: std.mem.Allocator) void {
            for (self.active_runs) |*r| r.deinit(allocator);
            allocator.free(self.active_runs);
        }
    };

    /// Run status for pool status
    pub const RunStatus = struct {
        run_id: []u8,
        project_id: []u8,
        status: []u8,
        started_at: i64,

        pub fn deinit(self: *RunStatus, allocator: std.mem.Allocator) void {
            allocator.free(self.run_id);
            allocator.free(self.project_id);
            allocator.free(self.status);
        }
    };

    /// Run options for starting the pool
    pub const RunOptions = struct {
        project_ids: ?[][]const u8 = null, // null = all active projects
        max_workers: u32 = 4,
        mode: []const u8 = "pool",
    };

    /// Initialize a new MultiPoolService
    pub fn init(
        allocator: std.mem.Allocator,
        project_svc: project_service.ProjectService,
        scheduler: scheduler_service.SchedulerService,
        store: controlplane_store.ControlPlaneStore,
    ) MultiPoolService {
        return .{
            .allocator = allocator,
            .project_svc = project_svc,
            .scheduler = scheduler,
            .store = store,
            .active_project_ids = std.StringHashMap(void).init(allocator),
            .active_runs = std.StringHashMap(RunInfo).init(allocator),
            .worker_pool = .{ .max_workers = 4 },
        };
    }

    /// Deinitialize the multi-pool service
    pub fn deinit(self: *MultiPoolService) void {
        // Stop if running
        if (self.running) {
            self.stop() catch {};
        }

        // Clean up active project IDs
        var proj_it = self.active_project_ids.keyIterator();
        while (proj_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.active_project_ids.deinit();

        // Clean up active runs
        var run_it = self.active_runs.valueIterator();
        while (run_it.next()) |run_info| {
            self.allocator.free(run_info.run_id);
            self.allocator.free(run_info.project_id);
            self.allocator.free(run_info.worker_id);
            self.allocator.free(run_info.mode);
        }
        self.active_runs.deinit();
    }

    /// Run the multi-project pool (main entry point)
    pub fn run(self: *MultiPoolService, options: RunOptions) !void {
        self.mutex.lock();

        if (self.running) {
            self.mutex.unlock();
            return error.AlreadyRunning;
        }

        self.running = true;
        self.stop_requested = false;
        self.worker_pool.max_workers = options.max_workers;
        self.mutex.unlock();

        // Initialize active projects
        try self.initializeProjects(options.project_ids);

        // Main loop
        var worker_counter: u32 = 0;

        while (true) {
            self.mutex.lock();
            const should_stop = self.stop_requested;
            const active_workers = self.worker_pool.active_workers;
            const max_workers = self.worker_pool.max_workers;
            self.mutex.unlock();

            if (should_stop and active_workers == 0) {
                break;
            }

            // Check if we can spawn more workers
            if (!should_stop and active_workers < max_workers) {
                // Try to claim a task
                const worker_id = try std.fmt.allocPrint(self.allocator, "worker-{d}", .{worker_counter});
                defer self.allocator.free(worker_id);

                if (try self.scheduler.claimNextTask(worker_id)) |claim| {
                    // Spawn worker to process task
                    worker_counter += 1;

                    self.mutex.lock();
                    self.worker_pool.active_workers += 1;
                    self.stats.total_tasks_claimed += 1;
                    self.mutex.unlock();

                    // Process task synchronously for now
                    // In a full implementation, this would spawn a thread
                    self.processTask(&claim) catch |err| {
                        std.log.err("Task processing failed: {s}", .{@errorName(err)});
                    };

                    self.mutex.lock();
                    self.worker_pool.active_workers -= 1;
                    self.mutex.unlock();

                    claim.deinit(self.allocator);
                } else {
                    // No tasks available, sleep before retry
                    std.Thread.sleep(1 * std.time.ns_per_s);
                }
            } else {
                // Max workers reached or stopping, sleep briefly
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }

        self.mutex.lock();
        self.running = false;
        self.mutex.unlock();
    }

    /// Stop the pool gracefully
    pub fn stop(self: *MultiPoolService) !void {
        self.mutex.lock();
        if (!self.running) {
            self.mutex.unlock();
            return error.NotRunning;
        }
        self.stop_requested = true;
        self.mutex.unlock();

        // Wait for workers to complete
        while (true) {
            self.mutex.lock();
            const active_workers = self.worker_pool.active_workers;
            self.mutex.unlock();

            if (active_workers == 0) break;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    /// Add a project to the pool dynamically
    pub fn addProjectToPool(self: *MultiPoolService, project_id: []const u8) !void {
        if (project_id.len == 0) return error.InvalidProjectId;

        // Check if project exists and is enabled
        const project = try self.project_svc.getProject(project_id) orelse return error.ProjectNotFound;
        defer project.deinit(self.allocator);

        if (!project.enabled) {
            return error.ProjectNotEnabled;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Add to active set
        if (!self.active_project_ids.contains(project_id)) {
            const owned_id = try self.allocator.dupe(u8, project_id);
            try self.active_project_ids.put(owned_id, {});
        }
    }

    /// Remove a project from the pool
    pub fn removeProjectFromPool(self: *MultiPoolService, project_id: []const u8) !void {
        if (project_id.len == 0) return error.InvalidProjectId;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.active_project_ids.fetchRemove(project_id)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Get current pool status
    pub fn getStatus(self: *MultiPoolService) !PoolStatus {
        self.mutex.lock();
        const is_running = self.running;
        const total_projects = @as(u32, @intCast(self.active_project_ids.count()));
        self.mutex.unlock();

        // Get all runs
        var runs = std.ArrayList(RunStatus).init(self.allocator);
        errdefer {
            for (runs.items) |*r| r.deinit(self.allocator);
            runs.deinit();
        }

        // Collect run information
        self.mutex.lock();
        var it = self.active_runs.valueIterator();
        while (it.next()) |run_info| {
            const run_data = try self.project_svc.store.getRun(run_info.run_id, self.allocator);
            if (run_data) |r| {
                defer r.deinit(self.allocator);
                try runs.append(self.allocator, .{
                    .run_id = try self.allocator.dupe(u8, r.run_id),
                    .project_id = try self.allocator.dupe(u8, r.project_id),
                    .status = try self.allocator.dupe(u8, r.status),
                    .started_at = r.started_at,
                });
            }
        }
        self.mutex.unlock();

        return PoolStatus{
            .is_running = is_running,
            .active_runs = try runs.toOwnedSlice(self.allocator),
            .total_projects = total_projects,
            .active_projects = total_projects, // For now, all tracked projects are active
            .total_queued_tasks = 0, // Would need to query from store
            .total_running_tasks = 0, // Would need to query from store
        };
    }

    /// Get list of active project IDs
    pub fn getActiveProjectIds(self: *MultiPoolService, allocator: std.mem.Allocator) ![][]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var ids = std.ArrayList([]u8).init(allocator);
        errdefer {
            for (ids.items) |id| allocator.free(id);
            ids.deinit();
        }

        var it = self.active_project_ids.keyIterator();
        while (it.next()) |key| {
            try ids.append(allocator, try allocator.dupe(u8, key.*));
        }

        return ids.toOwnedSlice(allocator);
    }

    /// Wait for pool to complete (blocking)
    pub fn waitForCompletion(self: *MultiPoolService) !void {
        while (true) {
            self.mutex.lock();
            const running = self.running;
            const active_workers = self.worker_pool.active_workers;
            self.mutex.unlock();

            if (!running or active_workers == 0) break;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    // === Internal Methods ===

    /// Initialize active projects list
    fn initializeProjects(self: *MultiPoolService, project_ids: ?[][]const u8) !void {
        if (project_ids) |ids| {
            // Use specified projects
            for (ids) |id| {
                try self.addProjectToPool(id);
            }
        } else {
            // Use all enabled projects
            const projects = try self.project_svc.listProjects(.{ .enabled_only = true });
            defer {
                for (projects) |*p| p.deinit(self.allocator);
                self.allocator.free(projects);
            }

            for (projects) |project| {
                try self.addProjectToPool(project.project_id);
            }
        }
    }

    /// Process a claimed task with full lifecycle management
    fn processTask(self: *MultiPoolService, claim: *const scheduler_service.TaskClaim) !void {
        // Generate a run_id for this execution
        const run_id = try generateRunId(self.allocator);
        defer self.allocator.free(run_id);

        const worker_id = claim.lease_id; // Use lease_id as worker identifier
        const lease_seconds: u64 = @intCast(@max(0, claim.lease_expires_at - std.time.timestamp()));

        std.log.info("Processing task {s} from project {s} (run: {s})", .{ claim.task_id, claim.project_id, run_id });

        // 1. Mark task as running in the store
        self.store.markRunning(claim.project_id, claim.task_id, worker_id, lease_seconds, run_id) catch |err| {
            std.log.err("Failed to mark task as running: {s}", .{@errorName(err)});
            self.scheduler.decrementRunningTasks(claim.project_id);
            return err;
        };

        // 2. Execute the task (real execution)
        const exec_result = executeTask(self.allocator, claim, run_id);

        // 3. Handle completion based on execution result
        switch (exec_result) {
            .success => |result| {
                if (result.needs_review) {
                    // Task completed but needs review - mark review open
                    const base_branch = result.base_branch orelse "main";
                    const head_branch = result.head_branch orelse "unknown";
                    const head_sha = result.head_sha orelse "unknown";

                    self.store.markReviewOpen(
                        claim.project_id,
                        claim.task_id,
                        worker_id,
                        run_id,
                        result.review_round,
                        base_branch,
                        head_branch,
                        head_sha,
                    ) catch |err| {
                        std.log.err("Failed to mark review open: {s}", .{@errorName(err)});
                    };

                    std.log.info("Task {s} completed with review opened (round {d})", .{ claim.task_id, result.review_round });
                } else {
                    // Task completed successfully - mark as done
                    self.store.markDone(claim.project_id, claim.task_id, worker_id, run_id) catch |err| {
                        std.log.err("Failed to mark task as done: {s}", .{@errorName(err)});
                    };

                    self.mutex.lock();
                    self.stats.total_tasks_completed += 1;
                    self.mutex.unlock();

                    std.log.info("Task {s} completed successfully", .{claim.task_id});
                }
            },
            .failure => |failure| {
                defer self.allocator.free(failure.message);

                // Task failed - mark as failed or requeue based on retry policy
                const fail_result = self.store.markFailedOrRequeue(
                    claim.project_id,
                    claim.task_id,
                    worker_id,
                    run_id,
                    failure.message,
                    3, // default_max_retries
                ) catch |err| blk: {
                    std.log.err("Failed to mark task as failed/requeue: {s}", .{@errorName(err)});
                    // Return default fail result on error
                    break :blk .{ .status = .failed, .retry_count = 0, .max_retries = 3 };
                };

                self.mutex.lock();
                if (fail_result.status == .failed) {
                    self.stats.total_tasks_failed += 1;
                    std.log.err("Task {s} failed permanently after {d}/{d} retries: {s}", .{
                        claim.task_id,
                        fail_result.retry_count,
                        fail_result.max_retries,
                        failure.message,
                    });
                } else {
                    std.log.warn("Task {s} failed and requeued ({d}/{d} retries): {s}", .{
                        claim.task_id,
                        fail_result.retry_count,
                        fail_result.max_retries,
                        failure.message,
                    });
                }
                self.mutex.unlock();
            },
        }

        // 4. Decrement running tasks in scheduler (always do this)
        self.scheduler.decrementRunningTasks(claim.project_id);
    }

    /// Execute a task and return the result
    /// This is the actual task execution logic (replaces simulated sleep)
    fn executeTask(
        allocator: std.mem.Allocator,
        claim: *const scheduler_service.TaskClaim,
        run_id: []const u8,
    ) TaskExecutionResult {
        // TODO: In a full implementation, this would:
        // - Set up the work directory
        // - Run the actual task code/prompt
        // - Handle git operations
        // - Collect results
        //
        // For now, we implement a basic execution that:
        // - Validates the work directory exists
        // - Logs the execution
        // - Returns success (placeholder for real implementation)

        _ = run_id;

        // Validate work directory
        std.fs.accessAbsolute(claim.work_dir, .{}) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Work directory inaccessible: {s}", .{@errorName(err)}) catch "Work directory inaccessible";
            return .{ .failure = .{ .message = msg } };
        };

        std.log.info("Executing task {s} in {s}", .{ claim.task_id, claim.work_dir });

        // Placeholder: Simulate actual work being done
        // In a real implementation, this would:
        // 1. Parse the task prompt
        // 2. Execute the appropriate actions
        // 3. Handle git operations (branch creation, commits)
        // 4. Return proper results with branch/SHA info
        std.Thread.sleep(10 * std.time.ns_per_ms);

        // Return success (placeholder - no review needed for basic execution)
        return .{ .success = .{
            .needs_review = false,
            .review_round = 0,
            .base_branch = null,
            .head_branch = null,
            .head_sha = null,
        } };
    }

    /// Generate a unique run ID
    fn generateRunId(allocator: std.mem.Allocator) ![]u8 {
        const timestamp = std.time.timestamp();
        const random = std.crypto.random.int(u32);
        return std.fmt.allocPrint(allocator, "run-{d}-{x}", .{ timestamp, random });
    }
};

// Error types
pub const Error = error{
    InvalidProjectId,
    ProjectNotFound,
    ProjectNotEnabled,
    AlreadyRunning,
    NotRunning,
};

// Tests
test "MultiPoolService - basic lifecycle" {
    // Full integration tests require a store
    // Unit tests would be added here
}
