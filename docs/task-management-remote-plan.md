# Pool 任务管理与远程前端化计划（V2）

更新时间：2026-03-20

## 1. 目标

让用户可以通过前端稳定地远程管理任务（创建、编辑、重试、取消、查看执行状态），并确保 `pool` 模式具备正确并发语义、审计能力和可维护性。

## 2. 现状与问题

当前实现：

- 任务状态落在单文件 `.techlead/tasks.json`。
- `runPoolMode` 启动时一次性读入任务，循环结束再整体写回。
- observe 仅有 `GET /tasks`（只读快照），前端只能展示。

问题：

1. 并发一致性风险高
- 运行中外部修改会被最终写回覆盖。
- 无任务级事务与并发控制。

2. 可维护性不足
- 文件既是状态源又是交换接口，边界不清晰。
- 缺少结构化审计。

3. 扩展性不足
- 难做分页/筛选/统计/历史回放。
- 不适合后续多 worker claim/lease。

结论：`tasks.json` 直接废弃，任务主存储切换到 SQLite。

## 3. 架构决策

## 3.1 存储层

新增 `TaskStore` 抽象（参照现有 `EventStore`）：

- `create/list/get/update/claim/complete/fail/requeue/cancel/appendTaskEvent`

实现：

- 仅实现 `SqliteTaskStore`（主路径、唯一支持路径）

明确约束：

- 不保留 `JsonTaskStore`
- 不保留 `tasks.json` 导入/导出兼容逻辑
- 启动阶段若发现旧 `tasks.json`，直接报错并提示迁移脚本（一次性离线迁移）

## 3.2 数据模型（SQLite）

`tasks`：

- `task_id TEXT PRIMARY KEY`
- `title TEXT NOT NULL`
- `prompt TEXT NULL`
- `status TEXT NOT NULL` (`queued|claimed|running|review|done|failed|canceled`)
- `lease_owner TEXT NULL`
- `lease_until INTEGER NULL`
- `retry_count INTEGER NOT NULL DEFAULT 0`
- `max_retries INTEGER NULL`
- `priority INTEGER NOT NULL DEFAULT 0`
- `last_error TEXT NULL`
- `version INTEGER NOT NULL DEFAULT 1`
- `created_at INTEGER NOT NULL`
- `updated_at INTEGER NOT NULL`

`task_events`：

- `id INTEGER PRIMARY KEY AUTOINCREMENT`
- `task_id TEXT NOT NULL`
- `run_id TEXT NULL`
- `event_type TEXT NOT NULL`
- `payload TEXT NOT NULL`
- `operator TEXT NULL`
- `source TEXT NULL`
- `request_id TEXT NULL`
- `created_at INTEGER NOT NULL`

## 3.3 调度语义（pool）

从“全量读写文件”改为“状态变更即事务落库”：

1. claim：原子条件更新，只 claim 可领取任务
2. running：状态更新并续租
3. done/failed/requeued：立即持久化并写 `task_events`
4. lease 过期回收：通过 claim 查询条件处理

## 4. API 设计（前端远程管理）

鉴权：

- 读接口：`observe token`
- 写接口：`control token`

API：

1. `GET /tasks`
- 参数：`status` `limit` `cursor` `q`
- 返回：分页列表 + 状态汇总

2. `GET /tasks/:id`
- 返回详情 + 最近事件

3. `POST /tasks`
- 创建任务（title/prompt/priority/max_retries）

4. `PATCH /tasks/:id`
- 更新任务（title/prompt/priority/max_retries）
- 必须携带 `version`

5. `POST /tasks/:id/actions`
- `action`: `requeue|cancel|resume|force_fail`

6. `GET /tasks/events?after=<id>`
- 前端增量刷新任务状态变化

## 5. 前端任务管理

在现有 React observe-ui 增加任务管理区：

1. 列表视图
- 按状态分组（queued/running/failed/done）
- 支持筛选和搜索

2. 详情面板
- 展示 prompt/retry/lease/最近事件
- 支持行级操作（requeue/cancel/edit）

3. 创建与编辑
- 表单走 `POST/PATCH`
- 带 `version` 做冲突保护

4. 实时刷新
- 先轮询，后续可切 `tasks/events` 增量流

## 6. 实施计划

## 阶段 A：TaskStore 抽象 + SQLite 实现（2-3 天）

- 新增 `src/storage/task_store.zig`
- 新增 `src/storage/sqlite_task_store.zig`
- `run_service` 改为使用 `TaskStore`
- 发现旧 `tasks.json` 时直接报错并中止

验收：pool 任务调度不再读写 `tasks.json`。

## 阶段 B：任务管理 API（1-2 天）

- 增加 `/tasks` 写接口与动作接口
- 幂等（`request_id`）和审计字段贯通

验收：API 可完成任务全生命周期管理。

## 阶段 C：前端任务管理 UI（2-3 天）

- 增加任务列表/详情/创建/编辑/动作
- 冲突提示与失败提示

验收：用户可远程完整管理任务。

## 阶段 D：硬化与回归（1-2 天）

- 并发冲突测试
- lease/retry 边界测试
- e2e：创建任务 -> pool 执行 -> 失败重试 -> requeue -> 完成

## 7. 回退与风险

策略：

- 不回退到 `tasks.json`
- 出现异常时仅允许“停机修复 SQLite 或恢复备份”

风险与应对：

1. SQLite 动态库不可用
- 启动前做显式健康检查；不可用即失败退出，不进入 run。

2. 迁移期间旧文件残留
- 提供一次性迁移脚本；启动时检测到旧文件直接报错，避免双写。

3. 前端误操作
- 所有写操作记录 `operator/source/request_id`；支持审计追踪。

## 8. Done 标准

1. 前端可创建/编辑/重试/取消任务。
2. pool 运行中不再出现文件覆盖问题。
3. 所有任务写操作可审计。
4. 至少一条远程 e2e 全链路通过。
