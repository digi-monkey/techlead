# Task Execution Timeline & Review Visibility Plan

This document outlines the detailed implementation plan (Option 2) to increase the visibility of `acpx` task executions in the frontend, providing users with a comprehensive timeline and review comments.

## Background & Goal

Currently, the `acpx` execution runs as a backend child process. The frontend simply sees the task transition from `pending` -> `running` -> `done`/`failed`. While task events and reviews are recorded in the SQLite database, the frontend does not render them. The goal is to build a rich timeline UI that displays granular execution progress and surfaces AI review commments seamlessly.

## Proposed Changes

---

### Backend (Event Interception & Parsing)

During `acpx` execution, we will enhance the process to emit fine-grained progression events rather than just blocking synchronously.

#### [MODIFY] `src/providers/acpx_provider.zig`
- Augment the `execAcpx` function's `stdout` reading loop.
- Intercept key state prefixes output by `acpx` (e.g., `[thinking]`, `[tool_call]`, `[client]`).
- Push these state changes into the SQLite task store as new `TaskEvent`s (e.g., event type `task.acpx.progress`, payload containing the log segment).
- *Note:* We must throttle event creation (e.g., only create a new DB event every few seconds or on major state boundaries) to avoid spamming the SQLite store.

#### [MODIFY] `src/storage/sqlite_task_store.zig` (if needed)
- Ensure that `appendTaskEvent` can handle high-frequency insertions safely (which it currently does nicely via mutexes). 

---

### Frontend (Timeline UI & Data Binding)

The UI will be overhauled to present a vertically scrolling or side-panel "Task Timeline".

#### [MODIFY] `web/observe-ui/src/views/TaskPoolView.tsx` (or new component `TaskTimeline.tsx`)
- Given that the `getTaskDetailJson` API already bundles `events: TaskPoolEvent[]` and `latest_reviews: TaskReviewSummary[]`, we will create a dedicated `TaskTimeline` sub-component.
- **Progress Events**: Map the `task.acpx.progress`, `task.running`, `task.done` events over a visual timeline tree (similar to GitHub Actions logs).
- **Review Events Display**: For `task.review.opened`, `task.review.approved`, `task.review.changes_requested`, parse the `payload_text` (or map directly from the `latest_reviews` array). 
- **Review Summary UI**: Highlight the `summary` and `blockers` array directly in the UI. If a task failed code review and entered a retry loop, users will see the "AI Code Review Comments" (The precise suggestions and blockers) inline within the timeline.

## Open Questions

> [!WARNING]
> **Throttling SQLite Writes**: `acpx` can print a lot of characters during `[thinking]` states. Should we only intercept major milestones (e.g., `[tool_call] exec` and `[done]`) instead of capturing every streaming line into the database?

> [!IMPORTANT]  
> **UI Layout Approach**: Where should the timeline be displayed? We could expand the existing "Task Card" downwards when clicked, or place it on a Sliding Sidebar when the user inspects a specific running task. Let me know your preference!

## Verification Plan

### Automated Tests
- N/A for UI display logic. The backend Zig event emission can be tested via `zig build test`.

### Manual Verification
1. Create a task via the new UI, initiating the `acpx` draft and execution.
2. Observe the frontend polling loop fetching the `events` field.
3. Validate that the UI dynamically updates to show `[thinking]` and `[tool_call]` steps.
4. If a review fails, confirm that the review blocker comments correctly appear in the timeline payload blocks.
