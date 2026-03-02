# Sprint 系统可迁移思想（仅记录，不改 Sprint 本体）

## 目的

本文档仅用于沉淀原 Sprint 子系统（已移除）与 `docs/operations/techlead-protocol.md` 的历史版本中，值得迁移到 v0.2.0 CLI (`src/cli.ts`) 的设计思想。

**范围声明：**
- 不修改 Sprint 系统现有状态机/脚本/测试。
- 不引入 AP-xxx 与 T-xxx 的状态互通。
- 仅作为 v0.2.0 后续迭代的设计输入。

---

## 候选思想（按优先级）

### P0: Bounded Retry + Escalation（有界重试与升级）
- 思想：每个关键阶段限制重试次数，超过阈值立即停止自动化并升级到人工处理。
- 价值：避免夜间无限循环烧 token。
- v0.2.0 落点：
  - `loop` 中对 review/test 失败次数设置硬上限。
  - 超限后写入任务日志并标记 `failed`。

### P0: Fresh-Context Adversarial Gate（新上下文对抗审查）
- 思想：审查者尽量不继承实现上下文，只基于 diff 与结果进行独立判定。
- 价值：降低“自己验证自己”的偏差。
- v0.2.0 落点：
  - 保持 review/test 阶段的独立 prompt。
  - 强制结构化 verdict 输出，避免自然语言误判。

### P0: Pitfall Compounding（失败知识复用）
- 思想：把失败原因结构化沉淀，后续任务自动注入相关失败经验。
- 价值：同类错误复发率显著下降。
- v0.2.0 落点：
  - 引入 `knowledge/pitfalls.md` 的自动读取与注入。
  - exec prompt 增加“必先处理的失败修复清单”。

### P1: Strategic Decomposition（战略层拆解）
- 思想：面对高层目标，先并行扫描多个维度，再收敛为可执行 backlog。
- 价值：减少任务定义偏差，提升计划完整度。
- v0.2.0 落点：
  - 新增可选的 `decompose` 阶段（仅规划，不执行代码）。
  - 输出结构化任务建议供 `add` 批量导入。

### P1: Deterministic Quality Gates（确定性质量门禁）
- 思想：必须通过明确 CLI 命令（如 `check:all`）才能推进状态。
- 价值：模型不可“口头宣称完成”。
- v0.2.0 落点：
  - 保持 exec -> review 之前的硬门禁。
  - 失败日志回灌到下一轮执行 prompt。

### P2: Human-on-the-loop Hooks（人在环上）
- 思想：默认自动执行，但在关键停机点可人工介入并恢复。
- 价值：无人值守可持续，同时可控。
- v0.2.0 落点：
  - 约定人工恢复动作（例如 reset fail count / 手动状态修复）。
  - 文档化“夜间运行 -> 次日恢复”的 SOP。

---

## 不迁移项（当前阶段）

- Sprint 的 AP-xxx 状态与 v0.2.0 的 T-xxx 状态打通。
- Sprint 并行 runner 直接接入 v0.2.0 CLI 主循环。
- 将 `sprint-board` 的全部命令镜像到 `techlead` 主 CLI。

原因：当前目标是先跑通单任务自动维护闭环，避免系统耦合度过早上升。

---

## 建议迭代顺序

1. **先做**：失败原因自动注入下一轮 exec（Pitfall 最小闭环）。
2. **再做**：review/test 的 verdict 强约束与统一解析。
3. **后做**：战略拆解（decompose）与批量导入任务。
4. **最后**：评估是否需要与 Sprint 体系互操作。
