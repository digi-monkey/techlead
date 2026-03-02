---
name: techlead
description: Bootstrap and operate the TechLead engineering loop in any repository. Use when users ask for autonomous delivery flow, quality gates, or /techlead mode.
metadata:
  version: 2.0.0
---

# TechLead Skill

## Trigger

Use this skill when the user asks to:

- initialize an autonomous engineering workflow
- adopt the task state machine in `.techlead/tasks/*/task.json`
- enforce build/review/acceptance gates
- run a manager-style multi-agent loop
- enable `/techlead` operating mode

## Workflow

1. Confirm target repository root (default: current directory).
2. Install scaffold:

```bash
npx -y techlead init <target-dir>
```

3. If npm package is unavailable, run fallback bootstrap:

```bash
tmp="$(mktemp -d)"
git clone --depth 1 https://github.com/digi-monkey/techlead "$tmp/techlead"
cd "$tmp/techlead" && pnpm install && pnpm run build
node "$tmp/techlead/dist/cli.js" init <target-dir>
```

4. Read and align these files to the target project:

- `.techlead/config.yaml`
- `docs/USAGE.md`
- `docs/design/v0.2.0-design.md`

5. Ensure quality gates are runnable:

- `qualityGate.buildCommand`
- `qualityGate.reviewCommand`
- `qualityGate.acceptanceTestCommand`

6. Start the loop:

- create tasks with `techlead add`
- inspect state with `techlead list` and `techlead status`
- advance execution with `techlead run` (single cycle) or `techlead loop` (continuous)
- run deterministic quality gate command(s)

## Output Contract

When completing a run, always report:

1. what was scaffolded or changed
2. active gate commands
3. next immediate task from task queue
4. any stop condition requiring human decision
