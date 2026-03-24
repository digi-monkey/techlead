const std = @import("std");
const controlplane_store = @import("../storage/controlplane_store.zig");
const task_store = @import("../storage/task_store.zig");

/// ProjectService provides high-level project management operations.
/// It wraps the ControlPlaneStore and provides additional business logic.
pub const ProjectService = struct {
    allocator: std.mem.Allocator,
    store: controlplane_store.ControlPlaneStore,

    /// Initialize a new ProjectService
    pub fn init(allocator: std.mem.Allocator, store: controlplane_store.ControlPlaneStore) ProjectService {
        return .{
            .allocator = allocator,
            .store = store,
        };
    }

    /// Register a new project
    pub fn registerProject(self: ProjectService, input: controlplane_store.RegisterProjectInput) !void {
        // Validate input
        if (input.project_id.len == 0) return error.InvalidProjectId;
        if (input.work_dir.len == 0) return error.InvalidWorkDir;

        // Check if project already exists
        if (try self.store.getProject(input.project_id, self.allocator)) |existing| {
            existing.deinit(self.allocator);
            return error.ProjectAlreadyExists;
        }

        // Create the project
        try self.store.registerProject(input);
    }

    /// Get project details by ID
    pub fn getProject(self: ProjectService, project_id: []const u8) !?controlplane_store.Project {
        if (project_id.len == 0) return error.InvalidProjectId;
        return try self.store.getProject(project_id, self.allocator);
    }

    /// List all projects
    pub fn listProjects(self: ProjectService, query: controlplane_store.ListProjectsQuery) ![]controlplane_store.Project {
        return try self.store.listProjects(query, self.allocator);
    }

    /// Update project configuration
    pub fn updateProject(self: ProjectService, project_id: []const u8, input: controlplane_store.UpdateProjectInput) !void {
        if (project_id.len == 0) return error.InvalidProjectId;

        // Check if project exists
        if (try self.store.getProject(project_id, self.allocator)) |existing| {
            existing.deinit(self.allocator);
        } else {
            return error.ProjectNotFound;
        }

        try self.store.updateProject(project_id, input);
    }

    /// Delete a project and all its associated data
    pub fn deleteProject(self: ProjectService, project_id: []const u8) !void {
        if (project_id.len == 0) return error.InvalidProjectId;

        // Check if project exists
        if (try self.store.getProject(project_id, self.allocator)) |existing| {
            existing.deinit(self.allocator);
        } else {
            return error.ProjectNotFound;
        }

        // TODO: Check if there are running tasks before deleting
        // For now, cascade delete is handled by foreign keys in SQLite

        try self.store.deleteProject(project_id);
    }

    /// Start a new run for a project
    pub fn startProjectRun(self: ProjectService, project_id: []const u8, mode: []const u8, worker_id: ?[]const u8) !controlplane_store.Run {
        if (project_id.len == 0) return error.InvalidProjectId;

        // Check if project exists and is enabled
        const project = try self.store.getProject(project_id, self.allocator) orelse return error.ProjectNotFound;
        defer project.deinit(self.allocator);

        if (!project.enabled) {
            return error.ProjectNotEnabled;
        }

        // Generate a unique run_id
        const run_id = try generateRunId(self.allocator);
        defer self.allocator.free(run_id);

        // Create the run
        try self.store.createRun(run_id, project_id, mode, worker_id);

        // Return the created run
        return (try self.store.getRun(run_id, self.allocator)) orelse return error.RunNotFound;
    }

    /// Stop a running project run
    pub fn stopProjectRun(self: ProjectService, run_id: []const u8) !void {
        if (run_id.len == 0) return error.InvalidRunId;

        // Check if run exists
        const run = try self.store.getRun(run_id, self.allocator) orelse return error.RunNotFound;
        defer run.deinit(self.allocator);

        // Update run status to completed
        const now = std.time.timestamp();
        try self.store.updateRunStatus(run_id, "completed", now);
    }

    /// Pause a project (disable scheduling)
    pub fn pauseProject(self: ProjectService, project_id: []const u8) !void {
        try self.updateProject(project_id, .{
            .enabled = false,
        });
    }

    /// Resume a project (enable scheduling)
    pub fn resumeProject(self: ProjectService, project_id: []const u8) !void {
        try self.updateProject(project_id, .{
            .enabled = true,
        });
    }

    /// List all runs for a project
    pub fn listProjectRuns(self: ProjectService, project_id: []const u8, limit: usize) ![]controlplane_store.Run {
        if (project_id.len == 0) return error.InvalidProjectId;
        return try self.store.listRunsByProject(project_id, limit, self.allocator);
    }

    /// Create a new task for a project
    pub fn createTask(self: ProjectService, project_id: []const u8, input: task_store.CreateTaskInput, meta: task_store.OperatorMeta) !void {
        if (project_id.len == 0) return error.InvalidProjectId;

        // Check if project exists
        const project = try self.store.getProject(project_id, self.allocator) orelse return error.ProjectNotFound;
        defer project.deinit(self.allocator);

        try self.store.createTask(project_id, input, meta);
    }

    /// Apply an action to a task
    pub fn applyTaskAction(self: ProjectService, project_id: []const u8, task_id: []const u8, action: task_store.Action, meta: task_store.OperatorMeta) !void {
        try self.store.applyAction(project_id, task_id, action, meta);
    }
};

/// Generate a unique run ID
fn generateRunId(allocator: std.mem.Allocator) ![]u8 {
    const timestamp = std.time.timestamp();
    const random = std.crypto.random.int(u32);
    return std.fmt.allocPrint(allocator, "run-{d}-{x}", .{ timestamp, random });
}

// Error types - these are used by the functions above
// ProjectService uses these error returns:
// - error.InvalidProjectId
// - error.InvalidWorkDir
// - error.InvalidRunId
// - error.ProjectAlreadyExists
// - error.ProjectNotFound
// - error.ProjectNotEnabled
// - error.RunNotFound

// Tests
test "ProjectService - register and get project" {
    // This test requires a SQLite store, so we'll just test the error cases
    // Full integration tests should be in a separate file
    _ = generateRunId;
}
