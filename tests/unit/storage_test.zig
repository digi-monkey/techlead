const std = @import("std");
const testing = std.testing;
const techlead = @import("techlead");
const sqlite_controlplane_store = techlead.storage.sqlite_controlplane_store;
const controlplane_store = techlead.storage.controlplane_store;
const task_store = techlead.storage.task_store;

// Test helpers
fn setupTestDb(allocator: std.mem.Allocator) !sqlite_controlplane_store.SqliteControlPlaneStore {
    return try sqlite_controlplane_store.SqliteControlPlaneStore.initInMemory(allocator);
}

fn cleanupTestDb(store: *sqlite_controlplane_store.SqliteControlPlaneStore) void {
    store.deinit();
}

fn createTestProjectId() []const u8 {
    return "test-project-123";
}

fn createTestTaskId() []const u8 {
    return "test-task-456";
}

fn createTestRunId() []const u8 {
    return "test-run-789";
}

// MARK: - Project CRUD Tests

test "project: register and get project" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();

    const input = controlplane_store.RegisterProjectInput{
        .project_id = project_id,
        .work_dir = "/tmp/test-work-dir",
        .enabled = true,
        .test_cmd = "npm test",
        .lint_cmd = "npm run lint",
        .max_workers = 2,
    };

    try cp_store.registerProject(input);

    const project_opt = try cp_store.getProject(project_id, allocator);
    try testing.expect(project_opt != null);

    var project = project_opt.?;
    defer project.deinit(allocator);

    try testing.expectEqualStrings(project_id, project.project_id);
    try testing.expectEqualStrings("/tmp/test-work-dir", project.work_dir);
    try testing.expectEqual(true, project.enabled);
    try testing.expect(project.created_at > 0);
}

test "project: get non-existent project returns null" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();

    const project_opt = try cp_store.getProject("non-existent-project", allocator);
    try testing.expect(project_opt == null);
}

test "project: list projects" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();

    for (0..3) |i| {
        const project_id = try std.fmt.allocPrint(allocator, "test-project-{d}", .{i});
        defer allocator.free(project_id);

        const input = controlplane_store.RegisterProjectInput{
            .project_id = project_id,
            .work_dir = "/tmp/test-work-dir",
            .enabled = i % 2 == 0,
            .max_workers = 1,
        };

        try cp_store.registerProject(input);
    }

    const query = controlplane_store.ListProjectsQuery{
        .enabled_only = false,
        .limit = 10,
        .cursor = 0,
    };

    const projects = try cp_store.listProjects(query, allocator);
    defer {
        for (projects) |*p| p.deinit(allocator);
        allocator.free(projects);
    }

    try testing.expect(projects.len >= 3);
}

test "project: update project" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();

    const input = controlplane_store.RegisterProjectInput{
        .project_id = project_id,
        .work_dir = "/tmp/test-work-dir",
        .enabled = true,
        .max_workers = 1,
    };
    try cp_store.registerProject(input);

    const update = controlplane_store.UpdateProjectInput{
        .work_dir = "/tmp/updated-work-dir",
        .enabled = false,
        .test_cmd = "cargo test",
        .max_workers = 4,
    };

    try cp_store.updateProject(project_id, update);

    const project_opt = try cp_store.getProject(project_id, allocator);
    try testing.expect(project_opt != null);

    var project = project_opt.?;
    defer project.deinit(allocator);

    try testing.expectEqualStrings("/tmp/updated-work-dir", project.work_dir);
    try testing.expectEqual(false, project.enabled);
}

test "project: delete project" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();

    const input = controlplane_store.RegisterProjectInput{
        .project_id = project_id,
        .work_dir = "/tmp/test-work-dir",
        .enabled = true,
        .max_workers = 1,
    };
    try cp_store.registerProject(input);

    try cp_store.deleteProject(project_id);

    const project_opt = try cp_store.getProject(project_id, allocator);
    try testing.expect(project_opt == null);
}

// MARK: - Task CRUD Tests

test "task: create and claim next" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();

    const project_input = controlplane_store.RegisterProjectInput{
        .project_id = project_id,
        .work_dir = "/tmp/test-work-dir",
        .enabled = true,
        .max_workers = 1,
    };
    try cp_store.registerProject(project_input);

    const task_id = createTestTaskId();
    const task_input = task_store.CreateTaskInput{
        .task_id = task_id,
        .title = "Test Task",
        .prompt = "This is a test prompt",
        .priority = 5,
        .max_retries = 3,
        .qa_force_reject_once = false,
    };

    const meta = task_store.OperatorMeta{
        .operator = "test-operator",
        .source = "test",
        .request_id = "req-123",
    };

    try cp_store.createTask(project_id, task_input, meta);

    const claim_options = controlplane_store.MultiProjectClaimOptions{
        .owner = "test-worker",
        .lease_seconds = 300,
        .default_max_retries = 3,
        .project_id = project_id,
    };

    const claimed_task_opt = try cp_store.claimNext(claim_options, allocator);
    try testing.expect(claimed_task_opt != null);

    if (claimed_task_opt) |claimed_task| {
        var task = claimed_task;
        defer task.deinit(allocator);

        try testing.expectEqualStrings(task_id, task.task_id);
        try testing.expectEqual(task_store.TaskStatus.claimed, task.status);
        try testing.expectEqualStrings("test-worker", task.lease_owner.?);
    }
}

test "task: claim next returns null when no queued tasks" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();

    const project_input = controlplane_store.RegisterProjectInput{
        .project_id = project_id,
        .work_dir = "/tmp/test-work-dir",
        .enabled = true,
        .max_workers = 1,
    };
    try cp_store.registerProject(project_input);

    const claim_options = controlplane_store.MultiProjectClaimOptions{
        .owner = "test-worker",
        .lease_seconds = 300,
        .default_max_retries = 3,
        .project_id = project_id,
    };

    const claimed_task_opt = try cp_store.claimNext(claim_options, allocator);
    try testing.expect(claimed_task_opt == null);
}

test "task: list tasks by project" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();

    const project_input = controlplane_store.RegisterProjectInput{
        .project_id = project_id,
        .work_dir = "/tmp/test-work-dir",
        .enabled = true,
        .max_workers = 1,
    };
    try cp_store.registerProject(project_input);

    for (0..5) |i| {
        const task_id = try std.fmt.allocPrint(allocator, "test-task-{d}", .{i});
        defer allocator.free(task_id);

        const task_title = try std.fmt.allocPrint(allocator, "Task {d}", .{i});
        defer allocator.free(task_title);

        const task_input = task_store.CreateTaskInput{
            .task_id = task_id,
            .title = task_title,
            .prompt = null,
            .priority = @intCast(i),
            .max_retries = null,
        };

        const meta = task_store.OperatorMeta{};
        try cp_store.createTask(project_id, task_input, meta);
    }

    const query = controlplane_store.ListTasksByProjectQuery{
        .project_id = project_id,
        .status = null,
        .limit = 10,
        .cursor = 0,
        .q = null,
    };

    const json_output = try cp_store.listTasksByProject(query, allocator);
    defer allocator.free(json_output);

    const json_str = std.mem.sliceTo(json_output, 0);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"tasks\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"summary\"") != null);
}

test "task: get task detail" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();

    const project_input = controlplane_store.RegisterProjectInput{
        .project_id = project_id,
        .work_dir = "/tmp/test-work-dir",
        .enabled = true,
        .max_workers = 1,
    };
    try cp_store.registerProject(project_input);

    const task_id = createTestTaskId();
    const task_input = task_store.CreateTaskInput{
        .task_id = task_id,
        .title = "Test Task for Detail",
        .prompt = "Test prompt",
        .priority = 1,
        .max_retries = null,
    };

    const meta = task_store.OperatorMeta{};
    try cp_store.createTask(project_id, task_input, meta);

    const detail_json = try cp_store.getTaskDetail(project_id, task_id, allocator);
    defer allocator.free(detail_json);

    const json_str = std.mem.sliceTo(detail_json, 0);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"task\"") != null);
}

test "task: get non-existent task detail returns error" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();

    const project_input = controlplane_store.RegisterProjectInput{
        .project_id = project_id,
        .work_dir = "/tmp/test-work-dir",
        .enabled = true,
        .max_workers = 1,
    };
    try cp_store.registerProject(project_input);

    const result = cp_store.getTaskDetail(project_id, "non-existent-task", allocator);
    try testing.expectError(error.TaskNotFound, result);
}

// MARK: - Task State Transition Tests

test "task: mark running after claim" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();
    const task_id = createTestTaskId();
    const run_id = createTestRunId();

    try cp_store.registerProject(.{
        .project_id = project_id,
        .work_dir = "/tmp/test",
        .enabled = true,
        .max_workers = 1,
    });

    try cp_store.createTask(project_id, .{
        .task_id = task_id,
        .title = "Test Task",
        .prompt = null,
        .priority = 1,
        .max_retries = null,
    }, .{});

    const claimed_task1 = try cp_store.claimNext(.{
        .owner = "test-worker",
        .lease_seconds = 300,
        .default_max_retries = 3,
        .project_id = project_id,
    }, allocator);
    if (claimed_task1) |task| {
        var t = task;
        t.deinit(allocator);
    }

    try cp_store.markRunning(project_id, task_id, "test-worker", 600, run_id);

    const detail = try cp_store.getTaskDetail(project_id, task_id, allocator);
    defer allocator.free(detail);

    try testing.expect(std.mem.indexOf(u8, detail, "\"running\"") != null);
}

test "task: mark done from running" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();
    const task_id = createTestTaskId();
    const run_id = createTestRunId();

    try cp_store.registerProject(.{
        .project_id = project_id,
        .work_dir = "/tmp/test",
        .enabled = true,
        .max_workers = 1,
    });

    try cp_store.createTask(project_id, .{
        .task_id = task_id,
        .title = "Test Task",
        .prompt = null,
        .priority = 1,
        .max_retries = null,
    }, .{});

    const claimed_task2 = try cp_store.claimNext(.{
        .owner = "test-worker",
        .lease_seconds = 300,
        .default_max_retries = 3,
        .project_id = project_id,
    }, allocator);
    if (claimed_task2) |task| {
        var t = task;
        t.deinit(allocator);
    }

    try cp_store.markRunning(project_id, task_id, "test-worker", 600, run_id);
    try cp_store.markDone(project_id, task_id, "test-worker", run_id);

    const detail = try cp_store.getTaskDetail(project_id, task_id, allocator);
    defer allocator.free(detail);

    try testing.expect(std.mem.indexOf(u8, detail, "\"done\"") != null);
}

test "task: review workflow - open, approve, merge" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();
    const task_id = createTestTaskId();
    const run_id = createTestRunId();

    try cp_store.registerProject(.{
        .project_id = project_id,
        .work_dir = "/tmp/test",
        .enabled = true,
        .max_workers = 1,
    });

    try cp_store.createTask(project_id, .{
        .task_id = task_id,
        .title = "Test Task",
        .prompt = null,
        .priority = 1,
        .max_retries = null,
    }, .{});

    const claimed_task3 = try cp_store.claimNext(.{
        .owner = "test-worker",
        .lease_seconds = 300,
        .default_max_retries = 3,
        .project_id = project_id,
    }, allocator);
    if (claimed_task3) |task| {
        var t = task;
        t.deinit(allocator);
    }

    try cp_store.markRunning(project_id, task_id, "test-worker", 600, run_id);
    try cp_store.markReviewOpen(project_id, task_id, "test-worker", run_id, 1, "main", "feature-branch", "abc123");
    try cp_store.markReviewApproved(project_id, task_id, "test-worker", run_id, 1);
    try cp_store.markMergedDone(project_id, task_id, "test-worker", run_id, 1, "merge-commit-abc");

    const detail = try cp_store.getTaskDetail(project_id, task_id, allocator);
    defer allocator.free(detail);

    try testing.expect(std.mem.indexOf(u8, detail, "\"done\"") != null);
}

// MARK: - Run Management Tests

test "run: create and get run" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();
    const run_id = createTestRunId();

    try cp_store.registerProject(.{
        .project_id = project_id,
        .work_dir = "/tmp/test",
        .enabled = true,
        .max_workers = 1,
    });

    try cp_store.createRun(run_id, project_id, "session", "worker-1");

    const run_opt = try cp_store.getRun(run_id, allocator);
    try testing.expect(run_opt != null);

    var run = run_opt.?;
    defer run.deinit(allocator);

    try testing.expectEqualStrings(run_id, run.run_id);
    try testing.expectEqualStrings(project_id, run.project_id);
}

test "run: update run status" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();
    const project_id = createTestProjectId();
    const run_id = createTestRunId();

    try cp_store.registerProject(.{
        .project_id = project_id,
        .work_dir = "/tmp/test",
        .enabled = true,
        .max_workers = 1,
    });

    try cp_store.createRun(run_id, project_id, "session", null);

    const now = std.time.timestamp();
    try cp_store.updateRunStatus(run_id, "completed", now);

    const run_opt = try cp_store.getRun(run_id, allocator);
    try testing.expect(run_opt != null);

    var run = run_opt.?;
    defer run.deinit(allocator);

    try testing.expectEqualStrings("completed", run.status);
}

// MARK: - Token Management Tests

test "token: set and get token" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();

    try cp_store.setToken("api-key", "secret-value-123");

    const token_opt = try cp_store.getToken("api-key", allocator);
    try testing.expect(token_opt != null);

    const token = token_opt.?;
    defer allocator.free(token);

    try testing.expectEqualStrings("secret-value-123", token);
}

test "token: get non-existent token returns null" {
    const allocator = testing.allocator;

    var store = try setupTestDb(allocator);
    defer cleanupTestDb(&store);

    const cp_store = store.asControlPlaneStore();

    const token_opt = try cp_store.getToken("non-existent-token", allocator);
    try testing.expect(token_opt == null);
}
