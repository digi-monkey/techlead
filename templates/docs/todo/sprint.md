# Sprint Board

> Last updated: {{DATE_ISO}} by TechLead
> Generated from `.techlead/sprint-state.json` via `node scripts/sprint-board.mjs render`.
>
> Rules:
> - Machine source of truth: `.techlead/sprint-state.json`
> - Human-readable projection: `docs/todo/sprint.md`
> - One primary task at a time in `In Progress`; independent tracks may run in parallel
> - Task ID format: `{{PROJECT_PREFIX}}-{3-digit number}`
> - Priority: P0(blocking) / P1(important) / P2(routine) / P3(optimization)
>
> State flow:
> ```
> Backlog -> In Progress -> Review -> Testing -> Done
>                  ^                     |
>                  +------ Failed <------+
> ```

---

## In Progress
| ID | Task | Owner | Started | Notes |
|----|------|-------|---------|-------|
| - | - | - | - | - |

## Failed
| ID | Task | Fail Count | Reason | Last Failed |
|----|------|------------|--------|-------------|
| - | - | - | - | - |

## Review
| ID | Task | Implementer | Security | QA | Domain | Architect |
|----|------|-------------|----------|----|--------|-----------|
| - | - | - | - | - | - | - |

## Testing
| ID | Task | Test Flow | MUST Pass Rate | SHOULD Pass Rate |
|----|------|-----------|----------------|------------------|
| - | - | - | - | - |

## Done
| ID | Task | Completed | Verification |
|----|------|-----------|--------------|
| - | - | - | - |

## Backlog
| Priority | ID | Task | Depends On | Owner | Source |
|----------|----|------|------------|-------|--------|
| P1 | {{PROJECT_PREFIX}}-001 | Replace with your first deliverable | - | TechLead | bootstrap |
