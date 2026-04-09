const std = @import("std");

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

pub const Session = struct {
    session_id: []u8,
    status: []u8,
    provider: []u8,
    model: []u8,
    provider_session_id: ?[]u8,
    in_flight_request_id: ?[]u8,
    last_error: ?[]u8,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.status);
        allocator.free(self.provider);
        allocator.free(self.model);
        if (self.provider_session_id) |v| allocator.free(v);
        if (self.in_flight_request_id) |v| allocator.free(v);
        if (self.last_error) |v| allocator.free(v);
    }
};

pub const Message = struct {
    id: i64,
    session_id: []u8,
    role: []u8,
    content: []u8,
    ts: i64,
    request_id: ?[]u8,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.role);
        allocator.free(self.content);
        if (self.request_id) |v| allocator.free(v);
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
    last_insert_rowid: *const fn (*sqlite3) callconv(.c) i64,
    changes: *const fn (*sqlite3) callconv(.c) CInt,
    limit: *const fn (*sqlite3, CInt, CInt) callconv(.c) CInt,
};

pub const SqliteSessionStore = struct {
    allocator: std.mem.Allocator,
    db: *sqlite3,
    dylib: std.DynLib,
    api: SqliteApi,
    mutex: std.Thread.Mutex = .{},
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, work_dir: []const u8) !SqliteSessionStore {
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
            .last_insert_rowid = dylib.lookup(*const fn (*sqlite3) callconv(.c) i64, "sqlite3_last_insert_rowid") orelse return error.MissingSqliteSymbol,
            .changes = dylib.lookup(*const fn (*sqlite3) callconv(.c) CInt, "sqlite3_changes") orelse return error.MissingSqliteSymbol,
            .limit = dylib.lookup(*const fn (*sqlite3, CInt, CInt) callconv(.c) CInt, "sqlite3_limit") orelse return error.MissingSqliteSymbol,
        };

        const db_dir = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, ".techlead" });
        defer allocator.free(db_dir);
        try std.fs.cwd().makePath(db_dir);

        const db_path = try std.fs.path.join(allocator, &[_][]const u8{ db_dir, "session.sqlite3" });
        defer allocator.free(db_path);

        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);

        var db_ptr: ?*sqlite3 = null;
        const rc = api.open_v2(db_path_z, &db_ptr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, null);
        if (rc != SQLITE_OK or db_ptr == null) return error.SqliteOpenFailed;

        var self = SqliteSessionStore{
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
            \\CREATE TABLE IF NOT EXISTS sessions (
            \\  session_id TEXT PRIMARY KEY,
            \\  status TEXT NOT NULL,
            \\  provider TEXT NOT NULL,
            \\  model TEXT NOT NULL,
            \\  provider_session_id TEXT,
            \\  in_flight_request_id TEXT,
            \\  last_error TEXT,
            \\  created_at INTEGER NOT NULL,
            \\  updated_at INTEGER NOT NULL
            \\);
        );
        try self.execSql(
            \\CREATE TABLE IF NOT EXISTS session_messages (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  session_id TEXT NOT NULL,
            \\  role TEXT NOT NULL,
            \\  content TEXT NOT NULL,
            \\  ts INTEGER NOT NULL,
            \\  request_id TEXT,
            \\  FOREIGN KEY (session_id) REFERENCES sessions(session_id)
            \\);
        );
        try self.execSql("CREATE INDEX IF NOT EXISTS idx_messages_session_ts ON session_messages(session_id, ts DESC);");
        try self.execSql("CREATE INDEX IF NOT EXISTS idx_messages_request_id ON session_messages(request_id);");

        return self;
    }

    pub fn deinit(self: *SqliteSessionStore) void {
        if (self.closed) return;
        _ = self.api.close_v2(self.db);
        self.dylib.close();
        self.closed = true;
    }

    /// Create a new session and return the session_id
    pub fn createSession(self: *SqliteSessionStore, provider: []const u8, model: []const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const session_id = try std.fmt.allocPrint(self.allocator, "sess-{d}", .{now});
        defer self.allocator.free(session_id);

        try self.insertSession(
            session_id,
            "active",
            provider,
            model,
            null,
            null,
            null,
            now,
            now,
        );

        return self.allocator.dupe(u8, session_id);
    }

    /// Create a session with a fixed session_id (for legacy migration/import).
    pub fn createSessionWithId(
        self: *SqliteSessionStore,
        session_id: []const u8,
        status: []const u8,
        provider: []const u8,
        model: []const u8,
        provider_session_id: ?[]const u8,
        in_flight_request_id: ?[]const u8,
        last_error: ?[]const u8,
        created_at: i64,
        updated_at: i64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.insertSession(
            session_id,
            status,
            provider,
            model,
            provider_session_id,
            in_flight_request_id,
            last_error,
            created_at,
            updated_at,
        );
    }

    fn insertSession(
        self: *SqliteSessionStore,
        session_id: []const u8,
        status: []const u8,
        provider: []const u8,
        model: []const u8,
        provider_session_id: ?[]const u8,
        in_flight_request_id: ?[]const u8,
        last_error: ?[]const u8,
        created_at: i64,
        updated_at: i64,
    ) !void {
        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);
        const status_q = try sqlQuote(self.allocator, status);
        defer self.allocator.free(status_q);
        const provider_q = try sqlQuote(self.allocator, provider);
        defer self.allocator.free(provider_q);
        const model_q = try sqlQuote(self.allocator, model);
        defer self.allocator.free(model_q);
        const psid_val = try sqlOptionalValue(self.allocator, provider_session_id);
        defer self.allocator.free(psid_val);
        const inflight_val = try sqlOptionalValue(self.allocator, in_flight_request_id);
        defer self.allocator.free(inflight_val);
        const last_error_val = try sqlOptionalValue(self.allocator, last_error);
        defer self.allocator.free(last_error_val);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO sessions(session_id,status,provider,model,provider_session_id,in_flight_request_id,last_error,created_at,updated_at) VALUES('{s}','{s}','{s}','{s}',{s},{s},{s},{d},{d});",
            .{ id_q, status_q, provider_q, model_q, psid_val, inflight_val, last_error_val, created_at, updated_at },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    /// Get session by session_id, returns null if not found
    pub fn getSession(self: *SqliteSessionStore, session_id: []const u8) !?Session {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT session_id,status,provider,model,provider_session_id,in_flight_request_id,last_error,created_at,updated_at FROM sessions WHERE session_id='{s}' LIMIT 1;",
            .{id_q},
        );
        defer self.allocator.free(sql);

        return try self.getOneSession(sql);
    }

    /// Get the current session (latest updated one), returns null if none.
    pub fn getCurrentSession(self: *SqliteSessionStore) !?Session {
        self.mutex.lock();
        defer self.mutex.unlock();

        return try self.getOneSession(
            "SELECT session_id,status,provider,model,provider_session_id,in_flight_request_id,last_error,created_at,updated_at FROM sessions ORDER BY updated_at DESC, created_at DESC, session_id DESC LIMIT 1;",
        );
    }

    /// Update session status
    pub fn updateSessionStatus(self: *SqliteSessionStore, session_id: []const u8, status: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);
        const status_q = try sqlQuote(self.allocator, status);
        defer self.allocator.free(status_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE sessions SET status='{s}', updated_at={d} WHERE session_id='{s}';",
            .{ status_q, now, id_q },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    /// End a session (set status to 'ended')
    pub fn endSession(self: *SqliteSessionStore, session_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE sessions SET status='ended', in_flight_request_id=NULL, updated_at={d} WHERE session_id='{s}';",
            .{ now, id_q },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    /// Update session's in_flight_request_id
    pub fn setInFlightRequestId(self: *SqliteSessionStore, session_id: []const u8, request_id: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);

        const req_val = try sqlOptionalValue(self.allocator, request_id);
        defer self.allocator.free(req_val);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE sessions SET in_flight_request_id={s}, updated_at={d} WHERE session_id='{s}';",
            .{ req_val, now, id_q },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    /// Update session's provider_session_id
    pub fn setProviderSessionId(self: *SqliteSessionStore, session_id: []const u8, provider_session_id: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);

        const psid_val = try sqlOptionalValue(self.allocator, provider_session_id);
        defer self.allocator.free(psid_val);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE sessions SET provider_session_id={s}, updated_at={d} WHERE session_id='{s}';",
            .{ psid_val, now, id_q },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    /// Set last_error for a session
    pub fn setLastError(self: *SqliteSessionStore, session_id: []const u8, last_error: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);

        const err_val = try sqlOptionalValue(self.allocator, last_error);
        defer self.allocator.free(err_val);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE sessions SET last_error={s}, updated_at={d} WHERE session_id='{s}';",
            .{ err_val, now, id_q },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    /// Add a message to a session, returns the message id
    pub fn addMessage(self: *SqliteSessionStore, session_id: []const u8, role: []const u8, content: []const u8, request_id: ?[]const u8) !i64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.insertMessage(session_id, role, content, std.time.timestamp(), request_id);
    }

    /// Add a message with a fixed timestamp (for migration/import), returns the message id.
    pub fn addMessageAt(self: *SqliteSessionStore, session_id: []const u8, role: []const u8, content: []const u8, ts: i64, request_id: ?[]const u8) !i64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.insertMessage(session_id, role, content, ts, request_id);
    }

    fn insertMessage(self: *SqliteSessionStore, session_id: []const u8, role: []const u8, content: []const u8, ts: i64, request_id: ?[]const u8) !i64 {
        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);
        const role_q = try sqlQuote(self.allocator, role);
        defer self.allocator.free(role_q);
        const content_q = try sqlQuote(self.allocator, content);
        defer self.allocator.free(content_q);
        const req_val = try sqlOptionalValue(self.allocator, request_id);
        defer self.allocator.free(req_val);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO session_messages(session_id,role,content,ts,request_id) VALUES('{s}','{s}','{s}',{d},{s});",
            .{ id_q, role_q, content_q, ts, req_val },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);

        return self.api.last_insert_rowid(self.db);
    }

    /// Get messages for a session, ordered by timestamp descending
    pub fn getMessages(self: *SqliteSessionStore, session_id: []const u8, limit: usize) ![]Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT id,session_id,role,content,ts,request_id FROM session_messages WHERE session_id='{s}' ORDER BY ts DESC LIMIT {d};",
            .{ id_q, limit },
        );
        defer self.allocator.free(sql);

        var msgs = std.ArrayList(Message).empty;
        defer {
            for (msgs.items) |*m| m.deinit(self.allocator);
            msgs.deinit(self.allocator);
        }

        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);

        while (self.api.step(stmt) == SQLITE_ROW) {
            try msgs.append(self.allocator, try self.readMessageFromStmt(stmt));
        }

        // Reverse to get ascending order
        std.mem.reverse(Message, msgs.items);
        return msgs.toOwnedSlice(self.allocator);
    }

    /// Find message by request_id
    pub fn findMessageByRequestId(self: *SqliteSessionStore, session_id: []const u8, request_id: []const u8) !?Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);
        const req_q = try sqlQuote(self.allocator, request_id);
        defer self.allocator.free(req_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT id,session_id,role,content,ts,request_id FROM session_messages WHERE session_id='{s}' AND request_id='{s}' LIMIT 1;",
            .{ id_q, req_q },
        );
        defer self.allocator.free(sql);

        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);

        if (self.api.step(stmt) == SQLITE_ROW) {
            return try self.readMessageFromStmt(stmt);
        }
        return null;
    }

    /// Find reply (assistant message) for a given request_id
    pub fn findReplyByRequestId(self: *SqliteSessionStore, session_id: []const u8, request_id: []const u8) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);
        const req_q = try sqlQuote(self.allocator, request_id);
        defer self.allocator.free(req_q);

        // Find the assistant message that comes after the user message with this request_id
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT m2.content FROM session_messages m1 JOIN session_messages m2 ON m2.ts > m1.ts AND m2.role = 'assistant' WHERE m1.session_id='{s}' AND m1.request_id='{s}' AND m1.role='user' ORDER BY m2.ts ASC LIMIT 1;",
            .{ id_q, req_q },
        );
        defer self.allocator.free(sql);

        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);

        if (self.api.step(stmt) == SQLITE_ROW) {
            return try self.columnTextDup(stmt, 0);
        }
        return null;
    }

    /// Get the latest user message content for a given request_id
    pub fn getLatestUserMessageByRequestId(self: *SqliteSessionStore, session_id: []const u8, request_id: []const u8) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id_q = try sqlQuote(self.allocator, session_id);
        defer self.allocator.free(id_q);
        const req_q = try sqlQuote(self.allocator, request_id);
        defer self.allocator.free(req_q);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT content FROM session_messages WHERE session_id='{s}' AND request_id='{s}' AND role='user' ORDER BY ts DESC LIMIT 1;",
            .{ id_q, req_q },
        );
        defer self.allocator.free(sql);

        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);

        if (self.api.step(stmt) == SQLITE_ROW) {
            return try self.columnTextDup(stmt, 0);
        }
        return null;
    }

    /// Check if there is an assistant reply for the given request_id
    pub fn hasReplyForRequestId(self: *SqliteSessionStore, session_id: []const u8, request_id: []const u8) !bool {
        return (try self.findReplyByRequestId(session_id, request_id)) != null;
    }

    /// Get session state as JSON string (for API compatibility)
    pub fn getSessionStateJson(self: *SqliteSessionStore, allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
        const maybe_session = try self.getSession(session_id);
        if (maybe_session == null) return error.SessionNotFound;
        var session = maybe_session.?;
        defer session.deinit(self.allocator);

        const messages = try self.getMessages(session_id, 10000);
        defer {
            for (messages) |*m| m.deinit(self.allocator);
            self.allocator.free(messages);
        }

        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);
        var w = out.writer(allocator);

        try w.writeAll("{");
        try w.print("\"session_id\":{f},", .{std.json.fmt(session.session_id, .{})});
        try w.print("\"status\":{f},", .{std.json.fmt(session.status, .{})});
        try w.print("\"provider\":{f},", .{std.json.fmt(session.provider, .{})});
        try w.print("\"model\":{f},", .{std.json.fmt(session.model, .{})});

        try w.writeAll("\"provider_session_id\":");
        if (session.provider_session_id) |v| {
            try w.print("{f}", .{std.json.fmt(v, .{})});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",");

        try w.writeAll("\"in_flight_request_id\":");
        if (session.in_flight_request_id) |v| {
            try w.print("{f}", .{std.json.fmt(v, .{})});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",");

        try w.writeAll("\"last_error\":");
        if (session.last_error) |v| {
            try w.print("{f}", .{std.json.fmt(v, .{})});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",");

        try w.print("\"created_at\":{d},\"updated_at\":{d},", .{ session.created_at, session.updated_at });

        // Calculate last_message_id
        var last_message_id: i64 = 0;
        for (messages) |m| {
            if (m.id > last_message_id) last_message_id = m.id;
        }
        try w.print("\"last_message_id\":{d},", .{last_message_id});

        try w.writeAll("\"messages\":[");
        for (messages, 0..) |m, idx| {
            if (idx > 0) try w.writeByte(',');
            try w.writeAll("{");
            try w.print("\"id\":{d},", .{m.id});
            try w.print("\"role\":{f},", .{std.json.fmt(m.role, .{})});
            try w.print("\"content\":{f},", .{std.json.fmt(m.content, .{})});
            try w.print("\"ts\":{d},", .{m.ts});
            try w.writeAll("\"request_id\":");
            if (m.request_id) |rid| {
                try w.print("{f}", .{std.json.fmt(rid, .{})});
            } else {
                try w.writeAll("null");
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");

        return out.toOwnedSlice(allocator);
    }

    fn getOneSession(self: *SqliteSessionStore, sql: []const u8) !?Session {
        const stmt = try self.prepare(sql);
        defer self.finalize(stmt);
        if (self.api.step(stmt) != SQLITE_ROW) return null;
        return try self.readSessionFromStmt(stmt);
    }

    fn readSessionFromStmt(self: *SqliteSessionStore, stmt: *sqlite3_stmt) !Session {
        return .{
            .session_id = try self.columnTextDup(stmt, 0),
            .status = try self.columnTextDup(stmt, 1),
            .provider = try self.columnTextDup(stmt, 2),
            .model = try self.columnTextDup(stmt, 3),
            .provider_session_id = try self.columnOptionalTextDup(stmt, 4),
            .in_flight_request_id = try self.columnOptionalTextDup(stmt, 5),
            .last_error = try self.columnOptionalTextDup(stmt, 6),
            .created_at = self.api.column_int64(stmt, 7),
            .updated_at = self.api.column_int64(stmt, 8),
        };
    }

    fn readMessageFromStmt(self: *SqliteSessionStore, stmt: *sqlite3_stmt) !Message {
        return .{
            .id = self.api.column_int64(stmt, 0),
            .session_id = try self.columnTextDup(stmt, 1),
            .role = try self.columnTextDup(stmt, 2),
            .content = try self.columnTextDup(stmt, 3),
            .ts = self.api.column_int64(stmt, 4),
            .request_id = try self.columnOptionalTextDup(stmt, 5),
        };
    }

    fn prepare(self: *SqliteSessionStore, sql: []const u8) !*sqlite3_stmt {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt_ptr: ?*sqlite3_stmt = null;
        const rc = self.api.prepare_v2(self.db, sql_z, -1, &stmt_ptr, null);
        if (rc != SQLITE_OK or stmt_ptr == null) return error.SqlitePrepareFailed;
        return stmt_ptr.?;
    }

    fn finalize(self: *SqliteSessionStore, stmt: *sqlite3_stmt) void {
        _ = self.api.finalize(stmt);
    }

    fn columnTextDup(self: *SqliteSessionStore, stmt: *sqlite3_stmt, index: CInt) ![]u8 {
        const p = self.api.column_text(stmt, index) orelse return error.SqliteColumnNull;
        return self.allocator.dupe(u8, std.mem.span(p));
    }

    fn columnOptionalTextDup(self: *SqliteSessionStore, stmt: *sqlite3_stmt, index: CInt) !?[]u8 {
        const p = self.api.column_text(stmt, index) orelse return null;
        const dup = try self.allocator.dupe(u8, std.mem.span(p));
        return dup;
    }

    fn execSql(self: *SqliteSessionStore, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var err_msg: ?[*:0]u8 = null;
        const rc = self.api.exec(self.db, sql_z, null, null, &err_msg);
        defer if (err_msg) |p| self.api.free(@ptrCast(p));
        if (rc != SQLITE_OK) {
            const err_txt = std.mem.span(self.api.errmsg(self.db));
            std.debug.print("sqlite session store exec failed: {s}\n", .{err_txt});
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
        // macOS
        "libsqlite3.dylib",
        "/usr/lib/libsqlite3.dylib",
        // Linux
        "libsqlite3.so.0",
        "/lib/x86_64-linux-gnu/libsqlite3.so.0",
        "libsqlite3.so",
    };
    for (candidates) |name| {
        if (std.DynLib.open(name)) |lib| return lib else |_| {}
    }
    return error.StoreNotAvailable;
}
