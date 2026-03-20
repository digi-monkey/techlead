const std = @import("std");
const store = @import("store.zig");

const sqlite3 = opaque {};

const CInt = i32;
const SQLITE_OK: CInt = 0;
const SQLITE_OPEN_READWRITE: CInt = 0x00000002;
const SQLITE_OPEN_CREATE: CInt = 0x00000004;
const SQLITE_OPEN_FULLMUTEX: CInt = 0x00010000;

const SqliteApi = struct {
    open_v2: *const fn ([*:0]const u8, *?*sqlite3, CInt, ?[*:0]const u8) callconv(.c) CInt,
    close_v2: *const fn (*sqlite3) callconv(.c) CInt,
    exec: *const fn (*sqlite3, [*:0]const u8, ?*const anyopaque, ?*anyopaque, *?[*:0]u8) callconv(.c) CInt,
    errmsg: *const fn (*sqlite3) callconv(.c) [*:0]const u8,
    free: *const fn (?*anyopaque) callconv(.c) void,
};

pub const SqliteEventStore = struct {
    allocator: std.mem.Allocator,
    db: *sqlite3,
    dylib: std.DynLib,
    api: SqliteApi,
    mutex: std.Thread.Mutex = .{},
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, work_dir: []const u8, log_dir: []const u8) !SqliteEventStore {
        var dylib = std.DynLib.open("libsqlite3.so.0") catch return error.StoreNotAvailable;
        errdefer dylib.close();

        const api = SqliteApi{
            .open_v2 = dylib.lookup(*const fn ([*:0]const u8, *?*sqlite3, CInt, ?[*:0]const u8) callconv(.c) CInt, "sqlite3_open_v2") orelse return error.MissingSqliteSymbol,
            .close_v2 = dylib.lookup(*const fn (*sqlite3) callconv(.c) CInt, "sqlite3_close_v2") orelse return error.MissingSqliteSymbol,
            .exec = dylib.lookup(*const fn (*sqlite3, [*:0]const u8, ?*const anyopaque, ?*anyopaque, *?[*:0]u8) callconv(.c) CInt, "sqlite3_exec") orelse return error.MissingSqliteSymbol,
            .errmsg = dylib.lookup(*const fn (*sqlite3) callconv(.c) [*:0]const u8, "sqlite3_errmsg") orelse return error.MissingSqliteSymbol,
            .free = dylib.lookup(*const fn (?*anyopaque) callconv(.c) void, "sqlite3_free") orelse return error.MissingSqliteSymbol,
        };

        const dir_path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, log_dir });
        defer allocator.free(dir_path);
        try std.fs.cwd().makePath(dir_path);

        const db_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, "events.sqlite3" });
        defer allocator.free(db_path);
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);

        var db_ptr: ?*sqlite3 = null;
        const rc = api.open_v2(db_path_z, &db_ptr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, null);
        if (rc != SQLITE_OK or db_ptr == null) return error.SqliteOpenFailed;

        var self = SqliteEventStore{
            .allocator = allocator,
            .db = db_ptr.?,
            .dylib = dylib,
            .api = api,
        };
        errdefer self.deinit();

        try self.execSql(
            \\CREATE TABLE IF NOT EXISTS events (
            \\  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  run_id TEXT NOT NULL,
            \\  task_id TEXT,
            \\  source TEXT NOT NULL,
            \\  event_type TEXT NOT NULL,
            \\  ts INTEGER NOT NULL,
            \\  payload TEXT NOT NULL
            \\);
        );
        try self.execSql("CREATE INDEX IF NOT EXISTS idx_events_run_id ON events(run_id);");

        return self;
    }

    pub fn asEventStore(self: *SqliteEventStore) store.EventStore {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *SqliteEventStore) void {
        if (self.closed) return;
        _ = self.api.close_v2(self.db);
        self.dylib.close();
        self.closed = true;
    }

    fn appendEvent(ctx: *anyopaque, event: store.Event) !void {
        const self: *SqliteEventStore = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.closed) return error.StoreClosed;

        const run_id_q = try sqlQuote(self.allocator, event.run_id);
        defer self.allocator.free(run_id_q);
        const source_q = try sqlQuote(self.allocator, @tagName(event.source));
        defer self.allocator.free(source_q);
        const event_type_q = try sqlQuote(self.allocator, event.event_type);
        defer self.allocator.free(event_type_q);
        const payload_q = try sqlQuote(self.allocator, event.payload);
        defer self.allocator.free(payload_q);

        const task_value = if (event.task_id) |task_id| blk: {
            const task_q = try sqlQuote(self.allocator, task_id);
            defer self.allocator.free(task_q);
            break :blk try std.fmt.allocPrint(self.allocator, "'{s}'", .{task_q});
        } else try self.allocator.dupe(u8, "NULL");
        defer self.allocator.free(task_value);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO events(run_id,task_id,source,event_type,ts,payload) VALUES('{s}',{s},'{s}','{s}',{d},'{s}');",
            .{ run_id_q, task_value, source_q, event_type_q, event.ts, payload_q },
        );
        defer self.allocator.free(sql);
        try self.execSql(sql);
    }

    fn close(ctx: *anyopaque) void {
        const self: *SqliteEventStore = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn execSql(self: *SqliteEventStore, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var err_msg: ?[*:0]u8 = null;
        const rc = self.api.exec(self.db, sql_z, null, null, &err_msg);
        defer if (err_msg) |p| self.api.free(@ptrCast(p));
        if (rc != SQLITE_OK) {
            const err_txt = std.mem.span(self.api.errmsg(self.db));
            std.debug.print("sqlite exec failed: {s}\n", .{err_txt});
            return error.SqliteExecFailed;
        }
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

    const vtable = store.EventStore.VTable{
        .appendEvent = appendEvent,
        .close = close,
    };
};

test "sqlite event store can initialize and write one event" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(work_dir);

    var s = SqliteEventStore.init(allocator, work_dir, ".techlead/iteration-logs") catch |err| switch (err) {
        error.StoreNotAvailable, error.MissingSqliteSymbol => return,
        else => return err,
    };
    defer s.deinit();

    const es = s.asEventStore();
    try es.appendEvent(.{
        .run_id = "run-sqlite",
        .source = .system,
        .event_type = "run.started",
        .ts = 1,
        .payload = "{\"ok\":true}",
    });

    const db_path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, ".techlead/iteration-logs", "events.sqlite3" });
    defer allocator.free(db_path);
    try std.fs.cwd().access(db_path, .{});
}
