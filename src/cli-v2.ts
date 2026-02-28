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
  // Find task by ID prefix
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

// Commands
function cmdInit(): void {
  const techleadDir = getTechleadDir();
  
  if (fs.existsSync(techleadDir)) {
    console.log("TechLead already initialized in this directory.");
    return;
  }
  
  // Create directories
  fs.mkdirSync(techleadDir, { recursive: true });
  fs.mkdirSync(getTasksDir(), { recursive: true });
  fs.mkdirSync(getKnowledgeDir(), { recursive: true });
  
  // Create current.json
  writeCurrent({ task_id: null, phase: null });
  
  // Create knowledge files
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
  
  console.log("✅ TechLead initialized successfully!");
  console.log("\nNext steps:");
  console.log("1. Add a task: techlead add \"Your task title\"");
  console.log("2. View status: techlead status");
}

function cmdAdd(title: string): void {
  if (!title || title.trim() === "") {
    console.error("Error: Task title is required");
    process.exit(1);
  }
  
  const taskId = generateTaskId();
  const dirName = `${taskId}-${sanitizeDirName(title)}`;
  const taskDir = path.join(getTasksDir(), dirName);
  
  // Create task directory
  fs.mkdirSync(taskDir, { recursive: true });
  
  // Create task.json
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
  
  // Create README.md
  fs.writeFileSync(
    path.join(taskDir, "README.md"),
    `# ${task.title}\n\nID: ${task.id}\nStatus: ${task.status}\nCreated: ${task.created_at}\n\n## Description\n\n${task.title}\n\n## Acceptance Criteria\n\n- [ ] 待补充\n`,
    "utf8"
  );
  
  console.log(`✅ Task created: ${taskId} - ${task.title}`);
  console.log(`   Location: ${taskDir}`);
}

function cmdList(): void {
  const tasksDir = getTasksDir();
  if (!fs.existsSync(tasksDir)) {
    console.log("No tasks found. Run 'techlead init' first.");
    return;
  }
  
  const entries = fs.readdirSync(tasksDir, { withFileTypes: true })
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
  
  if (entries.length === 0) {
    console.log("No tasks found.");
    return;
  }
  
  console.log("\n📋 Tasks:\n");
  console.log("ID      Status         Phase     Title");
  console.log("-".repeat(60));
  
  for (const task of entries) {
    const status = task.status.padEnd(14);
    const phase = (task.phase || "-").padEnd(9);
    console.log(`${task.id}  ${status} ${phase} ${task.title}`);
  }
  console.log();
}

function cmdStatus(): void {
  const current = readCurrent();
  
  if (!current.task_id) {
    console.log("\n📍 No active task.");
    console.log("   Run 'techlead add \"task title\"' to create a task.");
    return;
  }
  
  const task = readTask(current.task_id);
  
  console.log("\n📍 Current Task:\n");
  console.log(`   ID:     ${task.id}`);
  console.log(`   Title:  ${task.title}`);
  console.log(`   Status: ${task.status}`);
  console.log(`   Phase:  ${task.phase || "-"}`);
  
  // Show recent work log if exists
  const workLogPath = path.join(getTaskDir(current.task_id), "work-log.md");
  if (fs.existsSync(workLogPath)) {
    const content = fs.readFileSync(workLogPath, "utf8");
    const lines = content.split("\n").filter((l) => l.startsWith("## "));
    if (lines.length > 0) {
      console.log("\n   Recent Activity:");
      lines.slice(-3).forEach((line) => {
        console.log(`   ${line.replace("## ", "• ")}`);
      });
    }
  }
  console.log();
}

function cmdPlan(taskId: string, roles: string[]): void {
  const task = readTask(taskId);
  
  if (task.status !== "backlog") {
    console.error(`Error: Task ${taskId} is not in backlog status (current: ${task.status})`);
    process.exit(1);
  }
  
  const taskDir = getTaskDir(taskId);
  const planDir = path.join(taskDir, "plan");
  fs.mkdirSync(planDir, { recursive: true });
  
  // Update task
  task.status = "in_progress";
  task.phase = "plan";
  task.started_at = new Date().toISOString();
  writeTask(taskId, task);
  
  // Update current
  writeCurrent({ task_id: taskId, phase: "plan" });
  
  // Create placeholder files
  fs.writeFileSync(
    path.join(planDir, "discussion.md"),
    `# Plan Discussion: ${task.title}\n\n## Roles\n${roles.map((r) => `- ${r}`).join("\n")}\n\n## Discussion\n\n[TBD - Run agent with plan prompt to generate]\n`,
    "utf8"
  );
  
  fs.writeFileSync(
    path.join(planDir, "plan.md"),
    `# Execution Plan: ${task.title}\n\n## Overview\n\n[TBD]\n\n## Steps\n\n1. [ ] Step 1\n2. [ ] Step 2\n3. [ ] Step 3\n\n## Acceptance Criteria\n\n- [ ] Criterion 1\n`,
    "utf8"
  );
  
  // Create L0/L2 placeholders
  fs.writeFileSync(
    path.join(planDir, ".abstract.md"),
    `[TBD - One sentence summary of the plan]`,
    "utf8"
  );
  
  fs.writeFileSync(
    path.join(planDir, ".overview.md"),
    `# Plan Overview\n\n## Summary\n\n[TBD]\n\n## Key Sections\n\n- discussion.md: Multi-role discussion\n- plan.md: Execution plan\n`,
    "utf8"
  );
  
  console.log(`✅ Task ${taskId} moved to Plan phase`);
  console.log(`   Roles: ${roles.join(", ")}`);
  console.log(`   Next: Run agent to generate plan/discussion.md and plan/plan.md`);
}

function cmdStart(taskId: string): void {
  const task = readTask(taskId);
  
  if (task.phase !== "plan") {
    console.error(`Error: Task ${taskId} must be in plan phase (current: ${task.phase})`);
    process.exit(1);
  }
  
  const taskDir = getTaskDir(taskId);
  
  // Create work-log.md
  fs.writeFileSync(
    path.join(taskDir, "work-log.md"),
    `# Work Log: ${task.title}\n\n## ${new Date().toISOString()} - Started\n\nBeginning execution phase.\n\n---\n`,
    "utf8"
  );
  
  // Update task
  task.phase = "exec";
  writeTask(taskId, task);
  
  // Update current
  writeCurrent({ task_id: taskId, phase: "exec" });
  
  console.log(`✅ Task ${taskId} started execution phase`);
  console.log(`   Work log created: ${path.join(taskDir, "work-log.md")}`);
}

function cmdStep(): void {
  const current = readCurrent();
  
  if (!current.task_id) {
    console.error("Error: No active task. Run 'techlead start <task-id>' first.");
    process.exit(1);
  }
  
  if (current.phase !== "exec") {
    console.error(`Error: Current task is not in exec phase (current: ${current.phase})`);
    process.exit(1);
  }
  
  const task = readTask(current.task_id);
  const taskDir = getTaskDir(current.task_id);
  const workLogPath = path.join(taskDir, "work-log.md");
  
  // Read recent work log for context
  let workLogContent = "";
  if (fs.existsSync(workLogPath)) {
    workLogContent = fs.readFileSync(workLogPath, "utf8");
  }
  
  console.log(`\n📍 Executing step for ${current.task_id}: ${task.title}`);
  console.log("\n   Reading context...");
  console.log(`   - Task: ${task.title}`);
  console.log(`   - Phase: ${task.phase}`);
  
  const recentEntries = workLogContent
    .split("\n")
    .filter((l) => l.startsWith("## "))
    .slice(-5);
  
  if (recentEntries.length > 0) {
    console.log("   - Recent activity:");
    recentEntries.forEach((e) => console.log(`     ${e.replace("## ", "")}`));
  }
  
  console.log("\n   📝 Agent should:");
  console.log("   1. Read plan/plan.md");
  console.log("   2. Read work-log.md (recent entries)");
  console.log("   3. Execute one small step (15-30 min)");
  console.log("   4. Run verification (e.g., pnpm test)");
  console.log("   5. Append to work-log.md");
  console.log("\n   Run: techlead step (again) or techlead review <task-id>");
}

function cmdReview(taskId: string): void {
  const task = readTask(taskId);
  
  if (task.phase !== "exec") {
    console.error(`Error: Task ${taskId} must be in exec phase (current: ${task.phase})`);
    process.exit(1);
  }
  
  const taskDir = getTaskDir(taskId);
  const reviewDir = path.join(taskDir, "review");
  fs.mkdirSync(reviewDir, { recursive: true });
  
  // Update task
  task.status = "review";
  task.phase = "review";
  writeTask(taskId, task);
  writeCurrent({ task_id: taskId, phase: "review" });
  
  // Create review template
  fs.writeFileSync(
    path.join(reviewDir, "reviewer-1.md"),
    `# Adversarial Review: ${task.title}\n\nReviewer: [TBD - Assign perspective]\nContext: Diff only, no plan context\n\n## Findings\n\n### CRITICAL\n- [ ] None\n\n### WARNING\n- [ ] None\n\n### PASS\n- [ ] Review complete, no blocking issues\n\n## Summary\n\n[TBD]\n`,
    "utf8"
  );
  
  console.log(`✅ Task ${taskId} moved to Review phase`);
  console.log(`   Review template created: ${reviewDir}/reviewer-1.md`);
  console.log(`   Next: Run agent with adversarial review prompt`);
}

function cmdTest(taskId: string): void {
  const task = readTask(taskId);
  
  if (task.phase !== "review") {
    console.error(`Error: Task ${taskId} must be in review phase (current: ${task.phase})`);
    process.exit(1);
  }
  
  const taskDir = getTaskDir(taskId);
  const testDir = path.join(taskDir, "test");
  fs.mkdirSync(testDir, { recursive: true });
  
  // Update task
  task.status = "testing";
  task.phase = "test";
  writeTask(taskId, task);
  writeCurrent({ task_id: taskId, phase: "test" });
  
  // Create adversarial test template
  fs.writeFileSync(
    path.join(testDir, "adversarial-test.md"),
    `# Adversarial Test: ${task.title}\n\nTester: [TBD - Assign attacker persona]\n\n## Scenarios\n\n### Scenario 1: [Attack vector]\n- **Action**: [What to try]\n- **Expected**: [What should happen]\n- **Result**: [TBD]\n\n### Scenario 2: [Edge case]\n- **Action**: [What to try]\n- **Expected**: [What should happen]\n- **Result**: [TBD]\n\n## Summary\n\n- CRITICAL: 0\n- WARNING: 0\n- PASS: 0\n`,
    "utf8"
  );
  
  console.log(`✅ Task ${taskId} moved to Testing phase`);
  console.log(`   Test template created: ${testDir}/adversarial-test.md`);
  console.log(`   Next: Run agent with adversarial test prompt`);
}

function cmdDone(taskId: string): void {
  const task = readTask(taskId);
  
  if (task.phase !== "test") {
    console.error(`Error: Task ${taskId} must be in test phase (current: ${task.phase})`);
    process.exit(1);
  }
  
  // Update task
  task.status = "done";
  task.phase = "completed";
  task.completed_at = new Date().toISOString();
  writeTask(taskId, task);
  
  // Clear current if this was the active task
  const current = readCurrent();
  if (current.task_id === taskId) {
    writeCurrent({ task_id: null, phase: null });
  }
  
  console.log(`✅ Task ${taskId} completed!`);
  console.log(`   Title: ${task.title}`);
  console.log(`   Duration: ${task.started_at ? new Date(task.completed_at).getTime() - new Date(task.started_at).getTime() : 0}ms`);
}

// Main CLI
function main(): void {
  const cli = cac("techlead");

  cli
    .command("init", "Initialize TechLead in current directory")
    .action(cmdInit);

  cli
    .command("add <title>", "Add a new task to backlog")
    .action(cmdAdd);

  cli
    .command("list", "List all tasks")
    .action(cmdList);

  cli
    .command("status", "Show current task status")
    .action(cmdStatus);

  cli
    .command("plan <task-id>", "Move task to plan phase with multi-role discussion")
    .option("--roles <roles>", "Comma-separated roles (default: architect,security,dx)", {
      default: "architect,security,dx",
    })
    .action((taskId: string, options: { roles: string }) => {
      const roles = options.roles.split(",").map((r) => r.trim());
      cmdPlan(taskId, roles);
    });

  cli
    .command("start <task-id>", "Start execution phase for a task")
    .action(cmdStart);

  cli
    .command("step", "Execute one step of the current task (external driver)")
    .action(cmdStep);

  cli
    .command("review <task-id>", "Move task to review phase (adversarial)")
    .action(cmdReview);

  cli
    .command("test <task-id>", "Move task to testing phase (adversarial)")
    .action(cmdTest);

  cli
    .command("done <task-id>", "Mark task as completed")
    .action(cmdDone);

  cli.help();
  cli.parse();
}

main();
