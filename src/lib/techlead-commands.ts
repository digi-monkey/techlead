import fs from "node:fs";
import path from "node:path";
import {
  executeAgent,
  detectAgent,
  createDefaultConfig,
  type AgentResult,
} from "./agent-adapter.js";
import type { Task } from "./techlead-types.js";
import {
  getKnowledgeDir,
  getTaskDir,
  getTasksDir,
  getTechleadDir,
  getTemplatesRoot,
} from "./techlead-paths.js";
import {
  copyDir,
  generateTaskId,
  hasCriticalVerdict,
  isStepCompleted,
  loadPromptTemplate,
  renderTemplate,
  runQualityGate,
  sanitizeDirName,
} from "./techlead-utils.js";
import {
  findNextTask,
  listAllTasks,
  readCurrent,
  readTask,
  resolveTaskForCommand,
  selectTaskForExecution,
  writeCurrent,
  writeTask,
} from "./techlead-task-repo.js";

export function cmdHello(): void {
  console.log("hello from techlead");
}

export function cmdWorld(): void {
  const agentProvider = detectAgent();
  if (!agentProvider) {
    console.error("❌ No agent CLI found.");
    console.error("   Install Claude Code: npm install -g @anthropic-ai/claude-code");
    process.exit(1);
  }

  const config = createDefaultConfig(process.cwd());
  if (!config) {
    console.error("❌ Failed to create agent config");
    process.exit(1);
  }
  config.provider = "claude";

  console.log("🌍 Asking Claude to say hello to the world...");
  const result = executeAgent(
    'Say "Hello, World!" in a creative and inspiring way. Keep it under 3 sentences.',
    config,
    { timeoutMs: 30000 }
  );

  if (result.success) {
    console.log(`\n${result.content}`);
  } else {
    console.error("❌ Agent error:", result.error);
    process.exit(1);
  }
}

export function cmdInit(): void {
  const techleadDir = getTechleadDir();

  if (fs.existsSync(techleadDir)) {
    console.log("TechLead already initialized.");
    return;
  }

  const templatesRoot = getTemplatesRoot();
  if (fs.existsSync(templatesRoot)) {
    copyDir(templatesRoot, techleadDir);
    console.log("✅ TechLead initialized from templates.");
  } else {
    fs.mkdirSync(techleadDir, { recursive: true });
    fs.mkdirSync(getTasksDir(), { recursive: true });
    fs.mkdirSync(getKnowledgeDir(), { recursive: true });
    writeCurrent({ task_id: null, phase: null });
    console.log("✅ TechLead initialized.");
  }

  console.log('\nNext: techlead add "your task"');
}

export function cmdAdd(title: string): void {
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

  const templatesRoot = getTemplatesRoot();
  const taskTemplateDir = path.join(templatesRoot, "tasks");
  if (fs.existsSync(taskTemplateDir)) {
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

export function cmdList(): void {
  const tasks = listAllTasks();

  if (tasks.length === 0) {
    console.log('No tasks. Run: techlead add "task title"');
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

export function cmdStatus(): void {
  const current = readCurrent();

  if (!current.task_id) {
    const next = findNextTask();
    if (next) {
      console.log(`\n📍 Next task: ${next.id} - ${next.title}`);
      console.log("   Run: techlead run");
    } else {
      console.log("\n📍 No active task.");
      console.log('   Run: techlead add "task title"');
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

export function cmdPlan(taskId?: string): void {
  const task = resolveTaskForCommand(taskId);
  if (!task) {
    console.error("❌ No task found for plan command.");
    return;
  }
  if (task.status !== "backlog") {
    console.error(
      `❌ Task ${task.id} is not in backlog (current: ${task.status}/${task.phase || "-"}).`
    );
    return;
  }

  selectTaskForExecution(task);
  cmdRun();
}

export function cmdStart(taskId?: string): void {
  const task = resolveTaskForCommand(taskId);
  if (!task) {
    console.error("❌ No task found for start command.");
    return;
  }
  if (!(task.status === "in_progress" && task.phase === "plan")) {
    console.error(
      `❌ Task ${task.id} is not ready for start (expected in_progress/plan, got ${task.status}/${task.phase || "-"}).`
    );
    return;
  }

  selectTaskForExecution(task);
  cmdRun();
}

export function cmdStep(taskId?: string): void {
  const task = resolveTaskForCommand(taskId);
  if (!task) {
    console.error("❌ No task found for step command.");
    return;
  }
  if (!(task.status === "in_progress" && task.phase === "exec")) {
    console.error(
      `❌ Task ${task.id} is not in exec phase (current: ${task.status}/${task.phase || "-"}).`
    );
    return;
  }

  selectTaskForExecution(task);
  cmdRun();
}

export function cmdReview(taskId?: string): void {
  const task = resolveTaskForCommand(taskId);
  if (!task) {
    console.error("❌ No task found for review command.");
    return;
  }
  if (!(task.status === "review" && task.phase === "review")) {
    console.error(
      `❌ Task ${task.id} is not in review phase (current: ${task.status}/${task.phase || "-"}).`
    );
    return;
  }

  selectTaskForExecution(task);
  cmdRun();
}

export function cmdTest(taskId?: string): void {
  const task = resolveTaskForCommand(taskId);
  if (!task) {
    console.error("❌ No task found for test command.");
    return;
  }
  if (!(task.status === "testing" && task.phase === "test")) {
    console.error(
      `❌ Task ${task.id} is not in test phase (current: ${task.status}/${task.phase || "-"}).`
    );
    return;
  }

  selectTaskForExecution(task);
  cmdRun();
}

export function cmdDone(taskId?: string): void {
  const task = resolveTaskForCommand(taskId);
  if (!task) {
    console.error("❌ No task found for done command.");
    return;
  }

  if (task.status === "done") {
    console.log(`✅ Task ${task.id} is already done.`);
    return;
  }

  if (!(task.status === "testing" && task.test_passed === true)) {
    console.error(
      `❌ Task ${task.id} is not ready for done; run test first (current: ${task.status}/${task.phase || "-"}).`
    );
    return;
  }

  task.status = "done";
  task.phase = "completed";
  task.completed_at = new Date().toISOString();
  writeTask(task.id, task);

  const current = readCurrent();
  if (current.task_id === task.id) {
    writeCurrent({ task_id: null, phase: null });
  }

  console.log(`✅ Task ${task.id} marked as done.`);
}

export function cmdRun(): void {
  const nextTask = findNextTask();

  if (!nextTask) {
    console.log("\n✅ All tasks completed!");
    console.log('   Run: techlead add "new task"');
    return;
  }

  const agentProvider = detectAgent();
  if (!agentProvider) {
    console.error("\n❌ No agent CLI found.");
    console.error("   Install Claude Code: npm install -g @anthropic-ai/claude-code");
    console.error("   Install Codex: npm install -g @openai/codex");
    return;
  }

  console.log(`\n🚀 Running: ${nextTask.id} - ${nextTask.title}`);
  console.log(`   Agent: ${agentProvider}`);
  console.log(`   Status: ${nextTask.status}`);
  console.log(`   Phase: ${nextTask.phase || "starting"}`);

  if (nextTask.status === "backlog") {
    console.log("   Compose: plan");
  } else if (nextTask.status === "in_progress" && nextTask.phase === "plan") {
    console.log("   Compose: start");
  } else if (nextTask.status === "in_progress" && nextTask.phase === "exec") {
    console.log("   Compose: step");
  } else if (nextTask.status === "review" && nextTask.phase === "review") {
    console.log("   Compose: review");
  } else if (nextTask.status === "testing" && nextTask.phase === "test") {
    console.log("   Compose: test/done");
  }

  writeCurrent({ task_id: nextTask.id, phase: nextTask.phase });

  const config = createDefaultConfig(process.cwd());
  if (!config) {
    console.error("❌ Failed to create agent config");
    return;
  }

  const taskDir = getTaskDir(nextTask.id);
  let result: AgentResult;

  switch (nextTask.status) {
    case "backlog": {
      console.log("\n   → Entering Plan phase\n");

      nextTask.status = "in_progress";
      nextTask.phase = "plan";
      nextTask.started_at = new Date().toISOString();
      writeTask(nextTask.id, nextTask);
      writeCurrent({ task_id: nextTask.id, phase: "plan" });

      const planDir = path.join(taskDir, "plan");
      fs.mkdirSync(planDir, { recursive: true });

      const planTemplate = loadPromptTemplate("prompts/plan/multirole.md");
      const userPrompt = planTemplate
        ? renderTemplate(planTemplate, {
            TASK_ID: nextTask.id,
            TASK_TITLE: nextTask.title,
            ROLES: "architect,security,dx",
          })
        : `You are a software architect. Create a simple execution plan for this task:\n\nTask: ${nextTask.title}\n\nCreate these files in the plan/ directory:\n1. plan.md - 3-5 step execution plan\n2. discussion.md - Brief technical considerations\n\nKeep it concise.`;

      console.log("   🤖 Agent generating plan (simplified)...");
      result = executeAgent(userPrompt, config, {
        timeoutMs: 60000,
      });

      if (result.success) {
        console.log("   ✅ Plan generated");
        console.log(`   💰 Cost: $${result.costUsd?.toFixed(4) || "?"}`);

        const discussionPath = path.join(planDir, "discussion.md");
        const planMdPath = path.join(planDir, "plan.md");
        const abstractPath = path.join(planDir, ".abstract.md");
        const overviewPath = path.join(planDir, ".overview.md");

        if (!fs.existsSync(discussionPath)) {
          fs.writeFileSync(
            discussionPath,
            `# Discussion: ${nextTask.title}\n\n${result.content}\n`,
            "utf8"
          );
        }
        if (!fs.existsSync(planMdPath)) {
          fs.writeFileSync(
            planMdPath,
            `# Plan: ${nextTask.title}\n\nSee discussion.md for details.\n\n## Steps\n\n1. [ ] Implement\n2. [ ] Test\n3. [ ] Review\n`,
            "utf8"
          );
        }
        if (!fs.existsSync(abstractPath)) {
          fs.writeFileSync(abstractPath, result.content.substring(0, 200), "utf8");
        }
        if (!fs.existsSync(overviewPath)) {
          fs.writeFileSync(
            overviewPath,
            `# Overview: ${nextTask.title}\n\nSee discussion.md and plan.md\n`,
            "utf8"
          );
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

        nextTask.phase = "exec";
        writeTask(nextTask.id, nextTask);
        writeCurrent({ task_id: nextTask.id, phase: "exec" });

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

        const workLog = fs.existsSync(workLogPath) ? fs.readFileSync(workLogPath, "utf8") : "";
        const plan = fs.existsSync(planPath) ? fs.readFileSync(planPath, "utf8") : "";

        const recentEntries = workLog
          .split("\n")
          .filter((l) => l.startsWith("## "))
          .slice(-5)
          .join("\n");

        const execTemplate = loadPromptTemplate("prompts/exec/step.md");
        const userPrompt = execTemplate
          ? `${renderTemplate(execTemplate, {
              TASK_ID: nextTask.id,
              TASK_TITLE: nextTask.title,
              TIMESTAMP: new Date().toISOString(),
            })}\n\n---\n\nTask: ${nextTask.title}\n\nPlan:\n${plan}\n\nRecent work:\n${recentEntries}`
          : `Execute one step of the task.\n\nTask: ${nextTask.title}\n\nPlan:\n${plan}\n\nRecent work:\n${recentEntries}\n\nInstructions:\n1. Read the plan and recent work\n2. Execute ONE small step (15-30 min of work)\n3. Run verification (e.g., pnpm test)\n4. Report what was done\n\nOutput format:\n- Action: What you did\n- Files changed: List of files\n- Verification: Test results\n- Status: continue | completed`;

        console.log("   🤖 Agent executing step...");
        result = executeAgent(userPrompt, config, {
          outputFormat: "json",
          timeoutMs: 300000,
        });

        if (result.success) {
          console.log("   ✅ Step completed");
          console.log(`   💰 Cost: $${result.costUsd?.toFixed(4) || "?"}`);

          fs.appendFileSync(
            workLogPath,
            `\n## ${new Date().toISOString()}\n\n${result.content}\n\n---\n`,
            "utf8"
          );

          if (isStepCompleted(result.content)) {
            console.log("\n   ✨ Task appears complete!");
            const gate = runQualityGate();
            if (!gate.passed) {
              console.log("\n   ⚠️  Quality gate failed; staying in Exec phase");
              console.log(`   Command: ${gate.command}`);

              fs.appendFileSync(
                workLogPath,
                `\n## ${new Date().toISOString()} - Quality gate failed\n\nCommand: ${gate.command}\n\n${gate.output || gate.error || "Unknown error"}\n\n---\n`,
                "utf8"
              );
            } else {
              console.log("   ✅ Quality gate passed");
              console.log("   → Moving to Review phase\n");

              nextTask.status = "review";
              nextTask.phase = "review";
              writeTask(nextTask.id, nextTask);
              writeCurrent({ task_id: nextTask.id, phase: "review" });

              const reviewDir = path.join(taskDir, "review");
              fs.mkdirSync(reviewDir, { recursive: true });

              console.log("   📁 Review directory created");
              console.log("   Run: techlead run  # to start review");
            }
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

  if (nextTask.status === "review" && nextTask.phase === "review") {
    if (nextTask.review_passed === true) {
      console.log("\n   ✓ Already reviewed (passed)");
      console.log("   → Moving to Test phase\n");
      nextTask.status = "testing";
      nextTask.phase = "test";
      writeTask(nextTask.id, nextTask);
      writeCurrent({ task_id: nextTask.id, phase: "test" });
    } else if (nextTask.review_attempts && nextTask.review_attempts >= 1) {
      const reviewPath = path.join(taskDir, "review", "reviewer-1.md");
      if (fs.existsSync(reviewPath)) {
        const existingReview = fs.readFileSync(reviewPath, "utf8");
        const hasCritical = hasCriticalVerdict(existingReview);

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

    nextTask.review_attempts = (nextTask.review_attempts || 0) + 1;
    writeTask(nextTask.id, nextTask);

    const reviewTemplate = loadPromptTemplate("prompts/review/adversarial.md");
    const systemPrompt = reviewTemplate
      ? renderTemplate(reviewTemplate, {
          REVIEWER_PERSPECTIVE: "Skeptic",
          TASK_ID: nextTask.id,
          TASK_TITLE: nextTask.title,
          N: "1",
          PERSPECTIVE: "Skeptic",
        })
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

      const reviewPath = path.join(reviewDir, "reviewer-1.md");
      fs.writeFileSync(
        reviewPath,
        `# Adversarial Review: ${nextTask.title}\n\n${result.content}\n`,
        "utf8"
      );

      const workLogPath = path.join(taskDir, "work-log.md");
      if (fs.existsSync(workLogPath)) {
        fs.appendFileSync(
          workLogPath,
          `\n## ${new Date().toISOString()} - Review ${nextTask.review_attempts}\n\n- Review completed\n- Cost: $${result.costUsd?.toFixed(4) || "?"}\n\n---\n`,
          "utf8"
        );
      }

      const hasCritical = hasCriticalVerdict(result.content);

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

        const testDir = path.join(taskDir, "test");
        fs.mkdirSync(testDir, { recursive: true });
        console.log("   📁 Test directory created");
      }
    } else {
      console.error("   ❌ Review failed");
      console.error(`   Error: ${result.error}`);
    }
  }

  if (nextTask.status === "testing" && nextTask.phase === "test") {
    if (nextTask.test_passed === true) {
      console.log("\n   ✓ Already tested (passed)");
      console.log("   → Marking as Done\n");
      nextTask.status = "done";
      nextTask.phase = "completed";
      nextTask.completed_at = new Date().toISOString();
      writeTask(nextTask.id, nextTask);
      writeCurrent({ task_id: null, phase: null });

      console.log(`   ✅ Task ${nextTask.id} completed!`);
      console.log(
        `   Duration: ${nextTask.started_at && nextTask.completed_at ? `${Math.round((new Date(nextTask.completed_at).getTime() - new Date(nextTask.started_at).getTime()) / 1000 / 60)} min` : "N/A"}`
      );
      return;
    } else if (nextTask.test_attempts && nextTask.test_attempts >= 1) {
      const testPath = path.join(taskDir, "test", "adversarial-test.md");
      if (fs.existsSync(testPath)) {
        const existingTest = fs.readFileSync(testPath, "utf8");
        const hasCritical = hasCriticalVerdict(existingTest);

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

    nextTask.test_attempts = (nextTask.test_attempts || 0) + 1;
    writeTask(nextTask.id, nextTask);

    const testTemplate = loadPromptTemplate("prompts/test/adversarial.md");
    const systemPrompt = testTemplate
      ? renderTemplate(testTemplate, {
          TESTER_PERSONA: "Attacker",
          TASK_ID: nextTask.id,
          TASK_TITLE: nextTask.title,
          PERSONA: "Attacker",
        })
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

      const testPath = path.join(testDir, "adversarial-test.md");
      fs.writeFileSync(
        testPath,
        `# Adversarial Test: ${nextTask.title}\n\n${result.content}\n`,
        "utf8"
      );

      const workLogPath = path.join(taskDir, "work-log.md");
      if (fs.existsSync(workLogPath)) {
        fs.appendFileSync(
          workLogPath,
          `\n## ${new Date().toISOString()} - Test ${nextTask.test_attempts}\n\n- Test completed\n- Cost: $${result.costUsd?.toFixed(4) || "?"}\n\n---\n`,
          "utf8"
        );
      }

      const hasCritical = hasCriticalVerdict(result.content);

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
        console.log(
          `   Duration: ${nextTask.started_at && nextTask.completed_at ? `${Math.round((new Date(nextTask.completed_at).getTime() - new Date(nextTask.started_at).getTime()) / 1000 / 60)} min` : "N/A"}`
        );
      }
    } else {
      console.error("   ❌ Testing failed");
      console.error(`   Error: ${result.error}`);
    }
  }
}

export function cmdLoop(options: {
  maxCycles?: string | number;
  maxNoProgress?: string | number;
}): void {
  const maxCyclesRaw = options.maxCycles ?? 20;
  const maxNoProgressRaw = options.maxNoProgress ?? 3;
  const maxCycles = Number(maxCyclesRaw);
  const maxNoProgress = Number(maxNoProgressRaw);

  if (!Number.isFinite(maxCycles) || maxCycles < 1) {
    console.error("❌ --max-cycles must be a positive number");
    return;
  }
  if (!Number.isFinite(maxNoProgress) || maxNoProgress < 1) {
    console.error("❌ --max-no-progress must be a positive number");
    return;
  }

  console.log(
    `\n🔁 Starting autonomous loop (max cycles: ${maxCycles}, max no-progress: ${maxNoProgress})`
  );

  let previousState = "";
  let noProgressCount = 0;

  for (let cycle = 1; cycle <= maxCycles; cycle += 1) {
    const beforeCurrent = readCurrent();
    const beforeTask = beforeCurrent.task_id ? readTask(beforeCurrent.task_id) : null;
    const beforeDoneCount = listAllTasks().filter((t) => t.status === "done").length;

    console.log(`\n=== Loop Cycle ${cycle}/${maxCycles} ===`);
    cmdRun();

    const allTasks = listAllTasks();
    const afterDoneCount = allTasks.filter((t) => t.status === "done").length;
    const pendingCount = allTasks.filter((t) => t.status !== "done").length;
    const afterCurrent = readCurrent();
    const afterTask = afterCurrent.task_id ? readTask(afterCurrent.task_id) : null;

    if (pendingCount === 0) {
      console.log("\n✅ Loop completed: all tasks are done.");
      return;
    }

    const stateKey = `${afterCurrent.task_id || "none"}:${afterTask?.status || "none"}:${afterTask?.phase || "none"}:${afterDoneCount}`;
    const progressed =
      afterDoneCount > beforeDoneCount ||
      (beforeTask && afterTask
        ? beforeTask.status !== afterTask.status || beforeTask.phase !== afterTask.phase
        : beforeCurrent.task_id !== afterCurrent.task_id);

    if (!progressed && stateKey === previousState) {
      noProgressCount += 1;
    } else {
      noProgressCount = 0;
      previousState = stateKey;
    }

    if (afterTask) {
      if ((afterTask.review_attempts || 0) >= 3) {
        console.log(`\n⚠️  Loop stopped: review attempts reached limit for ${afterTask.id}.`);
        return;
      }
      if ((afterTask.test_attempts || 0) >= 3) {
        console.log(`\n⚠️  Loop stopped: test attempts reached limit for ${afterTask.id}.`);
        return;
      }
    }

    if (noProgressCount >= maxNoProgress) {
      console.log("\n⚠️  Loop stopped: no progress across consecutive cycles.");
      return;
    }
  }

  console.log("\n⏸️  Loop stopped: reached max cycle limit.");
}

export function cmdAbort(): void {
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

export function cmdNext(): void {
  const current = readCurrent();
  const tasks = listAllTasks();

  let nextTask: Task | null = null;

  const backlogTasks = tasks.filter((t) => t.status === "backlog" && t.id !== current.task_id);
  if (backlogTasks.length > 0) {
    nextTask = backlogTasks[0];
  }

  if (!nextTask) {
    const failedTasks = tasks.filter((t) => t.status === "failed" && t.id !== current.task_id);
    if (failedTasks.length > 0) {
      nextTask = failedTasks[0];
    }
  }

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
    console.log('\n   Run: techlead add "new task"');
    return;
  }

  writeCurrent({ task_id: nextTask.id, phase: nextTask.phase });

  console.log("\n➡️  Switched to next task:\n");
  console.log(`   ID:     ${nextTask.id}`);
  console.log(`   Title:  ${nextTask.title}`);
  console.log(`   Status: ${nextTask.status}`);
  if (nextTask.phase) {
    console.log(`   Phase:  ${nextTask.phase}`);
  }
  console.log("\n   Run: techlead run  # to execute");
  console.log("   Run: techlead status  # to check");
}
