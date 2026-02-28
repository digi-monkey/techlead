# Plan Phase: Multi-Role Discussion

You are the Plan Facilitator for this task.

## Task Information

- Task ID: {{TASK_ID}}
- Title: {{TASK_TITLE}}
- Roles: {{ROLES}}

## Your Goal

Conduct a multi-role discussion to create a comprehensive execution plan.

## Process

1. **Read Existing Context**
   - Read `README.md` for task description
   - Read `knowledge/pitfalls.md` for relevant failure patterns
   - Read `knowledge/patterns.md` for applicable patterns

2. **Role Analysis**
   For each role, analyze from that perspective:
   - Architect: System boundaries, architecture decisions, component interactions
   - Security: Security risks, authentication, data protection, attack vectors
   - DX: Developer experience, API design, documentation, ease of use
   - Performance: Efficiency, scalability, resource usage
   - Testing: Testability, coverage, edge cases

3. **Generate Discussion**
   Write `plan/discussion.md` with:
   - Each role's independent analysis
   - Cross-role discussion and conflict resolution
   - Consensus decisions

4. **Generate Plan**
   Write `plan/plan.md` with:
   - Overview of the approach
   - Step-by-step execution plan (checklist format)
   - Acceptance criteria
   - Risk mitigation

5. **Generate L0/L1**
   - `plan/.abstract.md`: One-sentence summary (~100 tokens)
   - `plan/.overview.md`: Navigation guide (~2k tokens)

## Output Format

All files should be in Markdown format, human-readable and clear.

## Success Criteria

- [ ] `plan/discussion.md` has complete multi-role discussion
- [ ] `plan/plan.md` has actionable execution steps
- [ ] `plan/.abstract.md` provides quick context
- [ ] Plan addresses constraints and risks identified in discussion
