#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { cac } from "cac";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Types
interface Task {
  id: string;
  title: string;
  status: "backlog" | "in_progress" | "review" | "testing" | "done" | "failed";
  phase: "plan" | "exec" | "review" | "test" | "completed" | null;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
}

interface Current {
  task_id: string | null;
  phase: string | null;
}

// Paths
function getTechleadDir(): string {
  return path.join(process.cwd(), ".techlead");
}

function getCurrentFile(): string {
  return path.join(getTechleadDir(), "current.json");
}

function getTasksDir(): string {
  return path.join(getTechleadDir(), "tasks");
}

function getKnowledgeDir(): string {
  return path.join(getTechleadDir(), "knowledge");
}

function getTaskDir(taskId: string): string {
  const tasksDir = getTasksDir();
  if (!fs.existsSync(tasksDir)) {
    throw new Error(`Tasks directory not found: ${tasksDir}`);
  }
  
  const entries = fs.readdirSync(tasksDir, { withFileTypes: true });
  const match = entries.find(
    (e) => e.isDirectory() && e.name.startsWith(taskId)
  );
  
  if (!match) {
    throw new Error(`Task not found: ${taskId}`);
  }
  
  return path.join(tasksDir, match.name);
}

function getTaskJsonPath(taskId: string): string {
  return path.join(getTaskDir(taskId), "task.json");
}

// Utils
function generateTaskId(): string {
  const tasksDir = getTasksDir();
  if (!fs.existsSync(tasksDir)) {
    return "T-001";
  }
  
  const entries = fs.readdirSync(tasksDir, { withFileTypes: true });
  const maxNum = entries
    .filter((e) => e.isDirectory() && e.name.match(/^T-\d+/))
    .map((e) => {
      const match = e.name.match(/^T-(\d+)/);
      return match ? parseInt(match[1], 10) : 0;
    })
    .reduce((max, n) => Math.max(max, n), 0);
  
  return `T-${String(maxNum + 1).padStart(3, "0")}`;
}

function sanitizeDirName(title: string): string {
  return title
    .replace(/[^a-zA-Z0-9\u4e00-\u9fa5]/g, "-")
    .replace(/-+/g, "-")
    .substring(0, 50);
}

function readJson<T>(filePath: string): T | null {
  if (!fs.existsSync(filePath)) return null;
  return JSON.parse(fs.readFileSync(filePath, "utf8")) as T;
}

function writeJson(filePath: string, data: unknown): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2) + "\n", "utf8");
}

function readCurrent(): Current {
  return readJson<Current>(getCurrentFile()) || { task_id: null, phase: null };
}

function writeCurrent(current: Current): void {
  writeJson(getCurrentFile(), current);
}

function readTask(taskId: string): Task {
  const task = readJson<Task>(getTaskJsonPath(taskId));
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }
  return task;
}

function writeTask(taskId: string, task: Task): void {
  writeJson(getTaskJsonPath(taskId), task);
}

function listAllTasks(): (Task & { dir: string })[] {
  const tasksDir = getTasksDir();
  if (!fs.existsSync(tasksDir)) return [];
  
  return fs.readdirSync(tasksDir, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => {
      const match = e.name.match(/^(T-\d+)-(.+)$/);
      if (!match) return null;
      
      const taskId = match[1];
      try {
        const task = readTask(taskId);
        return { ...task, dir: e.name };
      } catch {
        return null;
      }
    })
    .filter((t): t is Task & { dir: string } => t !== null)
    .sort((a, b) => a.id.localeCompare(b.id));
}

function findNextTask(): Task | null {
  const tasks = listAllTasks();
  
  // First check current
  const current = readCurrent();
  if (current.task_id) {
    const currentTask = tasks.find((t) => t.id === current.task_id);
    if (currentTask && currentTask.status !== "done") {
      return currentTask;
    }
  }
  
  // Find first backlog task
  const backlogTask = tasks.find((t) => t.status === "backlog");
  if (backlogTask) {
    return backlogTask;
  }
  
  // Find first failed task to retry
  const failedTask = tasks.find((t) => t.status === "failed");
  if (failedTask) {
    return failedTask;
  }
  
  return null;
}

// Commands
function cmdInit(): void {
  const techleadDir = getTechleadDir();
  
  if (fs.existsSync(techleadDir)) {
    console.log("TechLead already initialized.");
    return;
  }
  
  fs.mkdirSync(techleadDir, { recursive: true });
  fs.mkdirSync(getTasksDir(), { recursive: true });
  fs.mkdirSync(getKnowledgeDir(), { recursive: true });
  
  writeCurrent({ task_id: null, phase: null });
  
  fs.writeFileSync(
    path.join(getKnowledgeDir(), "pitfalls.md"),
    "# Pitfalls\n\n记录项目中的失败经验和教训。\n",
    "utf8"
  );
  fs.writeFileSync(
    path.join(getKnowledgeDir(), "patterns.md"),
    "# Patterns\n\n记录项目中的成功模式和最佳实践。\n",
    "utf8"
  );
  
  console.log("✅ TechLead initialized.");
  console.log("\nNext: techlead add \"your task\"");
}

function cmdAdd(title: string): void {
  if (!title?.trim()) {
    console.error("Error: Task title required");
    process.exit(1);
  }
  
  const taskId = generateTaskId();
  const dirName = `${taskId}-${sanitizeDirName(title)}`;
  const taskDir = path.join(getTasksDir(), dirName);
  
  fs.mkdirSync(taskDir, { recursive: true });
  
  const task: Task = {
    id: taskId,
    title: title.trim(),
    status: "backlog",
    phase: null,
    created_at: new Date().toISOString(),
    started_at: null,
    completed_at: null,
  };
  writeTask(taskId, task);
  
  fs.writeFileSync(
    path.join(taskDir, "README.md"),
    `# ${task.title}\n\n**ID**: ${task.id}\n**Status**: ${task.status}\n**Created**: ${task.created_at}\n\n## Description\n\n${task.title}\n\n## Acceptance Criteria\n\n- [ ] 待补充\n`,
    "utf8"
  );
  
  console.log(`✅ Task created: ${taskId}`);
  console.log(`   ${task.title}`);
  console.log(`\nRun: techlead run`);
}

function cmdList(): void {
  const tasks = listAllTasks();
  
  if (tasks.length === 0) {
    console.log("No tasks. Run: techlead add \"task title\"");
    return;
  }
  
  const current = readCurrent();
  
  console.log("\n📋 Tasks:\n");
  console.log("ID      Status         Phase     Title");
  console.log("-".repeat(60));
  
  for (const task of tasks) {
    const marker = current.task_id === task.id ? "▶ " : "  ";
    const status = task.status.padEnd(14);
    const phase = (task.phase || "-").padEnd(9);
    console.log(`${marker}${task.id}  ${status} ${phase} ${task.title}`);
  }
  console.log();
}

function cmdStatus(): void {
  const current = readCurrent();
  
  if (!current.task_id) {
    const next = findNextTask();
    if (next) {
      console.log(`\n📍 Next task: ${next.id} - ${next.title}`);
      console.log("   Run: techlead run");
    } else {
      console.log("\n📍 No active task.");
      console.log("   Run: techlead add \"task title\"");
    }
    return;
  }
  
  const task = readTask(current.task_id);
  
  console.log("\n📍 Current Task:\n");
  console.log(`   ${task.id}: ${task.title}`);
  console.log(`   Status: ${task.status}`);
  console.log(`   Phase:  ${task.phase || "-"}`);
  
  const taskDir = getTaskDir(current.task_id);
  const workLogPath = path.join(taskDir, "work-log.md");
  
  if (fs.existsSync(workLogPath)) {
    const content = fs.readFileSync(workLogPath, "utf8");
    const lines = content.split("\n").filter((l) => l.startsWith("## "));
    if (lines.length > 0) {
      console.log("\n   Recent:");
      lines.slice(-3).forEach((line) => {
        console.log(`   • ${line.replace("## ", "")}`);
      });
    }
  }
  
  console.log(`\n   Run: techlead run`);
}

function cmdRun(): void {
  const nextTask = findNextTask();
  
  if (!nextTask) {
    console.log("\n✅ All tasks completed!");
    console.log("   Run: techlead add \"new task\"");
    return;
  }
  
  // Set as current
  writeCurrent({ task_id: nextTask.id, phase: nextTask.phase });
  
  console.log(`\n🚀 Running: ${nextTask.id} - ${nextTask.title}`);
  console.log(`   Status: ${nextTask.status}`);
  console.log(`   Phase:  ${nextTask.phase || "starting"}`);
  
  // Auto-advance through phases
  switch (nextTask.status) {
    case "backlog":
      console.log("\n   → Entering Plan phase");
      console.log("   Agent will:");
      console.log("     1. Read README.md");
      console.log("     2. Run multi-role discussion");
      console.log("     3. Generate plan/discussion.md");
      console.log("     4. Generate plan/plan.md");
      break;
      
    case "in_progress":
      if (nextTask.phase === "plan") {
        console.log("\n   → Executing Plan phase");
        console.log("   Agent will:");
        console.log("     1. Read plan/plan.md");
        console.log("     2. Generate L0/L1 summaries");
        console.log("     3. Move to Exec phase");
      } else if (nextTask.phase === "exec") {
        console.log("\n   → Executing one step");
        console.log("   Agent will:");
        console.log("     1. Read plan + work-log");
        console.log("     2. Execute one small step");
        console.log("     3. Run verification");
        console.log("     4. Update work-log");
      }
      break;
      
    case "review":
      console.log("\n   → Running Adversarial Review");
      console.log("   Agent will:");
      console.log("     1. Read code diff");
      console.log("     2. Generate review/reviewer-*.md");
      console.log("     3. Check for CRITICAL issues");
      break;
      
    case "testing":
      console.log("\n   → Running Adversarial Testing");
      console.log("   Agent will:");
      console.log("     1. Design attack scenarios");
      console.log("     2. Generate test/adversarial-test.md");
      console.log("     3. Verify all pass");
      break;
      
    case "done":
      console.log("\n   ✓ Task completed");
      writeCurrent({ task_id: null, phase: null });
      break;
  }
  
  console.log("\n   [Agent execution placeholder]");
  console.log("   Connect to Codex/Claude API to auto-execute");
  console.log("\n   After completion, run: techlead run");
}

function cmdAbort(): void {
  const current = readCurrent();
  
  if (!current.task_id) {
    console.log("No active task to abort.");
    return;
  }
  
  const task = readTask(current.task_id);
  task.status = "failed";
  writeTask(current.task_id, task);
  writeCurrent({ task_id: null, phase: null });
  
  console.log(`⚠️  Task ${current.task_id} aborted (marked as failed)`);
}

// Main CLI
function main(): void {
  const cli = cac("techlead");

  cli.command("init", "Initialize TechLead").action(cmdInit);
  cli.command("add <title>", "Add a new task").action(cmdAdd);
  cli.command("list", "List all tasks").action(cmdList);
  cli.command("status", "Show current status").action(cmdStatus);
  cli.command("run", "Auto-run next task (smart selection)").action(cmdRun);
  cli.command("abort", "Abort current task").action(cmdAbort);

  cli.help();
  cli.parse();
}

main();
