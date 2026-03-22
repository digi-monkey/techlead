const std = @import("std");

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

const CInt = i32;
const SQLITE_OK: CInt = 0;
const SQLITE_ROW: CInt = 100;
const SQLITE_OPEN_READWRITE: CInt = 0x00000002;
const SQLITE_OPEN_CREATE: CInt = 0x00000004;
const SQLITE_OPEN_FULLMUTEX: CInt = 0x00010000;
const SQLITE_LIMIT_SQL_LENGTH: CInt = 1;

pub const RunState = struct {
    run_id: []u8,
    mode: []u8,
    status: []u8,
    updated_at: i64,

    pub fn deinit(self: *RunState, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.mode);
        allocator.free(self.status);
    }
};

pub const ControlCommand = struct {
    id: i64,
    action: []u8,
    prompt: ?[]u8,
    operator: ?[]u8,
    request_id: ?[]u8,
    source: ?[]u8,
    created_at: i64,

    pub fn deinit(self: *ControlCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.action);
        if (self.prompt) |v| allocator.free(v);
        if (self.operator) |v| allocator.free(v);
        if (self.request_id) |v| allocator.free(v);
        if (self.source) |v| allocator.free(v);
    }
};

pub const Tokens = struct {
    observe_token: []u8,
    control_token: []u8,
    observe_expires_at: i64,
    control_expires_at: i64,

    pub fn deinit(self: *Tokens, allocator: std.mem.Allocator) void {
        allocator.free(self.observe_token);
        allocator.free(self.control_token);
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
    column_int64: *const fn (*sqlite3_stmt, CInt) callconv(.c) i64,
    limit: *const fn (*sqlite3, CInt, CInt) callconv(.c) CInt,
};

pub const SqliteRuntimeStore = struct {
    allocator: std.mem.Allocator,
    db: *sqlite3,
    dylib: std.DynLib,
    api: SqliteApi,
    mutex: std.Thread.Mutex = .{},
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, work_dir: []const u8) !SqliteRuntimeStore {
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
            .column_int64 = dylib.lookup(*const fn (*sqlite3_stmt, CInt) callconv(.c) i64, "sqlite3_column_int64") orelse return error.MissingSqliteSymbol,
            .limit = dylib.lookup(*const fn (*sqlite3, CInt, CInt) callconv(.c) CInt, "sqlite3_limit") orelse return error.MissingSqliteSymbol,
        };

        const db_dir = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, ".techlead" });
        defer allocator.free(db_dir);
        try std.fs.cwd().makePath(db_dir);

        const db_path = try std.fs.path.join(allocator, &[_][]const u8{ db_dir, "runtime.sqlite3" });
        defer allocator.free(db_path);
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);

        var db_ptr: ?*sqlite3 = null;
        const rc = api.open_v2(db_path_z, &db_ptr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, null);
        if (rc != SQLITE_OK or db_ptr == null) return error.SqliteOpenFailed;

        var self = SqliteRuntimeStore{
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
            \\CREATE TABLE IF NOT EXISTS run_state (
            \\  id INTEGER PRIMARY KEY CHECK (id = 1),
            \\  run_id TEXT NOT NULL,
            \\  mode TEXT NOT NULL,
            \\  status TEXT NOT NULL,
            \\  updated_at INTEGER NOT NULL
            \\);
        );
        try self.execSql(
            \\CREATE TABLE IF NOT EXISTS control_queue (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  action TEXT NOT NULL,
            \\  prompt TEXT,
            \\  operator TEXT,
            \\  request_id TEXT,
            \\  source TEXT,
            \\  created_at INTEGER NOT NULL,
            \\  consumed_at INTEGER
            \\);
        );
        try self.execSql("CREATE INDEX IF NOT EXISTS idx_control_queue_pending ON control_queue(consumed_at, id);");
        try self.execSql(
            \\CREATE TABLE IF NOT EXISTS observe_tokens (
            \\  id INTEGER PRIMARY KEY CHECK (id = 1),
            \\  observe_token TEXT NOT NULL,
            \\  control_token TEXT NOT NULL,
            \\  observe_expires_at INTEGER NOT NULL,
            \\  control_expires_at INTEGER NOT NULL,
            \\  updated_at INTEGER NOT NULL
            \\);
        );

        return self;
    }

    pub fn deinit(self: *SqliteRuntimeStore) void {
        if (self.closed) return;
        _ = self.api.close_v2(self.db);
        self.dylib.close();
        self.closed = true;
    }

    pub fn upsertRunState(self: *SqliteRuntimeStore, run_id: []const u8, mode: []const u8, status: []const u8, updated_at: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const run_id_q = try sqlQuote(self.allocator, run_id);
        defer self.allocator.free(run_id_q);
        const mode_q = try sqlQuote(self.allocator, mode);
        defer self.allocator.free(mode_q);
        const status_q = try sqlQuote(self.allocator, status);
        defer self.allocator.free(status_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO run_state(id,run_id,mode,status,updated_at) VALUES(1,'{s}','{s}','{s}',{d}) ON CONFLICT(id) DO UPDATE SET run_id=excluded.run_id,mode=excluded.mode,status=excluded.status,updated_at=excluded.updated_at;",
            .{ run_id_q, mode_q, status_q, updated_at },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    pub fn getRunState(self: *SqliteRuntimeStore) !?RunState {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stmt = try self.prepare("SELECT run_id,mode,status,updated_at FROM run_state WHERE id=1 LIMIT 1;");
        defer self.finalize(stmt);
        if (self.api.step(stmt) != SQLITE_ROW) return null;

        return .{
            .run_id = try self.columnTextDup(stmt, 0),
            .mode = try self.columnTextDup(stmt, 1),
            .status = try self.columnTextDup(stmt, 2),
            .updated_at = self.api.column_int64(stmt, 3),
        };
    }

    pub fn enqueueControl(
        self: *SqliteRuntimeStore,
        action: []const u8,
        prompt: ?[]const u8,
        operator: []const u8,
        source: []const u8,
        request_id: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const action_q = try sqlQuote(self.allocator, action);
        defer self.allocator.free(action_q);
        const prompt_val = try sqlOptionalValue(self.allocator, prompt);
        defer self.allocator.free(prompt_val);
        const operator_q = try sqlQuote(self.allocator, operator);
        defer self.allocator.free(operator_q);
        const source_q = try sqlQuote(self.allocator, source);
        defer self.allocator.free(source_q);
        const rid_q = try sqlQuote(self.allocator, request_id);
        defer self.allocator.free(rid_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO control_queue(action,prompt,operator,request_id,source,created_at,consumed_at) VALUES('{s}',{s},'{s}','{s}','{s}',{d},NULL);",
            .{ action_q, prompt_val, operator_q, rid_q, source_q, std.time.timestamp() },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    pub fn consumeControl(self: *SqliteRuntimeStore) !?ControlCommand {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stmt = try self.prepare("SELECT id,action,prompt,operator,request_id,source,created_at FROM control_queue WHERE consumed_at IS NULL ORDER BY id ASC LIMIT 1;");
        defer self.finalize(stmt);

        if (self.api.step(stmt) != SQLITE_ROW) return null;

        var cmd = ControlCommand{
            .id = self.api.column_int64(stmt, 0),
            .action = try self.columnTextDup(stmt, 1),
            .prompt = try self.columnOptionalTextDup(stmt, 2),
            .operator = try self.columnOptionalTextDup(stmt, 3),
            .request_id = try self.columnOptionalTextDup(stmt, 4),
            .source = try self.columnOptionalTextDup(stmt, 5),
            .created_at = self.api.column_int64(stmt, 6),
        };
        errdefer cmd.deinit(self.allocator);

        const mark_sql = try std.fmt.allocPrint(self.allocator, "UPDATE control_queue SET consumed_at={d} WHERE id={d};", .{ std.time.timestamp(), cmd.id });
        defer self.allocator.free(mark_sql);
        try self.execSql(mark_sql);

        return cmd;
    }

    pub fn upsertTokens(
        self: *SqliteRuntimeStore,
        observe_token: []const u8,
        control_token: []const u8,
        observe_expires_at: i64,
        control_expires_at: i64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const observe_q = try sqlQuote(self.allocator, observe_token);
        defer self.allocator.free(observe_q);
        const control_q = try sqlQuote(self.allocator, control_token);
        defer self.allocator.free(control_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO observe_tokens(id,observe_token,control_token,observe_expires_at,control_expires_at,updated_at) VALUES(1,'{s}','{s}',{d},{d},{d}) ON CONFLICT(id) DO UPDATE SET observe_token=excluded.observe_token,control_token=excluded.control_token,observe_expires_at=excluded.observe_expires_at,control_expires_at=excluded.control_expires_at,updated_at=excluded.updated_at;",
            .{ observe_q, control_q, observe_expires_at, control_expires_at, std.time.timestamp() },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    pub fn getTokens(self: *SqliteRuntimeStore) !?Tokens {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stmt = try self.prepare("SELECT observe_token,control_token,observe_expires_at,control_expires_at FROM observe_tokens WHERE id=1 LIMIT 1;");
        defer self.finalize(stmt);
        if (self.api.step(stmt) != SQLITE_ROW) return null;

        return .{
            .observe_token = try self.columnTextDup(stmt, 0),
            .control_token = try self.columnTextDup(stmt, 1),
            .observe_expires_at = self.api.column_int64(stmt, 2),
            .control_expires_at = self.api.column_int64(stmt, 3),
        };
    }

    fn prepare(self: *SqliteRuntimeStore, sql: []const u8) !*sqlite3_stmt {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt_ptr: ?*sqlite3_stmt = null;
        const rc = self.api.prepare_v2(self.db, sql_z, -1, &stmt_ptr, null);
        if (rc != SQLITE_OK or stmt_ptr == null) return error.SqlitePrepareFailed;
        return stmt_ptr.?;
    }

    fn finalize(self: *SqliteRuntimeStore, stmt: *sqlite3_stmt) void {
        _ = self.api.finalize(stmt);
    }

    fn columnTextDup(self: *SqliteRuntimeStore, stmt: *sqlite3_stmt, index: CInt) ![]u8 {
        const p = self.api.column_text(stmt, index) orelse return error.SqliteColumnNull;
        return self.allocator.dupe(u8, std.mem.span(p));
    }

    fn columnOptionalTextDup(self: *SqliteRuntimeStore, stmt: *sqlite3_stmt, index: CInt) !?[]u8 {
        const p = self.api.column_text(stmt, index) orelse return null;
        const dup = try self.allocator.dupe(u8, std.mem.span(p));
        return dup;
    }

    fn execSql(self: *SqliteRuntimeStore, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var err_msg: ?[*:0]u8 = null;
        const rc = self.api.exec(self.db, sql_z, null, null, &err_msg);
        defer if (err_msg) |p| self.api.free(@ptrCast(p));
        if (rc != SQLITE_OK) {
            const err_txt = std.mem.span(self.api.errmsg(self.db));
            std.debug.print("sqlite runtime store exec failed: {s}\n", .{err_txt});
            return error.SqliteExecFailed;
        }
    }
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
