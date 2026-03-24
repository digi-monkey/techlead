const std = @import("std");

pub const TaskStatus = enum {
    queued,
    claimed,
    running,
    review,
    done,
    failed,
    canceled,
};

pub const ReviewStage = enum {
    none,
    open,
    changes_requested,
    approved,
    merged,
};

pub fn taskStatusFromString(text: []const u8) !TaskStatus {
    if (std.mem.eql(u8, text, "queued")) return .queued;
    if (std.mem.eql(u8, text, "claimed")) return .claimed;
    if (std.mem.eql(u8, text, "running")) return .running;
    if (std.mem.eql(u8, text, "review")) return .review;
    if (std.mem.eql(u8, text, "done")) return .done;
    if (std.mem.eql(u8, text, "failed")) return .failed;
    if (std.mem.eql(u8, text, "canceled")) return .canceled;
    return error.InvalidTaskStatus;
}

pub fn taskStatusToString(status: TaskStatus) []const u8 {
    return @tagName(status);
}

pub fn reviewStageFromString(text: []const u8) !ReviewStage {
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "open")) return .open;
    if (std.mem.eql(u8, text, "changes_requested")) return .changes_requested;
    if (std.mem.eql(u8, text, "approved")) return .approved;
    if (std.mem.eql(u8, text, "merged")) return .merged;
    return error.InvalidReviewStage;
}

pub fn reviewStageToString(stage: ReviewStage) []const u8 {
    return @tagName(stage);
}

pub const Task = struct {
    task_id: []u8,
    title: []u8,
    prompt: ?[]u8,
    status: TaskStatus,
    lease_owner: ?[]u8,
    lease_until: ?i64,
    retry_count: u32,
    max_retries: ?u32,
    priority: i32,
    last_error: ?[]u8,
    review_stage: ReviewStage,
    review_round: u32,
    base_branch: ?[]u8,
    head_branch: ?[]u8,
    head_sha: ?[]u8,
    merge_commit: ?[]u8,
    review_feedback: ?[]u8,
    qa_force_reject_once: bool,
    version: i64,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.title);
        if (self.prompt) |v| allocator.free(v);
        if (self.lease_owner) |v| allocator.free(v);
        if (self.last_error) |v| allocator.free(v);
        if (self.base_branch) |v| allocator.free(v);
        if (self.head_branch) |v| allocator.free(v);
        if (self.head_sha) |v| allocator.free(v);
        if (self.merge_commit) |v| allocator.free(v);
        if (self.review_feedback) |v| allocator.free(v);
    }
};

pub const TaskReviewRole = enum {
    correctness_reviewer,
    maintainability_reviewer,
};

pub fn taskReviewRoleToString(role: TaskReviewRole) []const u8 {
    return @tagName(role);
}

pub const TaskReviewVerdict = enum {
    approve,
    request_changes,
    block,
};

pub fn taskReviewVerdictToString(verdict: TaskReviewVerdict) []const u8 {
    return @tagName(verdict);
}

pub const CreateTaskReviewInput = struct {
    task_id: []const u8,
    review_round: u32,
    role: TaskReviewRole,
    verdict: TaskReviewVerdict,
    score: ?i32,
    summary: []const u8,
    blockers_json: []const u8,
    suggestions_json: []const u8,
    confidence: ?f64,
    reviewer_run_id: ?[]const u8,
};

pub const TaskEvent = struct {
    id: i64,
    task_id: []u8,
    run_id: ?[]u8,
    event_type: []u8,
    payload: []u8,
    operator: ?[]u8,
    source: ?[]u8,
    request_id: ?[]u8,
    created_at: i64,

    pub fn deinit(self: *TaskEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        if (self.run_id) |v| allocator.free(v);
        allocator.free(self.event_type);
        allocator.free(self.payload);
        if (self.operator) |v| allocator.free(v);
        if (self.source) |v| allocator.free(v);
        if (self.request_id) |v| allocator.free(v);
    }
};

pub const ListQuery = struct {
    status: ?TaskStatus = null,
    limit: usize = 50,
    cursor: usize = 0,
    q: ?[]const u8 = null,
};

pub const CreateTaskInput = struct {
    task_id: []const u8,
    title: []const u8,
    prompt: ?[]const u8,
    priority: i32,
    max_retries: ?u32,
    qa_force_reject_once: bool = false,
};

pub const PatchTaskInput = struct {
    title: ?[]const u8,
    prompt: ?[]const u8,
    priority: ?i32,
    max_retries: ?u32,
    version: i64,
};

pub const Action = enum {
    requeue,
    cancel,
    @"resume",
    force_fail,
    retry_review,
    force_merge,
};

pub const OperatorMeta = struct {
    operator: ?[]const u8 = null,
    source: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
};

pub const ClaimOptions = struct {
    owner: []const u8,
    lease_seconds: u64,
    default_max_retries: u32,
};

pub const FailResult = struct {
    status: TaskStatus,
    retry_count: u32,
    max_retries: u32,
};

pub const TaskStore = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        claimNext: *const fn (ctx: *anyopaque, options: ClaimOptions) anyerror!?Task,
        markRunning: *const fn (ctx: *anyopaque, task_id: []const u8, owner: []const u8, lease_seconds: u64, run_id: []const u8) anyerror!void,
        markDone: *const fn (ctx: *anyopaque, task_id: []const u8, owner: []const u8, run_id: []const u8) anyerror!void,
        markFailedOrRequeue: *const fn (ctx: *anyopaque, task_id: []const u8, owner: []const u8, run_id: []const u8, message: []const u8, default_max_retries: u32) anyerror!FailResult,
        markReviewOpen: *const fn (ctx: *anyopaque, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, base_branch: []const u8, head_branch: []const u8, head_sha: []const u8) anyerror!void,
        markReviewApproved: *const fn (ctx: *anyopaque, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32) anyerror!void,
        markReviewChangesRequestedAndRequeue: *const fn (
            ctx: *anyopaque,
            task_id: []const u8,
            owner: []const u8,
            run_id: []const u8,
            review_round: u32,
            feedback: []const u8,
            reason: []const u8,
            default_max_retries: u32,
        ) anyerror!FailResult,
        markMergedDone: *const fn (ctx: *anyopaque, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, merge_commit: []const u8) anyerror!void,
        listTasksJson: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, query: ListQuery) anyerror![]u8,
        getTaskDetailJson: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, task_id: []const u8) anyerror![]u8,
        getTaskEventsJson: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, after_id: i64, limit: usize) anyerror![]u8,
        createTask: *const fn (ctx: *anyopaque, input: CreateTaskInput, meta: OperatorMeta) anyerror!void,
        patchTask: *const fn (ctx: *anyopaque, task_id: []const u8, input: PatchTaskInput, meta: OperatorMeta) anyerror!void,
        createTaskReview: *const fn (ctx: *anyopaque, input: CreateTaskReviewInput) anyerror!void,
        applyAction: *const fn (ctx: *anyopaque, task_id: []const u8, action: Action, meta: OperatorMeta) anyerror!void,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn claimNext(self: TaskStore, options: ClaimOptions) !?Task {
        return self.vtable.claimNext(self.ctx, options);
    }

    pub fn markRunning(self: TaskStore, task_id: []const u8, owner: []const u8, lease_seconds: u64, run_id: []const u8) !void {
        return self.vtable.markRunning(self.ctx, task_id, owner, lease_seconds, run_id);
    }

    pub fn markDone(self: TaskStore, task_id: []const u8, owner: []const u8, run_id: []const u8) !void {
        return self.vtable.markDone(self.ctx, task_id, owner, run_id);
    }

    pub fn markFailedOrRequeue(self: TaskStore, task_id: []const u8, owner: []const u8, run_id: []const u8, message: []const u8, default_max_retries: u32) !FailResult {
        return self.vtable.markFailedOrRequeue(self.ctx, task_id, owner, run_id, message, default_max_retries);
    }

    pub fn markReviewOpen(self: TaskStore, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, base_branch: []const u8, head_branch: []const u8, head_sha: []const u8) !void {
        return self.vtable.markReviewOpen(self.ctx, task_id, owner, run_id, review_round, base_branch, head_branch, head_sha);
    }

    pub fn markReviewApproved(self: TaskStore, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32) !void {
        return self.vtable.markReviewApproved(self.ctx, task_id, owner, run_id, review_round);
    }

    pub fn markReviewChangesRequestedAndRequeue(
        self: TaskStore,
        task_id: []const u8,
        owner: []const u8,
        run_id: []const u8,
        review_round: u32,
        feedback: []const u8,
        reason: []const u8,
        default_max_retries: u32,
    ) !FailResult {
        return self.vtable.markReviewChangesRequestedAndRequeue(
            self.ctx,
            task_id,
            owner,
            run_id,
            review_round,
            feedback,
            reason,
            default_max_retries,
        );
    }

    pub fn markMergedDone(self: TaskStore, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, merge_commit: []const u8) !void {
        return self.vtable.markMergedDone(self.ctx, task_id, owner, run_id, review_round, merge_commit);
    }

    pub fn listTasksJson(self: TaskStore, allocator: std.mem.Allocator, query: ListQuery) ![]u8 {
        return self.vtable.listTasksJson(self.ctx, allocator, query);
    }

    pub fn getTaskDetailJson(self: TaskStore, allocator: std.mem.Allocator, task_id: []const u8) ![]u8 {
        return self.vtable.getTaskDetailJson(self.ctx, allocator, task_id);
    }

    pub fn getTaskEventsJson(self: TaskStore, allocator: std.mem.Allocator, after_id: i64, limit: usize) ![]u8 {
        return self.vtable.getTaskEventsJson(self.ctx, allocator, after_id, limit);
    }

    pub fn createTask(self: TaskStore, input: CreateTaskInput, meta: OperatorMeta) !void {
        return self.vtable.createTask(self.ctx, input, meta);
    }

    pub fn patchTask(self: TaskStore, task_id: []const u8, input: PatchTaskInput, meta: OperatorMeta) !void {
        return self.vtable.patchTask(self.ctx, task_id, input, meta);
    }

    pub fn createTaskReview(self: TaskStore, input: CreateTaskReviewInput) !void {
        return self.vtable.createTaskReview(self.ctx, input);
    }

    pub fn applyAction(self: TaskStore, task_id: []const u8, action: Action, meta: OperatorMeta) !void {
        return self.vtable.applyAction(self.ctx, task_id, action, meta);
    }

    pub fn close(self: TaskStore) void {
        self.vtable.close(self.ctx);
    }
};
