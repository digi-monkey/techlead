# VA Auto-Pilot Protocol

> Behavioral specification for autonomous multi-agent project execution.
> Read this before running a VA Auto-Pilot loop.

---

## Core Principles

1. You are the manager of outcomes, not the implementer of steps.
2. `.va-auto-pilot/sprint-state.json` is the machine task source of truth.
3. `docs/todo/sprint.md` is a generated board view (`node scripts/sprint-board.mjs render`).
4. `docs/todo/run-journal.md` is append-only execution memory.
5. Execute one primary task per cycle; optional parallel tracks are allowed when independent.
6. `docs/todo/human-board.md` always overrides automatic decisions.
7. Goal-first delegation: define objective + constraints + acceptance. Do not prescribe implementation steps.
8. CLI-first execution: prefer deterministic commands over manual operations.
9. Frontier model first: use the strongest available model for high-impact tasks.
10. Closed-loop quality is mandatory: build -> review -> acceptance -> commit.
11. Perspectives emerge from constraints and anchors — never from fixed role lists. Wrong perspectives mean wrong anchors; change both.

---

## State Machine

```
Backlog -> In Progress -> Review -> Testing -> Done
                 ^                     |
                 +------ Failed <------+
```

### State Semantics

- `Backlog`: not started
- `In Progress`: implementation running
- `Review`: implementation done, quality review pending
- `Testing`: review passed, acceptance tests running
- `Failed`: acceptance failed or blocking issue
- `Done`: all gates passed and committed

---

## Human Board Contract

At the start of each cycle:

1. Read `docs/todo/human-board.md`.
2. Execute unchecked items under `Instructions` immediately.
3. Fold `Feedback` into backlog updates or current task context.
4. Use `Direction` for priority decisions.
5. Mark handled instruction items as `[x]`.

Never delete human-written content.

---

## Operational Memory Contract

At the start of each cycle:

1. Read `docs/todo/run-journal.md`.
2. Check `Codebase Signals` first.
3. Reuse existing signals before inventing new conventions.
4. Append one execution entry at the end of each cycle.

---

## Decision Loop

```
Read human-board.md
  -> unhandled instructions? execute now
Read run-journal.md
Resolve next task via CLI
  -> node scripts/sprint-board.mjs next
  -> optional: node scripts/sprint-board.mjs plan --json --max-parallel 3
  -> has Failed task? fix + retest
  -> has Testing task? run acceptance
  -> has Review task? run review
  -> has In Progress task? continue
  -> has Backlog task? start highest priority
  -> none? mark Sprint Complete and stop
```

### Task Pick Strategy

- Priority order: P0 > P1 > P2 > P3
- Tie-breaker: earliest creation date
- Skip tasks requiring unavailable external resources
- Use CLI output as execution trigger, not manual guesswork

---

## Concurrency Contract

Parallel execution is encouraged when tasks are independent.

Rules:

1. Let the manager agent decide concurrency dynamically at runtime.
2. Parallelize where dependency graph allows; serialize where it does not.
3. Use quality gates as synchronization barriers before state promotion.
4. Never bypass acceptance to "speed up" parallel tracks.
5. Record concurrency decisions and tradeoffs in `run-journal.md`.

When planning concurrency, produce a machine-readable plan:

```json
{
  "primaryTaskId": "AP-001",
  "parallelTracks": ["AP-002", "AP-003"],
  "dependencyGraph": {
    "AP-001": [],
    "AP-002": [],
    "AP-003": ["AP-002"]
  },
  "syncPoints": ["quality-gates"]
}
```

Execution path preference:

1. Default: model-native tool orchestration + gate synchronization.
2. Experimental opt-in only (explicit human request): `node scripts/va-parallel-runner.mjs spawn --plan-file ...`.

---

## State Update Contract

Use deterministic updates only:

```bash
node scripts/sprint-board.mjs update --id AP-001 --state "In Progress"
node scripts/sprint-board.mjs journal --task AP-001 --summary "what changed"
```

Rules:

1. Do not hand-edit generated rows in `docs/todo/sprint.md`.
2. Update `.va-auto-pilot/sprint-state.json` through CLI whenever possible.
3. Keep `run-journal.md` append-only.

---

## Delegation Contract

Every implementation delegation must include:

1. Task ID and objective
2. Relevant file paths
3. Hard constraints (architecture, security, naming, limits)
4. Completion gates (`npm run check:all`)
5. A no-how clause: do not prescribe implementation steps

---

## Quality Gates

### Gate 1: Build and Static Quality

```bash
npm run check:all
```

### Gate 2: Code Review

```bash
codex review --uncommitted
```

Review findings policy:

- `CRITICAL` / `BUG` / `VIOLATION`: must fix and re-review
- style-only nits: optional, non-blocking

### Gate 3: Acceptance

```bash
npm run validate:distribution
```

Pass criteria:

- MUST assertions: 100% pass
- SHOULD assertions: >= 80% pass

---

## Multi-Perspective Review

### Design Philosophy

Perspectives are not predetermined roles — they are views from specific constraint intersections that expose distinct failure modes. The right perspectives emerge from identifying real constraints and anchors first. A fixed list of roles is valid only if each role was derived from the constraint and anchor analysis for this task and each exposes failure modes the others miss.

When a review stall occurs, the problem is most often in anchor or perspective selection, not the implementation. See [When Review Cycles Stall](#when-review-cycles-stall) for the bounded procedure governing anchor revision.

### Dynamic Perspective Selection

The model determines which perspectives to apply for each task.

**Step 1: Identify real constraints**

What hard boundaries govern this task? Examples: security invariants, performance budgets, API contracts, backward compatibility, data privacy, state-machine integrity.

**Step 2: Identify anchors**

What must remain true after this change? An anchor is the invariant that cannot be violated. Anchor selection determines whether subsequent analysis converges. A weak or misspecified anchor is the most common cause of false assurance.

> **Guard**: If no clear anchor can be identified after applying the constraint list, stop and request human clarification before beginning review. Do not start a review cycle without a confirmed anchor.

**Step 3: Let perspectives emerge**

Given the constraints and anchors, ask: which expert views would expose the most critical failure modes? Perspectives must be specific to this task, not generic role labels. Each must probe failure modes the others miss.

**Perspective count heuristic**: Start with 2. Add one perspective for each: external API surface affected, security boundary crossed, persistent state modified, multiple components touched. Cap at 5.

Examples — table entries are category-level sketches; instantiate each with task-specific framing in the actual review prompt (e.g., not "Threat modeler" but "Threat modeler focused on the new token refresh endpoint's exposure to replay attacks"):

| Change type | Possible perspectives |
|-------------|----------------------|
| CLI tool update | Correctness auditor, API consumer, Operator (failure modes) |
| Auth/security change | Threat modeler, Compliance reviewer, Regression auditor |
| Data pipeline | Data integrity auditor, Privacy/compliance, SRE |
| UX feature | Accessibility engineer, Performance auditor, Product consistency |
| Protocol/spec change | Adopter (downstream impact), Implementer (ambiguity), Adversarial reader |

**Step 4: Anchor-grounded review prompt**

Every review prompt must explicitly state:

1. What changed and why (the git diff scope and design rationale)
2. The hard constraints that apply
3. The anchor — the invariant that must hold
4. The reviewer's specific perspective and the concrete failure modes they are probing

### Review Completion Condition

Review is complete when all of the following are true:
- All selected perspectives have been applied
- No `CRITICAL`, `BUG`, or `ANCHOR VIOLATION` findings remain open
- Every `WARNING` / `RISK` finding has a recorded disposition (fixed or explicitly accepted with rationale)

**Iteration cap**: If `CRITICAL` findings persist after 3 complete review cycles (each cycle = all perspectives re-applied), stop and escalate to human.

### Finding Policy

- `CRITICAL` / `BUG` / `ANCHOR VIOLATION`: must fix, then re-run the full perspective set before proceeding
- `WARNING` / `RISK`: record and decide — fix or document accepted risk
- Style / preference: non-blocking

### When Review Cycles Stall

If the review completion condition is met but the model cannot confirm it with confidence:

1. Re-examine the anchor — it may be too weak or misspecified
2. Re-examine the constraint set — a missing constraint is the most common source of false assurance
3. Add a perspective that directly challenges the anchor
4. If the completion condition still cannot be confirmed after three re-anchoring attempts, treat remaining uncertainty as irreducible and escalate to human

---

## Commit Policy

Commit immediately after required gates pass.

Rules:

1. One completed task = one commit (parallel tracks commit independently after gates)
2. Stage only task-related files
3. Commit message describes intent
4. Never force push unless explicitly approved
5. Never commit secrets

---

## Stop Conditions

Stop and wait for human when:

1. Backlog is empty
2. Same task failed three times
3. External resources are required
4. High-impact architecture decision is needed
5. Destructive operation is required

Record stop reason in `sprint-state.json` and `run-journal.md`.

---

## Bootstrap Checklist

- [ ] `.va-auto-pilot/sprint-state.json` exists and backlog is populated
- [ ] `docs/todo/sprint.md` can be rendered via `scripts/sprint-board.mjs`
- [ ] `docs/todo/human-board.md` exists
- [ ] `docs/todo/run-journal.md` exists
- [ ] `scripts/test-runner.ts` runs
- [ ] at least one file under `test-flows/`
- [ ] review command is runnable

For public distribution repositories, also verify:

- [ ] `website/` exists and reflects the current protocol
- [ ] `skills/va-auto-pilot/` exists and links are shareable
- [ ] GitHub Pages workflow is present

Once all required items are true, start the loop.
