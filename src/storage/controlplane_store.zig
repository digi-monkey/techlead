const std = @import("std");
const task_store = @import("task_store.zig");

/// StoreError defines all possible errors from control plane storage operations
pub const StoreError = error{
    // SQLite-specific errors
    DatabaseBusy, // SQLITE_BUSY (5)
    ConstraintViolation, // SQLITE_CONSTRAINT (19)
    SqliteExecFailed,
    SqlitePrepareFailed,
    SqliteColumnNull,
    // Business logic errors
    LeaseExpired,
    TaskNotFound,
    ProjectNotFound,
    ProjectIdExists,
    InvalidStateTransition,
    ActionRejected,
    ForceMergeDisabled,
    OutOfMemory,
    // Data parsing errors
    InvalidTaskStatus,
    InvalidReviewStage,
    // Concurrency errors
    TaskNotClaimed,
};

pub const Project = struct {
    project_id: []u8,
    work_dir: []u8,
    enabled: bool,
    test_cmd: ?[]u8,
    lint_cmd: ?[]u8,
    max_workers: u32,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *const Project, allocator: std.mem.Allocator) void {
        allocator.free(self.project_id);
        allocator.free(self.work_dir);
        if (self.test_cmd) |v| allocator.free(v);
        if (self.lint_cmd) |v| allocator.free(v);
    }
};

pub const Run = struct {
    run_id: []u8,
    project_id: []u8,
    mode: []u8,
    status: []u8,
    worker_id: ?[]u8,
    started_at: i64,
    ended_at: ?i64,

    pub fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.project_id);
        allocator.free(self.mode);
        allocator.free(self.status);
        if (self.worker_id) |v| allocator.free(v);
    }
};

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

pub const RegisterProjectInput = struct {
    project_id: []const u8,
    work_dir: []const u8,
    enabled: bool = true,
    test_cmd: ?[]const u8 = null,
    lint_cmd: ?[]const u8 = null,
    max_workers: u32 = 1,
};

pub const UpdateProjectInput = struct {
    work_dir: ?[]const u8 = null,
    enabled: ?bool = null,
    test_cmd: ?[]const u8 = null,
    lint_cmd: ?[]const u8 = null,
    max_workers: ?u32 = null,
};

pub const ListProjectsQuery = struct {
    enabled_only: bool = false,
    limit: usize = 50,
    cursor: usize = 0,
};

pub const ListTasksByProjectQuery = struct {
    project_id: []const u8,
    status: ?task_store.TaskStatus = null,
    limit: usize = 50,
    cursor: usize = 0,
    q: ?[]const u8 = null,
};

pub const MultiProjectClaimOptions = struct {
    owner: []const u8,
    lease_seconds: u64,
    default_max_retries: u32,
    project_id: ?[]const u8 = null,
};

/// ControlPlaneStore is the interface for control plane storage operations.
/// It manages projects, runs, and leases across multiple projects.
pub const ControlPlaneStore = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Project management
        registerProject: *const fn (ctx: *anyopaque, input: RegisterProjectInput) StoreError!void,
        getProject: *const fn (ctx: *anyopaque, project_id: []const u8, allocator: std.mem.Allocator) StoreError!?Project,
        listProjects: *const fn (ctx: *anyopaque, query: ListProjectsQuery, allocator: std.mem.Allocator) StoreError![]Project,
        updateProject: *const fn (ctx: *anyopaque, project_id: []const u8, input: UpdateProjectInput) StoreError!void,
        deleteProject: *const fn (ctx: *anyopaque, project_id: []const u8) StoreError!void,

        // Multi-project task operations
        createTask: *const fn (ctx: *anyopaque, project_id: []const u8, input: task_store.CreateTaskInput, meta: task_store.OperatorMeta) StoreError!void,
        claimNext: *const fn (ctx: *anyopaque, options: MultiProjectClaimOptions, allocator: std.mem.Allocator) StoreError!?task_store.Task,
        listTasksByProject: *const fn (ctx: *anyopaque, query: ListTasksByProjectQuery, allocator: std.mem.Allocator) StoreError![]u8,
        getTaskDetail: *const fn (ctx: *anyopaque, project_id: []const u8, task_id: []const u8, allocator: std.mem.Allocator) StoreError![]u8,

        // Task state transitions (delegated to project-specific store logic)
        markRunning: *const fn (ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, lease_seconds: u64, run_id: []const u8) StoreError!void,
        markDone: *const fn (ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8) StoreError!void,
        markFailedOrRequeue: *const fn (ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, message: []const u8, default_max_retries: u32) StoreError!task_store.FailResult,
        markReviewOpen: *const fn (ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, base_branch: []const u8, head_branch: []const u8, head_sha: []const u8) StoreError!void,
        markReviewApproved: *const fn (ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32) StoreError!void,
        markReviewChangesRequestedAndRequeue: *const fn (ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, feedback: []const u8, reason: []const u8, default_max_retries: u32) StoreError!task_store.FailResult,
        markMergedDone: *const fn (ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, merge_commit: []const u8) StoreError!void,

        // Task reviews and events
        createTaskReview: *const fn (ctx: *anyopaque, project_id: []const u8, input: task_store.CreateTaskReviewInput) StoreError!void,
        getTaskEvents: *const fn (ctx: *anyopaque, project_id: []const u8, after_id: i64, limit: usize, allocator: std.mem.Allocator) StoreError![]u8,
        applyAction: *const fn (ctx: *anyopaque, project_id: []const u8, task_id: []const u8, action: task_store.Action, meta: task_store.OperatorMeta) StoreError!void,

        // Run management
        createRun: *const fn (ctx: *anyopaque, run_id: []const u8, project_id: []const u8, mode: []const u8, worker_id: ?[]const u8) StoreError!void,
        updateRunStatus: *const fn (ctx: *anyopaque, run_id: []const u8, status: []const u8, ended_at: ?i64) StoreError!void,
        getRun: *const fn (ctx: *anyopaque, run_id: []const u8, allocator: std.mem.Allocator) StoreError!?Run,
        listRunsByProject: *const fn (ctx: *anyopaque, project_id: []const u8, limit: usize, allocator: std.mem.Allocator) StoreError![]Run,

        // Lease management
        acquireLease: *const fn (ctx: *anyopaque, lease_id: []const u8, task_id: []const u8, project_id: []const u8, owner: []const u8, expires_at: i64) StoreError!void,
        releaseLease: *const fn (ctx: *anyopaque, lease_id: []const u8, owner: []const u8) StoreError!void,
        getLease: *const fn (ctx: *anyopaque, task_id: []const u8, allocator: std.mem.Allocator) StoreError!?Lease,

        close: *const fn (ctx: *anyopaque) void,
    };

    // Project management
    pub fn registerProject(self: ControlPlaneStore, input: RegisterProjectInput) StoreError!void {
        return self.vtable.registerProject(self.ctx, input);
    }

    pub fn getProject(self: ControlPlaneStore, project_id: []const u8, allocator: std.mem.Allocator) StoreError!?Project {
        return self.vtable.getProject(self.ctx, project_id, allocator);
    }

    pub fn listProjects(self: ControlPlaneStore, query: ListProjectsQuery, allocator: std.mem.Allocator) StoreError![]Project {
        return self.vtable.listProjects(self.ctx, query, allocator);
    }

    pub fn updateProject(self: ControlPlaneStore, project_id: []const u8, input: UpdateProjectInput) StoreError!void {
        return self.vtable.updateProject(self.ctx, project_id, input);
    }

    pub fn deleteProject(self: ControlPlaneStore, project_id: []const u8) StoreError!void {
        return self.vtable.deleteProject(self.ctx, project_id);
    }

    // Multi-project task operations
    pub fn createTask(self: ControlPlaneStore, project_id: []const u8, input: task_store.CreateTaskInput, meta: task_store.OperatorMeta) StoreError!void {
        return self.vtable.createTask(self.ctx, project_id, input, meta);
    }

    pub fn claimNext(self: ControlPlaneStore, options: MultiProjectClaimOptions, allocator: std.mem.Allocator) StoreError!?task_store.Task {
        return self.vtable.claimNext(self.ctx, options, allocator);
    }

    pub fn listTasksByProject(self: ControlPlaneStore, query: ListTasksByProjectQuery, allocator: std.mem.Allocator) StoreError![]u8 {
        return self.vtable.listTasksByProject(self.ctx, query, allocator);
    }

    pub fn getTaskDetail(self: ControlPlaneStore, project_id: []const u8, task_id: []const u8, allocator: std.mem.Allocator) StoreError![]u8 {
        return self.vtable.getTaskDetail(self.ctx, project_id, task_id, allocator);
    }

    // Task state transitions
    pub fn markRunning(self: ControlPlaneStore, project_id: []const u8, task_id: []const u8, owner: []const u8, lease_seconds: u64, run_id: []const u8) StoreError!void {
        return self.vtable.markRunning(self.ctx, project_id, task_id, owner, lease_seconds, run_id);
    }

    pub fn markDone(self: ControlPlaneStore, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8) StoreError!void {
        return self.vtable.markDone(self.ctx, project_id, task_id, owner, run_id);
    }

    pub fn markFailedOrRequeue(self: ControlPlaneStore, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, message: []const u8, default_max_retries: u32) StoreError!task_store.FailResult {
        return self.vtable.markFailedOrRequeue(self.ctx, project_id, task_id, owner, run_id, message, default_max_retries);
    }

    pub fn markReviewOpen(self: ControlPlaneStore, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, base_branch: []const u8, head_branch: []const u8, head_sha: []const u8) StoreError!void {
        return self.vtable.markReviewOpen(self.ctx, project_id, task_id, owner, run_id, review_round, base_branch, head_branch, head_sha);
    }

    pub fn markReviewApproved(self: ControlPlaneStore, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32) StoreError!void {
        return self.vtable.markReviewApproved(self.ctx, project_id, task_id, owner, run_id, review_round);
    }

    pub fn markReviewChangesRequestedAndRequeue(self: ControlPlaneStore, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, feedback: []const u8, reason: []const u8, default_max_retries: u32) StoreError!task_store.FailResult {
        return self.vtable.markReviewChangesRequestedAndRequeue(self.ctx, project_id, task_id, owner, run_id, review_round, feedback, reason, default_max_retries);
    }

    pub fn markMergedDone(self: ControlPlaneStore, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, merge_commit: []const u8) StoreError!void {
        return self.vtable.markMergedDone(self.ctx, project_id, task_id, owner, run_id, review_round, merge_commit);
    }

    // Task reviews and events
    pub fn createTaskReview(self: ControlPlaneStore, project_id: []const u8, input: task_store.CreateTaskReviewInput) StoreError!void {
        return self.vtable.createTaskReview(self.ctx, project_id, input);
    }

    pub fn getTaskEvents(self: ControlPlaneStore, project_id: []const u8, after_id: i64, limit: usize, allocator: std.mem.Allocator) StoreError![]u8 {
        return self.vtable.getTaskEvents(self.ctx, project_id, after_id, limit, allocator);
    }

    pub fn applyAction(self: ControlPlaneStore, project_id: []const u8, task_id: []const u8, action: task_store.Action, meta: task_store.OperatorMeta) StoreError!void {
        return self.vtable.applyAction(self.ctx, project_id, task_id, action, meta);
    }

    // Run management
    pub fn createRun(self: ControlPlaneStore, run_id: []const u8, project_id: []const u8, mode: []const u8, worker_id: ?[]const u8) StoreError!void {
        return self.vtable.createRun(self.ctx, run_id, project_id, mode, worker_id);
    }

    pub fn updateRunStatus(self: ControlPlaneStore, run_id: []const u8, status: []const u8, ended_at: ?i64) StoreError!void {
        return self.vtable.updateRunStatus(self.ctx, run_id, status, ended_at);
    }

    pub fn getRun(self: ControlPlaneStore, run_id: []const u8, allocator: std.mem.Allocator) StoreError!?Run {
        return self.vtable.getRun(self.ctx, run_id, allocator);
    }

    pub fn listRunsByProject(self: ControlPlaneStore, project_id: []const u8, limit: usize, allocator: std.mem.Allocator) StoreError![]Run {
        return self.vtable.listRunsByProject(self.ctx, project_id, limit, allocator);
    }

    // Lease management
    pub fn acquireLease(self: ControlPlaneStore, lease_id: []const u8, task_id: []const u8, project_id: []const u8, owner: []const u8, expires_at: i64) StoreError!void {
        return self.vtable.acquireLease(self.ctx, lease_id, task_id, project_id, owner, expires_at);
    }

    pub fn releaseLease(self: ControlPlaneStore, lease_id: []const u8, owner: []const u8) StoreError!void {
        return self.vtable.releaseLease(self.ctx, lease_id, owner);
    }

    pub fn getLease(self: ControlPlaneStore, task_id: []const u8, allocator: std.mem.Allocator) StoreError!?Lease {
        return self.vtable.getLease(self.ctx, task_id, allocator);
    }

    pub fn close(self: ControlPlaneStore) void {
        self.vtable.close(self.ctx);
    }
};
