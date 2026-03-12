# program.md - OpenCode 持续迭代配置

## Goal
[在这里描述项目目标，纯文本即可]
示例：优化数据处理脚本的性能，使其能够处理更大的数据集而不内存溢出。

## 迭代流程

### Step 1: 了解项目
- 读取本文件理解 goal
- 查看项目结构和当前代码
- 查看 git log 了解已有工作

### Step 2: 评估当前工作
检查当前 experiment-* 分支的工作：
- `git diff master..experiment-xxx` 查看改动
- 判断这些改动对 goal 是否有帮助
- [可选] 跑测试验证

### Step 3: 决策
```
IF 改动有帮助（代码更清晰、性能更好、更可靠）：
  → 保留：git checkout master && git merge experiment-xxx
ELSE：
  → 舍弃：git branch -D experiment-xxx
```

### Step 4: 开始新一轮
1. 确保在 master: `git checkout master`
2. 基于 goal 和已有工作，提出新想法
3. 创建新分支: `git checkout -b experiment-{描述}`
4. 动手实现，commit 到当前分支
5. **不要 merge 到 master**，留给下一轮评估

### Step 5: 循环
- 回到 Step 1，开始新一轮迭代
- 计数器 +1
- 如果达到 max_iterations，停止并报告总结

## 分支命名规范
- 格式: `experiment-{简短描述}`
- 描述由 AI 根据工作内容生成（kebab-case）
- 长度控制在 3-5 个词
- 示例: experiment-optimize-memory, experiment-add-caching

## 终止条件
- 最大迭代次数: 20
- 或者用户手动停止 (Ctrl+C)

## 评估标准
结合以下两点自主判断：

**主观评估**：
- 代码是否更清晰易读？
- 是否更接近 goal？
- 复杂度是否合理（不引入过度工程）？

**客观验证**：[可选]
- 如果有测试，测试是否通过？
- 如果可以测量，性能是否有改善？

**决策原则**：
- 当不确定时，宁可舍弃也不要保留可能的问题代码
- 简单的改进 > 复杂的改进（如果效果相同）
- 保持代码可工作是第一优先级

## 当前状态
- 迭代计数: 0
- 上次保留的分支: N/A
- 最佳改进: N/A
