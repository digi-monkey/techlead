# TechLead Protocol (Single CLI)

> Behavioral spec for the v0.2.0 single-CLI workflow.

## Core Principles

1. `techlead` is the only runtime entrypoint.
2. Task truth lives in `.techlead/tasks/*/task.json`.
3. Progress is phase-based: `plan -> exec -> review -> test -> completed`.
4. Status is queue-based: `backlog -> in_progress -> review -> testing -> done | failed`.
5. Quality checks are deterministic commands, never self-certified text.

## Operating Loop

1. Initialize once: `techlead init`
2. Create tasks: `techlead add "<goal>"`
3. Inspect queue: `techlead list` / `techlead status`
4. Execute one cycle: `techlead run`
5. Execute continuously: `techlead loop --max-cycles 20 --max-no-progress 3`

## Gate Rules

1. Before moving to review, run quality gate (`pnpm run check:all` when available).
2. If gate fails, task remains in exec and must be fixed first.
3. Review/Test CRITICAL results block completion and send task back to exec.
4. Stop after repeated no-progress or retry-limit hits; require human decision.

## Human Override

1. Humans can reprioritize by adding/removing tasks.
2. Humans can switch focus with `techlead next`.
3. Humans can stop current task with `techlead abort`.

## Completion Contract

A task can be marked `done` only when:

1. Execution work is complete.
2. Quality gate passes.
3. Adversarial review is non-critical.
4. Adversarial test is non-critical.
