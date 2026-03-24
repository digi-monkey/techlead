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
const SQLITE_BUSY: CInt = 5;
const SQLITE_CONSTRAINT: CInt = 19;
const SCHEMA_VERSION: CInt = 3;

const TASK_SELECT_COLUMNS =
    "task_id,title,prompt,status,lease_owner,lease_until,retry_count,max_retries,priority,last_error,review_stage,review_round,base_branch,head_branch,head_sha,merge_commit,review_feedback,qa_force_reject_once,version,created_at,updated_at";

const TaskReview = struct {
    id: i64,
    task_id: []u8,
    review_round: u32,
    role: []u8,
    verdict: []u8,
    score: ?i32,
    summary: []u8,
    blockers_json: []u8,
    suggestions_json: []u8,
    confidence: ?f64,
    reviewer_run_id: ?[]u8,
    created_at: i64,

    fn deinit(self: *TaskReview, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.role);
        allocator.free(self.verdict);
        allocator.free(self.summary);
        allocator.free(self.blockers_json);
        allocator.free(self.suggestions_json);
        if (self.reviewer_run_id) |v| allocator.free(v);
    }
};

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

        // Also clean up if coming from version 2 (need to recreate tables with foreign keys)
        if (user_version == 2) {
            try self.execSql("DROP TABLE IF EXISTS task_reviews;");
            try self.execSql("DROP TABLE IF EXISTS task_events;");
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
            \\CREATE TABLE IF NOT EXISTS task_events (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  task_id TEXT NOT NULL,
            \\  run_id TEXT,
            \\  event_type TEXT NOT NULL,
            \\  payload TEXT NOT NULL,
            \\  operator TEXT,
            \\  source TEXT,
            \\  request_id TEXT,
            \\  created_at INTEGER NOT NULL,
            \\  FOREIGN KEY (task_id) REFERENCES tasks(task_id) ON DELETE CASCADE
            \\);
        );

        try self.execSql(
            \\CREATE TABLE IF NOT EXISTS task_reviews (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  task_id TEXT NOT NULL,
            \\  review_round INTEGER NOT NULL,
            \\  role TEXT NOT NULL,
            \\  verdict TEXT NOT NULL,
            \\  score INTEGER,
            \\  summary TEXT NOT NULL,
            \\  blockers_json TEXT NOT NULL,
            \\  suggestions_json TEXT NOT NULL,
            \\  confidence REAL,
            \\  reviewer_run_id TEXT,
            \\  created_at INTEGER NOT NULL,
            \\  FOREIGN KEY (task_id) REFERENCES tasks(task_id) ON DELETE CASCADE
            \\);
        );

        try self.execSql("CREATE INDEX IF NOT EXISTS idx_task_events_task_id ON task_events(task_id, id DESC);");
        try self.execSql("CREATE INDEX IF NOT EXISTS idx_task_reviews_task_round ON task_reviews(task_id, review_round);");

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

        const now = std.time.timestamp();
        const lease_until = now + @as(i64, @intCast(options.lease_seconds));

        var retries: usize = 0;
        while (retries < 16) : (retries += 1) {
            // Build SELECT query with optional project filter
            var select_sql: std.ArrayList(u8) = .empty;
            defer select_sql.deinit(self.allocator);

            try select_sql.appendSlice(self.allocator, "SELECT task_id,version FROM tasks WHERE status='queued'");
            if (options.project_id) |pid| {
                const pid_q = try sqlQuote(self.allocator, pid);
                defer self.allocator.free(pid_q);
                try std.fmt.format(select_sql.writer(self.allocator), " AND project_id='{s}'", .{pid_q});
            }
            try select_sql.appendSlice(self.allocator, " ORDER BY priority DESC, created_at ASC LIMIT 1;");

            var selected_id: ?[]u8 = null;
            defer if (selected_id) |v| self.allocator.free(v);
            var selected_version: i64 = 0;

            const stmt = try self.prepare(select_sql.items);
            defer self.finalize(stmt);
            if (self.api.step(stmt) == SQLITE_ROW) {
                selected_id = try self.columnTextDup(stmt, 0, allocator);
                selected_version = self.api.column_int64(stmt, 1);
            } else {
                return null;
            }

            const id_q = try sqlQuote(self.allocator, selected_id.?);
            defer self.allocator.free(id_q);
            const owner_q = try sqlQuote(self.allocator, options.owner);
            defer self.allocator.free(owner_q);

            const update_sql = try std.fmt.allocPrint(
                self.allocator,
                "UPDATE tasks SET status='claimed', lease_owner='{s}', lease_until={d}, leased_at={d}, updated_at={d}, version=version+1 WHERE task_id='{s}' AND version={d};",
                .{ owner_q, lease_until, now, now, id_q, selected_version },
            );
            defer self.allocator.free(update_sql);
            try self.execSql(update_sql);
            if (self.api.changes(self.db) != 1) continue;

            const fetch_sql = try std.fmt.allocPrint(self.allocator, "SELECT {s} FROM tasks WHERE task_id='{s}' LIMIT 1;", .{ TASK_SELECT_COLUMNS, id_q });
            defer self.allocator.free(fetch_sql);
            return try self.getOneTask(fetch_sql, allocator);
        }

        return null;
    }

    fn listTasksByProject(ctx: *anyopaque, query: controlplane_store.ListTasksByProjectQuery, allocator: std.mem.Allocator) controlplane_store.StoreError![]u8 {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const limit = @max(@as(usize, 1), @min(query.limit, 200));
        var where_parts: std.ArrayList([]const u8) = .empty;
        defer where_parts.deinit(self.allocator);
        var owned_parts: std.ArrayList([]u8) = .empty;
        defer {
            for (owned_parts.items) |p| self.allocator.free(p);
            owned_parts.deinit(self.allocator);
        }

        // Always filter by project_id
        const project_q = try sqlQuote(self.allocator, query.project_id);
        try owned_parts.append(self.allocator, project_q);
        const project_clause = try std.fmt.allocPrint(self.allocator, "project_id='{s}'", .{project_q});
        try owned_parts.append(self.allocator, project_clause);
        try where_parts.append(self.allocator, project_clause);

        if (query.status) |status| {
            const status_q = try sqlQuote(self.allocator, task_store.taskStatusToString(status));
            try owned_parts.append(self.allocator, status_q);
            const clause = try std.fmt.allocPrint(self.allocator, "status='{s}'", .{status_q});
            try owned_parts.append(self.allocator, clause);
            try where_parts.append(self.allocator, clause);
        }
        if (query.q) |text| {
            const q_q = try sqlQuote(self.allocator, text);
            try owned_parts.append(self.allocator, q_q);
            const clause = try std.fmt.allocPrint(self.allocator, "(title LIKE '%%{s}%%' OR prompt LIKE '%%{s}%%')", .{ q_q, q_q });
            try owned_parts.append(self.allocator, clause);
            try where_parts.append(self.allocator, clause);
        }

        var where_sql: []const u8 = "";
        if (where_parts.items.len > 0) {
            var join = std.ArrayList(u8).empty;
            defer join.deinit(self.allocator);
            try join.appendSlice(self.allocator, " WHERE ");
            for (where_parts.items, 0..) |part, idx| {
                if (idx > 0) try join.appendSlice(self.allocator, " AND ");
                try join.appendSlice(self.allocator, part);
            }
            where_sql = try join.toOwnedSlice(self.allocator);
            try owned_parts.append(self.allocator, @constCast(where_sql));
        }

        const count_sql = try std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) FROM tasks{s};", .{where_sql});
        defer self.allocator.free(count_sql);
        const total = try self.queryCount(count_sql);

        const list_sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT {s} FROM tasks{s} ORDER BY updated_at DESC, task_id ASC LIMIT {d} OFFSET {d};",
            .{ TASK_SELECT_COLUMNS, where_sql, limit, query.cursor },
        );
        defer self.allocator.free(list_sql);

        var rows = std.ArrayList(task_store.Task).empty;
        defer {
            for (rows.items) |*item| item.deinit(self.allocator);
            rows.deinit(self.allocator);
        }

        const stmt = try self.prepare(list_sql);
        defer self.finalize(stmt);
        while (self.api.step(stmt) == SQLITE_ROW) {
            try rows.append(self.allocator, try self.readTaskFromStmt(stmt, self.allocator));
        }

        var sums = [_]struct { status: []const u8, count: i64 }{
            .{ .status = "queued", .count = 0 },
            .{ .status = "claimed", .count = 0 },
            .{ .status = "running", .count = 0 },
            .{ .status = "review", .count = 0 },
            .{ .status = "done", .count = 0 },
            .{ .status = "failed", .count = 0 },
            .{ .status = "canceled", .count = 0 },
        };

        // Get counts filtered by project_id only
        const sum_sql = try std.fmt.allocPrint(self.allocator, "SELECT status, COUNT(*) FROM tasks WHERE project_id='{s}' GROUP BY status;", .{project_q});
        defer self.allocator.free(sum_sql);
        const sum_stmt = try self.prepare(sum_sql);
        defer self.finalize(sum_stmt);
        while (self.api.step(sum_stmt) == SQLITE_ROW) {
            const status = (try self.columnTextDup(sum_stmt, 0, self.allocator));
            defer self.allocator.free(status);
            const cnt = self.api.column_int64(sum_stmt, 1);
            for (&sums) |*s| {
                if (std.mem.eql(u8, s.status, status)) {
                    s.count = cnt;
                    break;
                }
            }
        }

        const has_next = query.cursor + rows.items.len < @as(usize, @intCast(total));
        const next_cursor: ?usize = if (has_next) query.cursor + rows.items.len else null;

        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);
        var w = out.writer(allocator);
        try w.writeAll("{\"tasks\":[");
        for (rows.items, 0..) |task, idx| {
            if (idx > 0) try w.writeByte(',');
            var latest_reviews = std.ArrayList(TaskReview).empty;
            defer {
                for (latest_reviews.items) |*item| item.deinit(self.allocator);
                latest_reviews.deinit(self.allocator);
            }
            try self.collectLatestTaskReviews(task.task_id, &latest_reviews);
            try writeTaskJsonWithLatestReviews(&w, task, latest_reviews.items);
        }
        try w.writeAll("],\"summary\":{");
        for (sums, 0..) |s, idx| {
            if (idx > 0) try w.writeByte(',');
            try w.print("\"{s}\":{d}", .{ s.status, s.count });
        }
        try w.print("}},\"cursor\":{d},\"next_cursor\":", .{query.cursor});
        if (next_cursor) |v| {
            try w.print("{d}", .{v});
        } else {
            try w.writeAll("null");
        }
        try w.print(",\"limit\":{d},\"total\":{d}", .{ limit, total });
        try w.writeByte('}');

        return out.toOwnedSlice(allocator);
    }

    fn collectLatestTaskReviews(self: *SqliteControlPlaneStore, task_id: []const u8, out: *std.ArrayList(TaskReview)) controlplane_store.StoreError!void {
        const review_roles = [_]task_store.TaskReviewRole{
            .correctness_reviewer,
            .maintainability_reviewer,
        };
        for (review_roles) |role| {
            const review = try self.getLatestTaskReview(task_id, role);
            if (review) |r| try out.append(self.allocator, r);
        }
    }

    fn getLatestTaskReview(self: *SqliteControlPlaneStore, task_id: []const u8, role: task_store.TaskReviewRole) controlplane_store.StoreError!?TaskReview {
        const task_q = try sqlQuote(self.allocator, task_id);
        defer self.allocator.free(task_q);
        const role_q = try sqlQuote(self.allocator, task_store.taskReviewRoleToString(role));
        defer self.allocator.free(role_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT id,task_id,review_round,role,verdict,score,summary,blockers_json,suggestions_json,confidence,reviewer_run_id,created_at FROM task_reviews WHERE task_id='{s}' AND role='{s}' ORDER BY created_at DESC, id DESC LIMIT 1;",
            .{ task_q, role_q },
        );
        defer self.allocator.free(sql);

        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);
        if (self.api.step(stmt) != SQLITE_ROW) return null;
        return try self.readTaskReviewFromStmt(stmt);
    }

    fn readTaskReviewFromStmt(self: *SqliteControlPlaneStore, stmt: *sqlite3_stmt) controlplane_store.StoreError!TaskReview {
        return .{
            .id = self.api.column_int64(stmt, 0),
            .task_id = try self.columnTextDup(stmt, 1, self.allocator),
            .review_round = @intCast(self.api.column_int(stmt, 2)),
            .role = try self.columnTextDup(stmt, 3, self.allocator),
            .verdict = try self.columnTextDup(stmt, 4, self.allocator),
            .score = if (self.columnIsNull(stmt, 5)) null else self.api.column_int(stmt, 5),
            .summary = try self.columnTextDup(stmt, 6, self.allocator),
            .blockers_json = try self.columnTextDup(stmt, 7, self.allocator),
            .suggestions_json = try self.columnTextDup(stmt, 8, self.allocator),
            .confidence = if (self.columnIsNull(stmt, 9)) null else self.api.column_double(stmt, 9),
            .reviewer_run_id = try self.columnOptionalTextDup(stmt, 10, self.allocator),
            .created_at = self.api.column_int64(stmt, 11),
        };
    }

    fn appendTaskEvent(self: *SqliteControlPlaneStore, task_id: []const u8, run_id: ?[]const u8, event_type: []const u8, payload: []const u8, operator: ?[]const u8, source: ?[]const u8, request_id: ?[]const u8) controlplane_store.StoreError!void {
        const task_q = try sqlQuote(self.allocator, task_id);
        defer self.allocator.free(task_q);
        const event_q = try sqlQuote(self.allocator, event_type);
        defer self.allocator.free(event_q);
        const payload_q = try sqlQuote(self.allocator, payload);
        defer self.allocator.free(payload_q);
        const now = std.time.timestamp();

        const run_val = if (run_id) |r| blk: {
            const q = try sqlQuote(self.allocator, r);
            defer self.allocator.free(q);
            break :blk try std.fmt.allocPrint(self.allocator, "'{s}'", .{q});
        } else try self.allocator.dupe(u8, "NULL");
        defer self.allocator.free(run_val);

        const op_val = if (operator) |o| blk: {
            const q = try sqlQuote(self.allocator, o);
            defer self.allocator.free(q);
            break :blk try std.fmt.allocPrint(self.allocator, "'{s}'", .{q});
        } else try self.allocator.dupe(u8, "NULL");
        defer self.allocator.free(op_val);

        const source_val = if (source) |s| blk: {
            const q = try sqlQuote(self.allocator, s);
            defer self.allocator.free(q);
            break :blk try std.fmt.allocPrint(self.allocator, "'{s}'", .{q});
        } else try self.allocator.dupe(u8, "NULL");
        defer self.allocator.free(source_val);

        const req_val = if (request_id) |r| blk: {
            const q = try sqlQuote(self.allocator, r);
            defer self.allocator.free(q);
            break :blk try std.fmt.allocPrint(self.allocator, "'{s}'", .{q});
        } else try self.allocator.dupe(u8, "NULL");
        defer self.allocator.free(req_val);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO task_events(task_id,run_id,event_type,payload,operator,source,request_id,created_at) VALUES('{s}',{s},'{s}','{s}',{s},{s},{s},{d});",
            .{ task_q, run_val, event_q, payload_q, op_val, source_val, req_val, now },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    fn queryCount(self: *SqliteControlPlaneStore, sql: []const u8) controlplane_store.StoreError!i64 {
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);
        if (self.api.step(stmt) != SQLITE_ROW) return 0;
        return self.api.column_int64(stmt, 0);
    }

    fn getTaskDetail(ctx: *anyopaque, project_id: []const u8, task_id: []const u8, allocator: std.mem.Allocator) controlplane_store.StoreError![]u8 {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const task_q = try sqlQuote(self.allocator, task_id);
        defer self.allocator.free(task_q);
        const project_q = try sqlQuote(self.allocator, project_id);
        defer self.allocator.free(project_q);

        // Fetch task with project_id filter
        const task_sql = try std.fmt.allocPrint(self.allocator, "SELECT {s} FROM tasks WHERE task_id='{s}' AND project_id='{s}' LIMIT 1;", .{ TASK_SELECT_COLUMNS, task_q, project_q });
        defer self.allocator.free(task_sql);

        const maybe_task = try self.getOneTask(task_sql, self.allocator);
        if (maybe_task == null) return error.TaskNotFound;
        var task = maybe_task.?;
        defer task.deinit(self.allocator);

        // Fetch events
        const event_sql = try std.fmt.allocPrint(self.allocator, "SELECT id,task_id,run_id,event_type,payload,operator,source,request_id,created_at FROM task_events WHERE task_id='{s}' ORDER BY id DESC LIMIT 50;", .{task_q});
        defer self.allocator.free(event_sql);

        var events = std.ArrayList(task_store.TaskEvent).empty;
        defer {
            for (events.items) |*item| item.deinit(self.allocator);
            events.deinit(self.allocator);
        }

        const stmt = try self.prepare(event_sql);
        defer self.finalize(stmt);
        while (self.api.step(stmt) == SQLITE_ROW) {
            try events.append(self.allocator, try self.readTaskEventFromStmt(stmt));
        }

        // Fetch reviews
        var reviews = std.ArrayList(TaskReview).empty;
        defer {
            for (reviews.items) |*item| item.deinit(self.allocator);
            reviews.deinit(self.allocator);
        }

        const review_sql = try std.fmt.allocPrint(self.allocator, "SELECT id,task_id,review_round,role,verdict,score,summary,blockers_json,suggestions_json,confidence,reviewer_run_id,created_at FROM task_reviews WHERE task_id='{s}' ORDER BY created_at DESC, id DESC;", .{task_q});
        defer self.allocator.free(review_sql);

        const review_stmt = try self.prepare(review_sql);
        defer self.finalize(review_stmt);
        while (self.api.step(review_stmt) == SQLITE_ROW) {
            try reviews.append(self.allocator, try self.readTaskReviewFromStmt(review_stmt));
        }

        // Build JSON output
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);
        var w = out.writer(allocator);
        try writeTaskDetailJson(&w, task, events.items, reviews.items);
        return out.toOwnedSlice(allocator);
    }

    fn readTaskEventFromStmt(self: *SqliteControlPlaneStore, stmt: *sqlite3_stmt) controlplane_store.StoreError!task_store.TaskEvent {
        return .{
            .id = self.api.column_int64(stmt, 0),
            .task_id = try self.columnTextDup(stmt, 1, self.allocator),
            .run_id = try self.columnOptionalTextDup(stmt, 2, self.allocator),
            .event_type = try self.columnTextDup(stmt, 3, self.allocator),
            .payload = try self.columnTextDup(stmt, 4, self.allocator),
            .operator = try self.columnOptionalTextDup(stmt, 5, self.allocator),
            .source = try self.columnOptionalTextDup(stmt, 6, self.allocator),
            .request_id = try self.columnOptionalTextDup(stmt, 7, self.allocator),
            .created_at = self.api.column_int64(stmt, 8),
        };
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

        const safe_limit = @max(@as(usize, 1), @min(limit, 200));
        const pid_q = try sqlQuote(self.allocator, project_id);
        defer self.allocator.free(pid_q);

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT e.id,e.task_id,e.run_id,e.event_type,e.payload,e.operator,e.source,e.request_id,e.created_at FROM task_events e INNER JOIN tasks t ON e.task_id=t.task_id WHERE t.project_id='{s}' AND e.id>{d} ORDER BY e.id ASC LIMIT {d};", .{ pid_q, after_id, safe_limit });
        defer self.allocator.free(sql);

        var rows = std.ArrayList(task_store.TaskEvent).empty;
        defer {
            for (rows.items) |*item| item.deinit(self.allocator);
            rows.deinit(self.allocator);
        }

        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);
        var last_id = after_id;
        while (self.api.step(stmt) == SQLITE_ROW) {
            const evt = try self.readTaskEventFromStmt(stmt);
            if (evt.id > last_id) last_id = evt.id;
            try rows.append(self.allocator, evt);
        }

        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);
        var w = out.writer(allocator);
        try w.writeAll("{\"events\":[");
        for (rows.items, 0..) |evt, idx| {
            if (idx > 0) try w.writeByte(',');
            try writeTaskEventJson(&w, evt);
        }
        try w.print("],\"last_event_id\":{d}", .{last_id});
        try w.writeByte('}');
        return out.toOwnedSlice(allocator);
    }

    fn applyAction(ctx: *anyopaque, project_id: []const u8, task_id: []const u8, action: task_store.Action, meta: task_store.OperatorMeta) controlplane_store.StoreError!void {
        const self: *SqliteControlPlaneStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const pid_q = try sqlQuote(self.allocator, project_id);
        defer self.allocator.free(pid_q);
        const task_q = try sqlQuote(self.allocator, task_id);
        defer self.allocator.free(task_q);
        const now = std.time.timestamp();

        if (action == .force_merge) return error.ForceMergeDisabled;

        const sql = switch (action) {
            .requeue => try std.fmt.allocPrint(
                self.allocator,
                "UPDATE tasks SET status='queued', lease_owner=NULL, lease_until=NULL, last_error=NULL, updated_at={d}, version=version+1 WHERE project_id='{s}' AND task_id='{s}' AND (status='failed' OR status='canceled' OR status='review');",
                .{ now, pid_q, task_q },
            ),
            .cancel => try std.fmt.allocPrint(
                self.allocator,
                "UPDATE tasks SET status='canceled', lease_owner=NULL, lease_until=NULL, updated_at={d}, version=version+1 WHERE project_id='{s}' AND task_id='{s}' AND status!='done';",
                .{ now, pid_q, task_q },
            ),
            .@"resume" => try std.fmt.allocPrint(
                self.allocator,
                "UPDATE tasks SET status='queued', lease_owner=NULL, lease_until=NULL, updated_at={d}, version=version+1 WHERE project_id='{s}' AND task_id='{s}' AND (status='failed' OR status='canceled' OR status='review');",
                .{ now, pid_q, task_q },
            ),
            .force_fail => try std.fmt.allocPrint(
                self.allocator,
                "UPDATE tasks SET status='failed', lease_owner=NULL, lease_until=NULL, last_error='forced_fail', updated_at={d}, version=version+1 WHERE project_id='{s}' AND task_id='{s}' AND status!='done';",
                .{ now, pid_q, task_q },
            ),
            .retry_review => try std.fmt.allocPrint(
                self.allocator,
                "UPDATE tasks SET status='queued', lease_owner=NULL, lease_until=NULL, updated_at={d}, version=version+1 WHERE project_id='{s}' AND task_id='{s}' AND (status='review' OR status='queued') AND review_stage='changes_requested';",
                .{ now, pid_q, task_q },
            ),
            .force_merge => unreachable,
        };
        defer self.allocator.free(sql);
        try self.execSql(sql);
        if (self.api.changes(self.db) != 1) return error.ActionRejected;

        const event_type = switch (action) {
            .requeue => "task.action.requeue",
            .cancel => "task.action.cancel",
            .@"resume" => "task.action.resume",
            .force_fail => "task.action.force_fail",
            .retry_review => "task.action.retry_review",
            .force_merge => unreachable,
        };

        try self.appendTaskEvent(task_id, meta.run_id, event_type, "{}", meta.operator, meta.source, meta.request_id);
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

    fn columnIsNull(self: *SqliteControlPlaneStore, stmt: *sqlite3_stmt, index: CInt) bool {
        return @as(?[*:0]const u8, self.api.column_text(stmt, index)) == null;
    }

    fn getOneTask(self: *SqliteControlPlaneStore, sql: []const u8, allocator: std.mem.Allocator) controlplane_store.StoreError!?task_store.Task {
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);
        if (self.api.step(stmt) != SQLITE_ROW) return null;
        return try self.readTaskFromStmt(stmt, allocator);
    }

    fn readTaskFromStmt(self: *SqliteControlPlaneStore, stmt: *sqlite3_stmt, allocator: std.mem.Allocator) controlplane_store.StoreError!task_store.Task {
        const status_text = try self.columnTextDup(stmt, 3, allocator);
        defer self.allocator.free(status_text);
        const parsed_status = try task_store.taskStatusFromString(status_text);
        const review_stage_text = try self.columnTextDup(stmt, 10, allocator);
        defer self.allocator.free(review_stage_text);
        const parsed_review_stage = try task_store.reviewStageFromString(review_stage_text);

        return .{
            .task_id = try self.columnTextDup(stmt, 0, allocator),
            .title = try self.columnTextDup(stmt, 1, allocator),
            .prompt = try self.columnOptionalTextDup(stmt, 2, allocator),
            .status = parsed_status,
            .lease_owner = try self.columnOptionalTextDup(stmt, 4, allocator),
            .lease_until = if (self.columnIsNull(stmt, 5)) null else self.api.column_int64(stmt, 5),
            .retry_count = @intCast(self.api.column_int(stmt, 6)),
            .max_retries = if (self.columnIsNull(stmt, 7)) null else @intCast(self.api.column_int(stmt, 7)),
            .priority = self.api.column_int(stmt, 8),
            .last_error = try self.columnOptionalTextDup(stmt, 9, allocator),
            .review_stage = parsed_review_stage,
            .review_round = @intCast(self.api.column_int(stmt, 11)),
            .base_branch = try self.columnOptionalTextDup(stmt, 12, allocator),
            .head_branch = try self.columnOptionalTextDup(stmt, 13, allocator),
            .head_sha = try self.columnOptionalTextDup(stmt, 14, allocator),
            .merge_commit = try self.columnOptionalTextDup(stmt, 15, allocator),
            .review_feedback = try self.columnOptionalTextDup(stmt, 16, allocator),
            .qa_force_reject_once = self.api.column_int(stmt, 17) != 0,
            .version = self.api.column_int64(stmt, 18),
            .created_at = self.api.column_int64(stmt, 19),
            .updated_at = self.api.column_int64(stmt, 20),
        };
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

fn sqlQuote(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (text) |c| {
        if (c == '\'') {
            try out.append(allocator, '\'');
            try out.append(allocator, '\'');
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn writeTaskJson(writer: anytype, task: task_store.Task) !void {
    try writer.print("{{\"task_id\":{f},\"title\":{f},\"prompt\":", .{ std.json.fmt(task.task_id, .{}), std.json.fmt(task.title, .{}) });
    if (task.prompt) |p| {
        try writer.print("{f}", .{std.json.fmt(p, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"status\":{f},\"lease_owner\":", .{std.json.fmt(task_store.taskStatusToString(task.status), .{})});
    if (task.lease_owner) |owner| {
        try writer.print("{f}", .{std.json.fmt(owner, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"lease_until\":");
    if (task.lease_until) |until| {
        try writer.print("{d}", .{until});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"max_retries\":");
    if (task.max_retries) |mr| {
        try writer.print("{d}", .{mr});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"last_error\":");
    if (task.last_error) |msg| {
        try writer.print("{f}", .{std.json.fmt(msg, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"review_stage\":{f},\"review_round\":{d},\"base_branch\":", .{
        std.json.fmt(task_store.reviewStageToString(task.review_stage), .{}),
        task.review_round,
    });
    if (task.base_branch) |base_branch| {
        try writer.print("{f}", .{std.json.fmt(base_branch, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"head_branch\":");
    if (task.head_branch) |head_branch| {
        try writer.print("{f}", .{std.json.fmt(head_branch, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"head_sha\":");
    if (task.head_sha) |head_sha| {
        try writer.print("{f}", .{std.json.fmt(head_sha, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"merge_commit\":");
    if (task.merge_commit) |merge_commit| {
        try writer.print("{f}", .{std.json.fmt(merge_commit, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"review_feedback\":");
    if (task.review_feedback) |review_feedback| {
        try writer.print("{f}", .{std.json.fmt(review_feedback, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"retry_count\":{d},\"priority\":{d},\"qa_force_reject_once\":{s},\"version\":{d},\"created_at\":{d},\"updated_at\":{d}}}", .{ task.retry_count, task.priority, if (task.qa_force_reject_once) "true" else "false", task.version, task.created_at, task.updated_at });
}

fn writeTaskEventJson(writer: anytype, evt: task_store.TaskEvent) !void {
    try writer.print("{{\"id\":{d},\"task_id\":{f},\"run_id\":", .{ evt.id, std.json.fmt(evt.task_id, .{}) });
    if (evt.run_id) |run_id| {
        try writer.print("{f}", .{std.json.fmt(run_id, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"event_type\":{f},\"payload\":", .{std.json.fmt(evt.event_type, .{})});
    try writer.print("{f}", .{std.json.fmt(evt.payload, .{})});
    try writer.writeAll(",\"operator\":");
    if (evt.operator) |op| {
        try writer.print("{f}", .{std.json.fmt(op, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"source\":");
    if (evt.source) |source| {
        try writer.print("{f}", .{std.json.fmt(source, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"request_id\":");
    if (evt.request_id) |rid| {
        try writer.print("{f}", .{std.json.fmt(rid, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"created_at\":{d}}}", .{evt.created_at});
}

fn writeTaskDetailJson(
    writer: anytype,
    task: task_store.Task,
    events: []const task_store.TaskEvent,
    reviews: []const TaskReview,
) !void {
    try writer.writeAll("{\"task\":");
    try writeTaskJson(writer, task);
    try writer.writeAll(",\"reviews\":[");
    for (reviews, 0..) |review, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeTaskReviewJson(writer, review);
    }
    try writer.writeAll("],\"events\":[");
    for (events, 0..) |evt, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeTaskEventJson(writer, evt);
    }
    try writer.writeAll("]}");
}

fn writeTaskJsonWithLatestReviews(writer: anytype, task: task_store.Task, latest_reviews: []const TaskReview) !void {
    try writer.print("{{\"task_id\":{f},\"title\":{f},\"prompt\":", .{ std.json.fmt(task.task_id, .{}), std.json.fmt(task.title, .{}) });
    if (task.prompt) |p| {
        try writer.print("{f}", .{std.json.fmt(p, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"status\":{f},\"lease_owner\":", .{std.json.fmt(task_store.taskStatusToString(task.status), .{})});
    if (task.lease_owner) |owner| {
        try writer.print("{f}", .{std.json.fmt(owner, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"lease_until\":");
    if (task.lease_until) |until| {
        try writer.print("{d}", .{until});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"max_retries\":");
    if (task.max_retries) |mr| {
        try writer.print("{d}", .{mr});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"last_error\":");
    if (task.last_error) |msg| {
        try writer.print("{f}", .{std.json.fmt(msg, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"review_stage\":{f},\"review_round\":{d},\"base_branch\":", .{
        std.json.fmt(task_store.reviewStageToString(task.review_stage), .{}),
        task.review_round,
    });
    if (task.base_branch) |base_branch| {
        try writer.print("{f}", .{std.json.fmt(base_branch, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"head_branch\":");
    if (task.head_branch) |head_branch| {
        try writer.print("{f}", .{std.json.fmt(head_branch, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"head_sha\":");
    if (task.head_sha) |head_sha| {
        try writer.print("{f}", .{std.json.fmt(head_sha, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"merge_commit\":");
    if (task.merge_commit) |merge_commit| {
        try writer.print("{f}", .{std.json.fmt(merge_commit, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"review_feedback\":");
    if (task.review_feedback) |review_feedback| {
        try writer.print("{f}", .{std.json.fmt(review_feedback, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"retry_count\":{d},\"priority\":{d},\"qa_force_reject_once\":{s},\"version\":{d},\"created_at\":{d},\"updated_at\":{d}", .{ task.retry_count, task.priority, if (task.qa_force_reject_once) "true" else "false", task.version, task.created_at, task.updated_at });
    try writer.writeAll(",\"latest_reviews\":[");
    for (latest_reviews, 0..) |review, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeTaskReviewJson(writer, review);
    }
    try writer.writeByte(']');
    try writer.writeByte('}');
}

fn writeTaskReviewJson(writer: anytype, review: TaskReview) !void {
    try writer.print("{{\"id\":{d},\"task_id\":{f},\"review_round\":{d},\"role\":{f},\"verdict\":{f},\"score\":", .{
        review.id,
        std.json.fmt(review.task_id, .{}),
        review.review_round,
        std.json.fmt(review.role, .{}),
        std.json.fmt(review.verdict, .{}),
    });
    if (review.score) |score| {
        try writer.print("{d}", .{score});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"summary\":{f},\"blockers\":{s},\"suggestions\":{s},\"confidence\":", .{
        std.json.fmt(review.summary, .{}),
        review.blockers_json,
        review.suggestions_json,
    });
    if (review.confidence) |confidence| {
        try writer.print("{d}", .{confidence});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"reviewer_run_id\":");
    if (review.reviewer_run_id) |run_id| {
        try writer.print("{f}", .{std.json.fmt(run_id, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"created_at\":{d}}}", .{review.created_at});
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
