const std = @import("std");
const sqlite_store = @import("sqlite_store.zig");

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

const Allocator = std.mem.Allocator;
const CInt = i32;
const SQLITE_OK: CInt = 0;
const SQLITE_ROW: CInt = 100;
const SQLITE_OPEN_READONLY: CInt = 0x00000001;
const SQLITE_OPEN_FULLMUTEX: CInt = 0x00010000;

const SqliteApi = struct {
    open_v2: *const fn ([*:0]const u8, *?*sqlite3, CInt, ?[*:0]const u8) callconv(.c) CInt,
    close_v2: *const fn (*sqlite3) callconv(.c) CInt,
    prepare_v2: *const fn (*sqlite3, [*:0]const u8, CInt, *?*sqlite3_stmt, ?*?[*:0]const u8) callconv(.c) CInt,
    step: *const fn (*sqlite3_stmt) callconv(.c) CInt,
    finalize: *const fn (*sqlite3_stmt) callconv(.c) CInt,
    column_text: *const fn (*sqlite3_stmt, CInt) callconv(.c) ?[*:0]const u8,
    column_int64: *const fn (*sqlite3_stmt, CInt) callconv(.c) i64,
};

const SqliteReader = struct {
    allocator: Allocator,
    db: *sqlite3,
    dylib: std.DynLib,
    api: SqliteApi,

    fn init(allocator: Allocator, db_path: []const u8) !SqliteReader {
        var dylib = openSqliteDynLib() catch return error.StoreNotAvailable;
        errdefer dylib.close();

        const api = SqliteApi{
            .open_v2 = dylib.lookup(*const fn ([*:0]const u8, *?*sqlite3, CInt, ?[*:0]const u8) callconv(.c) CInt, "sqlite3_open_v2") orelse return error.MissingSqliteSymbol,
            .close_v2 = dylib.lookup(*const fn (*sqlite3) callconv(.c) CInt, "sqlite3_close_v2") orelse return error.MissingSqliteSymbol,
            .prepare_v2 = dylib.lookup(*const fn (*sqlite3, [*:0]const u8, CInt, *?*sqlite3_stmt, ?*?[*:0]const u8) callconv(.c) CInt, "sqlite3_prepare_v2") orelse return error.MissingSqliteSymbol,
            .step = dylib.lookup(*const fn (*sqlite3_stmt) callconv(.c) CInt, "sqlite3_step") orelse return error.MissingSqliteSymbol,
            .finalize = dylib.lookup(*const fn (*sqlite3_stmt) callconv(.c) CInt, "sqlite3_finalize") orelse return error.MissingSqliteSymbol,
            .column_text = dylib.lookup(*const fn (*sqlite3_stmt, CInt) callconv(.c) ?[*:0]const u8, "sqlite3_column_text") orelse return error.MissingSqliteSymbol,
            .column_int64 = dylib.lookup(*const fn (*sqlite3_stmt, CInt) callconv(.c) i64, "sqlite3_column_int64") orelse return error.MissingSqliteSymbol,
        };

        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);

        var db_ptr: ?*sqlite3 = null;
        const rc = api.open_v2(db_path_z, &db_ptr, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, null);
        if (rc != SQLITE_OK or db_ptr == null) return error.SqliteOpenFailed;

        return .{
            .allocator = allocator,
            .db = db_ptr.?,
            .dylib = dylib,
            .api = api,
        };
    }

    fn deinit(self: *SqliteReader) void {
        _ = self.api.close_v2(self.db);
        self.dylib.close();
    }

    fn prepare(self: *SqliteReader, sql: []const u8) !*sqlite3_stmt {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt_ptr: ?*sqlite3_stmt = null;
        const rc = self.api.prepare_v2(self.db, sql_z, -1, &stmt_ptr, null);
        if (rc != SQLITE_OK or stmt_ptr == null) return error.SqlitePrepareFailed;
        return stmt_ptr.?;
    }
};

const DiskEvent = struct {
    run_id: []const u8,
    task_id: ?[]const u8,
    source: []const u8,
    event_type: []const u8,
    ts: i64,
    payload: []const u8,
};

pub fn readEventsJsonl(allocator: Allocator, work_dir: []const u8, log_dir: []const u8) ![]u8 {
    const db_path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, log_dir, "events.sqlite3" });
    defer allocator.free(db_path);

    std.fs.cwd().access(db_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "{\"events\":[]}"),
        else => return err,
    };

    var reader = SqliteReader.init(allocator, db_path) catch |err| switch (err) {
        error.StoreNotAvailable, error.MissingSqliteSymbol, error.SqliteOpenFailed => return allocator.dupe(u8, "{\"events\":[]}"),
        else => return err,
    };
    defer reader.deinit();

    const stmt = try reader.prepare("SELECT run_id,task_id,source,event_type,ts,payload FROM events ORDER BY event_id ASC;");
    defer _ = reader.api.finalize(stmt);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var w = out.writer(allocator);
    try w.writeAll("{\"events\":[");

    var first = true;
    while (reader.api.step(stmt) == SQLITE_ROW) {
        const event = readDiskEventFromStmt(stmt, &reader.api);
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{f}", .{std.json.fmt(event, .{})});
    }
    try w.writeAll("]}");
    return out.toOwnedSlice(allocator);
}

pub fn readEventsAfter(allocator: Allocator, work_dir: []const u8, log_dir: []const u8, after: usize) ![]u8 {
    const db_path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, log_dir, "events.sqlite3" });
    defer allocator.free(db_path);

    std.fs.cwd().access(db_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "{\"events\":[],\"last_event_id\":0}"),
        else => return err,
    };

    var reader = SqliteReader.init(allocator, db_path) catch |err| switch (err) {
        error.StoreNotAvailable, error.MissingSqliteSymbol, error.SqliteOpenFailed => return allocator.dupe(u8, "{\"events\":[],\"last_event_id\":0}"),
        else => return err,
    };
    defer reader.deinit();

    const sql = try std.fmt.allocPrint(allocator, "SELECT event_id,run_id,task_id,source,event_type,ts,payload FROM events WHERE event_id>{d} ORDER BY event_id ASC;", .{after});
    defer allocator.free(sql);
    const stmt = try reader.prepare(sql);
    defer _ = reader.api.finalize(stmt);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var w = out.writer(allocator);
    try w.writeAll("{\"events\":[");

    var first = true;
    var last_event_id: usize = 0;
    while (reader.api.step(stmt) == SQLITE_ROW) {
        const event_id_raw = reader.api.column_int64(stmt, 0);
        if (event_id_raw <= 0) continue;
        const event_id: usize = @intCast(event_id_raw);
        if (event_id > last_event_id) last_event_id = event_id;

        const event = readDiskEventFromStmtOffset(stmt, &reader.api, 1);
        const line = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(event, .{})});
        defer allocator.free(line);

        if (!first) try w.writeByte(',');
        first = false;
        try w.print(
            "{{\"event_id\":{d},\"event_jsonl\":{f}}}",
            .{ event_id, std.json.fmt(line, .{}) },
        );
    }

    if (last_event_id == 0) {
        const max_stmt = try reader.prepare("SELECT COALESCE(MAX(event_id),0) FROM events;");
        defer _ = reader.api.finalize(max_stmt);
        if (reader.api.step(max_stmt) == SQLITE_ROW) {
            const max_id_raw = reader.api.column_int64(max_stmt, 0);
            if (max_id_raw > 0) last_event_id = @intCast(max_id_raw);
        }
    }

    try w.print("],\"last_event_id\":{d}}}", .{last_event_id});
    return out.toOwnedSlice(allocator);
}

fn readDiskEventFromStmt(stmt: *sqlite3_stmt, api: *const SqliteApi) DiskEvent {
    return readDiskEventFromStmtOffset(stmt, api, 0);
}

fn readDiskEventFromStmtOffset(stmt: *sqlite3_stmt, api: *const SqliteApi, offset: CInt) DiskEvent {
    const run_id = api.column_text(stmt, offset + 0) orelse "";
    const task_ptr = api.column_text(stmt, offset + 1);
    const source = api.column_text(stmt, offset + 2) orelse "";
    const event_type = api.column_text(stmt, offset + 3) orelse "";
    const ts = api.column_int64(stmt, offset + 4);
    const payload = api.column_text(stmt, offset + 5) orelse "";
    return .{
        .run_id = std.mem.span(run_id),
        .task_id = if (task_ptr) |p| std.mem.span(p) else null,
        .source = std.mem.span(source),
        .event_type = std.mem.span(event_type),
        .ts = ts,
        .payload = std.mem.span(payload),
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

test "readEventsJsonl handles missing file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(work_dir);
    const got = try readEventsJsonl(allocator, work_dir, ".techlead/iteration-logs");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("{\"events\":[]}", got);
}

test "readEventsAfter returns filtered events with event ids" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(work_dir);

    var s = sqlite_store.SqliteEventStore.init(allocator, work_dir, ".techlead/iteration-logs") catch |err| switch (err) {
        error.StoreNotAvailable, error.MissingSqliteSymbol => return,
        else => return err,
    };
    defer s.deinit();
    const es = s.asEventStore();

    try es.appendEvent(.{
        .run_id = "run-a",
        .source = .system,
        .event_type = "a",
        .ts = 1,
        .payload = "{\"a\":1}",
    });
    try es.appendEvent(.{
        .run_id = "run-a",
        .source = .system,
        .event_type = "b",
        .ts = 2,
        .payload = "{\"a\":2}",
    });

    const got = try readEventsAfter(allocator, work_dir, ".techlead/iteration-logs", 1);
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"event_id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"last_event_id\":2") != null);
}
