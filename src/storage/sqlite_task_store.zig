const std = @import("std");
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
    changes: *const fn (*sqlite3) callconv(.c) CInt,
    limit: *const fn (*sqlite3, CInt, CInt) callconv(.c) CInt,
};

pub const SqliteTaskStore = struct {
    allocator: std.mem.Allocator,
    db: *sqlite3,
    dylib: std.DynLib,
    api: SqliteApi,
    mutex: std.Thread.Mutex = .{},
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, work_dir: []const u8) !SqliteTaskStore {
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
            .changes = dylib.lookup(*const fn (*sqlite3) callconv(.c) CInt, "sqlite3_changes") orelse return error.MissingSqliteSymbol,
            .limit = dylib.lookup(*const fn (*sqlite3, CInt, CInt) callconv(.c) CInt, "sqlite3_limit") orelse return error.MissingSqliteSymbol,
        };

        const db_dir = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, ".techlead" });
        defer allocator.free(db_dir);
        try std.fs.cwd().makePath(db_dir);

        const db_path = try std.fs.path.join(allocator, &[_][]const u8{ db_dir, "tasks.sqlite3" });
        defer allocator.free(db_path);

        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);

        var db_ptr: ?*sqlite3 = null;
        const rc = api.open_v2(db_path_z, &db_ptr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, null);
        if (rc != SQLITE_OK or db_ptr == null) return error.SqliteOpenFailed;

        var self = SqliteTaskStore{
            .allocator = allocator,
            .db = db_ptr.?,
            .dylib = dylib,
            .api = api,
        };
        errdefer self.deinit();

        _ = self.api.limit(self.db, SQLITE_LIMIT_SQL_LENGTH, 8 * 1024 * 1024);

        try self.execSql("PRAGMA journal_mode=WAL;");
        try self.execSql("PRAGMA synchronous=NORMAL;");
        try self.execSql(
            \\CREATE TABLE IF NOT EXISTS tasks (
            \\  task_id TEXT PRIMARY KEY,
            \\  title TEXT NOT NULL,
            \\  prompt TEXT,
            \\  status TEXT NOT NULL,
            \\  lease_owner TEXT,
            \\  lease_until INTEGER,
            \\  retry_count INTEGER NOT NULL DEFAULT 0,
            \\  max_retries INTEGER,
            \\  priority INTEGER NOT NULL DEFAULT 0,
            \\  last_error TEXT,
            \\  version INTEGER NOT NULL DEFAULT 1,
            \\  created_at INTEGER NOT NULL,
            \\  updated_at INTEGER NOT NULL
            \\);
        );
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
            \\  created_at INTEGER NOT NULL
            \\);
        );
        try self.execSql("CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);");
        try self.execSql("CREATE INDEX IF NOT EXISTS idx_tasks_updated_at ON tasks(updated_at DESC);");
        try self.execSql("CREATE INDEX IF NOT EXISTS idx_task_events_task_id ON task_events(task_id, id DESC);");
        try self.execSql("CREATE INDEX IF NOT EXISTS idx_task_events_id ON task_events(id);");

        return self;
    }

    pub fn asTaskStore(self: *SqliteTaskStore) task_store.TaskStore {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn deinit(self: *SqliteTaskStore) void {
        if (self.closed) return;
        _ = self.api.close_v2(self.db);
        self.dylib.close();
        self.closed = true;
    }

    fn claimNext(ctx: *anyopaque, options: task_store.ClaimOptions) !?task_store.Task {
        const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const lease_until = now + @as(i64, @intCast(options.lease_seconds));

        var retries: usize = 0;
        while (retries < 16) : (retries += 1) {
            const select_sql = try std.fmt.allocPrint(
                self.allocator,
                "SELECT task_id,version FROM tasks WHERE (status='queued' OR ((status='claimed' OR status='running') AND lease_until IS NOT NULL AND lease_until<={d}) OR (status='failed' AND retry_count<COALESCE(max_retries,{d}))) ORDER BY priority DESC, created_at ASC LIMIT 1;",
                .{ now, options.default_max_retries },
            );
            defer self.allocator.free(select_sql);

            var selected_id: ?[]u8 = null;
            defer if (selected_id) |v| self.allocator.free(v);
            var selected_version: i64 = 0;

            const stmt = try self.prepare(select_sql);
            defer self.finalize(stmt);
            if (self.api.step(stmt) == SQLITE_ROW) {
                selected_id = try self.columnTextDup(stmt, 0);
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
                "UPDATE tasks SET status='claimed', lease_owner='{s}', lease_until={d}, updated_at={d}, version=version+1 WHERE task_id='{s}' AND version={d};",
                .{ owner_q, lease_until, now, id_q, selected_version },
            );
            defer self.allocator.free(update_sql);
            try self.execSql(update_sql);
            if (self.api.changes(self.db) != 1) continue;

            const fetch_sql = try std.fmt.allocPrint(self.allocator, "SELECT task_id,title,prompt,status,lease_owner,lease_until,retry_count,max_retries,priority,last_error,version,created_at,updated_at FROM tasks WHERE task_id='{s}' LIMIT 1;", .{id_q});
            defer self.allocator.free(fetch_sql);
            return try self.getOneTask(fetch_sql);
        }

        return error.ClaimConflict;
    }

    fn markRunning(ctx: *anyopaque, task_id: []const u8, owner: []const u8, lease_seconds: u64, run_id: []const u8) !void {
        const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const lease_until = now + @as(i64, @intCast(lease_seconds));
        const task_q = try sqlQuote(self.allocator, task_id);
        defer self.allocator.free(task_q);
        const owner_q = try sqlQuote(self.allocator, owner);
        defer self.allocator.free(owner_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE tasks SET status='running', lease_until={d}, updated_at={d}, version=version+1 WHERE task_id='{s}' AND lease_owner='{s}';",
            .{ lease_until, now, task_q, owner_q },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
        if (self.api.changes(self.db) != 1) return error.TaskNotClaimed;

        try self.appendTaskEvent(task_id, run_id, "task.running", "{\"status\":\"running\"}", null, null, null);
    }

    fn markDone(ctx: *anyopaque, task_id: []const u8, owner: []const u8, run_id: []const u8) !void {
        const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const task_q = try sqlQuote(self.allocator, task_id);
        defer self.allocator.free(task_q);
        const owner_q = try sqlQuote(self.allocator, owner);
        defer self.allocator.free(owner_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE tasks SET status='done', lease_owner=NULL, lease_until=NULL, last_error=NULL, updated_at={d}, version=version+1 WHERE task_id='{s}' AND lease_owner='{s}';",
            .{ now, task_q, owner_q },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
        if (self.api.changes(self.db) != 1) return error.TaskNotClaimed;

        try self.appendTaskEvent(task_id, run_id, "task.done", "{\"status\":\"done\"}", null, null, null);
    }

    fn markFailedOrRequeue(ctx: *anyopaque, task_id: []const u8, owner: []const u8, run_id: []const u8, message: []const u8, default_max_retries: u32) !task_store.FailResult {
        const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const task_q = try sqlQuote(self.allocator, task_id);
        defer self.allocator.free(task_q);
        const owner_q = try sqlQuote(self.allocator, owner);
        defer self.allocator.free(owner_q);
        const err_q = try sqlQuote(self.allocator, message);
        defer self.allocator.free(err_q);

        const now = std.time.timestamp();

        const read_sql = try std.fmt.allocPrint(self.allocator, "SELECT retry_count,COALESCE(max_retries,{d}) FROM tasks WHERE task_id='{s}' AND lease_owner='{s}' LIMIT 1;", .{ default_max_retries, task_q, owner_q });
        defer self.allocator.free(read_sql);
        const stmt = try self.prepare(read_sql);
        defer self.finalize(stmt);
        if (self.api.step(stmt) != SQLITE_ROW) return error.TaskNotClaimed;
        const current_retry: u32 = @intCast(self.api.column_int(stmt, 0));
        const max_retries: u32 = @intCast(self.api.column_int(stmt, 1));

        const next_retry = current_retry + 1;
        const next_status: task_store.TaskStatus = if (next_retry < max_retries) .queued else .failed;
        const status_str = task_store.taskStatusToString(next_status);
        const status_q = try sqlQuote(self.allocator, status_str);
        defer self.allocator.free(status_q);

        const update_sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE tasks SET status='{s}', retry_count={d}, lease_owner=NULL, lease_until=NULL, last_error='{s}', updated_at={d}, version=version+1 WHERE task_id='{s}' AND lease_owner='{s}';",
            .{ status_q, next_retry, err_q, now, task_q, owner_q },
        );
        defer self.allocator.free(update_sql);
        try self.execSql(update_sql);
        if (self.api.changes(self.db) != 1) return error.TaskNotClaimed;

        const payload = if (next_status == .queued)
            "{\"status\":\"queued\"}"
        else
            "{\"status\":\"failed\"}";
        const event_type = if (next_status == .queued) "task.requeued" else "task.failed";
        try self.appendTaskEvent(task_id, run_id, event_type, payload, null, null, null);

        return .{ .status = next_status, .retry_count = next_retry, .max_retries = max_retries };
    }

    fn listTasksJson(ctx: *anyopaque, allocator: std.mem.Allocator, query: task_store.ListQuery) ![]u8 {
        const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
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
            "SELECT task_id,title,prompt,status,lease_owner,lease_until,retry_count,max_retries,priority,last_error,version,created_at,updated_at FROM tasks{s} ORDER BY updated_at DESC, task_id ASC LIMIT {d} OFFSET {d};",
            .{ where_sql, limit, query.cursor },
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
            try rows.append(self.allocator, try self.readTaskFromStmt(stmt));
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
        const sum_stmt = try self.prepare("SELECT status, COUNT(*) FROM tasks GROUP BY status;");
        defer self.finalize(sum_stmt);
        while (self.api.step(sum_stmt) == SQLITE_ROW) {
            const status = (try self.columnTextDup(sum_stmt, 0));
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
            try writeTaskJson(&w, task);
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

    fn getTaskDetailJson(ctx: *anyopaque, allocator: std.mem.Allocator, task_id: []const u8) ![]u8 {
        const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const task_q = try sqlQuote(self.allocator, task_id);
        defer self.allocator.free(task_q);
        const task_sql = try std.fmt.allocPrint(self.allocator, "SELECT task_id,title,prompt,status,lease_owner,lease_until,retry_count,max_retries,priority,last_error,version,created_at,updated_at FROM tasks WHERE task_id='{s}' LIMIT 1;", .{task_q});
        defer self.allocator.free(task_sql);

        const maybe_task = try self.getOneTask(task_sql);
        if (maybe_task == null) return error.TaskNotFound;
        var task = maybe_task.?;
        defer task.deinit(self.allocator);

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

        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);
        var w = out.writer(allocator);
        try w.writeAll("{\"task\":");
        try writeTaskJson(&w, task);
        try w.writeAll(",\"events\":[");
        for (events.items, 0..) |evt, idx| {
            if (idx > 0) try w.writeByte(',');
            try writeTaskEventJson(&w, evt);
        }
        try w.writeAll("]}");
        return out.toOwnedSlice(allocator);
    }

    fn getTaskEventsJson(ctx: *anyopaque, allocator: std.mem.Allocator, after_id: i64, limit: usize) ![]u8 {
        const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const safe_limit = @max(@as(usize, 1), @min(limit, 200));
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT id,task_id,run_id,event_type,payload,operator,source,request_id,created_at FROM task_events WHERE id>{d} ORDER BY id ASC LIMIT {d};", .{ after_id, safe_limit });
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

    fn createTask(ctx: *anyopaque, input: task_store.CreateTaskInput, meta: task_store.OperatorMeta) !void {
        const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const id_q = try sqlQuote(self.allocator, input.task_id);
        defer self.allocator.free(id_q);
        const title_q = try sqlQuote(self.allocator, input.title);
        defer self.allocator.free(title_q);
        const prompt_val = if (input.prompt) |p| blk: {
            const pq = try sqlQuote(self.allocator, p);
            defer self.allocator.free(pq);
            break :blk try std.fmt.allocPrint(self.allocator, "'{s}'", .{pq});
        } else try self.allocator.dupe(u8, "NULL");
        defer self.allocator.free(prompt_val);

        const max_retries_val = if (input.max_retries) |v|
            try std.fmt.allocPrint(self.allocator, "{d}", .{v})
        else
            try self.allocator.dupe(u8, "NULL");
        defer self.allocator.free(max_retries_val);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO tasks(task_id,title,prompt,status,lease_owner,lease_until,retry_count,max_retries,priority,last_error,version,created_at,updated_at) VALUES('{s}','{s}',{s},'queued',NULL,NULL,0,{s},{d},NULL,1,{d},{d});",
            .{ id_q, title_q, prompt_val, max_retries_val, input.priority, now, now },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);

        try self.appendTaskEvent(input.task_id, meta.run_id, "task.created", "{}", meta.operator, meta.source, meta.request_id);
    }

    fn patchTask(ctx: *anyopaque, task_id: []const u8, input: task_store.PatchTaskInput, meta: task_store.OperatorMeta) !void {
        const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const task_q = try sqlQuote(self.allocator, task_id);
        defer self.allocator.free(task_q);

        var sets = std.ArrayList(u8).empty;
        defer sets.deinit(self.allocator);
        var w = sets.writer(self.allocator);

        var changed_fields: usize = 0;
        if (input.title) |title| {
            const title_q = try sqlQuote(self.allocator, title);
            defer self.allocator.free(title_q);
            try w.print("title='{s}'", .{title_q});
            changed_fields += 1;
        }
        if (input.prompt) |prompt| {
            if (changed_fields > 0) try w.writeAll(",");
            const prompt_q = try sqlQuote(self.allocator, prompt);
            defer self.allocator.free(prompt_q);
            try w.print("prompt='{s}'", .{prompt_q});
            changed_fields += 1;
        }
        if (input.priority) |priority| {
            if (changed_fields > 0) try w.writeAll(",");
            try w.print("priority={d}", .{priority});
            changed_fields += 1;
        }
        if (input.max_retries) |mr| {
            if (changed_fields > 0) try w.writeAll(",");
            try w.print("max_retries={d}", .{mr});
            changed_fields += 1;
        }
        if (changed_fields == 0) return;

        const now = std.time.timestamp();
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE tasks SET {s}, updated_at={d}, version=version+1 WHERE task_id='{s}' AND version={d};",
            .{ sets.items, now, task_q, input.version },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
        if (self.api.changes(self.db) != 1) return error.VersionConflict;

        try self.appendTaskEvent(task_id, meta.run_id, "task.updated", "{}", meta.operator, meta.source, meta.request_id);
    }

    fn applyAction(ctx: *anyopaque, task_id: []const u8, action: task_store.Action, meta: task_store.OperatorMeta) !void {
        const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const task_q = try sqlQuote(self.allocator, task_id);
        defer self.allocator.free(task_q);
        const now = std.time.timestamp();

        const sql = switch (action) {
            .requeue => try std.fmt.allocPrint(
                self.allocator,
                "UPDATE tasks SET status='queued', lease_owner=NULL, lease_until=NULL, last_error=NULL, updated_at={d}, version=version+1 WHERE task_id='{s}';",
                .{ now, task_q },
            ),
            .cancel => try std.fmt.allocPrint(
                self.allocator,
                "UPDATE tasks SET status='canceled', lease_owner=NULL, lease_until=NULL, updated_at={d}, version=version+1 WHERE task_id='{s}' AND status!='done';",
                .{ now, task_q },
            ),
            .@"resume" => try std.fmt.allocPrint(
                self.allocator,
                "UPDATE tasks SET status='queued', lease_owner=NULL, lease_until=NULL, updated_at={d}, version=version+1 WHERE task_id='{s}' AND (status='failed' OR status='canceled' OR status='review');",
                .{ now, task_q },
            ),
            .force_fail => try std.fmt.allocPrint(
                self.allocator,
                "UPDATE tasks SET status='failed', lease_owner=NULL, lease_until=NULL, last_error='forced_fail', updated_at={d}, version=version+1 WHERE task_id='{s}' AND status!='done';",
                .{ now, task_q },
            ),
        };
        defer self.allocator.free(sql);
        try self.execSql(sql);
        if (self.api.changes(self.db) != 1) return error.ActionRejected;

        const event_type = switch (action) {
            .requeue => "task.action.requeue",
            .cancel => "task.action.cancel",
            .@"resume" => "task.action.resume",
            .force_fail => "task.action.force_fail",
        };
        try self.appendTaskEvent(task_id, meta.run_id, event_type, "{}", meta.operator, meta.source, meta.request_id);
    }

    fn close(ctx: *anyopaque) void {
        const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn appendTaskEvent(self: *SqliteTaskStore, task_id: []const u8, run_id: ?[]const u8, event_type: []const u8, payload: []const u8, operator: ?[]const u8, source: ?[]const u8, request_id: ?[]const u8) !void {
        const task_q = try sqlQuote(self.allocator, task_id);
        defer self.allocator.free(task_q);
        const event_q = try sqlQuote(self.allocator, event_type);
        defer self.allocator.free(event_q);
        const payload_q = try sqlQuote(self.allocator, payload);
        defer self.allocator.free(payload_q);
        const now = std.time.timestamp();

        const run_val = try sqlOptionalValue(self.allocator, run_id);
        defer self.allocator.free(run_val);
        const op_val = try sqlOptionalValue(self.allocator, operator);
        defer self.allocator.free(op_val);
        const source_val = try sqlOptionalValue(self.allocator, source);
        defer self.allocator.free(source_val);
        const req_val = try sqlOptionalValue(self.allocator, request_id);
        defer self.allocator.free(req_val);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO task_events(task_id,run_id,event_type,payload,operator,source,request_id,created_at) VALUES('{s}',{s},'{s}','{s}',{s},{s},{s},{d});",
            .{ task_q, run_val, event_q, payload_q, op_val, source_val, req_val, now },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    fn getOneTask(self: *SqliteTaskStore, sql: []const u8) !?task_store.Task {
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);
        if (self.api.step(stmt) != SQLITE_ROW) return null;
        return try self.readTaskFromStmt(stmt);
    }

    fn readTaskFromStmt(self: *SqliteTaskStore, stmt: *sqlite3_stmt) !task_store.Task {
        const status_text = try self.columnTextDup(stmt, 3);
        defer self.allocator.free(status_text);
        const parsed_status = try task_store.taskStatusFromString(status_text);

        return .{
            .task_id = try self.columnTextDup(stmt, 0),
            .title = try self.columnTextDup(stmt, 1),
            .prompt = try self.columnOptionalTextDup(stmt, 2),
            .status = parsed_status,
            .lease_owner = try self.columnOptionalTextDup(stmt, 4),
            .lease_until = if (self.columnIsNull(stmt, 5)) null else self.api.column_int64(stmt, 5),
            .retry_count = @intCast(self.api.column_int(stmt, 6)),
            .max_retries = if (self.columnIsNull(stmt, 7)) null else @intCast(self.api.column_int(stmt, 7)),
            .priority = self.api.column_int(stmt, 8),
            .last_error = try self.columnOptionalTextDup(stmt, 9),
            .version = self.api.column_int64(stmt, 10),
            .created_at = self.api.column_int64(stmt, 11),
            .updated_at = self.api.column_int64(stmt, 12),
        };
    }

    fn readTaskEventFromStmt(self: *SqliteTaskStore, stmt: *sqlite3_stmt) !task_store.TaskEvent {
        return .{
            .id = self.api.column_int64(stmt, 0),
            .task_id = try self.columnTextDup(stmt, 1),
            .run_id = try self.columnOptionalTextDup(stmt, 2),
            .event_type = try self.columnTextDup(stmt, 3),
            .payload = try self.columnTextDup(stmt, 4),
            .operator = try self.columnOptionalTextDup(stmt, 5),
            .source = try self.columnOptionalTextDup(stmt, 6),
            .request_id = try self.columnOptionalTextDup(stmt, 7),
            .created_at = self.api.column_int64(stmt, 8),
        };
    }

    fn queryCount(self: *SqliteTaskStore, sql: []const u8) !i64 {
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);
        if (self.api.step(stmt) != SQLITE_ROW) return 0;
        return self.api.column_int64(stmt, 0);
    }

    fn prepare(self: *SqliteTaskStore, sql: []const u8) !*sqlite3_stmt {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt_ptr: ?*sqlite3_stmt = null;
        const rc = self.api.prepare_v2(self.db, sql_z, -1, &stmt_ptr, null);
        if (rc != SQLITE_OK or stmt_ptr == null) return error.SqlitePrepareFailed;
        return stmt_ptr.?;
    }

    fn finalize(self: *SqliteTaskStore, stmt: *sqlite3_stmt) void {
        _ = self.api.finalize(stmt);
    }

    fn columnTextDup(self: *SqliteTaskStore, stmt: *sqlite3_stmt, index: CInt) ![]u8 {
        const p = self.api.column_text(stmt, index) orelse return error.SqliteColumnNull;
        return self.allocator.dupe(u8, std.mem.span(p));
    }

    fn columnOptionalTextDup(self: *SqliteTaskStore, stmt: *sqlite3_stmt, index: CInt) !?[]u8 {
        const p = self.api.column_text(stmt, index) orelse return null;
        const dup = try self.allocator.dupe(u8, std.mem.span(p));
        return dup;
    }

    fn columnIsNull(self: *SqliteTaskStore, stmt: *sqlite3_stmt, index: CInt) bool {
        return @as(?[*:0]const u8, self.api.column_text(stmt, index)) == null;
    }

    fn execSql(self: *SqliteTaskStore, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var err_msg: ?[*:0]u8 = null;
        const rc = self.api.exec(self.db, sql_z, null, null, &err_msg);
        defer if (err_msg) |p| self.api.free(@ptrCast(p));
        if (rc != SQLITE_OK) {
            const err_txt = std.mem.span(self.api.errmsg(self.db));
            std.debug.print("sqlite task store exec failed: {s}\n", .{err_txt});
            return error.SqliteExecFailed;
        }
    }

    const vtable = task_store.TaskStore.VTable{
        .claimNext = claimNext,
        .markRunning = markRunning,
        .markDone = markDone,
        .markFailedOrRequeue = markFailedOrRequeue,
        .listTasksJson = listTasksJson,
        .getTaskDetailJson = getTaskDetailJson,
        .getTaskEventsJson = getTaskEventsJson,
        .createTask = createTask,
        .patchTask = patchTask,
        .applyAction = applyAction,
        .close = close,
    };
};

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

fn sqlOptionalValue(allocator: std.mem.Allocator, text: ?[]const u8) ![]u8 {
    if (text) |v| {
        const q = try sqlQuote(allocator, v);
        defer allocator.free(q);
        return std.fmt.allocPrint(allocator, "'{s}'", .{q});
    }
    return allocator.dupe(u8, "NULL");
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
    try writer.print(",\"retry_count\":{d},\"priority\":{d},\"version\":{d},\"created_at\":{d},\"updated_at\":{d}}}", .{ task.retry_count, task.priority, task.version, task.created_at, task.updated_at });
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
