# VA Auto-Pilot 协议（精简版）

> 适用：AI 执行循环快速参考 | 完整版：`docs/operations/va-auto-pilot-protocol.md`

---

## 核心原则

1. 你是结果管理者，不是步骤执行者
2. `.va-auto-pilot/sprint-state.json` 是机器任务源
3. `docs/todo/sprint.md` 是 CLI 生成的看板视图
4. `docs/todo/run-journal.md` 是追加式执行记忆
5. 每个循环执行一个主任务，独立任务可并行
6. `docs/todo/human-board.md` 永远覆盖自动决策
7. **目标优先委派**: 定义目标+约束+验收，不规定实现步骤
8. **CLI 优先**: 确定性命令 > 手动操作
9. **前沿模型优先**: 高影响任务用最强制型
10. **闭环质量**: build → review → acceptance → commit

---

## 状态机

```
Backlog → In Progress → Review → Testing → Done
                 ^                     |
                 +------ Failed <-------+
```

---

## 每轮循环

1. **读取 human-board.md** — 执行未完成的 Instructions
2. **读取 run-journal.md** — 获取上下文
3. **CLI 获取任务** — `node scripts/sprint-board.mjs next`
4. **委派执行** — 子 Agent 实现
5. **质量门禁** — `pnpm run check:all`
6. **更新状态** — CLI 更新 `sprint-state.json`
7. **追加日志** — `run-journal.md`

---

## 委派格式

```
Task ID: AP-XXX
目标: [必须达成的结果]
相关文件: [路径列表]
硬约束:
- [架构/安全/命名限制]
- [验收标准: pnpm run check:all 必须通过]
完成门禁: [typecheck/lint/test/review/distribution]

⚠️ 不规定实现步骤，只定义必须满足的条件
```

---

## 质量门禁

```bash
# Gate 1: 构建与静态检查
pnpm run check:all

# Gate 2: 代码审查
codex review --uncommitted  # 或等价工具

# Gate 3: 验收测试
pnpm run validate:distribution
```

通过标准：MUST 100%，SHOULD >= 80%

---

## 多视角审查

**动态选择视角**（非固定角色）：
1. 识别真实约束
2. 确定锚点（必须保持的不变量）
3. 让视角浮现：哪些专家视角能暴露关键失败模式？

每个审查必须声明：
- 变更内容
- 硬约束
- 锚点
- 具体视角和要探测的失败模式

---

## 状态更新

**只用 CLI，不手改文件**：

```bash
# 更新任务状态
node scripts/sprint-board.mjs update --id AP-001 --state "In Progress"

# 添加执行日志
node scripts/sprint-board.mjs journal --task AP-001 --summary "做了什么"

# 标记失败并记录陷阱
node scripts/sprint-board.mjs update --id AP-001 --state "Failed" \
  --failure-type review --attempted "..." --hypothesis "..."
node scripts/sprint-board.mjs pitfall --task AP-001 \
  --failure-type review --attempted "..." --hypothesis "..."
```

---

## 停止条件

遇以下情况停止并等待人类：
1. 任务清单为空
2. 同一任务失败 3 次
3. 需要外部资源
4. 高影响架构决策
5. 破坏性操作

记录停止原因到 `sprint-state.json` 和 `run-journal.md`。

---

## 启动检查清单

- [ ] `.va-auto-pilot/sprint-state.json` 存在且 backlog 已填充
- [ ] `docs/todo/sprint.md` 可通过 CLI 渲染
- [ ] `docs/todo/human-board.md` 存在
- [ ] `docs/todo/run-journal.md` 存在
- [ ] `pnpm run check:all` 可运行
- [ ] `test-flows/` 下至少有一个文件

全部通过后开始循环。
