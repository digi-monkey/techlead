# 增量 Review 工作流设计方案 (Incremental Review Workflow)

本方案旨在解决 Techlead 在 Projects 模式下，因 Review 未通过导致任务每次重试都会“删库跑路”（强制 `git checkout -B` 切回基线分支并完全重写）所带来的问题。

## 1. 背景与痛点
当前的“悲观重试策略”适合于基础架构完全错误的情况。但在实际工程中，大量 Review 驳回仅属于**细节修复**（如变量命名错误、漏掉部分单测、小概率边界条件未处理）。
强制全盘重写会导致：
- 抹杀此前 AI 已经完成的极有价值的代码工作。
- 极大增加引入全新代码 Bug 的概率（缺乏稳定性）。
- 带来不必要的巨大上下文消耗和 Token 浪费。

## 2. 演进方案：带兜底的增量提交 (Incremental with Fallback)

我们期望通过模拟人类 Pull Request 的持续迭代（Continuous Commit）习惯，在已有工作基础上叠加修改，同时利用 Git 的特性保留廉价的错误兜底能力。

### 2.1 Git 状态树管理调整
- 废除单任务轮次多分支（如 `task-123-v1` / `v2`），统一缩减为一个长尾分支 `task-[id]`。
- **增量迭代**：如果不需要重置，重试时仅执行 `git checkout task-[id]` 或者 `git checkout -b task-[id] main`（如果是全新轮次）。
- **兜底重置 (Fallback)**：如果需要重写，直接执行 `git checkout -B task-[id] main` 进行强制还原，抹除全部烂代码。

### 2.2 确定 Fallback (重写) 的判定策略
可采用以下两种策略组合或其中之一：

- **策略 A (Reviewer 一票否决制 - 推荐)**：
  调整 Review Agent 的 JSON 协议，增加 `require_rewrite: boolean` 字段。
  只有当 Reviewer 判定现有架构严重跑偏、难以修正时，才强硬标记 `true`，触发后端的重置动作。
  
- **策略 B (阈值法兜底)**：
  当 `review_round` 堆叠过多（例如 > 3）时，系统自动判定当前增量流已变成难以挽回的“屎山”，强制触发 `fallback` 将分支 Reset 为 `main`。

### 2.3 Agent 侧的 Prompt 响应支持
为了配合增量修改，针对 Implementer Agent 的系统 Prompt 需要支持双态：
- **新生模式**：按原始逻辑进行。
- **修补模式 (Refine Mode)**：向 Implementer 强调“这已经是你的第 N 次提交，**请保留已存在的正确逻辑，仅严格针对当前的 Review Feedback 进行精确打补丁修改**。”

## 3. 实现节奏与影响面
- **数据结构**：无需新增复杂的持久化状态，重置逻辑纯依赖执行时的 Git 树重组。
- **控制面**：在 Pool Service 的 `processClaimedTask` 中拆分 Branch Checkout 逻辑。
- **模型提效**：有望大幅提高简单 Review 修复环节的过签率并缩短耗时。
