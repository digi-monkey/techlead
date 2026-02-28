---
name: techlead
description: Bootstrap and operate the TechLead engineering loop in any repository. Use when users ask for autonomous delivery flow, sprint/human boards, quality gates, or /techlead mode.
metadata:
  version: 2.0.0
---

# TechLead Skill

## Trigger

Use this skill when the user asks to:

- initialize an autonomous engineering workflow
- adopt sprint state machine + human override board
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
- `.techlead/sprint-state.json`
- `docs/todo/sprint.md`
- `docs/todo/human-board.md`
- `docs/todo/run-journal.md`
- `docs/operations/techlead-protocol.md`

5. Ensure quality gates are runnable:

- `qualityGate.buildCommand`
- `qualityGate.reviewCommand`
- `qualityGate.acceptanceTestCommand`

6. Start the loop (primary task + optional parallel tracks):

- read `human-board.md`
- read `run-journal.md` (`Codebase Signals` first)
- resolve next action with `node scripts/sprint-board.mjs next`
- produce optional parallel plan with `node scripts/sprint-board.mjs plan --json --max-parallel 3`
- execute parallel tracks via model-native parallel tool calls by default
- use `scripts/techlead-parallel-runner.mjs` only if the user explicitly asks for the experimental external runner
- execute current task by objective + constraints (no step-by-step instructions)
- run build/review/acceptance gates
- update state with `node scripts/sprint-board.mjs update ...`
- append memory with `node scripts/sprint-board.mjs journal ...`

## Output Contract

When completing a run, always report:

1. what was scaffolded or changed
2. active gate commands
3. next immediate task from sprint state
4. any stop condition requiring human decision
