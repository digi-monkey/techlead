# 多项目计划问题清单（Review）

更新时间：2026-03-25（UTC）

## 1. 范围

本清单聚焦“多项目 Pool（单端口监控）”相关实现与计划偏差，主要对照：

1. `docs/multiproject-pool-breaking-implementation-playbook.md`
2. `docs/task-management-remote-plan.md`
3. `docs/next-steps-execution-plan.md`

## 2. 结论摘要

当前多项目链路仍处于“骨架 + 占位”状态，存在多项阻断级问题，未达到计划中的可验收闭环。

严重级别汇总：

1. 阻断（P0）：5 项
2. 高（P1）：5 项
3. 中（P2）：2 项

## 3. 详细问题

### MP-01（P0）ControlPlane 任务核心接口仍是占位实现

计划要求：多项目 API 能创建/列表/详情/动作/事件完整闭环。  
现状证据：

1. `listTasksByProject` 固定返回空（`src/storage/sqlite_controlplane_store.zig:412`）
2. `getTaskDetail` 固定返回 `{"task":null...}`（`src/storage/sqlite_controlplane_store.zig:420`）
3. `getTaskEvents` 固定空事件（`src/storage/sqlite_controlplane_store.zig:523`）
4. `applyAction` no-op（`src/storage/sqlite_controlplane_store.zig:533`）
5. 多个状态迁移函数仅 `_ = ...`（`src/storage/sqlite_controlplane_store.zig:429-513`）

影响：`/projects/:id/tasks*` 基本不可用，无法支撑 Task Pool 实际管理。

---

### MP-02（P0）执行面与观察面使用两套不同任务库，数据断裂

计划要求：单端口监控多个项目，状态与事件应一致可观测。  
现状证据：

1. pool 执行仍直接使用项目目录下 `SqliteTaskStore`（`src/app/pool_service.zig:93`）
2. observe API 使用全局 `SqliteControlPlaneStore`（`src/observe.zig:205`）

影响：UI 看到的任务与实际执行任务不是同一份数据，形成“写 A 读 B”。

---

### MP-03（P0）多项目调度 claim 路径不可用

计划要求：全局调度器能跨项目 claim 并保证公平。  
现状证据：

1. `claimNext` 直接 `return null`（`src/storage/sqlite_controlplane_store.zig:403-410`）
2. `SchedulerService.claimNextTask` 依赖该接口（`src/app/scheduler_service.zig:89`）

影响：调度器无法真正认领任务，后续流程无法启动。

---

### MP-04（P0）MultiPool 执行逻辑仍是模拟流程

计划要求：真实执行“认领 -> running -> 实现/review/merge -> done/failed”。  
现状证据：

1. `processTask` 明确是“simulate work + placeholder”（`src/app/multi_pool_service.zig:349-365`）
2. 未调用实际 pool 实现链路，仅 sleep 后统计 +1（`src/app/multi_pool_service.zig:361-368`）

影响：多项目 worker 运行不产生真实任务状态迁移和代码结果。

---

### MP-05（P0）多项目 e2e 脚本仍是 TODO/跳过型脚本

计划要求：脚本可复跑并给出真实通过证据。  
现状证据：

1. `scripts/e2e-multiproject-smoke.sh` 大量 `TODO`/`SKIPPED`（如 `:81`, `:185`）
2. `scripts/e2e-multiproject-review-loop.sh` 同样依赖“API not yet implemented”分支（如 `:68`, `:239`）

影响：无法完成“阶段验收必须通过”的执行纪律，也不能产出真实证据。

---

### MP-06（P1）`PATCH /tasks/:id` 返回成功但没有实际更新

计划要求：支持编辑任务，且版本冲突可感知。  
现状证据：

1. handler 明确注明未接入 store patch
2. 直接返回 `{"ok":true}`（`src/observe.zig:1115-1121`）

影响：前端会误判成功，数据一致性被破坏，冲突保护失效。

---

### MP-07（P1）run 状态收敛未实现，可能长期卡 `running`

计划要求：run 可追踪、可结束、可查询当前真实状态。  
现状证据：

1. `createRun` 会写入 run（`src/observe.zig:800`）
2. `updateRunStatus` 仍是 no-op（`src/storage/sqlite_controlplane_store.zig:568`）

影响：`run_already_active` 判定可能长期为真，阻塞新 run。

---

### MP-08（P1）Breaking 计划要求移除旧接口，但代码保留 legacy 路由

计划要求：不保留旧单项目 API。  
现状证据：

1. `serveRequest` 中保留整段 “Legacy API (Backward Compatibility)” 路径（`src/observe.zig:467-545`）

影响：语义边界混乱，测试口径分叉，容易出现“新旧接口行为不一致”。

---

### MP-09（P1）`/events?project_id` 设计未按计划实现

计划要求：`GET /events?project_id=<id>&after=<n>` 支持全局/按项目过滤。  
现状证据：

1. 当前 `/events` 路由依赖 `default_project_id` 兜底（`src/observe.zig:470-475`）
2. 未实现通用 `project_id` 查询参数分流逻辑

影响：当无 default project 或多项目并存时，事件查询语义不符合计划。

---

### MP-10（P1）Token 生命周期硬化未完成（重启即变）

计划要求：token 生命周期可控、轮换可管理。  
现状证据：

1. `ensureTokensInternal` 注释写明“每次启动都新生成，store 不持久化”（`src/observe.zig:1818-1820`）

影响：服务重启后凭据失效，和“稳定性硬化”目标冲突。

---

### MP-11（P2）`/projects/:id/runs/start` 默认 mode 为 `optimize`

计划期望：多项目执行主路径是 pool。  
现状证据：

1. `handleRunStart` 默认 `mode = "optimize"`（`src/observe.zig:752`）

影响：未显式传参时容易误入 optimize 流程，与多项目 pool 心智不一致。

---

### MP-12（P2）多项目新增模块缺少有效测试覆盖

现状证据：

1. `scheduler_service` 仅占位测试（`src/app/scheduler_service.zig:427`）
2. `multi_pool_service` 仅占位测试（`src/app/multi_pool_service.zig:387`）

影响：关键调度与并发路径缺少回归护栏。

## 4. 建议修复顺序（最小可落地）

1. 先补齐 `sqlite_controlplane_store` 的任务读写/状态迁移/事件/action/claim 实现（MP-01, MP-03）。
2. 打通执行面到 controlplane 同一数据源（MP-02），确保 observe 与 run 看同一状态。
3. 接入真实 multi-pool 执行链路并替换模拟逻辑（MP-04）。
4. 修复 API 行为一致性：`PATCH /tasks/:id`、`/events?project_id`、run 状态更新（MP-06, MP-07, MP-09）。
5. 清理 breaking 冲突项与默认模式偏差（MP-08, MP-11）。
6. 补齐可通过的 e2e 与模块测试（MP-05, MP-12）。

