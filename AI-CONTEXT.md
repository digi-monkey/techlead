# AI 上下文指引

## 项目概览

**VA Auto-Pilot** —— CLI-first 自主多智能体工程循环框架

- **核心**: 为最强模型设计的自治执行框架，不设步骤清单
- **哲学**: 给定目标 + 约束 + 验收标准，让模型自己找路径
- **质量门禁**: 确定性 CLI 命令 (`pnpm run check:all`)

## 关键文件

| 文件 | 用途 |
|------|------|
| `bin/va-auto-pilot.mjs` | CLI 入口 |
| `docs/operations/va-auto-pilot-protocol.md` | 完整协议文档 |
| `docs/operations/va-auto-pilot-protocol-concise.md` | 精简版（省 token） |
| `.va-auto-pilot/sprint-state.json` | 机器可读任务状态 |
| `docs/todo/sprint.md` | 任务看板（CLI 生成） |
| `docs/todo/human-board.md` | 人类控制面板 |
| `docs/todo/run-journal.md` | 执行日志（追加式） |

## 常用命令

```bash
# 初始化项目
node bin/va-auto-pilot.mjs init .

# 渲染看板
node scripts/sprint-board.mjs render

# 获取下一个任务
node scripts/sprint-board.mjs next

# 运行全部检查
pnpm run check:all

# 验证分发
pnpm run validate:distribution
```

## 代码规范

- **模块**: ESM (`"type": "module"`)
- **Node**: >= 20
- **包管理**: pnpm (已配置 `.npmrc`)
- **脚本**: `.mjs` 扩展名

## 修改注意事项

1. 保持 CLI 优先设计 —— 所有操作应有确定性命令
2. 状态更新通过 CLI，不要手改 `sprint-state.json`
3. `run-journal.md` 是追加式，只添加不修改历史
4. 质量门禁必须通过 (`pnpm run check:all`)

## 项目结构

```
.
├── bin/              # CLI 入口
├── scripts/          # 核心脚本 (sprint-board, test-runner等)
├── templates/        # 项目模板
├── skills/           # Codex/Claude 技能分发
├── docs/             # 文档
│   ├── operations/   # 协议文档
│   └── todo/         # 任务看板 (运行时生成)
├── example-project/  # 示例项目
├── website/          # 官网
└── .va-auto-pilot/   # 运行时状态
```
