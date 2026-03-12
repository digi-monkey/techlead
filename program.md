# program.md - OpenCode 持续迭代配置

## Goal
[在这里描述项目目标，纯文本即可]
示例：优化数据处理脚本的性能，使其能够处理更大的数据集而不内存溢出。

## 系统说明

这个 program.md 由 `iterate.sh` 脚本调用。脚本负责：
- 控制总迭代次数
- 每次迭代都通过 curl 调用新的 OpenCode session
- 保持上下文干净

你（AI）只需要关注**单次迭代**的任务：
- 要么评估现有的 experiment 分支
- 要么创建新的 experiment 分支并工作

## 单次迭代流程

### 情况 A：当前在 experiment-* 分支（需要评估）

**你的任务**：评估这个分支的工作是否值得保留

1. **查看改动**：`git diff master..$(git branch --show-current)`
2. **评估价值**：这个改动对 Goal 有帮助吗？
   - 代码更清晰？
   - 性能更好？
   - 更可靠？
   - [可选] 跑测试验证
3. **做出决策**：
   ```bash
   # 如果有帮助：
   git checkout master
   git merge $(git branch --show-current)
   echo "DECISION: KEEP"
   
   # 如果没帮助：
   git branch -D $(git branch --show-current)
   echo "DECISION: DISCARD"
   ```
4. **说明理由**：简要解释为什么保留或舍弃

### 情况 B：当前在 master 分支（需要开始新实验）

**你的任务**：提出并实施一个改进想法

1. **分析现状**：
   - 阅读当前代码
   - 查看 git log 了解已有工作
   - 思考：如何更接近 Goal？

2. **提出想法**：基于分析，提出具体的改进方向
   - 优化某个算法？
   - 重构某个函数？
   - 添加错误处理？
   - 改进数据结构？

3. **创建分支**：
   ```bash
   git checkout -b experiment-{简短描述}
   # 示例: experiment-optimize-memory, experiment-add-caching
   ```

4. **实施改进**：
   - 编辑代码实现你的想法
   - 保持改动聚焦（不要一次改太多）
   - 确保代码能运行

5. **提交工作**：
   ```bash
   git add .
   git commit -m "改进: {你的描述}"
   echo "DECISION: EXPERIMENT_CREATED"
   ```

6. **简要说明**：描述你做了什么改进

## 重要约束

**不要**：
- 不要 merge 到 master（留给下一次迭代评估）
- 不要一次做太多改动（保持可审查）
- 不要删除其他 experiment 分支

**要**：
- 保持代码可运行
- 如果无法确定价值，宁可舍弃也不要保留问题代码
- 简单的改进 > 复杂的改进

## 评估标准

**主观判断**：
- 代码是否更清晰易读？
- 是否更接近 Goal？
- 复杂度是否合理？

**客观验证**（可选）：
- 如果有测试，测试是否通过？
- 如果可以测量，性能是否有改善？

**决策原则**：当不确定时，舍弃。质量 > 数量。
