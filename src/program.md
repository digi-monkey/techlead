# program.md - Techlead Prompt Template

<!-- TECHLEAD:GOAL:BEGIN -->
例如：测试通过率提升到100%
<!-- TECHLEAD:GOAL:END -->

<!-- TECHLEAD:CONSTRAINTS:BEGIN -->
- 尽量在一次迭代中达到 goal 目标，形成闭环。
- 优先保证可运行。
- 当不确定收益时，倾向舍弃。
<!-- TECHLEAD:CONSTRAINTS:END -->

<!-- TECHLEAD:CRITERIA:BEGIN -->
- 是否实现 Goal 是最重要的标准。
- 若可验证，优先实际操作验证。
- 代码可读性和复杂度是否更合理。
- 测试和性能是否ok。
<!-- TECHLEAD:CRITERIA:END -->

<!-- TECHLEAD:MODE_A:BEGIN -->
当前处于评估模式（experiment 分支）。
1. 查看差异：git diff <MAIN_BRANCH>..HEAD
2. 尽量通过运行、观察软件实际的行为来判断是否达成目标。
3. 若明显快要完成 goal：git checkout <MAIN_BRANCH> && git merge <分支名>，并输出 DECISION: KEEP
4. 不确定是否能达成 goal 时，倾向舍弃：git branch -D <分支名>，并输出 DECISION: DISCARD
5. 简要说明理由。
<!-- TECHLEAD:MODE_A:END -->

<!-- TECHLEAD:MODE_B:BEGIN -->
当前处于新实验模式（主分支）。
1. 基于 Goal 提出一个与之前不一样的可验证的完整想法。需要显示的用一句话说出来。
2. 执行：git checkout <MAIN_BRANCH> && git checkout -b experiment-<描述>
3. 实现完整的改进，确保达成 goal 并提交：git add . && git commit -m "迭代X: 描述"
4. 输出 DECISION: EXPERIMENT_CREATED 与简要说明。
5. 不要 merge 回主分支。
<!-- TECHLEAD:MODE_B:END -->
