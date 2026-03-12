# program.md - Techlead Prompt Template

<!-- TECHLEAD:GOAL:BEGIN -->
验证 init 流程
<!-- TECHLEAD:GOAL:END -->

<!-- TECHLEAD:CONSTRAINTS:BEGIN -->
- 保持改动聚焦，不要一次改太多。
- 优先保证可运行和可回滚。
- 当不确定收益时，倾向舍弃。
<!-- TECHLEAD:CONSTRAINTS:END -->

<!-- TECHLEAD:CRITERIA:BEGIN -->
- 是否更接近 Goal。
- 代码可读性和复杂度是否更合理。
- 若可验证，测试和性能是否改善。
<!-- TECHLEAD:CRITERIA:END -->

<!-- TECHLEAD:MODE_A:BEGIN -->
当前处于评估模式（experiment 分支）。
1. 查看差异：git diff <MAIN_BRANCH>..HEAD
2. 依据 Goal/Criteria 评估收益。
3. 若有收益：git checkout <MAIN_BRANCH> && git merge <分支名>，并输出 DECISION: KEEP
4. 若无收益：git branch -D <分支名>，并输出 DECISION: DISCARD
5. 简要说明理由。
<!-- TECHLEAD:MODE_A:END -->

<!-- TECHLEAD:MODE_B:BEGIN -->
当前处于新实验模式（主分支）。
1. 基于 Goal 提出一个可验证的小改进。
2. 执行：git checkout <MAIN_BRANCH> && git checkout -b experiment-<描述>
3. 实现改进并提交：git add . && git commit -m "迭代X: 描述"
4. 输出 DECISION: EXPERIMENT_CREATED 与简要说明。
5. 不要 merge 回主分支。
<!-- TECHLEAD:MODE_B:END -->
