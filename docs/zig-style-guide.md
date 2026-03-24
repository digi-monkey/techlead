# Zig 代码风格指南

基于 Techlead 代码库 (Zig 0.15+) 的编程模式和最佳实践

---

## 1. 接口定义最佳实践

### 1.1 VTable 模式 (接口抽象)

代码库使用 VTable 模式实现接口/实现分离:

```zig
// 接口定义 (task_store.zig)
pub const TaskStore = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        claimNext: *const fn (ctx: *anyopaque, options: ClaimOptions) anyerror!?Task,
        markRunning: *const fn (ctx: *anyopaque, task_id: []const u8, ...) anyerror!void,
        // ... 更多方法
        close: *const fn (ctx: *anyopaque) void,
    };

    // 包装方法
    pub fn claimNext(self: TaskStore, options: ClaimOptions) !?Task {
        return self.vtable.claimNext(self.ctx, options);
    }
};
```

**关键原则:**
- `ctx: *anyopaque` - 指向具体实现的指针
- `vtable: *const VTable` - 指向虚函数表的指针
- 所有方法返回 `anyerror!T` 以支持错误传播
- 提供包装方法简化调用

### 1.2 类型转换模式

```zig
// 实现中转换 ctx 回具体类型
fn claimNext(ctx: *anyopaque, options: task_store.ClaimOptions) !?task_store.Task {
    const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
    // ... 实现
}
```

### 1.3 转换为接口

```zig
pub fn asTaskStore(self: *SqliteTaskStore) task_store.TaskStore {
    return .{ .ctx = self, .vtable = &vtable };
}

const vtable = task_store.TaskStore.VTable{
    .claimNext = claimNext,
    .markRunning = markRunning,
    // ...
    .close = close,
};
```

---

## 2. 数据结构定义

### 2.1 领域模型结构体

```zig
pub const Task = struct {
    task_id: []u8,           // 动态分配内存
    title: []u8,
    prompt: ?[]u8,          // 可选字段
    status: TaskStatus,      // 枚举类型
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
    version: i64,           // 乐观锁版本
    created_at: i64,
    updated_at: i64,

    // 必须实现 deinit 方法释放内存
    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.title);
        if (self.prompt) |v| allocator.free(v);
        if (self.lease_owner) |v| allocator.free(v);
        // ... 释放所有可选字段
    }
};
```

### 2.2 枚举定义

```zig
pub const TaskStatus = enum {
    queued,
    claimed,
    running,
    review,
    done,
    failed,
    canceled,
};

// 枚举与字符串转换
pub fn taskStatusFromString(text: []const u8) !TaskStatus {
    if (std.mem.eql(u8, text, "queued")) return .queued;
    if (std.mem.eql(u8, text, "claimed")) return .claimed;
    // ...
    return error.InvalidTaskStatus;  // 自定义错误
}

pub fn taskStatusToString(status: TaskStatus) []const u8 {
    return @tagName(status);  // 使用 @tagName 获取枚举名称
}
```

### 2.3 输入/输出结构体

```zig
pub const CreateTaskInput = struct {
    task_id: []const u8,
    title: []const u8,
    prompt: ?[]const u8,
    priority: i32,
    max_retries: ?u32,
};

pub const PatchTaskInput = struct {
    title: ?[]const u8,     // 所有字段都是可选的
    prompt: ?[]const u8,
    priority: ?i32,
    max_retries: ?u32,
    version: i64,           // 版本控制（乐观锁）
};

pub const OperatorMeta = struct {
    operator: ?[]const u8 = null,
    source: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
};
```

---

## 3. SQLite 操作最佳实践

### 3.1 存储结构

```zig
pub const SqliteTaskStore = struct {
    allocator: std.mem.Allocator,
    db: *sqlite3,
    dylib: std.DynLib,
    api: SqliteApi,
    mutex: std.Thread.Mutex = .{},  // 线程安全
    closed: bool = false,
};

const SqliteApi = struct {
    open_v2: *const fn ([*:0]const u8, *?*sqlite3, CInt, ?[*:0]const u8) callconv(.c) CInt,
    close_v2: *const fn (*sqlite3) callconv(.c) CInt,
    exec: *const fn (*sqlite3, [*:0]const u8, ?*const anyopaque, ?*anyopaque, *?[*:0]u8) callconv(.c) CInt,
    // ... 其他 SQLite C 函数
};
```

### 3.2 动态库加载模式

```zig
pub fn init(allocator: std.mem.Allocator, work_dir: []const u8) !SqliteTaskStore {
    var dylib = openSqliteDynLib() catch return error.StoreNotAvailable;
    errdefer dylib.close();

    const api = SqliteApi{
        .open_v2 = dylib.lookup(*const fn (...) callconv(.c) CInt, "sqlite3_open_v2") 
            orelse return error.MissingSqliteSymbol,
        // ... 查找其他符号
    };
    // ...
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
```

### 3.3 SQL 执行模式

```zig
fn execSql(self: *SqliteTaskStore, sql: []const u8) !void {
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
```

### 3.4 Prepared Statement 模式

```zig
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

// 使用模式
const stmt = try self.prepare(sql);
defer self.finalize(stmt);
```

### 3.5 列数据读取模式

```zig
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
```

### 3.6 SQL 字符串转义

```zig
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
```

### 3.7 乐观锁模式

```zig
// 读取当前版本
const read_sql = try std.fmt.allocPrint(self.allocator, 
    "SELECT retry_count,COALESCE(max_retries,{d}) FROM tasks WHERE task_id='{s}' AND lease_owner='{s}' LIMIT 1;", 
    .{ default_max_retries, task_q, owner_q });
defer self.allocator.free(read_sql);
const stmt = try self.prepare(read_sql);
defer self.finalize(stmt);
if (self.api.step(stmt) != SQLITE_ROW) return error.TaskNotClaimed;

// 使用版本号进行条件更新
const update_sql = try std.fmt.allocPrint(
    self.allocator,
    "UPDATE tasks SET status='{s}', version=version+1 WHERE task_id='{s}' AND version={d};",
    .{ status_q, task_q, current_version },
);
// 检查 affected rows
if (self.api.changes(self.db) != 1) return error.VersionConflict;
```

---

## 4. 错误处理最佳实践

### 4.1 自定义错误类型

```zig
// 定义领域特定错误
pub const MyError = error{
    InvalidTaskStatus,
    InvalidReviewStage,
    TaskNotFound,
    TaskNotClaimed,
    VersionConflict,
    ActionRejected,
    ForceMergeDisabled,
    ClaimConflict,
    SqliteExecFailed,
    SqlitePrepareFailed,
    StoreNotAvailable,
    MissingSqliteSymbol,
};

// 组合错误
pub const AllErrors = MyError || std.mem.Allocator.Error || std.fmt.AllocPrintError;
```

### 4.2 错误传播

```zig
// 使用 try 传播错误
const stmt = try self.prepare(sql);

// 使用 catch 处理错误
var dylib = openSqliteDynLib() catch return error.StoreNotAvailable;

// 在 switch 中处理特定错误
ts.applyAction(task_id, action, meta) catch |err| switch (err) {
    error.ActionRejected => return respondJson(req, .conflict, "{\"error\":\"action_rejected\"}"),
    error.ForceMergeDisabled => return respondJson(req, .bad_request, "{\"error\":\"force_merge_disabled\"}"),
    else => return respondJson(req, .bad_request, "{\"error\":\"action_failed\"}"),
};
```

### 4.3 获取错误名称

```zig
const err_name = @errorName(err);
ui.logError("操作失败: {s}", .{err_name});
```

---

## 5. 内存管理最佳实践

### 5.1 defer 模式

```zig
// 基础 defer
const sql = try std.fmt.allocPrint(self.allocator, "...", .{});
defer self.allocator.free(sql);

// 带条件的 defer
var selected_id: ?[]u8 = null;
defer if (selected_id) |v| self.allocator.free(v);

// defer 块清理多个资源
defer {
    for (rows.items) |*item| item.deinit(self.allocator);
    rows.deinit(self.allocator);
}

// 错误路径专用 defer (errdefer)
const merge_commit = try gitRevParse(allocator, cwd, "HEAD");
errdefer allocator.free(merge_commit);
```

### 5.2 ArrayList 模式

```zig
// 使用 ArrayList 构建动态内容
var out = std.ArrayList(u8).empty;
defer out.deinit(allocator);
var w = out.writer(allocator);
try w.writeAll("{\"tasks\":[");
// ... 写入内容
return out.toOwnedSlice(allocator);  // 转移所有权
```

### 5.3 资源所有权转移

```zig
// 创建资源
const id_q = try sqlQuote(self.allocator, input.task_id);
// 转移到容器
const key_copy = try ctx.allocator.dupe(u8, bootstrap_id);
errdefer ctx.allocator.free(key_copy);  // 失败时清理
ctx.bootstrap_tickets.put(key_copy, .{...}) catch |err| {
    ctx.allocator.free(key_copy);  // 手动清理
    return err;
};
// 成功后 key_copy 由 HashMap 管理
```

---

## 6. JSON 处理最佳实践

### 6.1 序列化 (使用 std.json.fmt)

```zig
// 动态构建 JSON
var out = std.ArrayList(u8).empty;
defer out.deinit(allocator);
var w = out.writer(allocator);

try w.writeAll("{\"task_id\":");
try w.print("{f}", .{std.json.fmt(task.task_id, .{})});  // 自动转义
try w.writeAll(",\"status\":");
try w.print("{f}", .{std.json.fmt(taskStatusToString(task.status), .{})});
try w.writeAll(",\"count\":");
try w.print("{d}", .{task.retry_count});
// 可选字段
if (task.prompt) |p| {
    try w.print("{f}", .{std.json.fmt(p, .{})});
} else {
    try w.writeAll("null");
}
try w.writeByte('}');

return out.toOwnedSlice(allocator);
```

### 6.2 反序列化

```zig
// 解析到结构体
const parsed = try std.json.parseFromSlice(ControlBody, allocator, body_raw, .{});
defer parsed.deinit();

// 解析到动态 Value
var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
defer parsed.deinit();

if (parsed.value != .object) return error.ResultJsonInvalid;
const obj = parsed.value.object;

const blockers_value = obj.get("blockers") orelse return error.ResultJsonMissingBlockers;
if (blockers_value != .array) return error.ResultJsonBlockersNotArray;
```

### 6.3 JSON Value 处理

```zig
// 安全获取字符串
fn jsonValueAsString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// 获取数字（支持多种类型）
const confidence: f64 = switch (confidence_value) {
    .float => |f| f,
    .integer => |i| @as(f64, @floatFromInt(i)),
    .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.InvalidNumber,
    else => return error.InvalidType,
};
```

---

## 7. 并发与同步

### 7.1 Mutex 使用模式

```zig
// 全局互斥锁
var g_store_mutex: std.Thread.Mutex = .{};
var g_session_ops_mutex: std.Thread.Mutex = .{};

// 方法级锁定
fn claimNext(ctx: *anyopaque, options: task_store.ClaimOptions) !?task_store.Task {
    const self: *SqliteTaskStore = @ptrCast(@alignCast(ctx));
    self.mutex.lock();
    defer self.mutex.unlock();  // 确保释放
    // ... 执行操作
}
```

### 7.2 全局状态管理

```zig
// 惰性初始化的全局单例
var g_store: ?sqlite_session_store.SqliteSessionStore = null;
var g_store_mutex: std.Thread.Mutex = .{};

fn getStore(allocator: Allocator, target_dir: []const u8) !*sqlite_session_store.SqliteSessionStore {
    g_store_mutex.lock();
    defer g_store_mutex.unlock();

    if (g_store == null) {
        g_store = try sqlite_session_store.SqliteSessionStore.init(allocator, target_dir);
    }
    return &g_store.?;
}

pub fn deinitStore() void {
    g_store_mutex.lock();
    defer g_store_mutex.unlock();

    if (g_store) |*store| {
        store.deinit();
        g_store = null;
    }
}
```

---

## 8. HTTP 服务与 API 模式

### 8.1 请求体结构体

```zig
const CreateTaskBody = struct {
    title: ?[]const u8 = null,      // 可选字段
    prompt: ?[]const u8 = null,
    priority: ?i32 = null,
    max_retries: ?u32 = null,
    request_id: ?[]const u8 = null,
};

const PatchTaskBody = struct {
    title: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    priority: ?i32 = null,
    max_retries: ?u32 = null,
    version: ?i64 = null,           // 乐观锁版本（必需时检查）
    request_id: ?[]const u8 = null,
};
```

### 8.2 请求解析模式

```zig
fn parseCreateTaskBody(req: *http.Server.Request, allocator: Allocator) !?CreateTaskBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;  // 限制大小

    var buf: [1024]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(CreateTaskBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();

    return .{
        .title = if (parsed.value.title) |v| try allocator.dupe(u8, v) else null,
        .prompt = if (parsed.value.prompt) |v| try allocator.dupe(u8, v) else null,
        .priority = parsed.value.priority,
        .max_retries = parsed.value.max_retries,
        .request_id = if (parsed.value.request_id) |v| try allocator.dupe(u8, v) else null,
    };
}
```

### 8.3 响应构建模式

```zig
fn respondJson(req: *http.Server.Request, status: http.Status, body: []const u8) !void {
    try respondBody(req, status, body, "application/json; charset=utf-8", "no-store");
}

fn respondBody(req: *http.Server.Request, status: http.Status, body: []const u8, 
               content_type: []const u8, cache_control: []const u8) !void {
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = cache_control },
    };
    try req.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &headers,
    });
}

// 带 Cookie 的响应
fn respondJsonWithCookies(req: *http.Server.Request, status: http.Status, body: []const u8, 
                          observe_cookie: []const u8, control_cookie: []const u8) !void {
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "set-cookie", .value = observe_cookie },
        .{ .name = "set-cookie", .value = control_cookie },
    };
    try req.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &headers,
    });
}
```

### 8.4 API 处理器模式

```zig
fn handleTasksApi(ctx: *ServerContext, req: *http.Server.Request, target: []const u8) !void {
    // 初始化存储
    var store = sqlite_task_store.SqliteTaskStore.init(ctx.allocator, ctx.target_dir) 
        catch |err| switch (err) {
            error.StoreNotAvailable => return respondJson(req, .service_unavailable, ...),
            else => return respondJson(req, .bad_request, ...),
        };
    defer store.deinit();
    const ts = store.asTaskStore();

    // 路由分发
    if (std.mem.eql(u8, target, "/tasks") or std.mem.startsWith(u8, target, "/tasks?")) {
        if (req.head.method == .GET) {
            // 权限检查
            if (!authorizedObserve(ctx, req)) return respondJson(req, .unauthorized, ...);
            
            // 解析查询参数
            const status_text = queryValue(target, "status");
            const limit = parseLimitQuery(target, 50);
            
            // 执行业务逻辑
            const out = ts.listTasksJson(ctx.allocator, .{...}) 
                catch return respondJson(req, .bad_request, ...);
            defer ctx.allocator.free(out);
            return respondJson(req, .ok, out);
        }
        // ... 其他方法
    }
    // ... 其他路由
}
```

### 8.5 查询参数解析

```zig
fn queryValue(target: []const u8, key: []const u8) ?[]const u8 {
    const qpos = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[qpos + 1 ..];
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        const v = pair[eq + 1 ..];
        if (std.mem.eql(u8, k, key)) return v;
    }
    return null;
}

fn parseLimitQuery(target: []const u8, default_value: usize) usize {
    const raw = queryValue(target, "limit") orelse return default_value;
    return std.fmt.parseInt(usize, raw, 10) catch default_value;
}

fn pathNoQuery(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..q];
}
```

---

## 9. 测试模式

### 9.1 内联测试

```zig
test "review gate approves when both approve and score >= 3" {
    try std.testing.expect(!shouldRequestChanges(.approve, .approve, 3, "[]", "[]"));
    try std.testing.expect(!shouldRequestChanges(.approve, .approve, 5, "[]", "[]"));
}

test "parseReviewJsonMeta parses valid object" {
    const allocator = std.testing.allocator;
    var meta = try parseReviewJsonMeta(
        allocator,
        "{\"blockers\":[],\"suggestions\":[\"a\"],\"confidence\":0.75}",
    );
    defer meta.deinit(allocator);

    try std.testing.expectEqualStrings("[]", meta.blockers_json);
    try std.testing.expectEqualStrings("[\"a\"]", meta.suggestions_json);
    try std.testing.expectApproxEqRel(@as(f64, 0.75), meta.confidence.?, 1e-9);
}
```

### 9.2 E2E 测试设置

```zig
const PoolE2ESetup = struct {
    cfg: config.Config,
    store: sqlite_task_store.SqliteTaskStore,
    work_dir: []u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *PoolE2ESetup) void {
        self.store.deinit();
        config.deinitConfig(self.allocator, &self.cfg);
        std.fs.cwd().deleteTree(self.work_dir) catch {};
        self.allocator.free(self.work_dir);
    }
};

test "pool e2e: approve -> merge -> done" {
    const allocator = std.testing.allocator;
    var setup = try setupPoolE2E(allocator);
    defer setup.deinit();

    var mock = MockPoolProvider{ .scenario = .approve_and_merge };
    const outcome = try runSingleTaskForScenario(allocator, setup.cfg, setup.store.asTaskStore(), &mock);
    try std.testing.expectEqual(TaskOutcome.done, outcome);
}
```

---

## 10. 关键总结

### 命名约定
- **结构体**: PascalCase (`TaskStore`, `SqliteTaskStore`)
- **函数**: camelCase (`claimNext`, `markRunning`)
- **类型/枚举**: PascalCase (`TaskStatus`, `EventSource`)
- **常量**: SCREAMING_SNAKE_CASE (`SQLITE_OK`, `TOKEN_TTL_SECONDS`)
- **私有函数**: 使用下划线前缀或直接小写 (`fn close(ctx: ...)`)

### 代码组织
- 每个领域一个文件 (`task_store.zig`, `session_service.zig`)
- 接口与实现分离 (`task_store.zig` 定义接口, `sqlite_task_store.zig` 实现)
- 存储层独立,服务层组合存储

### 错误处理原则
1. 尽可能使用 `try` 传播错误
2. 为领域定义具体错误类型
3. 使用 `errdefer` 确保错误路径清理资源
4. 在 API 边界使用 switch 处理特定错误,转换为 HTTP 状态码

### 内存管理原则
1. 每个动态分配内存的结构体必须有 `deinit` 方法
2. 分配后立即 `defer` 释放
3. 使用 `errdefer` 处理错误路径
4. 资源转移所有权时,接收方负责释放

### 并发安全
1. 存储层使用 Mutex 保护共享状态
2. 全局单例使用双重检查锁定模式
3. 尽量减小临界区范围

### JSON 处理原则
1. 序列化使用 `std.json.fmt()` 自动处理转义
2. 反序列化到结构体用于已知 schema
3. 反序列化到 `std.json.Value` 用于动态/未知 schema
4. 始终使用 `defer parsed.deinit()` 释放解析资源

---

**文档版本**: 1.0  
**目标 Zig 版本**: 0.15+  
**适用范围**: Techlead 项目及类似 Zig 代码库
