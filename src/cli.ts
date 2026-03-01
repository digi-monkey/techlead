#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { cac } from "cac";
import {
  executeAgent,
  detectAgent,
  createDefaultConfig,
  type AgentResult,
} from "./lib/agent-adapter.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const templatesRoot = path.join(__dirname, "../templates/.techlead");

// Types
interface Task {
  id: string;
  title: string;
  status: "backlog" | "in_progress" | "review" | "testing" | "done" | "failed";
  phase: "plan" | "exec" | "review" | "reviewed" | "test" | "tested" | "completed" | null;
  review_passed?: boolean;
  test_passed?: boolean;
  review_attempts?: number;
  test_attempts?: number;
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

  // Copy templates
  if (fs.existsSync(templatesRoot)) {
    copyDir(templatesRoot, techleadDir);
    console.log("✅ TechLead initialized from templates.");
  } else {
    // Fallback to hardcoded init
    fs.mkdirSync(techleadDir, { recursive: true });
    fs.mkdirSync(getTasksDir(), { recursive: true });
    fs.mkdirSync(getKnowledgeDir(), { recursive: true });
    writeCurrent({ task_id: null, phase: null });
    console.log("✅ TechLead initialized.");
  }

  console.log("\nNext: techlead add \"your task\"");
}

// Copy directory recursively
function copyDir(src: string, dest: string): void {
  fs.mkdirSync(dest, { recursive: true });
  const entries = fs.readdirSync(src, { withFileTypes: true });

  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);

    if (entry.isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
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

  // Use template or create from scratch
  const taskTemplateDir = path.join(templatesRoot, "tasks");
  if (fs.existsSync(taskTemplateDir)) {
    // Copy README template
    const readmeTemplatePath = path.join(taskTemplateDir, "README.md");
    if (fs.existsSync(readmeTemplatePath)) {
      let readme = fs.readFileSync(readmeTemplatePath, "utf8");
      readme = readme
        .replace(/\{\{TASK_TITLE\}\}/g, task.title)
        .replace(/\{\{TASK_ID\}\}/g, task.id)
        .replace(/\{\{CREATED_AT\}\}/g, task.created_at)
        .replace(/\{\{TASK_DESCRIPTION\}\}/g, task.title);
      fs.writeFileSync(path.join(taskDir, "README.md"), readme, "utf8");
    }
  } else {
    // Fallback
    fs.writeFileSync(
      path.join(taskDir, "README.md"),
      `# ${task.title}\n\n**ID**: ${task.id}\n**Status**: ${task.status}\n**Created**: ${task.created_at}\n\n## Description\n\n${task.title}\n\n## Acceptance Criteria\n\n- [ ] Criterion 1\n`,
      "utf8"
    );
  }

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

  // Check if agent is available
  const agentProvider = detectAgent();
  if (!agentProvider) {
    console.error("\n❌ No agent CLI found.");
    console.error("   Install Claude Code: npm install -g @anthropic-ai/claude-code");
    console.error("   Install Codex: npm install -g @openai/codex");
    process.exit(1);
  }

  console.log(`\n🚀 Running: ${nextTask.id} - ${nextTask.title}`);
  console.log(`   Agent: ${agentProvider}`);
  console.log(`   Status: ${nextTask.status}`);
  console.log(`   Phase: ${nextTask.phase || "starting"}`);

  // Set as current
  writeCurrent({ task_id: nextTask.id, phase: nextTask.phase });

  const config = createDefaultConfig(process.cwd());
  if (!config) {
    console.error("❌ Failed to create agent config");
    process.exit(1);
  }

  const taskDir = getTaskDir(nextTask.id);
  const readmePath = path.join(taskDir, "README.md");
  let result: AgentResult;

  // Auto-advance through phases
  switch (nextTask.status) {
    case "backlog": {
      console.log("\n   → Entering Plan phase\n");

      // Update task status
      nextTask.status = "in_progress";
      nextTask.phase = "plan";
      nextTask.started_at = new Date().toISOString();
      writeTask(nextTask.id, nextTask);
      writeCurrent({ task_id: nextTask.id, phase: "plan" });

      // Create plan directory
      const planDir = path.join(taskDir, "plan");
      fs.mkdirSync(planDir, { recursive: true });

      // Read system prompt
      const promptPath = path.join(__dirname, "../prompts/plan/multirole.md");
      const systemPrompt = fs.existsSync(promptPath)
        ? fs.readFileSync(promptPath, "utf8")
        : undefined;

      // Execute agent
      const userPrompt = `Task: ${nextTask.title}\n\nRead ${readmePath} and create a comprehensive execution plan with multi-role discussion.\n\nGenerate:\n1. plan/discussion.md - Multi-role discussion (Architect, Security, DX perspectives)\n2. plan/plan.md - Step-by-step execution plan\n3. plan/.abstract.md - One sentence summary\n4. plan/.overview.md - Navigation overview`;

      console.log("   🤖 Agent generating plan...");
      result = executeAgent(userPrompt, config, {
        systemPrompt,
        outputFormat: "json",
        timeoutMs: 120000,
      });

      if (result.success) {
        console.log("   ✅ Plan generated");
        console.log(`   💰 Cost: $${result.costUsd?.toFixed(4) || "?"}`);

        // Create placeholder files if agent didn't create them
        const discussionPath = path.join(planDir, "discussion.md");
        const planMdPath = path.join(planDir, "plan.md");
        const abstractPath = path.join(planDir, ".abstract.md");
        const overviewPath = path.join(planDir, ".overview.md");

        if (!fs.existsSync(discussionPath)) {
          fs.writeFileSync(discussionPath, `# Discussion: ${nextTask.title}\n\n${result.content}\n`, "utf8");
        }
        if (!fs.existsSync(planMdPath)) {
          fs.writeFileSync(planMdPath, `# Plan: ${nextTask.title}\n\nSee discussion.md for details.\n\n## Steps\n\n1. [ ] Implement\n2. [ ] Test\n3. [ ] Review\n`, "utf8");
        }
        if (!fs.existsSync(abstractPath)) {
          fs.writeFileSync(abstractPath, result.content.substring(0, 200), "utf8");
        }
        if (!fs.existsSync(overviewPath)) {
          fs.writeFileSync(overviewPath, `# Overview: ${nextTask.title}\n\nSee discussion.md and plan.md\n`, "utf8");
        }

        console.log("\n   📁 Files created:");
        console.log(`      ${planDir}`);
      } else {
        console.error("   ❌ Plan generation failed");
        console.error(`   Error: ${result.error}`);
      }
      break;
    }

    case "in_progress": {
      if (nextTask.phase === "plan") {
        console.log("\n   → Transitioning to Exec phase\n");

        // Move to exec phase
        nextTask.phase = "exec";
        writeTask(nextTask.id, nextTask);
        writeCurrent({ task_id: nextTask.id, phase: "exec" });

        // Create work log
        const workLogPath = path.join(taskDir, "work-log.md");
        fs.writeFileSync(
          workLogPath,
          `# Work Log: ${nextTask.title}\n\n## ${new Date().toISOString()} - Started execution\n\n`,
          "utf8"
        );

        console.log("   ✅ Ready for execution");
        console.log(`   📁 ${workLogPath}`);

      } else if (nextTask.phase === "exec") {
        console.log("\n   → Executing one step\n");

        const workLogPath = path.join(taskDir, "work-log.md");
        const planPath = path.join(taskDir, "plan/plan.md");

        // Read context
        const workLog = fs.existsSync(workLogPath)
          ? fs.readFileSync(workLogPath, "utf8")
          : "";
        const plan = fs.existsSync(planPath)
          ? fs.readFileSync(planPath, "utf8")
          : "";

        const recentEntries = workLog
          .split("\n")
          .filter((l) => l.startsWith("## "))
          .slice(-5)
          .join("\n");

        const userPrompt = `Execute one step of the task.\n\nTask: ${nextTask.title}\n\nPlan:\n${plan}\n\nRecent work:\n${recentEntries}\n\nInstructions:\n1. Read the plan and recent work\n2. Execute ONE small step (15-30 min of work)\n3. Run verification (e.g., pnpm test)\n4. Report what was done\n\nOutput format:\n- Action: What you did\n- Files changed: List of files\n- Verification: Test results\n- Status: continue | completed`;

        console.log("   🤖 Agent executing step...");
        result = executeAgent(userPrompt, config, {
          outputFormat: "json",
          timeoutMs: 300000, // 5 min for code execution
        });

        if (result.success) {
          console.log("   ✅ Step completed");
          console.log(`   💰 Cost: $${result.costUsd?.toFixed(4) || "?"}`);

          // Append to work log
          fs.appendFileSync(
            workLogPath,
            `\n## ${new Date().toISOString()}\n\n${result.content}\n\n---\n`,
            "utf8"
          );

          // Check if task is complete (agent says "completed")
          if (result.content.toLowerCase().includes("completed")) {
            console.log("\n   ✨ Task appears complete!");
            console.log("   → Moving to Review phase\n");
            
            // Transition to review phase
            nextTask.status = "review";
            nextTask.phase = "review";
            writeTask(nextTask.id, nextTask);
            writeCurrent({ task_id: nextTask.id, phase: "review" });
            
            // Create review directory
            const reviewDir = path.join(taskDir, "review");
            fs.mkdirSync(reviewDir, { recursive: true });
            
            console.log("   📁 Review directory created");
            console.log("   Run: techlead run  # to start review");
          } else {
            console.log("\n   🔄 Continue execution");
            console.log("   Run: techlead run");
          }
        } else {
          console.error("   ❌ Step failed");
          console.error(`   Error: ${result.error}`);
        }
      }
      break;
    }

    default:
      console.log("\n   [Phase not yet implemented]");
      console.log(`   Current: ${nextTask.status} / ${nextTask.phase}`);
  }

  // Handle review phase
  if (nextTask.status === "review" && nextTask.phase === "review") {
    // Check if already reviewed
    if (nextTask.review_passed === true) {
      console.log("\n   ✓ Already reviewed (passed)");
      console.log("   → Moving to Test phase\n");
      nextTask.status = "testing";
      nextTask.phase = "test";
      writeTask(nextTask.id, nextTask);
      writeCurrent({ task_id: nextTask.id, phase: "test" });
    } else if (nextTask.review_attempts && nextTask.review_attempts >= 1) {
      // Check if review file exists and was already processed
      const reviewPath = path.join(taskDir, "review", "reviewer-1.md");
      if (fs.existsSync(reviewPath)) {
        const existingReview = fs.readFileSync(reviewPath, "utf8");
        const hasCritical = existingReview.toLowerCase().includes("critical");
        
        if (!hasCritical) {
          console.log("\n   ✓ Review file exists and passed");
          nextTask.review_passed = true;
          nextTask.status = "testing";
          nextTask.phase = "test";
          writeTask(nextTask.id, nextTask);
          writeCurrent({ task_id: nextTask.id, phase: "test" });
          console.log("   → Moving to Test phase\n");
        } else {
          console.log("\n   ⚠️  Previous review had CRITICAL issues");
          console.log("   → Returning to Exec phase to fix\n");
          nextTask.status = "in_progress";
          nextTask.phase = "exec";
          writeTask(nextTask.id, nextTask);
          writeCurrent({ task_id: nextTask.id, phase: "exec" });
        }
        return;
      }
    }

    console.log("\n   → Running Review phase\n");

    const reviewDir = path.join(taskDir, "review");
    fs.mkdirSync(reviewDir, { recursive: true });

    // Track review attempt
    nextTask.review_attempts = (nextTask.review_attempts || 0) + 1;
    writeTask(nextTask.id, nextTask);

    // Read system prompt for review
    const reviewPromptPath = path.join(__dirname, "../prompts/review/adversarial.md");
    const systemPrompt = fs.existsSync(reviewPromptPath)
      ? fs.readFileSync(reviewPromptPath, "utf8")
      : "You are a code reviewer. Review the changes and identify issues.";

    const userPrompt = `Review the implementation for task: ${nextTask.title}\n\nCheck:\n1. Code quality and correctness\n2. Potential bugs or edge cases\n3. Security issues\n4. Performance concerns\n\nGenerate review/reviewer-1.md with structured findings (CRITICAL/WARNING/PASS).`;

    console.log(`   🤖 Agent reviewing code... (attempt ${nextTask.review_attempts})`);
    result = executeAgent(userPrompt, config, {
      systemPrompt,
      outputFormat: "json",
      timeoutMs: 120000,
    });

    if (result.success) {
      console.log("   ✅ Review completed");
      console.log(`   💰 Cost: $${result.costUsd?.toFixed(4) || "?"}`);

      // Save review output
      const reviewPath = path.join(reviewDir, "reviewer-1.md");
      fs.writeFileSync(reviewPath, `# Adversarial Review: ${nextTask.title}\n\n${result.content}\n`, "utf8");

      // Append to work log
      const workLogPath = path.join(taskDir, "work-log.md");
      if (fs.existsSync(workLogPath)) {
        fs.appendFileSync(
          workLogPath,
          `\n## ${new Date().toISOString()} - Review ${nextTask.review_attempts}\n\n- Review completed\n- Cost: $${result.costUsd?.toFixed(4) || "?"}\n\n---\n`,
          "utf8"
        );
      }

      // Check for CRITICAL issues
      const hasCritical = result.content.toLowerCase().includes("critical");
      
      if (hasCritical) {
        console.log("\n   ⚠️  CRITICAL issues found!");
        console.log("   → Returning to Exec phase to fix\n");
        nextTask.status = "in_progress";
        nextTask.phase = "exec";
        nextTask.review_passed = false;
        writeTask(nextTask.id, nextTask);
        writeCurrent({ task_id: nextTask.id, phase: "exec" });
      } else {
        console.log("\n   ✨ Review passed!");
        console.log("   → Moving to Test phase\n");
        nextTask.status = "testing";
        nextTask.phase = "test";
        nextTask.review_passed = true;
        writeTask(nextTask.id, nextTask);
        writeCurrent({ task_id: nextTask.id, phase: "test" });
        
        // Create test directory
        const testDir = path.join(taskDir, "test");
        fs.mkdirSync(testDir, { recursive: true });
        console.log("   📁 Test directory created");
      }
    } else {
      console.error("   ❌ Review failed");
      console.error(`   Error: ${result.error}`);
    }
  }

  // Handle test phase
  if (nextTask.status === "testing" && nextTask.phase === "test") {
    // Check if already tested
    if (nextTask.test_passed === true) {
      console.log("\n   ✓ Already tested (passed)");
      console.log("   → Marking as Done\n");
      nextTask.status = "done";
      nextTask.phase = "completed";
      nextTask.completed_at = new Date().toISOString();
      writeTask(nextTask.id, nextTask);
      writeCurrent({ task_id: null, phase: null });
      
      console.log(`   ✅ Task ${nextTask.id} completed!`);
      console.log(`   Duration: ${nextTask.started_at && nextTask.completed_at ? 
        Math.round((new Date(nextTask.completed_at).getTime() - new Date(nextTask.started_at).getTime()) / 1000 / 60) + " min" : "N/A"}`);
      return;
    } else if (nextTask.test_attempts && nextTask.test_attempts >= 1) {
      // Check if test file exists and was already processed
      const testPath = path.join(taskDir, "test", "adversarial-test.md");
      if (fs.existsSync(testPath)) {
        const existingTest = fs.readFileSync(testPath, "utf8");
        const hasCritical = existingTest.toLowerCase().includes("critical");
        
        if (!hasCritical) {
          console.log("\n   ✓ Test file exists and passed");
          nextTask.test_passed = true;
          nextTask.status = "done";
          nextTask.phase = "completed";
          nextTask.completed_at = new Date().toISOString();
          writeTask(nextTask.id, nextTask);
          writeCurrent({ task_id: null, phase: null });
          console.log(`   ✅ Task ${nextTask.id} completed!`);
          return;
        } else {
          console.log("\n   ⚠️  Previous test had CRITICAL failures");
          console.log("   → Returning to Exec phase to fix\n");
          nextTask.status = "in_progress";
          nextTask.phase = "exec";
          writeTask(nextTask.id, nextTask);
          writeCurrent({ task_id: nextTask.id, phase: "exec" });
        }
        return;
      }
    }

    console.log("\n   → Running Test phase\n");

    const testDir = path.join(taskDir, "test");
    fs.mkdirSync(testDir, { recursive: true });

    // Track test attempt
    nextTask.test_attempts = (nextTask.test_attempts || 0) + 1;
    writeTask(nextTask.id, nextTask);

    // Read system prompt for test
    const testPromptPath = path.join(__dirname, "../prompts/test/adversarial.md");
    const systemPrompt = fs.existsSync(testPromptPath)
      ? fs.readFileSync(testPromptPath, "utf8")
      : "You are a tester. Test the implementation thoroughly.";

    const userPrompt = `Test the implementation for task: ${nextTask.title}\n\nDesign and run:\n1. Unit tests\n2. Edge case tests\n3. Adversarial tests (attack scenarios)\n4. Integration tests\n\nGenerate test/adversarial-test.md with results (PASS/WARNING/CRITICAL).`;

    console.log(`   🤖 Agent testing... (attempt ${nextTask.test_attempts})`);
    result = executeAgent(userPrompt, config, {
      systemPrompt,
      outputFormat: "json",
      timeoutMs: 120000,
    });

    if (result.success) {
      console.log("   ✅ Testing completed");
      console.log(`   💰 Cost: $${result.costUsd?.toFixed(4) || "?"}`);

      // Save test output
      const testPath = path.join(testDir, "adversarial-test.md");
      fs.writeFileSync(testPath, `# Adversarial Test: ${nextTask.title}\n\n${result.content}\n`, "utf8");

      // Append to work log
      const workLogPath = path.join(taskDir, "work-log.md");
      if (fs.existsSync(workLogPath)) {
        fs.appendFileSync(
          workLogPath,
          `\n## ${new Date().toISOString()} - Test ${nextTask.test_attempts}\n\n- Test completed\n- Cost: $${result.costUsd?.toFixed(4) || "?"}\n\n---\n`,
          "utf8"
        );
      }

      // Check for CRITICAL issues
      const hasCritical = result.content.toLowerCase().includes("critical");
      
      if (hasCritical) {
        console.log("\n   ⚠️  CRITICAL test failures!");
        console.log("   → Returning to Exec phase to fix\n");
        nextTask.status = "in_progress";
        nextTask.phase = "exec";
        nextTask.test_passed = false;
        writeTask(nextTask.id, nextTask);
        writeCurrent({ task_id: nextTask.id, phase: "exec" });
      } else {
        console.log("\n   ✨ All tests passed!");
        console.log("   → Marking as Done\n");
        nextTask.status = "done";
        nextTask.phase = "completed";
        nextTask.test_passed = true;
        nextTask.completed_at = new Date().toISOString();
        writeTask(nextTask.id, nextTask);
        writeCurrent({ task_id: null, phase: null });
        
        console.log(`   ✅ Task ${nextTask.id} completed!`);
        console.log(`   Duration: ${nextTask.started_at && nextTask.completed_at ? 
          Math.round((new Date(nextTask.completed_at).getTime() - new Date(nextTask.started_at).getTime()) / 1000 / 60) + " min" : "N/A"}`);
      }
    } else {
      console.error("   ❌ Testing failed");
      console.error(`   Error: ${result.error}`);
    }
  }
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

function cmdNext(): void {
  const current = readCurrent();
  const tasks = listAllTasks();

  // Find next task (skip current)
  let nextTask: Task | null = null;

  // 1. Find first backlog task that's not current
  const backlogTasks = tasks.filter(
    (t) => t.status === "backlog" && t.id !== current.task_id
  );
  if (backlogTasks.length > 0) {
    nextTask = backlogTasks[0];
  }

  // 2. If no backlog, find first failed task that's not current
  if (!nextTask) {
    const failedTasks = tasks.filter(
      (t) => t.status === "failed" && t.id !== current.task_id
    );
    if (failedTasks.length > 0) {
      nextTask = failedTasks[0];
    }
  }

  // 3. If still no task, check if we should retry current failed task
  if (!nextTask && current.task_id) {
    const currentTask = tasks.find((t) => t.id === current.task_id);
    if (currentTask?.status === "failed") {
      console.log(`\n🔄 Retrying current failed task: ${currentTask.id}`);
      nextTask = currentTask;
    }
  }

  if (!nextTask) {
    console.log("\n✅ No more tasks in queue.");
    if (current.task_id) {
      const currentTask = tasks.find((t) => t.id === current.task_id);
      if (currentTask?.status === "done") {
        console.log("   All tasks completed!");
      } else {
        console.log(`   Current task ${current.task_id} still active.`);
      }
    }
    console.log("\n   Run: techlead add \"new task\"");
    return;
  }

  // Switch to next task
  writeCurrent({ task_id: nextTask.id, phase: nextTask.phase });

  console.log("\n➡️  Switched to next task:\n");
  console.log(`   ID:     ${nextTask.id}`);
  console.log(`   Title:  ${nextTask.title}`);
  console.log(`   Status: ${nextTask.status}`);
  if (nextTask.phase) {
    console.log(`   Phase:  ${nextTask.phase}`);
  }
  console.log(`\n   Run: techlead run  # to execute`);
  console.log(`   Run: techlead status  # to check`);
}

// Main CLI
function main(): void {
  const cli = cac("techlead");

  cli.command("init", "Initialize TechLead").action(cmdInit);
  cli.command("add <title>", "Add a new task").action(cmdAdd);
  cli.command("list", "List all tasks").action(cmdList);
  cli.command("status", "Show current status").action(cmdStatus);
  cli.command("next", "Switch to next task in queue").action(cmdNext);
  cli.command("run", "Auto-run current/next task").action(cmdRun);
  cli.command("abort", "Abort current task").action(cmdAbort);

  cli.help();
  cli.parse();
}

main();
