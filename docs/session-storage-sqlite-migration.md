# Session 存储迁移方案：JSON → SQLite

## 背景

当前 session 使用单文件 JSON 存储（`.techlead/session_state.json`），随着消息量增加，存在以下问题：

1. **全文件读写开销**：每次消息操作需读取整个文件 → 解析 → 修改 → 序列化 → 写入
2. **并发问题**：多进程/线程同时写入可能冲突
3. **扩展性**：不支持多 session 历史查询、分页加载等高级功能

## 目标

将 session 存储从 JSON 文件迁移到 SQLite，支持：
- 增量读写（只操作新增消息）
- 事务安全
- 未来支持多 session 管理和历史查询

## Schema 设计

```sql
-- sessions 表：存储会话元数据
CREATE TABLE sessions (
    session_id TEXT PRIMARY KEY,
    status TEXT NOT NULL,              -- active/processing/ended/error
    provider TEXT NOT NULL,            -- codex/opencode
    model TEXT NOT NULL,
    provider_session_id TEXT,          -- 供应商侧的 session ID
    in_flight_request_id TEXT,         -- 当前处理中的请求
    last_error TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

-- session_messages 表：存储消息内容
CREATE TABLE session_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL,                -- user/assistant/system
    content TEXT NOT NULL,
    ts INTEGER NOT NULL,
    request_id TEXT,                   -- 关联请求 ID（用于去重）
    FOREIGN KEY (session_id) REFERENCES sessions(session_id)
);

-- 索引
CREATE INDEX idx_messages_session_ts ON session_messages(session_id, ts DESC);
CREATE INDEX idx_messages_request_id ON session_messages(request_id);
```

## 架构对比

### 当前 JSON 模式
```
session_state.json (8MB+)
├── session_id
├── status
├── provider
├── model
├── messages: [              // 每次都要全量读写
│   {id, role, content, ts, request_id},
│   ... (1000+ messages)
]
└── ...
```

### SQLite 模式
```
session.sqlite3
├── sessions 表              // 元数据行，极小
└── session_messages 表      // 消息单独存储，按需查询
    ├── INSERT 单条消息     // O(1)
    ├── SELECT 最近 N 条     // O(log n)
    └── 支持分页、搜索
```

## 性能预估

| 场景 | JSON | SQLite | 提升 |
|-----|------|--------|------|
| 发送消息（100条历史） | 读取 100KB + 写入 105KB | INSERT 1 行 | 100x+ |
| 加载最近 20 条 | 解析 100KB JSON | SELECT 20 行 | 50x+ |
| 并发操作 | 文件锁冲突 | WAL 模式无冲突 | 可靠 |

## 实现步骤

### Phase 1: 基础存储层
1. 创建 `src/storage/sqlite_session_store.zig`
   - 参考 `sqlite_task_store.zig` 结构
   - 实现 `init/deinit` 和 schema 迁移
   - 实现基础 CRUD 操作

2. API 设计：
```zig
pub const SqliteSessionStore = struct {
    pub fn init(allocator: Allocator, work_dir: []const u8) !SqliteSessionStore;
    pub fn deinit(self: *SqliteSessionStore) void;
    
    // Session 操作
    pub fn createSession(self: *SqliteSessionStore, provider: []const u8, model: []const u8) ![]const u8;
    pub fn getSession(self: *SqliteSessionStore, session_id: []const u8) !?Session;
    pub fn updateSessionStatus(self: *SqliteSessionStore, session_id: []const u8, status: []const u8) !void;
    pub fn endSession(self: *SqliteSessionStore, session_id: []const u8) !void;
    
    // Message 操作
    pub fn addMessage(self: *SqliteSessionStore, session_id: []const u8, role: []const u8, content: []const u8, request_id: ?[]const u8) !u64;
    pub fn getMessages(self: *SqliteSessionStore, session_id: []const u8, limit: usize) ![]Message;
    pub fn findMessageByRequestId(self: *SqliteSessionStore, session_id: []const u8, request_id: []const u8) !?Message;
};
```

### Phase 2: 业务层适配
修改 `src/app/session_service.zig`：
- 替换 `loadSession/saveSession` 为 SQLite API
- 保持对外接口不变（向后兼容）
- 添加数据迁移逻辑（首次启动时 JSON → SQLite）

### Phase 3: 数据迁移
```zig
fn migrateFromJsonIfNeeded(allocator: Allocator, work_dir: []const u8, store: *SqliteSessionStore) !void {
    const legacy_path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, ".techlead/session_state.json" });
    defer allocator.free(legacy_path);
    
    // 检查是否存在旧文件
    std.fs.cwd().access(legacy_path, .{}) catch return; // 不存在，无需迁移
    
    // 读取 JSON
    // 写入 SQLite
    // 重命名旧文件为 session_state.json.bak
}
```

### Phase 4: 多 session 支持（可选）
- 添加 `listSessions()` 接口
- 支持分页查询历史 session
- API 改为 `/sessions/:id/*` 格式

## 工作量评估

| 任务 | 预估代码量 | 时间 |
|-----|-----------|------|
| sqlite_session_store.zig 实现 | ~400 行 | 2-3 小时 |
| session_service.zig 适配 | ~200 行修改 | 1-2 小时 |
| 数据迁移逻辑 | ~100 行 | 1 小时 |
| 测试验证 | - | 1-2 小时 |
| **总计** | ~700 行 | **1 天** |

## 风险与缓解

1. **数据迁移失败**
   - 缓解：保留旧 JSON 文件备份，可回滚
   
2. **SQLite 依赖问题**
   - 缓解：参考 task_store，已有 sqlite3 动态加载方案

3. **性能不如预期**
   - 缓解：WAL 模式 + 适当索引，性能应优于 JSON

## 决策建议

**推荐迁移时机**：
- ✅ 当前平均 session 消息数 > 500
- ✅ 有多个 session 并发需求
- ✅ 需要 session 历史查询功能
- ⏸️ 当前消息数 < 100，可暂缓

**暂不迁移理由**：
- JSON 实现简单，调试方便
- 单文件便于备份和查看
- 当前性能瓶颈更可能在前端轮询而非后端存储

## 相关文件

- `src/app/session_service.zig` - 当前 JSON 实现
- `src/storage/sqlite_task_store.zig` - SQLite 参考实现
- `.techlead/session_state.json` - 当前数据文件
