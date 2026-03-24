# 多项目 Pool（单端口监控）落地手册（Breaking 版本，给执行型 AI）

## 0. 文档定位与执行纪律

本手册是给“执行能力一般、容易跑偏”的 AI 用的。目标不是讨论方案，而是按步骤把功能做出来并自证可用。

硬规则：

1. 这是 **Breaking Change**，不做向前兼容，不保留旧单项目 API。
2. 每完成一个阶段必须跑该阶段的验收命令，未通过不能进入下一阶段。
3. 不允许“脑补已完成”，所有结论要有命令输出或事件日志证据。
4. 任何阶段失败时，先修到通过再继续，不允许跳过。

---

## 1. 最终目标（Done 定义）

完成后必须同时满足：

1. 一个 `observe` 进程、一个端口，可监控和控制多个项目。
2. 项目维度完整隔离：任务、日志、评审、合并互不串扰。
3. 全局 pool 调度支持多项目公平分配（避免一个项目饿死其他项目）。
4. 使用 2-3 个 GitHub 小项目完成整条链路：
   `任务认领 -> 实现提交 -> review -> 驳回 -> 再提交 -> 再 review -> 接受并完成`。
5. 提供可复跑的验收脚本和验收报告（含事件序列和 commit 证据）。

---

## 2. 真实测试项目（固定使用）

使用以下公开仓库（小型、成熟、易跑）：

1. Node 项目：`https://github.com/sindresorhus/p-limit`
2. Python 项目：`https://github.com/pallets/itsdangerous`
3. 可选第三个：`https://github.com/pallets-eco/blinker`

选择理由：

1. 体量小，CI/测试脚本清晰。
2. 依赖生态稳定，适合重复验证。
3. 技术栈不同（Node + Python），可验证调度和隔离健壮性。

---

## 3. 统一架构（必须按此实现）

### 3.1 控制面与执行面分离

1. 控制面（单实例、单端口）：
   - 管理项目注册。
   - 全局任务列表与调度。
   - 统一 API 和 UI。
2. 执行面（按项目隔离）：
   - 在目标项目目录执行实现与 review。
   - 使用项目自己的 worktree 和 merge lock。

### 3.2 存储设计（Breaking）

新增全局 DB：`~/.config/techlead/controlplane.sqlite3`

核心表：

1. `projects`
2. `tasks`
3. `task_reviews`
4. `task_events`
5. `runs`
6. `leases`

注意：旧 `.techlead/task_pool.sqlite3` 与旧 API 不再作为主路径。

### 3.3 调度约束

1. 全局并发：`max_workers`。
2. 单项目并发：`per_project_max_workers=1`（第一版先锁死 1）。
3. 调度策略：`WRR + aging`。
4. claim 使用租约（lease），超时后可回收。

---

## 4. API 设计（直接替换旧接口）

保留最小可用集合：

1. `POST /projects`：注册项目。
2. `GET /projects`：列出项目。
3. `POST /projects/:project_id/runs/start`：启动该项目 pool 运行。
4. `POST /projects/:project_id/tasks`：创建任务。
5. `GET /projects/:project_id/tasks`：任务列表。
6. `GET /projects/:project_id/tasks/:task_id`：任务详情。
7. `POST /projects/:project_id/tasks/:task_id/actions`：任务动作。
8. `GET /events?project_id=<id>&after=<n>`：事件流（可全局/按项目过滤）。

返回 JSON 必须带：

1. `project_id`
2. `task_id`（涉及任务时）
3. `status`
4. `updated_at`

---

## 5. 代码改造清单（文件级）

> 执行 AI 必须按顺序改，不要跳。

### 阶段 A：数据层

新增：

1. `src/storage/sqlite_controlplane_store.zig`
2. `src/storage/controlplane_store.zig`

改动：

1. `src/storage/` 下导出入口（按项目现有风格接入）。
2. 新增 schema 初始化与 migration（直接到 V2，不保兼容）。

阶段 A 验收：

1. 能创建 `controlplane.sqlite3`。
2. 能增删查 `projects`。
3. 能创建/claim/requeue 任务。

### 阶段 B：服务层

新增：

1. `src/app/project_service.zig`
2. `src/app/multi_pool_service.zig`
3. `src/app/scheduler_service.zig`

改动：

1. `src/app/pool_service.zig`：下沉“单任务执行函数”，供 multi-pool 复用。
2. `src/runner.zig`：新增多项目 run 入口。

阶段 B 验收：

1. 两个项目各建 1 个任务后，调度器都能 claim。
2. 不出现同一任务被双 worker 同时 claim。

### 阶段 C：observe/API

改动：

1. `src/observe.zig`：从单 `target_dir` 上下文改为多项目上下文。
2. `src/main.zig`：路由改为项目化 API。

阶段 C 验收：

1. 单端口下可 `POST /projects` 注册多个目录。
2. `GET /projects/:id/tasks` 可独立看到各自任务。

### 阶段 D：前端

改动：

1. `web/observe-ui/src/lib/`：新增 project API client。
2. `web/observe-ui/src/views/`：新增项目切换与全局看板。
3. `web/observe-ui/src/App.tsx`（或等效入口）：路由与状态改造。

阶段 D 验收：

1. UI 单端口可切换项目。
2. 每个项目任务和事件不串台。

### 阶段 E：规则门禁与可复现驳回链路

新增：

1. 项目级 gate 配置：`test_cmd`、`lint_cmd`。
2. QA 开关：`qa_force_reject_once`（只用于验收）。

阶段 E 验收：

1. 首轮可稳定触发 `changes_requested`。
2. 第二轮修复后可进入 `approved -> done`。

---

## 6. 执行顺序（必须严格执行）

1. 先完成阶段 A（存储），跑 A 验收。
2. 再做阶段 B（调度），跑 B 验收。
3. 再做阶段 C（API），跑 C 验收。
4. 再做阶段 D（UI），跑 D 验收。
5. 最后做阶段 E（门禁 + 驳回复现），跑 E 验收。

任何阶段失败：回到该阶段修复，不得推进。

---

## 7. 自我验收方案（开发中）

## 7.1 最小自测（本地临时仓库）

1. 建两个临时 git repo（A/B）。
2. 注册到 `/projects`。
3. 各创建 2 个任务。
4. 启动全局调度器（单进程多 worker）。
5. 验证 claim 分配不是全部偏向 A。

检查点：

1. 每个项目至少有 1 个任务进入 `running`。
2. 事件里 `project_id` 正确。
3. 无跨项目文件改动。

## 7.2 稳定性与故障注入

1. 在任务 `claimed/running/review` 阶段杀掉 worker。
2. 重启后观察 lease 回收并重新 claim。
3. 最终任务可继续完成。

检查点：

1. 无永久卡死在 `claimed`。
2. 无重复 merge。

---

## 8. 真实项目全链路验收（必须执行）

## 8.1 环境准备命令

```bash
set -euo pipefail

WORK_ROOT=/tmp/techlead-multi-e2e
rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"
cd "$WORK_ROOT"

git clone https://github.com/sindresorhus/p-limit.git
git clone https://github.com/pallets/itsdangerous.git
# 可选第三个
# git clone https://github.com/pallets-eco/blinker.git
```

## 8.2 初始化项目（每个项目）

示例（按你最终 CLI 调整）：

```bash
# 仅示例：若 init 逻辑变化，请同步替换
techlead init --dir "$WORK_ROOT/p-limit" "Keep tests green while improving maintainability" --force
techlead init --dir "$WORK_ROOT/itsdangerous" "Keep tests green while improving maintainability" --force
```

## 8.3 注册项目到单端口控制面

```bash
curl -sS -X POST http://127.0.0.1:7810/projects -H 'content-type: application/json' -d '{"project_id":"p-limit","work_dir":"/tmp/techlead-multi-e2e/p-limit","enabled":true,"test_cmd":"npm test"}'

curl -sS -X POST http://127.0.0.1:7810/projects -H 'content-type: application/json' -d '{"project_id":"itsdangerous","work_dir":"/tmp/techlead-multi-e2e/itsdangerous","enabled":true,"test_cmd":"pytest -q"}'
```

## 8.4 创建任务（每个项目两个）

每个项目任务 1（应直接通过）：

1. 小幅重构或注释改进。

每个项目任务 2（必须走驳回再通过）：

1. 打开 `qa_force_reject_once=true`。
2. 首轮自动驳回，二轮修复后通过。

示例：

```bash
# p-limit: happy path
curl -sS -X POST http://127.0.0.1:7810/projects/p-limit/tasks -H 'content-type: application/json' -d '{"title":"refactor small utility","prompt":"Refactor a small utility without behavior change","priority":50}'

# p-limit: reject once
curl -sS -X POST http://127.0.0.1:7810/projects/p-limit/tasks -H 'content-type: application/json' -d '{"title":"add guard + tests","prompt":"Add edge-case guard and tests","priority":60,"qa_force_reject_once":true}'

# itsdangerous: happy path
curl -sS -X POST http://127.0.0.1:7810/projects/itsdangerous/tasks -H 'content-type: application/json' -d '{"title":"small cleanup","prompt":"Small cleanup and keep tests green","priority":50}'

# itsdangerous: reject once
curl -sS -X POST http://127.0.0.1:7810/projects/itsdangerous/tasks -H 'content-type: application/json' -d '{"title":"tighten validation","prompt":"Tighten validation and add tests","priority":60,"qa_force_reject_once":true}'
```

## 8.5 启动运行（同一个 observe 端口）

```bash
# 启动 observe（单端口）
techlead observe start --port 7810

# 启动每个项目 run（可通过 API）
curl -sS -X POST http://127.0.0.1:7810/projects/p-limit/runs/start -H 'content-type: application/json' -d '{"mode":"pool"}'
curl -sS -X POST http://127.0.0.1:7810/projects/itsdangerous/runs/start -H 'content-type: application/json' -d '{"mode":"pool"}'
```

## 8.6 必须采集的验收证据

每个“reject once”任务必须有以下证据：

1. 状态序列完整：
   - `queued`
   - `claimed`
   - `running`
   - `review`
   - `changes_requested`
   - `queued`
   - `claimed`
   - `running`
   - `review`
   - `approved`
   - `done`
2. 两轮实现提交 commit SHA。
3. 两轮 review 记录（第一轮驳回理由、第二轮通过理由）。
4. 最终 merge commit SHA。

推荐导出命令（示例）：

```bash
# 导出项目事件
curl -sS "http://127.0.0.1:7810/events?project_id=p-limit&after=0" > /tmp/p-limit-events.json
curl -sS "http://127.0.0.1:7810/events?project_id=itsdangerous&after=0" > /tmp/itsdangerous-events.json

# 导出任务详情（替换 task_id）
curl -sS "http://127.0.0.1:7810/projects/p-limit/tasks/<TASK_ID>" > /tmp/p-limit-task.json
curl -sS "http://127.0.0.1:7810/projects/itsdangerous/tasks/<TASK_ID>" > /tmp/itsdangerous-task.json

# 导出 git 证据
cd /tmp/techlead-multi-e2e/p-limit && git log --oneline --decorate -n 30 > /tmp/p-limit-gitlog.txt
cd /tmp/techlead-multi-e2e/itsdangerous && git log --oneline --decorate -n 30 > /tmp/itsdangerous-gitlog.txt
```

---

## 9. 自动化验收脚本（必须新增）

至少新增 3 个脚本：

1. `scripts/e2e-multiproject-smoke.sh`
   - 两项目注册、建任务、启动、看到 claim 即通过。
2. `scripts/e2e-multiproject-review-loop.sh`
   - 强制跑 `changes_requested -> requeue -> approved -> done`。
3. `scripts/e2e-multiproject-live-proof.sh`
   - 跑真实仓库并导出验收证据到 `artifacts/`。

每个脚本必须：

1. `set -euo pipefail`
2. 可重复执行（先清理旧状态）
3. 失败时输出明确错误点

---

## 10. 执行 AI 的“逐步提示词模板”

当你把该任务交给另一个 AI 时，使用以下模板逐阶段执行。

模板（每阶段都用）：

1. 你现在只做“阶段 X”。
2. 先列出你会改动的文件清单。
3. 完成后运行阶段验收命令并贴结果摘要。
4. 如果验收失败，先修复，不要进入下一阶段。
5. 最后只输出：
   - 改了哪些文件
   - 验收是否通过
   - 下一阶段是否可开始

---

## 11. 阶段验收命令总表

> 按你项目当前构建命令调整；这里给默认版本。

```bash
# 编译与单测
zig build test

# pool 相关测试（如果有过滤）
zig build test -- --test-filter "pool"

# 前端构建
cd web/observe-ui && npm ci && npm run build

# 多项目 e2e 冒烟
bash scripts/e2e-multiproject-smoke.sh

# 驳回-重提-通过链路
bash scripts/e2e-multiproject-review-loop.sh

# 真实仓库证据回放
bash scripts/e2e-multiproject-live-proof.sh
```

通过门槛：

1. 所有命令退出码为 0。
2. 真实项目报告中包含完整状态序列与 commit/review 证据。

---

## 12. 常见失败与处理

1. 任务卡在 `claimed`：
   - 检查 lease 是否过大或未回收。
   - 检查 worker 崩溃后是否正确释放。
2. 项目串改：
   - 检查执行时 cwd 是否错误。
   - 检查 worktree 路径是否带 `project_id`。
3. 驳回链路不稳定：
   - 启用 `qa_force_reject_once`，避免依赖模型随机性。
4. 单项目占满资源：
   - 检查 `per_project_max_workers` 是否生效。
   - 检查 WRR + aging 权重更新逻辑。

---

## 13. 最终交付物清单

提交前必须具备：

1. 代码：多项目控制面 + 调度 + API + UI。
2. 文档：本手册（当前文件）+ API 文档更新。
3. 脚本：3 个 e2e 脚本。
4. 报告：`artifacts/` 下真实项目验收证据。

若上述任一缺失，视为未完成。
