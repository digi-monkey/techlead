#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import {
  nowIso,
  resolveDefaults,
  parseArgv,
  requireOption
} from "./lib/sprint-utils.mjs";

const VALID_STATES = ["Backlog", "In Progress", "Review", "Testing", "Failed", "Done"];
const NEXT_ORDER = ["Failed", "Testing", "Review", "In Progress", "Backlog"];
const PRIORITY_WEIGHT = { P0: 0, P1: 1, P2: 2, P3: 3 };
const DEFAULT_MAX_PARALLEL = 2;

const DEFAULTS = resolveDefaults();

function printHelp() {
  console.log(`sprint-board

Usage:
  node scripts/sprint-board.mjs summary [--state-file <path>]
  node scripts/sprint-board.mjs next [--json] [--state-file <path>]
  node scripts/sprint-board.mjs plan [--json] [--max-parallel <n>] [--state-file <path>]
  node scripts/sprint-board.mjs render [--state-file <path>] [--board-file <path>]
  node scripts/sprint-board.mjs update --id <TASK-ID> [--state <state>] [options]
  node scripts/sprint-board.mjs journal --task <TASK-ID> --summary <text> [options]

Options (update):
  --title <text>
  --priority <P0|P1|P2|P3>
  --owner <text>
  --source <text>
  --verification <text>
  --reason <text>
  --flow <flow-name>
  --must-rate <value>
  --should-rate <value>
  --implementer <text>
  --security <text>
  --qa <text>
  --domain <text>
  --architect <text>
  --note <text>
  --depends-on <ID1,ID2,...>
  --reset-fail-count        Reset failCount to 0 (use after fixing a failed task)

Options (journal):
  --files <comma-separated paths>
  --signals <comma-separated signals>

Global options:
  --max-parallel <n>
  --state-file <path>
  --board-file <path>
  --journal-file <path>
`);
}

function shortDate(raw) {
  if (!raw) return "-";
  return String(raw).slice(0, 10);
}

function escapeCell(value) {
  const input = String(value ?? "").trim();
  if (!input) return "-";
  return input.replaceAll("|", "\\|").replaceAll("\n", "<br>");
}

function sortTasks(tasks) {
  return [...tasks].sort((a, b) => {
    const pA = PRIORITY_WEIGHT[a.priority] ?? 99;
    const pB = PRIORITY_WEIGHT[b.priority] ?? 99;
    if (pA !== pB) return pA - pB;

    const cA = String(a.createdAt ?? "");
    const cB = String(b.createdAt ?? "");
    if (cA !== cB) return cA.localeCompare(cB);

    return String(a.id ?? "").localeCompare(String(b.id ?? ""));
  });
}

function normalizeDependsOn(raw) {
  if (Array.isArray(raw)) {
    return raw.map((item) => String(item ?? "").trim()).filter(Boolean);
  }

  if (typeof raw === "string") {
    return raw
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean);
  }

  return [];
}

function normalizeTask(task) {
  return {
    id: String(task.id ?? ""),
    title: String(task.title ?? ""),
    priority: String(task.priority ?? "P2"),
    state: String(task.state ?? "Backlog"),
    owner: String(task.owner ?? ""),
    source: String(task.source ?? ""),
    createdAt: String(task.createdAt ?? ""),
    startedAt: String(task.startedAt ?? ""),
    completedAt: String(task.completedAt ?? ""),
    lastFailedAt: String(task.lastFailedAt ?? ""),
    failCount: Number(task.failCount ?? 0),
    reason: String(task.reason ?? ""),
    verification: String(task.verification ?? ""),
    notes: String(task.notes ?? ""),
    review: {
      implementer: String(task.review?.implementer ?? ""),
      security: String(task.review?.security ?? ""),
      qa: String(task.review?.qa ?? ""),
      domain: String(task.review?.domain ?? ""),
      architect: String(task.review?.architect ?? "")
    },
    testing: {
      flow: String(task.testing?.flow ?? ""),
      mustPassRate: String(task.testing?.mustPassRate ?? ""),
      shouldPassRate: String(task.testing?.shouldPassRate ?? "")
    },
    dependsOn: normalizeDependsOn(task.dependsOn)
  };
}

function readState(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`State file not found: ${filePath}`);
  }

  const raw = fs.readFileSync(filePath, "utf8");
  const data = JSON.parse(raw);

  if (!Array.isArray(data.tasks)) {
    throw new Error("Invalid state file: tasks must be an array");
  }

  data.tasks = data.tasks.map(normalizeTask);
  return data;
}

function writeState(filePath, data) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(data, null, 2)}\n`, "utf8");
}

function rowsForSection(tasks, columns, mapRow) {
  if (tasks.length === 0) {
    return `| ${columns.map(() => "-").join(" | ")} |`;
  }

  return tasks.map((task) => {
    const values = mapRow(task).map(escapeCell);
    return `| ${values.join(" | ")} |`;
  }).join("\n");
}

function renderBoardMarkdown(state) {
  const date = shortDate(state.updatedAt || nowIso());
  const prefix = escapeCell(state.projectPrefix || "TASK");
  const tasks = sortTasks(state.tasks);

  const inProgress = tasks.filter((task) => task.state === "In Progress");
  const failed = tasks.filter((task) => task.state === "Failed");
  const review = tasks.filter((task) => task.state === "Review");
  const testing = tasks.filter((task) => task.state === "Testing");
  const done = tasks.filter((task) => task.state === "Done");
  const backlog = tasks.filter((task) => task.state === "Backlog");

  return `# Sprint Board

> Last updated: ${date} by VA Auto-Pilot
> Generated from \`.va-auto-pilot/sprint-state.json\` via \`node scripts/sprint-board.mjs render\`.
>
> Rules:
> - Machine source of truth: \`.va-auto-pilot/sprint-state.json\`
> - Human-readable projection: \`docs/todo/sprint.md\`
> - One primary task at a time in \`In Progress\`; independent tracks may run in parallel
> - Task ID format: \`${prefix}-{3-digit number}\`
> - Priority: P0(blocking) / P1(important) / P2(routine) / P3(optimization)
>
> State flow:
> \`\`\`
> Backlog -> In Progress -> Review -> Testing -> Done
>                  ^                     |
>                  +------ Failed <------+
> \`\`\`

---

## In Progress
| ID | Task | Owner | Started | Notes |
|----|------|-------|---------|-------|
${rowsForSection(inProgress, ["ID", "Task", "Owner", "Started", "Notes"], (task) => [task.id, task.title, task.owner, shortDate(task.startedAt), task.notes])}

## Failed
| ID | Task | Fail Count | Reason | Last Failed |
|----|------|------------|--------|-------------|
${rowsForSection(failed, ["ID", "Task", "Fail Count", "Reason", "Last Failed"], (task) => [task.id, task.title, task.failCount, task.reason, shortDate(task.lastFailedAt)])}

## Review
| ID | Task | Implementer | Security | QA | Domain | Architect |
|----|------|-------------|----------|----|--------|-----------|
${rowsForSection(review, ["ID", "Task", "Implementer", "Security", "QA", "Domain", "Architect"], (task) => [task.id, task.title, task.review.implementer, task.review.security, task.review.qa, task.review.domain, task.review.architect])}

## Testing
| ID | Task | Test Flow | MUST Pass Rate | SHOULD Pass Rate |
|----|------|-----------|----------------|------------------|
${rowsForSection(testing, ["ID", "Task", "Test Flow", "MUST Pass Rate", "SHOULD Pass Rate"], (task) => [task.id, task.title, task.testing.flow, task.testing.mustPassRate, task.testing.shouldPassRate])}

## Done
| ID | Task | Completed | Verification |
|----|------|-----------|--------------|
${rowsForSection(done, ["ID", "Task", "Completed", "Verification"], (task) => [task.id, task.title, shortDate(task.completedAt), task.verification])}

## Backlog
| Priority | ID | Task | Depends On | Owner | Source |
|----------|----|------|------------|-------|--------|
${rowsForSection(backlog, ["Priority", "ID", "Task", "Depends On", "Owner", "Source"], (task) => [task.priority, task.id, task.title, task.dependsOn.join(", "), task.owner, task.source])}
`;
}

function writeBoard(boardFile, state) {
  const markdown = renderBoardMarkdown(state);
  fs.mkdirSync(path.dirname(boardFile), { recursive: true });
  fs.writeFileSync(boardFile, markdown, "utf8");
}

/**
 * Detects dependency cycles using DFS.
 *
 * Returns an array of cycle descriptions (empty if no cycles).
 * Each description is a string like "A -> B -> C -> A".
 */
function detectCycles(tasks) {
  const adjById = new Map();
  for (const task of tasks) {
    adjById.set(task.id, task.dependsOn ?? []);
  }

  // 0 = unvisited, 1 = in stack, 2 = done
  const color = new Map();
  const parent = new Map();
  const cycles = [];

  function dfs(nodeId) {
    color.set(nodeId, 1);

    for (const depId of (adjById.get(nodeId) ?? [])) {
      if (!adjById.has(depId)) continue; // unknown dep, skip

      if (color.get(depId) === 1) {
        // Back edge found — reconstruct the cycle path
        const path = [depId];
        let cur = nodeId;
        while (cur !== depId) {
          path.unshift(cur);
          cur = parent.get(cur);
          if (cur === undefined) break; // safety guard
        }
        path.unshift(depId);
        cycles.push(path.join(" -> "));
        continue;
      }

      if (!color.has(depId) || color.get(depId) === 0) {
        parent.set(depId, nodeId);
        dfs(depId);
      }
    }

    color.set(nodeId, 2);
  }

  for (const task of tasks) {
    if (!color.has(task.id) || color.get(task.id) === 0) {
      dfs(task.id);
    }
  }

  return cycles;
}

function isDependencySatisfied(task, doneIds) {
  return task.dependsOn.every((dependencyId) => doneIds.has(dependencyId));
}

function findNextTask(tasks) {
  const doneIds = new Set(
    tasks
      .filter((task) => task.state === "Done")
      .map((task) => task.id)
  );

  for (const state of NEXT_ORDER) {
    let candidates = sortTasks(tasks.filter((task) => task.state === state));
    if (state === "Backlog") {
      candidates = candidates.filter((task) => isDependencySatisfied(task, doneIds));
    }

    if (candidates.length > 0) {
      const action =
        state === "Failed"
          ? "fix-and-retest"
          : state === "Testing"
            ? "run-acceptance"
            : state === "Review"
              ? "run-review"
              : state === "In Progress"
                ? "continue-implementation"
                : "start-task";
      return { state, action, task: candidates[0] };
    }
  }

  return null;
}

function buildParallelPlan(tasks, maxParallel) {
  // Guard: report cycles before planning to prevent silent deadlocks.
  const cycles = detectCycles(tasks);
  if (cycles.length > 0) {
    throw new Error(
      `Dependency cycle(s) detected in sprint state:\n${cycles.map((c) => `  ${c}`).join("\n")}\nFix dependsOn fields before running a parallel plan.`
    );
  }

  const primary = findNextTask(tasks);
  if (!primary) return null;

  const parallelAllowedActions = new Set(["start-task", "continue-implementation"]);
  const doneIds = new Set(
    tasks
      .filter((task) => task.state === "Done")
      .map((task) => task.id)
  );
  const primaryTask = primary.task;

  const dependencyGraph = {
    [primaryTask.id]: [...primaryTask.dependsOn]
  };

  if (!parallelAllowedActions.has(primary.action) || maxParallel <= 0) {
    return {
      generatedAt: nowIso(),
      primaryTaskId: primaryTask.id,
      primaryAction: primary.action,
      parallelTracks: [],
      dependencyGraph,
      syncPoints: ["quality-gates"]
    };
  }

  const tracks = [];
  const backlog = sortTasks(tasks.filter((task) => task.state === "Backlog" && task.id !== primaryTask.id));

  for (const task of backlog) {
    if (tracks.length >= maxParallel) break;
    if (task.dependsOn.includes(primaryTask.id)) continue;
    if (!isDependencySatisfied(task, doneIds)) continue;
    tracks.push(task.id);
    dependencyGraph[task.id] = [...task.dependsOn];
  }

  return {
    generatedAt: nowIso(),
    primaryTaskId: primaryTask.id,
    primaryAction: primary.action,
    parallelTracks: tracks,
    dependencyGraph,
    syncPoints: ["quality-gates"]
  };
}

function updateTask(state, options, flags) {
  const id = requireOption(options, "id");
  const task = state.tasks.find((item) => item.id === id);

  if (!task) {
    throw new Error(`Task not found: ${id}`);
  }

  if (options.state) {
    if (!VALID_STATES.includes(options.state)) {
      throw new Error(`Invalid state '${options.state}'. Expected one of: ${VALID_STATES.join(", ")}`);
    }

    task.state = options.state;

    if (task.state === "In Progress" && !task.startedAt) {
      task.startedAt = nowIso();
    }

    if (task.state === "Failed") {
      task.failCount += 1;
      task.lastFailedAt = nowIso();
    }

    if (task.state === "Done") {
      task.completedAt = nowIso();
    }
  }

  // --reset-fail-count: used after a human fixes a failed task and wants
  // to re-enter the loop without the 3-failure stop condition triggering.
  if (flags && flags.has("reset-fail-count")) {
    task.failCount = 0;
    task.lastFailedAt = "";
    task.reason = options.reason ?? task.reason;
  }

  if (options.title) task.title = options.title;
  if (options.owner) task.owner = options.owner;
  if (options.source) task.source = options.source;
  if (options.verification) task.verification = options.verification;
  if (options.reason) task.reason = options.reason;

  if (options.priority) {
    if (!(options.priority in PRIORITY_WEIGHT)) {
      throw new Error(`Invalid priority '${options.priority}'. Expected P0/P1/P2/P3.`);
    }
    task.priority = options.priority;
  }

  if (options.flow) task.testing.flow = options.flow;
  if (options["must-rate"]) task.testing.mustPassRate = options["must-rate"];
  if (options["should-rate"]) task.testing.shouldPassRate = options["should-rate"];
  if (options.implementer) task.review.implementer = options.implementer;
  if (options.security) task.review.security = options.security;
  if (options.qa) task.review.qa = options.qa;
  if (options.domain) task.review.domain = options.domain;
  if (options.architect) task.review.architect = options.architect;

  if (options.note) {
    task.notes = task.notes ? `${task.notes}; ${options.note}` : options.note;
  }

  if (options["depends-on"] !== undefined) {
    task.dependsOn = normalizeDependsOn(options["depends-on"]);
  }

  state.updatedAt = nowIso();
  return task;
}

function appendJournal(filePath, options) {
  const taskId = requireOption(options, "task");
  const summary = requireOption(options, "summary");
  const files = String(options.files ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  const signals = String(options.signals ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);

  const lines = [];
  lines.push(`## ${nowIso()} - ${taskId}`);
  lines.push(`- Summary: ${summary}`);

  if (files.length > 0) {
    lines.push(`- Files: ${files.map((item) => `\`${item}\``).join(", ")}`);
  }

  if (signals.length > 0) {
    lines.push("- Signals:");
    for (const signal of signals) {
      lines.push(`  - ${signal}`);
    }
  }

  lines.push("---");

  fs.mkdirSync(path.dirname(filePath), { recursive: true });

  const prefix = fs.existsSync(filePath) ? "\n" : "# Run Journal\n\n## Codebase Signals\n- Add reusable patterns and gotchas here.\n\n## Entries\n";
  fs.appendFileSync(filePath, `${prefix}${lines.join("\n")}\n`, "utf8");
}

function printSummary(state) {
  const counts = Object.fromEntries(VALID_STATES.map((name) => [name, 0]));
  for (const task of state.tasks) {
    if (counts[task.state] === undefined) continue;
    counts[task.state] += 1;
  }

  console.log("Sprint Summary");
  for (const name of VALID_STATES) {
    console.log(`${name.padEnd(11, " ")}: ${counts[name]}`);
  }

  const next = findNextTask(state.tasks);
  if (!next) {
    const backlogCount = state.tasks.filter((task) => task.state === "Backlog").length;
    if (backlogCount > 0) {
      console.log("Next Task  : none (all backlog tasks are blocked by dependencies)");
    } else {
      console.log("Next Task  : none (backlog empty)");
    }
    return;
  }

  console.log(`Next Task  : ${next.task.id} (${next.action})`);

  const plan = buildParallelPlan(state.tasks, DEFAULT_MAX_PARALLEL);
  if (plan && plan.parallelTracks.length > 0) {
    console.log(`Parallel   : ${plan.parallelTracks.join(", ")}`);
  } else {
    console.log("Parallel   : none");
  }
}

function main() {
  const argv = process.argv.slice(2);
  const parsed = parseArgv(argv, new Set(["json", "help", "reset-fail-count"]));

  if (!parsed.command || parsed.flags.has("help") || parsed.command === "help") {
    printHelp();
    return;
  }

  const stateFile = path.resolve(parsed.options["state-file"] ?? DEFAULTS.stateFile);
  const boardFile = path.resolve(parsed.options["board-file"] ?? DEFAULTS.boardFile);
  const journalFile = path.resolve(parsed.options["journal-file"] ?? DEFAULTS.journalFile);

  if (parsed.command === "journal") {
    appendJournal(journalFile, parsed.options);
    console.log(`Journal updated: ${path.relative(process.cwd(), journalFile)}`);
    return;
  }

  const state = readState(stateFile);

  if (parsed.command === "summary") {
    printSummary(state);
    return;
  }

  if (parsed.command === "next") {
    const next = findNextTask(state.tasks);

    if (parsed.flags.has("json")) {
      console.log(JSON.stringify(next, null, 2));
      return;
    }

    if (!next) {
      console.log("No actionable task found.");
      return;
    }

    console.log(`${next.task.id} ${next.action}`);
    console.log(`${next.task.title}`);
    return;
  }

  if (parsed.command === "plan") {
    const rawMaxParallel = parsed.options["max-parallel"];
    const maxParallel =
      rawMaxParallel === undefined
        ? DEFAULT_MAX_PARALLEL
        : Number.parseInt(String(rawMaxParallel), 10);

    if (!Number.isFinite(maxParallel) || maxParallel < 0) {
      throw new Error("Invalid --max-parallel value. Expected a non-negative integer.");
    }

    const plan = buildParallelPlan(state.tasks, maxParallel);

    if (!plan) {
      if (parsed.flags.has("json")) {
        console.log("null");
      } else {
        console.log("No actionable task found.");
      }
      return;
    }

    if (parsed.flags.has("json")) {
      console.log(JSON.stringify(plan, null, 2));
      return;
    }

    console.log(`Primary    : ${plan.primaryTaskId} (${plan.primaryAction})`);
    if (plan.parallelTracks.length === 0) {
      console.log("Parallel   : none");
    } else {
      console.log(`Parallel   : ${plan.parallelTracks.join(", ")}`);
    }
    console.log(`Sync Points: ${plan.syncPoints.join(", ")}`);
    return;
  }

  if (parsed.command === "render") {
    writeBoard(boardFile, state);
    console.log(`Sprint board rendered: ${path.relative(process.cwd(), boardFile)}`);
    return;
  }

  if (parsed.command === "update") {
    const task = updateTask(state, parsed.options, parsed.flags);
    writeState(stateFile, state);
    writeBoard(boardFile, state);
    console.log(`Task updated: ${task.id} -> ${task.state}`);
    console.log(`State file: ${path.relative(process.cwd(), stateFile)}`);
    console.log(`Board file: ${path.relative(process.cwd(), boardFile)}`);
    return;
  }

  throw new Error(`Unknown command: ${parsed.command}`);
}

try {
  main();
} catch (error) {
  console.error(`Error: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
