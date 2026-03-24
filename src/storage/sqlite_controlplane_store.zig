const std = @import("std");
const controlplane_store = @import("controlplane_store.zig");
const task_store = @import("task_store.zig");

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

const CInt = i32;
const SQLITE_OK: CInt = 0;
const SQLITE_ROW: CInt = 100;
const SQLITE_DONE: CInt = 101;
const SQLITE_OPEN_READWRITE: CInt = 0x00000002;
const SQLITE_OPEN_CREATE: CInt = 0x00000004;
const SQLITE_OPEN_FULLMUTEX: CInt = 0x00010000;
const SQLITE_LIMIT_SQL_LENGTH: CInt = 1;
const SCHEMA_VERSION: CInt = 2;
const SQLITE_BUSY: CInt = 5;
const SQLITE_CONSTRAINT: CInt = 19;

const SqliteApi = struct {
    open_v2: *const fn ([*:0]const u8, *?*sqlite3, CInt, ?[*:0]const u8) callconv(.c) CInt,
    close_v2: *const fn (*sqlite3) callconv(.c) CInt,
    exec: *const fn (*sqlite3, [*:0]const u8, ?*const anyopaque, ?*anyopaque, *?[*:0]u8) callconv(.c) CInt,
    errmsg: *const fn (*sqlite3) callconv(.c) [*:0]const u8,
    free: *const fn (?*anyopaque) callconv(.c) void,
    prepare_v2: *const fn (*sqlite3, [*:0]const u8, CInt, *?*sqlite3_stmt, ?*?[*:0]const u8) callconv(.c) CInt,
    step: *const fn (*sqlite3_stmt) callconv(.c) CInt,
    finalize: *const fn (*sqlite3_stmt) callconv(.c) CInt,
    column_text: *const fn (*sqlite3_stmt, CInt) callconv(.c) ?[*:0]const u8,
    column_int: *const fn (*sqlite3_stmt, CInt) callconv(.c) CInt,
    column_int64: *const fn (*sqlite3_stmt, CInt) callconv(.c) i64,
    column_double: *const fn (*sqlite3_stmt, CInt) callconv(.c) f64,
    changes: *const fn (*sqlite3) callconv(.c) CInt,
    limit: *const fn (*sqlite3, CInt, CInt) callconv(.c) CInt,
    bind_text: *const fn (*sqlite3_stmt, CInt, [*:0]const u8, CInt, ?*anyopaque) callconv(.c) CInt,
    bind_int64: *const fn (*sqlite3_stmt, CInt, i64) callconv(.c) CInt,
    bind_int: *const fn (*sqlite3_stmt, CInt, CInt) callconv(.c) CInt,
    bind_double: *const fn (*sqlite3_stmt, CInt, f64) callconv(.c) CInt,
    bind_null: *const fn (*sqlite3_stmt, CInt) callconv(.c) CInt,
    clear_bindings: *const fn (*sqlite3_stmt) callconv(.c) CInt,
    reset: *const fn (*sqlite3_stmt) callconv(.c) CInt,
};

pub const SqliteControlPlaneStore = struct {
    allocator: std.mem.Allocator,
    db: *sqlite3,
    dylib: std.DynLib,
    api: SqliteApi,
    mutex: std.Thread.Mutex = .{},
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) !SqliteControlPlaneStore {
        var dylib = openSqliteDynLib() catch return error.StoreNotAvailable;
        errdefer dylib.close();

        const api = SqliteApi{
            .open_v2 = dylib.lookup(*const fn ([*:0]const u8, *?*sqlite3, CInt, ?[*:0]const u8) callconv(.c) CInt, "sqlite3_open_v2") orelse return error.MissingSqliteSymbol,
            .close_v2 = dylib.lookup(*const fn (*sqlite3) callconv(.c) CInt, "sqlite3_close_v2") orelse return error.MissingSqliteSymbol,
            .exec = dylib.lookup(*const fn (*sqlite3, [*:0]const u8, ?*const anyopaque, ?*anyopaque, *?[*:0]u8) callconv(.c) CInt, "sqlite3_exec") orelse return error.MissingSqliteSymbol,
            .errmsg = dylib.lookup(*const fn (*sqlite3) callconv(.c) [*:0]const u8, "sqlite3_errmsg") orelse return error.MissingSqliteSymbol,
            .free = dylib.lookup(*const fn (?*anyopaque) callconv(.c) void, "sqlite3_free") orelse return error.MissingSqliteSymbol,
            .prepare_v2 = dylib.lookup(*const fn (*sqlite3, [*:0]const u8, CInt, *?*sqlite3_stmt, ?*?[*:0]const u8) callconv(.c) CInt, "sqlite3_prepare_v2") orelse return error.MissingSqliteSymbol,
            .step = dylib.lookup(*const fn (*sqlite3_stmt) callconv(.c) CInt, "sqlite3_step") orelse return error.MissingSqliteSymbol,
            .finalize = dylib.lookup(*const fn (*sqlite3_stmt) callconv(.c) CInt, "sqlite3_finalize") orelse return error.MissingSqliteSymbol,
            .column_text = dylib.lookup(*const fn (*sqlite3_stmt, CInt) callconv(.c) ?[*:0]const u8, "sqlite3_column_text") orelse return error.MissingSqliteSymbol,
            .column_int = dylib.lookup(*const fn (*sqlite3_stmt, CInt) callconv(.c) CInt, "sqlite3_column_int") orelse return error.MissingSqliteSymbol,
            .column_int64 = dylib.lookup(*const fn (*sqlite3_stmt, CInt) callconv(.c) i64, "sqlite3_column_int64") orelse return error.MissingSqliteSymbol,
            .column_double = dylib.lookup(*const fn (*sqlite3_stmt, CInt) callconv(.c) f64, "sqlite3_column_double") orelse return error.MissingSqliteSymbol,
            .changes = dylib.lookup(*const fn (*sqlite3) callconv(.c) CInt, "sqlite3_changes") orelse return error.MissingSqliteSymbol,
            .limit = dylib.lookup(*const fn (*sqlite3, CInt, CInt) callconv(.c) CInt, "sqlite3_limit") orelse return error.MissingSqliteSymbol,
            .bind_text = dylib.lookup(*const fn (*sqlite3_stmt, CInt, [*:0]const u8, CInt, ?*anyopaque) callconv(.c) CInt, "sqlite3_bind_text") orelse return error.MissingSqliteSymbol,
            .bind_int64 = dylib.lookup(*const fn (*sqlite3_stmt, CInt, i64) callconv(.c) CInt, "sqlite3_bind_int64") orelse return error.MissingSqliteSymbol,
            .bind_int = dylib.lookup(*const fn (*sqlite3_stmt, CInt, CInt) callconv(.c) CInt, "sqlite3_bind_int") orelse return error.MissingSqliteSymbol,
            .bind_double = dylib.lookup(*const fn (*sqlite3_stmt, CInt, f64) callconv(.c) CInt, "sqlite3_bind_double") orelse return error.MissingSqliteSymbol,
            .bind_null = dylib.lookup(*const fn (*sqlite3_stmt, CInt) callconv(.c) CInt, "sqlite3_bind_null") orelse return error.MissingSqliteSymbol,
            .clear_bindings = dylib.lookup(*const fn (*sqlite3_stmt) callconv(.c) CInt, "sqlite3_clear_bindings") orelse return error.MissingSqliteSymbol,
            .reset = dylib.lookup(*const fn (*sqlite3_stmt) callconv(.c) CInt, "sqlite3_reset") orelse return error.MissingSqliteSymbol,
        };

        const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch "/tmp";
        defer allocator.free(home_dir);

        const config_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".config", "techlead" });
        defer allocator.free(config_dir);
        try std.fs.cwd().makePath(config_dir);

        const db_path = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, "controlplane.sqlite3" });
        defer allocator.free(db_path);

        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);

        var db_ptr: ?*sqlite3 = null;
        const rc = api.open_v2(db_path_z, &db_ptr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, null);
        if (rc != SQLITE_OK or db_ptr == null) return error.SqliteOpenFailed;

        var self = SqliteControlPlaneStore{
            .allocator = allocator,
            .db = db_ptr.?,
            .dylib = dylib,
            .api = api,
        };
        errdefer self.deinit();

        _ = self.api.limit(self.db, SQLITE_LIMIT_SQL_LENGTH, 8 * 1024 * 1024);

        try self.execSql("PRAGMA journal_mode=WAL;");
        try self.execSql("PRAGMA synchronous=NORMAL;");
        try self.execSql("PRAGMA foreign_keys=ON;");
        try self.ensureSchema();

        return self;
    }

    pub fn asControlPlaneStore(self: *SqliteControlPlaneStore) controlplane_store.ControlPlaneStore {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn deinit(self: *SqliteControlPlaneStore) void {
        if (self.closed) return;
        _ = self.api.close_v2(self.db);
        self.dylib.close();
        self.closed = true;
    }

    fn ensureSchema(self: *SqliteControlPlaneStore) controlplane_store.StoreError!void {
        const user_version = try self.queryUserVersion();
        if (user_version < SCHEMA_VERSION) {
            try self.execSql("DROP TABLE IF EXISTS leases;");
            try self.execSql("DROP TABLE IF EXISTS runs;");
            try self.execSql("DROP TABLE IF EXISTS task_reviews;");
            try self.execSql("DROP TABLE IF EXISTS task_events;");
            try self.execSql("DROP TABLE IF EXISTS tasks;");
            try self.execSql("DROP TABLE IF EXISTS projects;");
        }

        try self.execSql(
            \\CREATE TABLE IF NOT EXISTS projects (
            \\  project_id TEXT PRIMARY KEY,
            \\  work_dir TEXT NOT NULL,
            \\  enabled INTEGER NOT NULL DEFAULT 1,
            \\  test_cmd TEXT,
            \\  lint_cmd TEXT,
            \\  max_workers INTEGER NOT NULL DEFAULT 1,
            \\  running_tasks INTEGER NOT NULL DEFAULT 0,
            \\  created_at INTEGER NOT NULL,
            \\  updated_at INTEGER NOT NULL
            \\);
        );

        try self.execSql(
            \\CREATE TABLE IF NOT EXISTS tasks (
            \\  task_id TEXT PRIMARY KEY,
            \\  project_id TEXT NOT NULL,
            \\  title TEXT NOT NULL,
            \\  prompt TEXT,
            \\  status TEXT NOT NULL,
            \\  lease_owner TEXT,
            \\  lease_until INTEGER,
            \\  leased_at INTEGER,
            \\  lease_heartbeat_at INTEGER,
            \\  retry_count INTEGER NOT NULL DEFAULT 0,
            \\  max_retries INTEGER,
            \\  priority INTEGER NOT NULL DEFAULT 0,
            \\  last_error TEXT,
            \\  review_stage TEXT NOT NULL DEFAULT 'none',
            \\  review_round INTEGER NOT NULL DEFAULT 0,
            \\  base_branch TEXT,
            \\  head_branch TEXT,
            \\  head_sha TEXT,
            \\  merge_commit TEXT,
            \\  review_feedback TEXT,
            \\  qa_force_reject_once INTEGER NOT NULL DEFAULT 0,
            \\  version INTEGER NOT NULL DEFAULT 1,
            \\  created_at INTEGER NOT NULL,
            \\  updated_at INTEGER NOT NULL,
            \\  FOREIGN KEY (project_id) REFERENCES projects(project_id) ON DELETE CASCADE
            \\);
        );

        try self.execSql("CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON tasks(project_id);");
        try self.execSql("CREATE INDEX IF NOT EXISTS idx_tasks_project_status ON tasks(project_id, status);");

        try self.execSql(
            \\CREATE TABLE IF NOT EXISTS runs (
            \\  run_id TEXT PRIMARY KEY,
            \\  project_id TEXT NOT NULL,
            \\  mode TEXT NOT NULL,
            \\  status TEXT NOT NULL,
            \\  worker_id TEXT,
            \\  started_at INTEGER NOT NULL,
            \\  ended_at INTEGER,
            \\  FOREIGN KEY (project_id) REFERENCES projects(project_id) ON DELETE CASCADE
            \\);
        );

        try self.execSql("PRAGMA user_version=2;");
    }

    fn registerProject(ctx: *anyopaque, input: controlplane_store.RegisterProjectInput) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        const sql = "INSERT INTO projects(project_id, work_dir, enabled, test_cmd, lint_cmd, max_workers, created_at, updated_at) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);";
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);

        try self.bindText(stmt, 1, input.project_id);
        try self.bindText(stmt, 2, input.work_dir);
        _ = self.api.bind_int(stmt, 3, if (input.enabled) 1 else 0);
        if (input.test_cmd) |cmd| {
            try self.bindText(stmt, 4, cmd);
        } else {
            _ = self.api.bind_null(stmt, 4);
        }
        if (input.lint_cmd) |cmd| {
            try self.bindText(stmt, 5, cmd);
        } else {
            _ = self.api.bind_null(stmt, 5);
        }
        _ = self.api.bind_int(stmt, 6, @intCast(input.max_workers));
        _ = self.api.bind_int64(stmt, 7, now);
        _ = self.api.bind_int64(stmt, 8, now);

        const rc = self.api.step(stmt);
        if (rc != SQLITE_DONE) return error.SqliteExecFailed;
    }

    fn getProject(ctx: *anyopaque, project_id: []const u8, allocator: std.mem.Allocator) controlplane_store.StoreError!?controlplane_store.Project {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const sql = "SELECT project_id, work_dir, enabled, test_cmd, lint_cmd, max_workers, created_at, updated_at FROM projects WHERE project_id=?1 LIMIT 1;";
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);

        try self.bindText(stmt, 1, project_id);

        if (self.api.step(stmt) != SQLITE_ROW) return null;

        return try self.readProjectFromStmt(stmt, allocator);
    }

    fn listProjects(ctx: *anyopaque, query: controlplane_store.ListProjectsQuery, allocator: std.mem.Allocator) controlplane_store.StoreError![]controlplane_store.Project {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(self.allocator);

        try sql.appendSlice(self.allocator, "SELECT project_id, work_dir, enabled, test_cmd, lint_cmd, max_workers, created_at, updated_at FROM projects");

        if (query.enabled_only) {
            try sql.appendSlice(self.allocator, " WHERE enabled=1");
        }

        try sql.appendSlice(self.allocator, " ORDER BY updated_at DESC LIMIT ");
        try std.fmt.format(sql.writer(self.allocator), "{d} OFFSET {d};", .{ query.limit, query.cursor });

        const stmt = try self.prepare(sql.items);
        defer self.finalize(stmt);

        var results = std.ArrayList(controlplane_store.Project).empty;
        errdefer {
            for (results.items) |*p| p.deinit(allocator);
            results.deinit(allocator);
        }

        while (self.api.step(stmt) == SQLITE_ROW) {
            try results.append(allocator, try self.readProjectFromStmt(stmt, allocator));
        }

        return results.toOwnedSlice(allocator);
    }

    fn updateProject(ctx: *anyopaque, project_id: []const u8, input: controlplane_store.UpdateProjectInput) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(self.allocator);

        try sql.appendSlice(self.allocator, "UPDATE projects SET ");

        var first = true;
        if (input.work_dir) |_| {
            if (!first) try sql.appendSlice(self.allocator, ", ");
            try sql.appendSlice(self.allocator, "work_dir=?1");
            first = false;
        }
        if (input.enabled) |_| {
            if (!first) try sql.appendSlice(self.allocator, ", ");
            try sql.appendSlice(self.allocator, "enabled=?2");
            first = false;
        }
        if (input.test_cmd) |_| {
            if (!first) try sql.appendSlice(self.allocator, ", ");
            try sql.appendSlice(self.allocator, "test_cmd=?3");
            first = false;
        }
        if (input.lint_cmd) |_| {
            if (!first) try sql.appendSlice(self.allocator, ", ");
            try sql.appendSlice(self.allocator, "lint_cmd=?4");
            first = false;
        }
        if (input.max_workers) |_| {
            if (!first) try sql.appendSlice(self.allocator, ", ");
            try sql.appendSlice(self.allocator, "max_workers=?5");
            first = false;
        }

        if (first) return;

        try sql.appendSlice(self.allocator, ", updated_at=?6 WHERE project_id=?7;");

        const stmt = try self.prepare(sql.items);
        defer self.finalize(stmt);

        const now = std.time.timestamp();
        var param_idx: CInt = 1;

        if (input.work_dir) |v| {
            try self.bindText(stmt, param_idx, v);
            param_idx += 1;
        }
        if (input.enabled) |v| {
            _ = self.api.bind_int(stmt, param_idx, if (v) 1 else 0);
            param_idx += 1;
        }
        if (input.test_cmd) |v| {
            try self.bindText(stmt, param_idx, v);
            param_idx += 1;
        }
        if (input.lint_cmd) |v| {
            try self.bindText(stmt, param_idx, v);
            param_idx += 1;
        }
        if (input.max_workers) |v| {
            _ = self.api.bind_int(stmt, param_idx, @intCast(v));
            param_idx += 1;
        }

        _ = self.api.bind_int64(stmt, param_idx, now);
        param_idx += 1;
        try self.bindText(stmt, param_idx, project_id);

        const rc = self.api.step(stmt);
        if (rc != SQLITE_DONE) return error.SqliteExecFailed;
        if (self.api.changes(self.db) != 1) return error.ProjectNotFound;
    }

    fn deleteProject(ctx: *anyopaque, project_id: []const u8) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const sql = "DELETE FROM projects WHERE project_id=?1;";
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);

        try self.bindText(stmt, 1, project_id);

        const rc = self.api.step(stmt);
        if (rc != SQLITE_DONE) return error.SqliteExecFailed;
        if (self.api.changes(self.db) != 1) return error.ProjectNotFound;
    }

    fn createTask(ctx: *anyopaque, project_id: []const u8, input: task_store.CreateTaskInput, meta: task_store.OperatorMeta) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        const sql = "INSERT INTO tasks(task_id, project_id, title, prompt, status, lease_owner, lease_until, retry_count, max_retries, priority, last_error, review_stage, review_round, qa_force_reject_once, version, created_at, updated_at) VALUES(?1, ?2, ?3, ?4, 'queued', NULL, NULL, 0, ?5, ?6, NULL, 'none', 0, ?7, 1, ?8, ?9);";
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);

        try self.bindText(stmt, 1, input.task_id);
        try self.bindText(stmt, 2, project_id);
        try self.bindText(stmt, 3, input.title);
        if (input.prompt) |p| {
            try self.bindText(stmt, 4, p);
        } else {
            _ = self.api.bind_null(stmt, 4);
        }
        if (input.max_retries) |mr| {
            _ = self.api.bind_int(stmt, 5, @intCast(mr));
        } else {
            _ = self.api.bind_null(stmt, 5);
        }
        _ = self.api.bind_int(stmt, 6, input.priority);
        _ = self.api.bind_int(stmt, 7, if (input.qa_force_reject_once) 1 else 0);
        _ = self.api.bind_int64(stmt, 8, now);
        _ = self.api.bind_int64(stmt, 9, now);

        const rc = self.api.step(stmt);
        if (rc != SQLITE_DONE) return error.SqliteExecFailed;
        _ = meta;
    }

    fn claimNext(ctx: *anyopaque, options: controlplane_store.MultiProjectClaimOptions, allocator: std.mem.Allocator) controlplane_store.StoreError!?task_store.Task {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = options;
        _ = allocator;
        return null;
    }

    fn listTasksByProject(ctx: *anyopaque, query: controlplane_store.ListTasksByProjectQuery, allocator: std.mem.Allocator) controlplane_store.StoreError![]u8 {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = query;
        return allocator.dupe(u8, "{\"tasks\":[],\"summary\":{},\"cursor\":0,\"next_cursor\":null,\"limit\":50,\"total\":0}");
    }

    fn getTaskDetail(ctx: *anyopaque, project_id: []const u8, task_id: []const u8, allocator: std.mem.Allocator) controlplane_store.StoreError![]u8 {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = project_id;
        _ = task_id;
        return allocator.dupe(u8, "{\"task\":null,\"reviews\":[],\"events\":[]}");
    }

    fn markRunning(ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, lease_seconds: u64, run_id: []const u8) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = project_id;
        _ = task_id;
        _ = owner;
        _ = lease_seconds;
        _ = run_id;
    }

    fn markDone(ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = project_id;
        _ = task_id;
        _ = owner;
        _ = run_id;
    }

    fn markFailedOrRequeue(ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, message: []const u8, default_max_retries: u32) controlplane_store.StoreError!task_store.FailResult {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = project_id;
        _ = task_id;
        _ = owner;
        _ = run_id;
        _ = message;
        _ = default_max_retries;
        return .{ .status = .failed, .retry_count = 0, .max_retries = 3 };
    }

    fn markReviewOpen(ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, base_branch: []const u8, head_branch: []const u8, head_sha: []const u8) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = project_id;
        _ = task_id;
        _ = owner;
        _ = run_id;
        _ = review_round;
        _ = base_branch;
        _ = head_branch;
        _ = head_sha;
    }

    fn markReviewApproved(ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = project_id;
        _ = task_id;
        _ = owner;
        _ = run_id;
        _ = review_round;
    }

    fn markReviewChangesRequestedAndRequeue(ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, feedback: []const u8, reason: []const u8, default_max_retries: u32) controlplane_store.StoreError!task_store.FailResult {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = project_id;
        _ = task_id;
        _ = owner;
        _ = run_id;
        _ = review_round;
        _ = feedback;
        _ = reason;
        _ = default_max_retries;
        return .{ .status = .queued, .retry_count = 0, .max_retries = 3 };
    }

    fn markMergedDone(ctx: *anyopaque, project_id: []const u8, task_id: []const u8, owner: []const u8, run_id: []const u8, review_round: u32, merge_commit: []const u8) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = project_id;
        _ = task_id;
        _ = owner;
        _ = run_id;
        _ = review_round;
        _ = merge_commit;
    }

    fn createTaskReview(ctx: *anyopaque, project_id: []const u8, input: task_store.CreateTaskReviewInput) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = project_id;
        _ = input;
    }

    fn getTaskEvents(ctx: *anyopaque, project_id: []const u8, after_id: i64, limit: usize, allocator: std.mem.Allocator) controlplane_store.StoreError![]u8 {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = project_id;
        _ = after_id;
        _ = limit;
        return allocator.dupe(u8, "{\"events\":[],\"last_event_id\":0}");
    }

    fn applyAction(ctx: *anyopaque, project_id: []const u8, task_id: []const u8, action: task_store.Action, meta: task_store.OperatorMeta) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = project_id;
        _ = task_id;
        _ = action;
        _ = meta;
    }

    fn createRun(ctx: *anyopaque, run_id: []const u8, project_id: []const u8, mode: []const u8, worker_id: ?[]const u8) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        const sql = "INSERT INTO runs(run_id, project_id, mode, status, worker_id, started_at) VALUES(?1, ?2, ?3, 'running', ?4, ?5);";
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);

        try self.bindText(stmt, 1, run_id);
        try self.bindText(stmt, 2, project_id);
        try self.bindText(stmt, 3, mode);
        if (worker_id) |wid| {
            try self.bindText(stmt, 4, wid);
        } else {
            _ = self.api.bind_null(stmt, 4);
        }
        _ = self.api.bind_int64(stmt, 5, now);

        const rc = self.api.step(stmt);
        if (rc != SQLITE_DONE) return error.SqliteExecFailed;
    }

    fn updateRunStatus(ctx: *anyopaque, run_id: []const u8, status: []const u8, ended_at: ?i64) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = run_id;
        _ = status;
        _ = ended_at;
    }

    fn getRun(ctx: *anyopaque, run_id: []const u8, allocator: std.mem.Allocator) controlplane_store.StoreError!?controlplane_store.Run {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const sql = "SELECT run_id, project_id, mode, status, worker_id, started_at, ended_at FROM runs WHERE run_id=?1 LIMIT 1;";
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);

        try self.bindText(stmt, 1, run_id);

        if (self.api.step(stmt) != SQLITE_ROW) return null;

        return try self.readRunFromStmt(stmt, allocator);
    }

    fn listRunsByProject(ctx: *anyopaque, project_id: []const u8, limit: usize, allocator: std.mem.Allocator) controlplane_store.StoreError![]controlplane_store.Run {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const safe_limit = @max(@as(usize, 1), @min(limit, 200));

        const sql = "SELECT run_id, project_id, mode, status, worker_id, started_at, ended_at FROM runs WHERE project_id=?1 ORDER BY started_at DESC LIMIT ?2;";
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);

        try self.bindText(stmt, 1, project_id);
        _ = self.api.bind_int(stmt, 2, @intCast(safe_limit));

        var results = std.ArrayList(controlplane_store.Run).empty;
        errdefer {
            for (results.items) |*r| r.deinit(allocator);
            results.deinit(allocator);
        }

        while (self.api.step(stmt) == SQLITE_ROW) {
            try results.append(allocator, try self.readRunFromStmt(stmt, allocator));
        }

        return results.toOwnedSlice(allocator);
    }

    fn acquireLease(ctx: *anyopaque, lease_id: []const u8, task_id: []const u8, project_id: []const u8, owner: []const u8, expires_at: i64) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = lease_id;
        _ = task_id;
        _ = project_id;
        _ = owner;
        _ = expires_at;
    }

    fn releaseLease(ctx: *anyopaque, lease_id: []const u8, owner: []const u8) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = lease_id;
        _ = owner;
    }

    fn getLease(ctx: *anyopaque, task_id: []const u8, allocator: std.mem.Allocator) controlplane_store.StoreError!?controlplane_store.Lease {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = task_id;
        _ = allocator;
        return null;
    }

    fn close(ctx: *anyopaque) void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn prepare(self: *SqliteControlPlaneStore, sql: []const u8) controlplane_store.StoreError!*sqlite3_stmt {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt_ptr: ?*sqlite3_stmt = null;
        const rc = self.api.prepare_v2(self.db, sql_z, -1, &stmt_ptr, null);
        if (rc != SQLITE_OK or stmt_ptr == null) return error.SqlitePrepareFailed;
        return stmt_ptr.?;
    }

    fn finalize(self: *SqliteControlPlaneStore, stmt: *sqlite3_stmt) void {
        _ = self.api.finalize(stmt);
    }

    fn execSql(self: *SqliteControlPlaneStore, sql: []const u8) controlplane_store.StoreError!void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var err_msg: ?[*:0]u8 = null;
        const rc = self.api.exec(self.db, sql_z, null, null, &err_msg);
        defer if (err_msg) |p| self.api.free(@ptrCast(p));
        if (rc != SQLITE_OK) {
            const err_txt = std.mem.span(self.api.errmsg(self.db));
            std.debug.print("sqlite controlplane store exec failed: {s}\n", .{err_txt});
            return error.SqliteExecFailed;
        }
    }

    fn queryUserVersion(self: *SqliteControlPlaneStore) controlplane_store.StoreError!CInt {
        const stmt = try self.prepare("PRAGMA user_version;");
        defer self.finalize(stmt);
        if (self.api.step(stmt) != SQLITE_ROW) return error.SqliteExecFailed;
        return self.api.column_int(stmt, 0);
    }

    fn columnTextDup(self: *SqliteControlPlaneStore, stmt: *sqlite3_stmt, index: CInt, allocator: std.mem.Allocator) controlplane_store.StoreError![]u8 {
        const p = self.api.column_text(stmt, index) orelse return error.SqliteColumnNull;
        return allocator.dupe(u8, std.mem.span(p));
    }

    fn columnOptionalTextDup(self: *SqliteControlPlaneStore, stmt: *sqlite3_stmt, index: CInt, allocator: std.mem.Allocator) controlplane_store.StoreError!?[]u8 {
        const p = self.api.column_text(stmt, index) orelse return null;
        const dup = try allocator.dupe(u8, std.mem.span(p));
        return dup;
    }

    fn readProjectFromStmt(self: *SqliteControlPlaneStore, stmt: *sqlite3_stmt, allocator: std.mem.Allocator) controlplane_store.StoreError!controlplane_store.Project {
        return .{
            .project_id = try self.columnTextDup(stmt, 0, allocator),
            .work_dir = try self.columnTextDup(stmt, 1, allocator),
            .enabled = self.api.column_int(stmt, 2) != 0,
            .test_cmd = try self.columnOptionalTextDup(stmt, 3, allocator),
            .lint_cmd = try self.columnOptionalTextDup(stmt, 4, allocator),
            .max_workers = @intCast(self.api.column_int(stmt, 5)),
            .created_at = self.api.column_int64(stmt, 6),
            .updated_at = self.api.column_int64(stmt, 7),
        };
    }

    fn readRunFromStmt(self: *SqliteControlPlaneStore, stmt: *sqlite3_stmt, allocator: std.mem.Allocator) controlplane_store.StoreError!controlplane_store.Run {
        return .{
            .run_id = try self.columnTextDup(stmt, 0, allocator),
            .project_id = try self.columnTextDup(stmt, 1, allocator),
            .mode = try self.columnTextDup(stmt, 2, allocator),
            .status = try self.columnTextDup(stmt, 3, allocator),
            .worker_id = try self.columnOptionalTextDup(stmt, 4, allocator),
            .started_at = self.api.column_int64(stmt, 5),
            .ended_at = if (self.api.column_text(stmt, 6) == null) null else self.api.column_int64(stmt, 6),
        };
    }

    fn bindText(self: *SqliteControlPlaneStore, stmt: *sqlite3_stmt, index: CInt, text: []const u8) controlplane_store.StoreError!void {
        const text_z = try self.allocator.dupeZ(u8, text);
        defer self.allocator.free(text_z);
        _ = self.api.bind_text(stmt, index, text_z, @intCast(text.len), null);
    }

    const vtable = controlplane_store.ControlPlaneStore.VTable{
        .registerProject = registerProject,
        .getProject = getProject,
        .listProjects = listProjects,
        .updateProject = updateProject,
        .deleteProject = deleteProject,
        .createTask = createTask,
        .claimNext = claimNext,
        .listTasksByProject = listTasksByProject,
        .getTaskDetail = getTaskDetail,
        .markRunning = markRunning,
        .markDone = markDone,
        .markFailedOrRequeue = markFailedOrRequeue,
        .markReviewOpen = markReviewOpen,
        .markReviewApproved = markReviewApproved,
        .markReviewChangesRequestedAndRequeue = markReviewChangesRequestedAndRequeue,
        .markMergedDone = markMergedDone,
        .createTaskReview = createTaskReview,
        .getTaskEvents = getTaskEvents,
        .applyAction = applyAction,
        .createRun = createRun,
        .updateRunStatus = updateRunStatus,
        .getRun = getRun,
        .listRunsByProject = listRunsByProject,
        .acquireLease = acquireLease,
        .releaseLease = releaseLease,
        .getLease = getLease,
        .close = close,
    };
};

/// Convert SQLite result code to StoreError
fn sqliteToStoreError(rc: CInt) controlplane_store.StoreError {
    return switch (rc) {
        SQLITE_BUSY => error.DatabaseBusy,
        SQLITE_CONSTRAINT => error.ConstraintViolation,
        else => error.DatabaseBusy,
    };
}

fn openSqliteDynLib() !std.DynLib {
    const candidates = [_][]const u8{
        "libsqlite3.so.0",
        "/lib/x86_64-linux-gnu/libsqlite3.so.0",
        "libsqlite3.so",
    };
    for (candidates) |name| {
        if (std.DynLib.open(name)) |lib| return lib else |_| {}
    }
    return error.StoreNotAvailable;
}

pub const Error = error{
    StoreNotAvailable,
    MissingSqliteSymbol,
    SqliteOpenFailed,
    SqlitePrepareFailed,
    SqliteExecFailed,
    SqliteColumnNull,
    ProjectNotFound,
    TaskNotFound,
    TaskNotClaimed,
    VersionConflict,
    ActionRejected,
    RunNotFound,
    LeaseNotFound,
    ClaimConflict,
    ForceMergeDisabled,
};
