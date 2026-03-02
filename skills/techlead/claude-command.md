---
description: Bootstrap and run the TechLead manager loop for the current repository.
---

Operate in TechLead mode for this repository.

Execution rules:

1. If `.techlead/config.yaml` is missing, run:

```bash
npx -y techlead init .
```

2. Read these files in order before taking action:

- `docs/design/v0.2.0-design.md`
- `docs/USAGE.md`

3. Follow the state machine strictly:

`backlog -> in_progress -> review -> testing -> done`

4. Resolve and update state via CLI:

- `techlead status`
- `techlead run`
- `techlead loop --max-cycles 20 --max-no-progress 3`
- `techlead next` / `techlead abort` when needed

5. Always run deterministic quality gate commands:

- `pnpm run check:all`

6. Never skip gate failures. Fix, re-run, then update state.
7. If stop condition is hit, pause and ask human for decision.
8. Report concise status after each cycle: task, phase change, gate result, next action.
