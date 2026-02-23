# Sprint Board

> Last updated: 2026-02-23 by VA Auto-Pilot
> Generated from `.va-auto-pilot/sprint-state.json` via `node scripts/sprint-board.mjs render`.
>
> Rules:
> - Machine source of truth: `.va-auto-pilot/sprint-state.json`
> - Human-readable projection: `docs/todo/sprint.md`
> - One primary task at a time in `In Progress`; independent tracks may run in parallel
> - Task ID format: `AP-{3-digit number}`
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
| AP-004 | Add unit test suite for sprint-board.mjs pure functions | - | 2026-02-23 | - |
| AP-008 | Resolve templates/ dual-copy maintenance burden | - | 2026-02-23 | - |

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
| AP-001 | Upgrade multi-perspective review to dynamic perspective selection | 2026-02-23 | Two cross-reviews (adversarial + protocol designer), 6 CRITICALs resolved, templates synced |
| AP-003 | Add sprint-board.mjs add command to create tasks via CLI without hand-editing JSON | 2026-02-23 | add command implemented: auto-ID (AP-NNN), validation, depends-on, regex-safe prefix; printHelp updated; templates mirrored; all gates pass |
| AP-006 | Expand test-flows to cover add, update, journal, and next CLI commands | 2026-02-23 | sprint-board-cli.yaml added (9 flows, 18 MUST/3 SHOULD); test-cli-flows.mjs runner with isolated_state/isolated_journal; check:cli-flows added to check:all; all gates pass |
| AP-002 | Fix parseArgv boolean flag regression (--flag value silently dropped) | 2026-02-23 | parseArgv now throws when bool flag is followed by non-flag token; templates mirrored; check:all and validate:distribution pass |
| AP-005 | Replace hand-rolled YAML parser with yaml package in sprint-utils.mjs | 2026-02-23 | yaml package moved to dependencies; readSprintPathsFromConfig replaced with yaml.parse(); stripYamlValue kept as compat export; templates mirrored; all gates pass |
| AP-007 | Correct 'human-out-of-the-loop' framing to 'human-on-the-loop' across docs and website | 2026-02-23 | docs/human-on-the-loop.md created with updated framing; old file removed; README.md and README.zh.md references updated; all gates pass |

## Backlog
| Priority | ID | Task | Depends On | Owner | Source |
|----------|----|------|------------|-------|--------|
| - | - | - | - | - | - |
