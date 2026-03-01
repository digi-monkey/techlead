# TechLead CLI 使用指南

## 安装

### 从源码构建

```bash
cd techlead
pnpm install
pnpm build

# 选项1: 全局链接（推荐）
pnpm link --global

# 选项2: 直接使用 node
node ./dist/cli.js

# 选项3: 添加 alias 到 .bashrc
alias techlead='node /path/to/techlead/dist/cli.js'
```

## 快速开始

```bash
# 1. 初始化项目
techlead init

# 2. 添加任务
techlead add "实现新功能"

# 3. 查看状态
techlead status

# 4. 运行（自动驱动 Agent）
techlead run

# 5. 查看所有任务
techlead list
```

## 完整工作流

### 单任务开发流程

```bash
# 人类给目标
techlead add "实现用户登录功能"

# Agent 全自动执行
techlead run
# → 自动进入 Plan 阶段（生成 plan/discussion.md）
# → 自动进入 Exec 阶段（执行代码）
# → 自动进入 Review 阶段（对抗性审查）
# → 自动进入 Test 阶段（对抗性测试）
# → 自动标记 Done

# 人类检查进度
techlead status
techlead list
```

### 多任务队列

```bash
# 批量添加任务
techlead add "任务 A"
techlead add "任务 B"
techlead add "任务 C"

# 按顺序自动执行
techlead run  # 执行 A
techlead run  # 执行 B
techlead run  # 执行 C
```

## 目录结构

```
.techlead/
├── current.json          # 当前任务指针
├── tasks/
│   ├── T-001-任务A/
│   │   ├── task.json     # 任务元数据
│   │   ├── README.md     # 任务描述
│   │   ├── plan/         # Plan 阶段产出
│   │   │   ├── discussion.md
│   │   │   ├── plan.md
│   │   │   ├── .abstract.md
│   │   │   └── .overview.md
│   │   ├── work-log.md   # 执行日志
│   │   └── review/       # Review 阶段产出
│   └── T-002-任务B/
└── knowledge/
    ├── pitfalls.md       # 失败经验
    └── patterns.md       # 成功模式
```

## 命令参考

### `init`
初始化 TechLead 工作目录

```bash
techlead init
```

### `add <title>`
创建新任务

```bash
techlead add "实现 OAuth 登录"
techlead add "优化性能"
```

### `list`
列出所有任务

```bash
techlead list
```

输出示例：
```
📋 Tasks:

ID      Status         Phase     Title
------------------------------------------------------------
▶ T-001  in_progress    exec      实现 OAuth 登录
  T-002  backlog        -         优化性能
```

### `status`
查看当前任务状态

```bash
techlead status
```

### `run`
自动运行下一个任务

```bash
# 智能选择任务优先级：
# 1. 当前未完成任务
# 2. Backlog 任务
# 3. Failed 任务（重试）
techlead run
```

### `abort`
中止当前任务（标记为 failed）

```bash
techlead abort
```

## 吃自己狗粮（Dogfooding）

用 TechLead 开发 TechLead 本身：

```bash
cd techlead

# 添加开发任务
techlead add "实现 Agent 自动执行功能"
techlead add "添加 L0/L1 自动生成"
techlead add "优化错误处理"

# 运行第一个任务
techlead run
# → Codex/Claude 自动读取 prompts/plan/multirole.md
# → 生成 Plan
# → 自动执行
# → 自动审查
```

## 配置 Agent

创建 `.techlead/config.yaml`：

```yaml
agent:
  provider: codex  # 或 claude
  model: gpt-4o    # 或 sonnet
  max_budget_usd: 2.0
  allowed_tools:
    - Read
    - Edit
    - Bash
```

## 故障排除

### 找不到命令
```bash
# 检查构建
pnpm build

# 使用完整路径
node /path/to/techlead/dist/cli.js --help
```

### Agent 未安装
```bash
# 安装 Claude Code
npm install -g @anthropic-ai/claude-code

# 或安装 Codex CLI
npm install -g @openai/codex
```

### 权限问题
```bash
chmod +x dist/cli.js
```
