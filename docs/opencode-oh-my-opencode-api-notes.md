# autocode 项目可用 API 盘点（基于本机已安装 opencode / oh-my-opencode）

更新时间：2026-03-13

## 1. 本机已安装版本

- `opencode`: `1.2.25`
- `oh-my-opencode`: `3.10.0`

## 2. 你当前项目已经在使用的能力（已验证）

从 `src/main.zig` 当前实现看，核心调用是：

- `opencode run --attach <url> --dir <work_dir> --format json --title <title> [--model <provider/model>] <prompt>`
- `opencode serve`（通过 `opencode_url` 可达性检查）

对应价值：

- `--attach` + `--dir`：把会话绑定到目标工程目录，避免共享 server 时串上下文。
- `--format json`：你现在的日志/状态解析依赖 JSON 事件流，这一点非常关键。
- `--model`：可通过 `.techlead/techlead.json` 的 `model` 字段切换模型。

## 3. 对本项目最有用的 opencode CLI API

以下是已经在本机帮助里确认过、并且对这个“持续迭代改进 CLI”直接有价值的 API。

### 3.1 `opencode run`

主要参数（你已用或建议新增）：

- `--attach <url>`：连接已有 opencode server（已用）
- `--dir <path>`：设定远端工作目录（已用）
- `--format json|default`：结构化事件输出（已用 `json`）
- `--title <text>`：会话标题（已用）
- `--model <provider/model>`：指定模型（已用）
- `--session <id>`：继续指定 session
- `--continue`：继续最近一次 session
- `--fork`：继续会话时先分叉，避免污染原会话
- `--file <path...>`：附加文件到消息上下文
- `--variant <value>`：模型推理强度/变体（provider 特定）
- `--thinking`：显示 thinking blocks（调试提示工程时有用）
- `--password`：连接带 basic auth 的 server

对你的项目建议：

- 增加“可恢复模式”：记录上次 `session id`，失败后可自动 `--session` 续跑。
- 增加“分叉试验模式”：当进入实验分支时配合 `--fork`，降低误改主线上下文风险。

### 3.2 `opencode serve`

主要参数：

- `--port`：监听端口（默认 0，随机）
- `--hostname`：监听地址（默认 `127.0.0.1`）
- `--cors <domain...>`：允许跨域来源
- `--mdns` / `--mdns-domain`：局域网发现

对你的项目建议：

- 你目前默认配置是 `http://localhost:4096`，建议固定 server 启动时也显式指定 `--port 4096`，避免端口漂移导致 run 阶段连接失败。

### 3.3 会话与审计相关 API

- `opencode session list`
- `opencode session delete <sessionID>`
- `opencode export [sessionID]`
- `opencode import <file|url>`

对你的项目建议：

- 每次迭代完成后可以追加“会话导出归档”（`opencode export`），把决策链和工具轨迹落盘到 `.techlead/iteration-logs` 旁，便于回溯。

### 3.4 MCP 与模型管理 API

- `opencode mcp add|list|auth|logout|debug`
- `opencode models [provider] [--verbose] [--refresh]`

对你的项目建议：

- 在 CI 或日常巡检脚本中加入 `opencode models --refresh`，减少因模型列表缓存过期导致的模型名错误。
- 若后续要让迭代流程访问外部知识源，可先通过 `opencode mcp` 统一管理可用 MCP 服务。

## 4. 对本项目最有用的 oh-my-opencode API

### 4.1 `oh-my-opencode run`（最值得用）

参数：

- `run <message>`
- `--agent <name>`
- `--directory <path>`
- `--port <port>` 或 `--attach <url>`
- `--session-id <id>`（继续会话）
- `--json`（结构化输出）
- `--verbose`
- `--on-complete <command>`（完成后执行命令）
- `--no-timestamp`

它相对 `opencode run` 的核心差异（文档声明）：

- 会等待到 todos 完成/取消
- 会等待所有子会话（后台任务）空闲

对你的项目价值：

- 你现在每轮调用后只依据返回流判断；切到 `oh-my-opencode run` 后，天然更符合“单轮必须收敛完成再进入下一轮”的目标。
- `--on-complete` 可直接挂你已有的 git 状态检查、日志整理命令。

### 4.2 `oh-my-opencode doctor`

- `doctor --status|--verbose|--json`

对你的项目价值：

- 可以作为 `run` 前置健康检查（替代只检查 URL 连通），把配置/安装层面的故障更早暴露出来。

### 4.3 `oh-my-opencode mcp oauth`

- `login <server-name> [--server-url --client-id --scopes...]`
- `status [server-name]`
- `logout <server-name> [--server-url]`

对你的项目价值：

- 如果后续你的自动迭代要用 MCP 服务（文档检索、代码搜索等），OAuth 生命周期可以统一走这组命令，不需要你在项目里自己维护 token 逻辑。

### 4.4 版本与安装 API（运维向）

- `oh-my-opencode get-local-version [--json] [--directory]`
- `oh-my-opencode install [--no-tui ...]`

对你的项目价值：

- 在启动脚本里加入版本探针（`get-local-version --json`）可提前发现环境漂移（本机与 CI 版本不一致）。

## 5. 建议优先级（按你这个仓库现状）

1. **高优先级**：保留现有 `opencode run --format json` 主链路，同时新增 `session` 恢复机制（`--session`/`--continue`）。
2. **高优先级**：把 `opencode serve` 固定端口与 `techlead.json` 对齐，避免随机端口导致断连。
3. **中优先级**：引入 `oh-my-opencode doctor --json` 作为运行前健康检查。
4. **中优先级**：评估将执行器从 `opencode run` 切到 `oh-my-opencode run --json`，换取 todo/子任务收敛保证。
5. **低优先级**：补充 `opencode export` 归档、`mcp` 管理与 OAuth 工作流。

## 6. 可直接执行的手工验证命令

```bash
# 版本
opencode --version
oh-my-opencode --version

# 当前主链路相关
opencode run --help
opencode serve --help

# 会话/导出
opencode session --help
opencode export --help

# MCP
opencode mcp --help
oh-my-opencode mcp oauth --help

# oh-my-opencode 执行与体检
oh-my-opencode run --help
oh-my-opencode doctor --help
```

## 7. 在 autocode 项目里接入 oh-my-opencode 强能力

结论：**可以**，而且有两种方式。

### 方式 A（低改造，推荐先做）

继续使用当前 `opencode run` 主链路，但确保运行中的 opencode server 已加载 oh-my-opencode 插件，并在调用时显式传入 agent（如 `Sisyphus`）。

对当前仓库的意义：

- 你现有解析逻辑（`--format json` 事件流）不用重写。
- 你能吃到 oh-my-opencode 提供的 agent 体系与调度策略。

建议改动点：

- 在 `.techlead/techlead.json` 增加 agent 配置字段（例如 `agent`）。
- 在 `src/main.zig` 组装参数时，若 `agent` 非空则追加 `--agent <agent>`。

### 方式 B（高能力上限，改造稍大）

把执行器从 `opencode run` 切换为 `oh-my-opencode run --json`。

优点：

- 有 todo/子任务收敛等待语义（更像“这一轮真完成了再进入下一轮”）。
- 支持 `--on-complete` 等自动化钩子。

代价：

- 需要调整 `src/main.zig` 当前基于 opencode JSON 事件流的解析逻辑（输出结构不同）。

### 关键前提（很重要）

你的 autocode 在 `src/main.zig` 中使用了 `--attach <opencode_url>`，因此**最终能力取决于被 attach 的那台 server 环境**：

- 若 server 端装了并启用了 oh-my-opencode 插件，你的自动调用就能用到增强能力。
- 若 server 端没有插件，即便你本机装了 oh-my-opencode，也不会自动获得同等能力。

### 对这个仓库的推荐路线

1. 先做方式 A：最小改动接入 `--agent`，快速验证收益。
2. 稳定后再评估方式 B：把执行器升级为 `oh-my-opencode run`。
3. 两种方式都建议加 `doctor` 预检，提前发现环境不一致问题。

---

如果你希望，我可以下一步直接基于这份文档改 `src/main.zig`：

- 增加 `session_id` 持久化与断点续跑
- 增加可选执行器（`opencode` / `oh-my-opencode`）
- 增加 `doctor` 预检开关
