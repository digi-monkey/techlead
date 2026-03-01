/**
 * Example usage of agent-adapter
 */

import {
  AgentConfig,
  AgentOptions,
  createDefaultConfig,
  detectAgent,
  executeAgent,
  executeAgentAsync,
  isAgentAvailable,
} from "./agent-adapter.js";

// Example 1: Basic usage with auto-detection
async function example1() {
  console.log("=== Example 1: Auto-detect and execute ===\n");

  const agent = detectAgent();
  if (!agent) {
    console.log("No agent CLI found. Install claude or codex.");
    return;
  }

  console.log(`Detected: ${agent}`);

  const config = createDefaultConfig(process.cwd());
  if (!config) return;

  const result = executeAgent(
    "List the files in the current directory",
    config,
    { outputFormat: "text" }
  );

  console.log("Success:", result.success);
  console.log("Content:", result.content.substring(0, 500));
  console.log("Cost:", result.costUsd);
}

// Example 2: Execute with system prompt from file
async function example2() {
  console.log("\n=== Example 2: With system prompt ===\n");

  const config: AgentConfig = {
    provider: "claude",
    model: "sonnet",
    maxBudgetUsd: 0.5,
    allowedTools: ["Read", "Bash"],
    workingDir: process.cwd(),
  };

  const options: AgentOptions = {
    systemPrompt: "You are a helpful assistant. Be concise.",
    outputFormat: "json",
    timeoutMs: 60000,
  };

  const result = executeAgent(
    "What is the current git branch?",
    config,
    options
  );

  console.log("Success:", result.success);
  console.log("Session ID:", result.sessionId);
  console.log("Tokens:", result.inputTokens, "in /", result.outputTokens, "out");
}

// Example 3: Async with streaming
async function example3() {
  console.log("\n=== Example 3: Async with streaming ===\n");

  const config: AgentConfig = {
    provider: "codex",
    model: "gpt-4o",
    workingDir: process.cwd(),
  };

  const result = await executeAgentAsync(
    "Explain what this codebase does",
    config,
    { outputFormat: "text" },
    (chunk) => {
      process.stdout.write(chunk); // Stream to console
    }
  );

  console.log("\n\nFinal success:", result.success);
}

// Example 4: Structured output with JSON schema
async function example4() {
  console.log("\n=== Example 4: Structured output ===\n");

  const schema = {
    type: "object",
    properties: {
      summary: { type: "string" },
      files: {
        type: "array",
        items: { type: "string" },
      },
      confidence: { type: "number", minimum: 0, maximum: 1 },
    },
    required: ["summary", "files"],
  };

  const config: AgentConfig = {
    provider: "claude",
    model: "sonnet",
    workingDir: process.cwd(),
  };

  const options: AgentOptions = {
    outputFormat: "json",
    jsonSchema: schema,
  };

  const result = executeAgent(
    "Analyze the src directory and summarize what this project does",
    config,
    options
  );

  if (result.success) {
    try {
      const data = JSON.parse(result.content);
      console.log("Parsed result:", JSON.stringify(data, null, 2));
    } catch {
      console.log("Raw result:", result.content);
    }
  }
}

// Example 5: Multi-step task (simulating subagent)
async function example5() {
  console.log("\n=== Example 5: Multi-step (simulating subagent) ===\n");

  const workingDir = process.cwd();
  const config = createDefaultConfig(workingDir);
  if (!config) return;

  // Step 1: Planner
  console.log("Step 1: Planning...");
  const planResult = executeAgent(
    "Create a plan to refactor the main CLI file into smaller modules",
    config,
    {
      systemPrompt: "You are a planner. Output a numbered list of steps.",
      outputFormat: "text",
    }
  );

  if (!planResult.success) {
    console.log("Planning failed:", planResult.error);
    return;
  }

  console.log("Plan:\n", planResult.content.substring(0, 300));

  // Step 2: Executor (would iterate through plan)
  console.log("\nStep 2: Executing first step...");
  const execResult = executeAgent(
    `Execute the first step of this plan:\n${planResult.content}`,
    config,
    {
      systemPrompt: "You are a coder. Implement the changes.",
      outputFormat: "text",
    }
  );

  console.log("Execution result:", execResult.success ? "Success" : "Failed");

  // Step 3: Reviewer
  console.log("\nStep 3: Reviewing...");
  const reviewResult = executeAgent(
    "Review the changes made to the codebase. List any issues.",
    config,
    {
      systemPrompt:
        "You are a code reviewer. Be critical and find potential bugs.",
      outputFormat: "text",
    }
  );

  console.log("Review:\n", reviewResult.content.substring(0, 300));
}

// Run examples
if (require.main === module) {
  (async () => {
    // Check available agents
    console.log("Available agents:");
    console.log("  claude:", isAgentAvailable("claude"));
    console.log("  codex:", isAgentAvailable("codex"));
    console.log();

    // Run examples
    await example1();
    // await example2();
    // await example3();
    // await example4();
    // await example5();
  })();
}
