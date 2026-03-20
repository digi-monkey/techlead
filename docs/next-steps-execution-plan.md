# 下一步执行计划（V1）

更新时间：2026-03-20

## 目标

在现有统一架构基础上，完成以下 5 项关键推进，并按优先级落地：

1. `codex` provider 最小可用版
2. observe API 协议稳定化（增量事件 + 标准控制接口）
3. pool 并发 worker + lease + retry
4. 最小前端观察页（手机/PC 同入口）
5. 运行稳定性硬化（token 生命周期、审计字段、e2e）

## 任务分解

### 1. `codex` provider 最小可用版（进行中）

交付项：

- `src/providers/codex_cli_provider.zig` 从占位改为真实执行
- 使用 `codex exec --cd <work_dir> --json` 执行单轮任务
- 支持 `model` 透传（若配置非空则附加 `--model`）
- 复用现有 prompt 模板（含运行中 `inject_prompt`）
- 输出流写入 `.techlead/iteration-logs/iteration-N.log`
- 返回成功/失败状态给统一调度层

验收：

- `provider = "codex"` 时可进入真实执行路径
- 失败可回传且不崩溃
- `zig build test` 与 smoke 通过

### 2. observe API 协议稳定化

交付项：

- `GET /events?after=<event_id>` 增量拉取
- `POST /runs/:id/control` 标准化请求体
- 保留旧路径但标记为兼容层

验收：

- 观察端可无全量重拉刷新
- 控制接口参数统一且可审计

### 3. pool 并发 worker + lease + retry

交付项：

- 任务字段增加 `lease_owner` `lease_until` `retry_count`
- worker 认领与续约
- 超时回收、失败重试

验收：

- 2+ worker 并发下不重复消费同一任务
- 崩溃后任务可回收继续执行

### 4. 最小前端观察页

交付项：

- 任务列表 + 事件流 + 控制按钮
- 扫码后手机浏览器可直接查看

验收：

- 手机/PC 都能看到同一实时状态
- 可从页面发 `pause/resume/abort/inject`

### 5. 稳定性硬化

交付项：

- token 轮换与过期
- 控制命令审计字段：操作者、来源、时间、请求 ID
- e2e 脚本覆盖核心链路

验收：

- 长时间运行无明显状态漂移
- 控制动作可追溯

## 当前执行状态

- 已开始执行任务 1（`codex` provider 最小可用版）。

