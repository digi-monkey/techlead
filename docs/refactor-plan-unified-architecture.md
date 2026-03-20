# techlead 统一架构重构执行计划（可落地版）

更新时间：2026-03-20

## 1. 背景与目标

当前项目已具备：

- `init / run / server start|stop / init-agent` CLI 基础能力
- 面向 `opencode/oh-my-opencode` 的单轮执行能力
- 迭代日志能力（按轮落盘）

当前缺口：

- 执行模型偏“单线程找最优解”，不适配“任务认领池”
- agent 平台耦合度高，扩展到 codex/claude CLI 成本高
- tracing 不是统一事件模型，复现与审计能力有限
- 远程观察与控制能力缺失

本次重构目标：

1. 建立统一内核，支持两种调度模式（`optimize` / `pool`）
2. 将 agent 调用抽象为可插拔 Provider（先 opencode，后 codex/claude）
3. 建立可回放 tracing 与控制平面（Web/本机同构入口）
4. 在不大爆炸重写的前提下，分阶段演进并保持可回滚

非目标（本轮不做）：

- 不做多节点分布式调度
- 不做复杂 RBAC（先 token + scope）
- 不做跨仓库统一任务编排

## 2. 目标架构（统一模型）

```text
CLI / Web(Control)
        |
        v
  Application Service
  (RunService / TaskService / ControlService)
        |
        v
     Core Domain
 (Run, Task, Worker, Event, Checkpoint, Scheduler)
        |
        +--------------------+
        |                    |
        v                    v
  Agent Provider API    State Store API
 (opencode/codex/...)  (sqlite/jsonl)
        |
        v
 Runtime Process Adapter
 (spawn, stream, interrupt, inject, resume)
```

关键原则：

- 核心域（状态机、调度）不依赖具体 agent CLI
- 观察与权限是独立模块，不和调度模式耦合
- 所有控制动作都写入统一 tracing 事件流

## 3. 目录重构方案

建议在 `src/` 下按边界拆分：

- `src/core/`
  - `domain.zig`：实体与状态定义
  - `scheduler.zig`：调度策略接口与实现注册
  - `state_machine.zig`：状态转换与校验
- `src/providers/`
  - `provider.zig`：Provider 抽象接口与事件标准
  - `opencode_provider.zig`
  - `codex_cli_provider.zig`（占位）
  - `claude_cli_provider.zig`（占位）
- `src/runtime/`
  - `process_runner.zig`：子进程生命周期、stdout/stderr 流
  - `control_channel.zig`：中断/注入控制
- `src/storage/`
  - `store.zig`：存储接口
  - `sqlite_store.zig`：SQLite 实现（首选）
  - `jsonl_store.zig`：降级实现（可选）
- `src/observe/`
  - `api.zig`：HTTP API（run/task/event 查询与控制）
  - `auth.zig`：token/qr 授权
- `src/app/`
  - `run_service.zig`
  - `task_service.zig`
  - `control_service.zig`

迁移策略：

- 保留现有 `src/main.zig` 命令入口
- 逐步把 `runner.zig`/`opencode.zig` 内逻辑下沉到 `app + core + providers`

## 4. 统一数据与事件模型

## 4.1 核心实体

- `Run`
  - `run_id`, `mode(optimize|pool)`, `status`, `created_at`, `updated_at`
- `Task`
  - `task_id`, `run_id`, `status`, `priority`, `lease_owner`, `lease_until`
- `Worker`
  - `worker_id`, `provider`, `status`, `last_heartbeat`
- `Checkpoint`
  - `checkpoint_id`, `run_id/task_id`, `provider_state`, `git_ref`, `created_at`

## 4.2 统一事件（Tracing）

事件字段最小集合：

- `event_id`（单调递增）
- `run_id` / `task_id`（可空）
- `source`（scheduler/provider/runtime/control/user）
- `type`（state_changed/tool_called/stdout/stderr/decision/control）
- `ts`
- `payload_json`
- `digest`（可选，便于审计）

事件落盘：

- 第一优先：SQLite `events` 表
- 同步写入 `*.jsonl`（可选）用于快速 tail/迁移

## 5. Provider 抽象接口

`providers/provider.zig` 定义统一契约（示意）：

1. `start(spec) -> handle`
2. `poll(handle) -> []ProviderEvent`（非阻塞批量）
3. `interrupt(handle, mode: graceful|force)`
4. `inject(handle, prompt_patch)`
5. `snapshot(handle) -> ProviderState`
6. `resume(spec, state) -> handle`
7. `close(handle)`

ProviderEvent 标准化：

- `provider.lifecycle.started|exited`
- `provider.message.delta`
- `provider.tool.call`
- `provider.decision`
- `provider.error`

适配策略：

- `opencode_provider`：先完整实现（当前默认）
- `codex_cli_provider`：先实现 `start/poll/interrupt/close` 最小子集
- `claude_cli_provider`：结构占位 + 单测桩

## 6. 调度模式设计

## 6.1 `optimize`（兼容现有）

- 继续迭代 N 轮语义
- 用统一事件替代“仅文本日志”
- 分支决策仍可沿用 `KEEP/DISCARD/EXPERIMENT_CREATED`

## 6.2 `pool`（新增）

- 任务状态机：`queued -> claimed -> running -> review -> done|failed`
- lease 机制防止 worker 崩溃导致任务永久占有
- 支持并发 worker 拉取任务

两模式共用：

- Provider 层
- Store 层
- Observe/Control 层

## 7. 控制平面（Web/本机/QR）

最小 API：

1. `GET /runs` / `GET /runs/:id`
2. `GET /runs/:id/events?after=<event_id>`
3. `POST /runs/:id/control`（`pause|abort|resume|inject_prompt`）
4. `GET /tasks` / `POST /tasks`（pool 模式）
5. `POST /auth/qr/bootstrap`（生成一次性二维码 token）
6. `POST /auth/token/exchange`（扫码换长期 token）

安全策略（MVP）：

- 本机默认 `127.0.0.1`
- 远程访问需显式开启
- token 分 scope：`observe` / `control`
- 所有控制动作写入 `control` 事件并记录操作者

## 8. 分阶段执行计划（每阶段可独立上线）

## 阶段 0：基线冻结与回归护栏（1-2 天）

目标：

- 冻结现状行为，避免重构误伤

任务：

1. 补齐 characterization 测试骨架为可执行测试
2. 增加 smoke 脚本：`init -> run(1 iter) -> assert log`
3. 文档化当前 CLI 行为与错误语义

交付标准：

- CI 可执行最小回归测试
- 当前主流程行为可被脚本化验证

## 阶段 1：抽离 Provider 接口（2-4 天）

目标：

- 从 `opencode.zig` 分离“抽象契约”与“opencode 实现”

任务：

1. 新增 `src/providers/provider.zig` 接口定义
2. 迁移现有调用逻辑到 `opencode_provider.zig`
3. `runner.zig` 改为依赖 Provider 接口

交付标准：

- 功能对齐当前 `run` 行为
- 不改 CLI 参数时输出结果一致

## 阶段 2：引入统一 Event Store（3-5 天）

目标：

- 将文本日志升级为结构化 tracing

任务：

1. 新增 `storage/store.zig` 与 `sqlite_store.zig`
2. 在 run 生命周期关键节点发事件
3. 保留现有 `iteration-N.log` 作为兼容输出

交付标准：

- 任意一次 run 可按 `event_id` 回放主流程
- 失败路径有结构化错误事件

## 阶段 3：重构调度器并支持 `pool`（4-7 天）

目标：

- 在统一内核上增加任务池模式

任务：

1. 抽离 `scheduler` 接口
2. 保留 `optimize_scheduler`
3. 新增 `pool_scheduler`（任务 claim/lease/retry）
4. CLI 增加 `run --mode optimize|pool`（默认 optimize）

交付标准：

- optimize 兼容旧行为
- pool 可执行至少 2 个并发 worker 的任务领取与完成

## 阶段 4：控制与观察 API（4-6 天）

目标：

- 提供本机/远程统一观察入口与控制入口

任务：

1. 新增 observe HTTP server（独立端口）
2. 实现 runs/events 查询与控制命令
3. 实现二维码 bootstrap 与 token 交换

交付标准：

- 手机浏览器扫码授权后可查看进度
- `pause/abort/inject_prompt/resume` 可审计可复现

## 阶段 5：多 Provider 扩展（3-6 天）

目标：

- 准备 codex/claude CLI 适配能力

任务：

1. 添加 `codex_cli_provider` 最小实现
2. 添加 `claude_cli_provider` 占位实现与 mock
3. provider 兼容性测试（同一用例跑多 provider）

交付标准：

- 能通过配置切换 provider
- 至少 opencode + codex 两种 provider 跑通 smoke

## 9. 代码质量与可维护性策略

硬约束：

1. 单向依赖：`core` 不得 import `providers/runtime/observe`
2. 统一错误分层：`DomainError / ProviderError / InfraError`
3. 不允许跨层直接拼接命令参数（集中在 provider 实现）
4. 所有状态转换必须经过 `state_machine` 验证

测试策略：

1. Core 状态机单测（高覆盖）
2. Provider 契约测试（统一测试套件）
3. 回放测试（event stream -> deterministic state）
4. E2E smoke（optimize/pool 各 1 条）

文档策略：

1. 新增 ADR：
  - Provider 抽象
  - Event schema
  - Scheduler 分层
2. 每阶段更新迁移说明和回滚方案

## 10. 迁移与回滚策略

迁移原则：

- 渐进式替换，不在单次 PR 内同时做“抽象 + 功能新增 + UI”
- 每阶段可通过 feature flag 开关：
  - `TECHLEAD_NEW_PROVIDER=1`
  - `TECHLEAD_EVENT_STORE=1`
  - `TECHLEAD_MODE_POOL=1`
  - `TECHLEAD_OBSERVE_API=1`

回滚策略：

- 任一阶段若不稳定，关闭对应 flag 退回旧链路
- 保留 `runner + opencode` 旧实现直到阶段 4 稳定

## 11. 近期执行顺序（建议）

第 1 周：

1. 阶段 0 完成
2. 阶段 1 完成并上线

第 2 周：

1. 阶段 2 完成（结构化 tracing）
2. 阶段 3 启动（先 optimize scheduler 迁移）

第 3 周：

1. 阶段 3 完成（pool MVP）
2. 阶段 4 启动（observe API + token）

第 4 周：

1. 阶段 4 完成
2. 阶段 5 启动（codex provider）

## 12. 第一批具体改动清单（可立即开始）

1. 新增文件骨架：
   - `src/providers/provider.zig`
   - `src/providers/opencode_provider.zig`
   - `src/storage/store.zig`
   - `src/core/domain.zig`
2. 在 `runner.zig` 引入 Provider 接口（保持默认 opencode）
3. 增加 run 生命周期事件（至少 8 类事件）
4. 增加 `run --mode optimize|pool` 参数解析（pool 暂先报未启用）
5. 新增 `docs/adr/0001-provider-abstraction.md`（下一步）

完成第一批后验收：

- 原 `run` 用例可跑通
- 事件可落盘并查询
- CLI 向后兼容

