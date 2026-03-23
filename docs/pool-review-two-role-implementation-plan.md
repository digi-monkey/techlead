# Pool 模式独立流程 + 双角色 Review 落地方案（实现交接版）

更新时间：2026-03-23

## 0. 文档定位（给实现 AI 的要求）

这份文档是“按步骤施工”的实现说明，不是讨论稿。

执行要求：

1. 严格按本文“实施顺序”执行，不要跳步。
2. 不做兼容层，不保留旧 pool 语义（本模式此前未启用）。
3. `pool` 与 `optimize` 彻底解耦：`pool` 禁止依赖 `program.md` / `preparePrompt`。
4. 任何不确定行为都要显式报错，不允许静默 fallback。
5. 每完成一个阶段都必须跑对应验收命令。

---

## 1. 目标与非目标

## 1.1 目标

实现一个独立的 `pool` 执行流水线：

1. 任务实现（Implementation）
2. 双角色 AI Review：
- `correctness_reviewer`（功能正确性、回归风险）
- `maintainability_reviewer`（Clean Code、可维护性）
3. 基于 review 结果自动决定：
- 进入 `done`（通过并本地 merge）
- 或回到 `queued`（要求修改）
- 或 `failed`

## 1.2 非目标

1. 不做 GitHub/GitLab 远程 PR。
2. 不做多种 review 角色扩展（先只做两个角色）。
3. 不做老 schema 兼容迁移（可直接 destructive 升级）。
4. 本期不做并发 worker/worktree（并发方案放入下一里程碑 M2）。

---

## 2. 总体架构（必须独立于 optimize）

新架构约束：

1. `optimize` 继续使用当前 `runIteration + program.md`。
2. `pool` 使用新服务 `pool_service`，自行构建 prompt，不走 `opencode.preparePrompt`。
3. `provider` 增加“执行原始 prompt”的能力，供 pool 的 implement/review 复用。

建议调用链：

`run_service.executeWithProvider(mode=pool)` -> `pool_service.run(...)` -> `provider.runPrompt(...)`

---

## 3. 任务状态机设计

## 3.1 主状态（沿用）

`queued -> claimed -> running -> review -> done|failed|canceled`

## 3.2 review 子状态（新增字段）

`review_stage`：

- `none`：未进入 review
- `open`：已进入 review，等待两个 reviewer 结果
- `changes_requested`：至少一个 reviewer 未通过
- `approved`：两个 reviewer 均通过
- `merged`：已完成本地 merge

## 3.3 状态迁移规则（强约束）

1. `running -> review(open)`：实现阶段成功后。
2. `review(open) -> review(changes_requested)`：任一 reviewer `verdict != approve`。
3. `review(open) -> review(approved)`：两个 reviewer 都 `approve` 且 maintainability score >= 3。
4. `review(changes_requested) -> queued`：自动回队列并附带 review 反馈。
5. `review(approved) -> done + review(merged)`：merge 成功。
6. 任意阶段异常可进入 `failed`（按重试策略回队列或最终失败）。

---

## 4. 双角色 Review 协议

## 4.1 Correctness Reviewer

关注点：

1. 是否满足 task 要求。
2. 是否有明显 bug / 回归风险。
3. 关键边界是否有验证（测试或可复现证据）。

输出 JSON（强制格式）：

```json
{
  "role": "correctness_reviewer",
  "verdict": "approve|request_changes|block",
  "summary": "...",
  "blockers": [
    {
      "title": "...",
      "detail": "...",
      "severity": "high|medium|low",
      "file": "path",
      "line": 123,
      "evidence": "command/output or reasoning"
    }
  ],
  "suggestions": ["..."],
  "confidence": 0.0
}
```

## 4.2 Maintainability Reviewer

关注点：

1. Clean Code（命名、函数职责、重复、复杂度、可读性）。
2. 可维护性（模块边界、扩展成本、技术债）。

输出 JSON（强制格式）：

```json
{
  "role": "maintainability_reviewer",
  "verdict": "approve|request_changes|block",
  "score": 1,
  "summary": "...",
  "blockers": [
    {
      "title": "...",
      "detail": "...",
      "severity": "high|medium|low",
      "file": "path",
      "line": 123,
      "clean_code_rule": "..."
    }
  ],
  "suggestions": ["..."],
  "confidence": 0.0
}
```

## 4.3 审核门禁（必须实现）

1. 若任一 reviewer `verdict in [request_changes, block]` -> `changes_requested`。
2. 若 maintainability `score < 3` -> 强制 `changes_requested`。
3. 两个 reviewer 都 `approve` 且 score >=3 -> `approved`。

---

## 5. 数据模型（SQLite，直接升版，不做兼容）

## 5.1 tasks 表新增字段

在 `tasks` 中新增：

1. `review_stage TEXT NOT NULL DEFAULT 'none'`
2. `review_round INTEGER NOT NULL DEFAULT 0`
3. `base_branch TEXT`
4. `head_branch TEXT`
5. `head_sha TEXT`
6. `merge_commit TEXT`
7. `review_feedback TEXT`（聚合反馈，回灌给下轮实现）

## 5.2 新增 task_reviews 表

```sql
CREATE TABLE IF NOT EXISTS task_reviews (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL,
  review_round INTEGER NOT NULL,
  role TEXT NOT NULL, -- correctness_reviewer|maintainability_reviewer
  verdict TEXT NOT NULL, -- approve|request_changes|block
  score INTEGER,
  summary TEXT NOT NULL,
  blockers_json TEXT NOT NULL,
  suggestions_json TEXT NOT NULL,
  confidence REAL,
  reviewer_run_id TEXT,
  created_at INTEGER NOT NULL
);
```

索引：

```sql
CREATE INDEX IF NOT EXISTS idx_task_reviews_task_round ON task_reviews(task_id, review_round);
CREATE INDEX IF NOT EXISTS idx_task_reviews_role ON task_reviews(role, created_at DESC);
```

## 5.3 schema 策略

因为不要求兼容：

1. 使用 `PRAGMA user_version = 2`。
2. 若 `<2`：直接 drop 并重建 `tasks`、`task_events`、`task_reviews`。
3. 启动日志必须打印 `destructive reset` 提示。

---

## 6. API 设计（最小可用）

## 6.1 保留现有接口

1. `GET /tasks`
2. `GET /tasks/:id`
3. `POST /tasks`
4. `PATCH /tasks/:id`
5. `POST /tasks/:id/actions`
6. `GET /tasks/events`

## 6.2 返回字段扩展

`GET /tasks` / `GET /tasks/:id` 追加：

1. `review_stage`
2. `review_round`
3. `base_branch`
4. `head_branch`
5. `head_sha`
6. `merge_commit`
7. `latest_reviews`（按角色各一条）

## 6.3 actions 扩展

在 `POST /tasks/:id/actions` 增加：

1. `retry_review`：将 `review(changes_requested)` 重新入队。
2. `force_merge`：仅 control token 可调用，绕过双 review（审计必记）。

说明：若不想开放 `force_merge`，可先不做；但要在文档和代码里明确禁用。

当前代码基线约定：`force_merge` 默认禁用，API 返回 `400 {"error":"force_merge_disabled"}`。

## 6.4 前端交互规划（必须先设计）

目标：先把前端页面行为定义清楚，再写后端细节，避免接口返工。

页面建议：在 `observe-ui` 新增 `Task Pool` 视图，最少包含 3 个区块。

1. 列表区（左侧）
- 按主状态分组：`queued/running/review/done/failed/canceled`
- 每行展示：`title`、`status`、`review_stage`、`review_round`、`updated_at`
- 支持筛选与搜索（复用 `GET /tasks?status&q&cursor`）

2. 详情区（右侧上）
- 基本信息：`task_id/title/prompt/priority/max_retries/retry_count`
- Git 信息：`base_branch/head_branch/head_sha/merge_commit`
- Review 信息：`review_stage`、两角色 `latest_reviews`

3. 时间线区（右侧下）
- 渲染 `task_events`（重要事件高亮）
- 可看到 `task.review.*`、`task.merge.*` 事件

按钮与动作映射：

1. `retry_review`：优先 `status=review && review_stage=changes_requested`；若已自动回队列，允许 `status=queued && review_stage=changes_requested`
2. `requeue`：`failed/canceled/review` 可用
3. `cancel`：`queued/running/review` 可用
4. `force_merge`（若启用）：仅 `review(open|approved|changes_requested)` 可见

前端错误处理（必须实现）：

1. 409（冲突/版本问题）展示明确文案，不可吞错误。
2. 429（限流）自动退避重试，最多 3 次。
3. `invalid_body/action_failed` 显示原始 error code 便于排障。

前端刷新策略：

1. 列表：5 秒轮询 `GET /tasks`
2. 详情：选中任务后 3 秒轮询 `GET /tasks/:id`
3. 事件：2 秒轮询 `GET /tasks/events?after=<id>`
4. 首版不用 SSE，先确保稳定性。

---

## 7. Provider 与 Prompt 解耦设计

## 7.1 provider 接口改造

`src/providers/provider.zig` 新增：

```zig
runPrompt: fn(..., prompt: []const u8, log_label: []const u8) -> ExecutionResult
```

要求：

1. `runIteration` 保留给 optimize。
2. `runPrompt` 给 pool implement/review 使用。

## 7.2 prompt 模板文件（新增）

新增目录 `src/pool/prompts/`：

1. `implement.md`
2. `review_correctness.md`
3. `review_maintainability.md`

模板要求：

1. 明确角色目标。
2. 明确输出必须包含 `RESULT_JSON:` 前缀 + 单行 JSON。
3. review 模式要求“不要修改代码”，仅审查。

## 7.3 结果解析

新增解析器：

1. 从 stdout/stderr 合并文本中提取 `RESULT_JSON:` 后 JSON。
2. 解析失败直接判为 `failed`（可重试）。
3. JSON 缺字段判为无效结果。

---

## 8. Git 执行模型（本地 PR 语义）

## 8.1 分支命名

1. `base_branch = cfg.main_branch`
2. `head_branch = task/<task_id>/r<review_round>`

## 8.2 实现阶段

1. 从 `base_branch` 切 `head_branch`。
2. 运行 implement prompt。
3. 强校验：必须有 commit 产出（`git rev-parse HEAD` 与 base 不同）。
4. 记录 `head_sha`。
5. 更新任务到 `review(open)`。

## 8.3 merge 阶段

1. 获取 merge 锁（文件锁）。
2. checkout `base_branch`。
3. `git merge --no-ff <head_branch> -m "task(<id>): merge"`。
4. 成功后写 `merge_commit`，任务 `done + review_stage=merged`。
5. 失败（冲突） -> `review(changes_requested)`，把冲突信息写入 `review_feedback`。

## 8.4 并发约束

最小实现先不引入 worktree 并发执行，先串行 worker（避免仓库互斥复杂度）。

后续再做并发 worker + worktree。

---

## 9. Pool 主流程伪代码（必须按此语义实现）

```text
loop:
  task = claimNextQueuedTask()
  if task == null: sleep(2s); continue

  mark running
  impl_result = run implementer prompt
  if impl_result fail:
    markFailedOrRequeue(task)
    continue

  move task -> review(open), review_round += 1, write branch/sha

  c = run correctness reviewer
  m = run maintainability reviewer

  persist two review records

  if c.verdict != approve or m.verdict != approve or m.score < 3:
    aggregate feedback -> task.review_feedback
    move task -> review(changes_requested)
    action: requeue (status=queued)
    continue

  merge_result = merge head -> base
  if merge_result success:
    mark done (review_stage=merged)
  else:
    write feedback
    move task -> review(changes_requested)
    requeue
```

---

## 10. 代码改动清单（文件级）

必改文件：

1. `src/app/run_service.zig`
- `runPoolMode` 改为调用新 `pool_service`
- 空队列不能退出，改为常驻轮询

2. `src/app/pool_service.zig`（新增）
- 实现第 9 节完整流程

3. `src/storage/task_store.zig`
- Task 结构增加 review 字段
- 增加写入 review 记录的接口

4. `src/storage/sqlite_task_store.zig`
- schema v2
- 新字段读写
- `task_reviews` 表 CRUD

5. `src/providers/provider.zig`
- 新增 `runPrompt`

6. `src/providers/opencode_provider.zig`
7. `src/providers/codex_cli_provider.zig`
- 实现 `runPrompt`

8. `src/observe.zig`
- `/tasks` 返回新字段
- action 扩展（`retry_review`）

9. `src/pool/prompts/*.md`（新增 3 个）

10. `web/observe-ui/src/`（新增 task pool 页面与 API）
- 新增 `views/TaskPoolView.tsx`
- 新增 `lib/taskPoolApi.ts`
- 在 `App.tsx` 接入入口与状态管理

11. `tests/` 新增 pool-review 测试

---

## 11. 实施顺序（严格执行）

## 阶段 A：数据层与状态机（先做）

1. 扩展 `Task` 结构与 SQLite schema v2。
2. 增加 `task_reviews` 持久化。
3. `GET /tasks` / detail JSON 带新字段。

验收：

1. `zig build test` 通过。
2. 新建任务能看到 `review_stage=none`。

## 阶段 B：provider 解耦

1. 增加 `runPrompt` 接口。
2. opencode/codex provider 实现 `runPrompt`。
3. 新增 pool prompts 与 JSON 解析器。

验收：

1. 单测可模拟 `RESULT_JSON` 正常解析/异常解析。

## 阶段 C：pool_service 主流程

1. 实现 implement -> double review -> merge。
2. 接入 `run_service.runPoolMode`。
3. 队列空时 sleep 轮询（常驻）。

验收：

1. 能自动跑完整任务并进入 done。
2. review 拒绝时会回队列且有 feedback。

## 阶段 D：API 稳定化与前端联调前准备

1. `/tasks` 返回最新双角色 review 摘要。
2. action `retry_review`。
3. 补齐错误码语义（409/429/400）与文档示例。

验收：

1. 前端联调前，接口字段和错误码固定，不再随意变更。

## 阶段 E：前端 Task Pool 页面

1. 新增 Task Pool 页面（列表/详情/时间线三栏）。
2. 接入 `retry_review/requeue/cancel` 按钮逻辑。
3. 展示两角色最新 review 与阻断项摘要。
4. 加入轮询与错误提示（409/429/400）。

验收：

1. 页面可直接展示 two-role review 结果。
2. 操作后 2 个轮询周期内可看到状态变化。
3. review 拒绝时可直接在 UI 看到 `review_feedback`。

---

## 12. 测试计划（必须补）

## 12.1 单测

1. review 判定：
- 双 approve + score>=3 -> approved
- 任一 request_changes -> changes_requested
- score<3 -> changes_requested

2. 状态转换非法输入测试。

3. JSON 解析失败测试。

## 12.2 集成测试

新增脚本：`scripts/e2e-pool-review.sh`

场景：

1. 创建任务 -> 实现成功 -> 两 reviewer approve -> merge -> done。
2. maintainability score=2 -> changes_requested -> requeue。
3. merge 冲突 -> changes_requested。

---

## 13. 观测与审计

每次关键动作必须写 `task_events`：

1. `task.running`
2. `task.review.opened`
3. `task.review.correctness.completed`
4. `task.review.maintainability.completed`
5. `task.review.changes_requested`
6. `task.review.approved`
7. `task.merge.succeeded|task.merge.failed`

payload 必须包含：

1. `task_id`
2. `review_round`
3. `role`（如果是 review 事件）
4. `verdict/score`（如果有）

---

## 14. 失败策略（必须明确）

1. provider 执行失败：走 `markFailedOrRequeue`。
2. review JSON 非法：视为 review 失败，进入 `changes_requested`，并记录解析错误。
3. merge 冲突：进入 `changes_requested`，自动 requeue。
4. 连续超过 `max_retries`：最终 `failed`。

---

## 15. 完成定义（DoD）

满足以下全部条件才算完成：

1. `pool` 不再调用 `program.md` 相关逻辑。
2. `pool` 可常驻消费任务，不因队列暂时为空退出。
3. 双角色 review 结果可审计、可回放。
4. 至少 3 条 e2e 用例通过（通过 / 改回 / 冲突）。
5. `zig build` 与 `zig build test` 通过。
6. 前端 Task Pool 页面可完成“查看 + 操作 + 回显”闭环。

---

## 16. 里程碑（Milestones）

## M1（本期，必须完成）

1. 串行 `pool` worker（常驻轮询）
2. 双角色 review（correctness + maintainability）
3. 本地 merge gate
4. Task Pool 前端页面（MVP）

## M2（下期备注，不在本次实现）

1. 多 worker 并发执行
2. `git worktree` 隔离执行目录
3. 仓库级 merge 锁 + 分支漂移自动处理强化

---

## 17. 实施 Checklist（交接执行清单）

使用方式：

1. 每完成一项就改成 `[x]`。
2. 不允许跳项；必须按顺序推进。
3. 每个阶段结束必须执行“阶段验收命令”并记录结果。

### 17.1 阶段 A：数据层与状态机

- [ ] 在 `task_store.Task` 增加：`review_stage/review_round/base_branch/head_branch/head_sha/merge_commit/review_feedback`
- [ ] 在 `sqlite_task_store` schema 增加上述字段
- [ ] 新增 `task_reviews` 表与索引
- [ ] 实现 schema version 升级逻辑（`user_version=2`，按文档执行 destructive reset）
- [ ] `GET /tasks` JSON 输出新增字段
- [ ] `GET /tasks/:id` JSON 输出新增字段
- [ ] 补充数据层单测（字段序列化/反序列化）

阶段验收命令：

```bash
zig build test
zig build
```

### 17.2 阶段 B：provider 解耦 + pool prompts

- [ ] 在 `provider.zig` 增加 `runPrompt(...)`
- [ ] 在 `opencode_provider.zig` 实现 `runPrompt(...)`
- [ ] 在 `codex_cli_provider.zig` 实现 `runPrompt(...)`
- [ ] 新增目录 `src/pool/prompts/`
- [ ] 新增 `implement.md`
- [ ] 新增 `review_correctness.md`
- [ ] 新增 `review_maintainability.md`
- [ ] 新增 `RESULT_JSON` 解析器
- [ ] 补充解析器单测：成功/缺字段/非法 JSON

阶段验收命令：

```bash
zig build test
```

### 17.3 阶段 C：pool_service 主流程

- [ ] 新增 `src/app/pool_service.zig`
- [ ] 实现 claim -> running -> implement -> review(open) 流程
- [ ] 实现 correctness reviewer 调用与落库
- [ ] 实现 maintainability reviewer 调用与落库
- [ ] 实现 review gate（score<3 或任一非 approve -> changes_requested）
- [ ] 实现 changes_requested -> queued（回灌 `review_feedback`）
- [ ] 实现 approved -> merge -> done
- [ ] merge 失败时进入 `changes_requested` 并 requeue
- [ ] 空队列时 sleep 轮询（常驻，不退出）
- [ ] 在 `run_service.runPoolMode` 接入 `pool_service`
- [ ] 补充关键事件写入：`task.review.*`、`task.merge.*`

阶段验收命令：

```bash
zig build test
zig build
```

### 17.4 阶段 D：API 稳定化

- [ ] `POST /tasks/:id/actions` 增加 `retry_review`
- [ ] `retry_review` 仅允许 `review_stage=changes_requested` 且 `status in (review, queued)`
- [ ] 明确 `400/409/429` 语义并统一 error code
- [ ] `GET /tasks/:id` 增加 `latest_reviews`（两角色最近一条）
- [ ] 更新接口文档示例（请求体/响应体/错误码）

阶段验收命令：

```bash
zig build test
```

### 17.5 阶段 E：前端 Task Pool 页面

- [ ] 新增 `web/observe-ui/src/lib/taskPoolApi.ts`
- [ ] 新增 `web/observe-ui/src/views/TaskPoolView.tsx`
- [ ] 在 `App.tsx` 挂载 Task Pool 页面入口
- [ ] 列表区：状态分组 + 搜索 + 分页
- [ ] 详情区：任务字段 + Git 字段 + review 摘要
- [ ] 时间线区：渲染 `task_events`
- [ ] 按钮：`retry_review/requeue/cancel`（按可用状态启用禁用）
- [ ] 错误处理：409/429/400 文案与重试策略
- [ ] 轮询策略：列表 5s、详情 3s、事件 2s

阶段验收命令：

```bash
cd web/observe-ui
pnpm test || npm test
pnpm build || npm run build
```

### 17.6 E2E 与收尾

- [ ] 新增 `scripts/e2e-pool-review.sh`
- [ ] 用例 1：双 reviewer approve -> done
- [ ] 用例 2：maintainability score=2 -> changes_requested -> queued
- [ ] 用例 3：merge 冲突 -> changes_requested -> queued
- [ ] 检查事件流完整性（`task.review.*` / `task.merge.*`）
- [ ] 更新 README 或 docs 索引，标注该模式入口

最终验收命令：

```bash
zig build
zig build test
bash scripts/e2e-pool-review.sh
```

### 17.7 提交前人工复核（必须）

- [ ] 确认 `pool` 代码路径不再调用 `program.md` / `preparePrompt`
- [ ] 确认 `pool` 空队列不会退出进程
- [ ] 确认 `latest_reviews` 字段在空数据时返回空数组而非 null
- [ ] 确认 `review_feedback` 在 requeue 后可被下一轮 implement prompt 读取
- [ ] 确认 API 失败时不会吞掉 error code
