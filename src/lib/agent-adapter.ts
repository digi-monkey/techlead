/**
 * Agent Adapter - Unified interface for Claude Code and Codex CLI
 */

import { execSync, execFileSync, spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { AgentExecutionLogger, generateTaskId } from "./agent-logger.js";

export type AgentProvider = "claude" | "codex";

export interface AgentConfig {
  provider: AgentProvider;
  model?: string;
  maxBudgetUsd?: number;
  allowedTools?: string[];
  workingDir?: string;
}

export interface AgentResult {
  success: boolean;
  content: string;
  sessionId?: string;
  costUsd?: number;
  inputTokens?: number;
  outputTokens?: number;
  error?: string;
}

export interface AgentOptions {
  systemPrompt?: string;
  systemPromptFile?: string;
  outputFormat?: "text" | "json";
  jsonSchema?: object;
  timeoutMs?: number;
  env?: Record<string, string>;
  /**
   * Enable execution logging
   * @default false
   */
  enableLogging?: boolean;
  /**
   * Custom task ID for logging
   * If not provided, a new one will be generated
   */
  taskId?: string;
  /**
   * Session ID for grouping related tasks
   */
  sessionId?: string;
  /**
   * Directory for log files
   * @default "logs/agent-executions"
   */
  logDir?: string;
}

/**
 * Check if agent CLI is available
 */
export function isAgentAvailable(provider: AgentProvider): boolean {
  try {
    execSync(`which ${provider}`, { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

/**
 * Load system prompt from file or use provided string
 */
function loadSystemPrompt(options: AgentOptions): string | undefined {
  if (options.systemPromptFile && existsSync(options.systemPromptFile)) {
    return readFileSync(options.systemPromptFile, "utf8");
  }
  return options.systemPrompt;
}

/**
 * Build Claude Code CLI command
 */
export function buildClaudeCommand(
  prompt: string,
  config: AgentConfig,
  options: AgentOptions
): string {
  const args: string[] = ["-p"]; // Non-interactive mode

  // Output format
  if (options.outputFormat === "json") {
    args.push("--output-format=json");
  }

  // Model
  if (config.model) {
    args.push(`--model=${config.model}`);
  }

  // Budget limit
  if (config.maxBudgetUsd) {
    args.push(`--max-budget-usd=${config.maxBudgetUsd}`);
  }

  // Allowed tools
  if (config.allowedTools?.length) {
    args.push(`--allowed-tools=${config.allowedTools.join(",")}`);
  }

  // System prompt - merge into user prompt to avoid escaping issues
  const systemPrompt = loadSystemPrompt(options);
  let finalPrompt = prompt;
  if (systemPrompt) {
    finalPrompt = `[System Instructions]\n${systemPrompt}\n\n[User Request]\n${prompt}`;
  }

  // JSON Schema for structured output
  if (options.jsonSchema) {
    const schemaStr = JSON.stringify(options.jsonSchema).replace(/"/g, '\\"');
    args.push(`--json-schema="${schemaStr}"`);
  }

  // Working directory
  if (config.workingDir) {
    args.push(`--add-dir=${resolve(config.workingDir)}`);
  }

  // Disable session persistence for non-interactive
  args.push("--no-session-persistence");

  // Add the prompt (no escaping needed, execSync handles it)
  args.push(finalPrompt);

  return `claude ${args.join(" ")}`;
}

/**
 * Build Codex CLI command - simplified without shell escaping
 */
export function buildCodexCommand(
  prompt: string,
  config: AgentConfig,
  options: AgentOptions
): { cmd: string; args: string[] } {
  const args: string[] = ["exec"];

  // Output format
  if (options.outputFormat === "json") {
    args.push("--json");
  }

  // Model
  if (config.model) {
    args.push(`-m=${config.model}`);
  }

  // Full auto mode (non-interactive)
  args.push("--full-auto");

  // Sandbox mode
  args.push("--sandbox=workspace-write");

  // Working directory
  if (config.workingDir) {
    args.push(`-C=${resolve(config.workingDir)}`);
  }

  // System prompt via config
  const systemPrompt = loadSystemPrompt(options);
  if (systemPrompt) {
    args.push(`-c=system_prompt=${systemPrompt}`);
  }

  // Add the prompt as final arg
  args.push(prompt);

  return { cmd: "codex", args };
}

/**
 * Parse Claude Code JSON output
 */
export function parseClaudeOutput(output: string): AgentResult {
  try {
    const data = JSON.parse(output);
    return {
      success: data.subtype === "success" && !data.is_error,
      content: data.result || "",
      sessionId: data.session_id,
      costUsd: data.total_cost_usd,
      inputTokens: data.usage?.input_tokens,
      outputTokens: data.usage?.output_tokens,
    };
  } catch (error) {
    return {
      success: false,
      content: output,
      error: `Failed to parse JSON: ${error}`,
    };
  }
}

/**
 * Parse Codex JSONL output
 */
export function parseCodexOutput(output: string): AgentResult {
  // Codex outputs JSONL, find the last result message
  const lines = output.trim().split("\n");
  let lastResult: any = null;

  for (const line of lines) {
    try {
      const data = JSON.parse(line);
      if (data.type === "result" || data.type === "message") {
        lastResult = data;
      }
    } catch {
      // Skip invalid JSON lines
    }
  }

  if (!lastResult) {
    return {
      success: output.length > 0,
      content: output,
    };
  }

  return {
    success: lastResult.type === "result" && !lastResult.error,
    content: lastResult.content || lastResult.message || output,
    sessionId: lastResult.session_id,
    error: lastResult.error,
  };
}

/**
 * Execute agent with unified interface
 */
export function executeAgent(
  prompt: string,
  config: AgentConfig,
  options: AgentOptions = {}
): AgentResult {
  if (!isAgentAvailable(config.provider)) {
    return {
      success: false,
      content: "",
      error: `${config.provider} CLI not found. Please install it.`,
    };
  }

  // Initialize logger if enabled
  const logger = options.enableLogging
    ? new AgentExecutionLogger({
        taskId: options.taskId ?? generateTaskId(),
        sessionId: options.sessionId,
        logDir: options.logDir,
        provider: config.provider,
        model: config.model,
        workingDir: config.workingDir,
      })
    : null;

  // Log input
  logger?.logInput(prompt, {
    systemPrompt: options.systemPrompt,
    outputFormat: options.outputFormat,
  });

  try {
    let output: string;

    if (config.provider === "claude") {
      // Claude: use stdin to pass prompt to avoid shell escaping issues
      const args: string[] = ["-p"];

      // Output format
      if (options.outputFormat === "json") {
        args.push("--output-format=json");
      }

      // Model
      if (config.model) {
        args.push(`--model=${config.model}`);
      }

      // Budget limit
      if (config.maxBudgetUsd) {
        args.push(`--max-budget-usd=${config.maxBudgetUsd}`);
      }

      // Allowed tools
      if (config.allowedTools?.length) {
        args.push(`--allowed-tools=${config.allowedTools.join(",")}`);
      }

      // Working directory
      if (config.workingDir) {
        args.push(`--add-dir=${resolve(config.workingDir)}`);
      }

      // Disable session persistence for non-interactive
      args.push("--no-session-persistence");

      // Prepare input (system + user prompt)
      const systemPrompt = loadSystemPrompt(options);
      const input = systemPrompt
        ? `[System Instructions]\n${systemPrompt}\n\n[User Request]\n${prompt}`
        : prompt;

      output = execFileSync("claude", args, {
        encoding: "utf8",
        timeout: options.timeoutMs || 300000,
        cwd: config.workingDir,
        env: { ...process.env, ...options.env },
        maxBuffer: 50 * 1024 * 1024,
        input, // Pass via stdin
      });

      // Log output
      logger?.logStdout(output);
      logger?.logEnd(0);

      if (options.outputFormat === "json") {
        return parseClaudeOutput(output);
      }
      return { success: true, content: output };
    } else {
      // Codex: use spawn with args array to avoid shell escaping
      const { cmd, args } = buildCodexCommand(prompt, config, options);
      output = execFileSync(cmd, args, {
        encoding: "utf8",
        timeout: options.timeoutMs || 300000,
        cwd: config.workingDir,
        env: { ...process.env, ...options.env },
        maxBuffer: 50 * 1024 * 1024,
      });

      // Log output
      logger?.logStdout(output);
      logger?.logEnd(0);

      if (options.outputFormat === "json") {
        return parseCodexOutput(output);
      }
      return { success: true, content: output };
    }
  } catch (error: any) {
    const errorMessage = error.message || String(error);
    const stdout = error.stdout || "";

    // Log error
    logger?.logError(error instanceof Error ? error : new Error(errorMessage));
    logger?.logEnd(null);

    return {
      success: false,
      content: stdout,
      error: errorMessage,
    };
  }
}

/**
 * Execute agent asynchronously with streaming support
 */
export async function executeAgentAsync(
  prompt: string,
  config: AgentConfig,
  options: AgentOptions = {},
  onChunk?: (chunk: string) => void
): Promise<AgentResult> {
  if (!isAgentAvailable(config.provider)) {
    return {
      success: false,
      content: "",
      error: `${config.provider} CLI not found`,
    };
  }

  // Initialize logger if enabled
  const logger = options.enableLogging
    ? new AgentExecutionLogger({
        taskId: options.taskId ?? generateTaskId(),
        sessionId: options.sessionId,
        logDir: options.logDir,
        provider: config.provider,
        model: config.model,
        workingDir: config.workingDir,
      })
    : null;

  // Log input
  logger?.logInput(prompt, {
    systemPrompt: options.systemPrompt,
    outputFormat: options.outputFormat,
  });

  return new Promise((resolve) => {
    const chunks: string[] = [];
    let child: ReturnType<typeof spawn>;

    if (config.provider === "claude") {
      // Claude: use shell command
      const command = buildClaudeCommand(prompt, config, options);
      child = spawn(command, {
        shell: true,
        cwd: config.workingDir,
        env: { ...process.env, ...options.env },
      });
    } else {
      // Codex: use spawn with args array
      const { cmd, args } = buildCodexCommand(prompt, config, options);
      child = spawn(cmd, args, {
        cwd: config.workingDir,
        env: { ...process.env, ...options.env },
      });
    }

    child.stdout?.on("data", (data: Buffer) => {
      const chunk = data.toString();
      chunks.push(chunk);
      logger?.logStdout(chunk);
      onChunk?.(chunk);
    });

    child.stderr?.on("data", (data: Buffer) => {
      const chunk = data.toString();
      chunks.push(chunk);
      logger?.logStderr(chunk);
      onChunk?.(chunk);
    });

    child.on("close", (code) => {
      logger?.logEnd(code);
      const output = chunks.join("");

      if (options.outputFormat === "json") {
        const result =
          config.provider === "claude" ? parseClaudeOutput(output) : parseCodexOutput(output);
        resolve(result);
        return;
      }

      resolve({
        success: code === 0,
        content: output,
      });
    });

    child.on("error", (error) => {
      logger?.logError(error);
      logger?.logEnd(null);
      resolve({
        success: false,
        content: chunks.join(""),
        error: error.message,
      });
    });

    // Timeout
    setTimeout(() => {
      child.kill();
      logger?.logEnd(null);
      resolve({
        success: false,
        content: chunks.join(""),
        error: "Timeout",
      });
    }, options.timeoutMs || 300000);
  });
}

/**
 * Auto-detect available agent
 */
export function detectAgent(): AgentProvider | null {
  if (isAgentAvailable("claude")) return "claude";
  if (isAgentAvailable("codex")) return "codex";
  return null;
}

/**
 * Create default config for detected agent
 */
export function createDefaultConfig(workingDir?: string): AgentConfig | null {
  const provider = detectAgent();
  if (!provider) return null;

  return {
    provider,
    model: provider === "claude" ? "sonnet" : "gpt-4o",
    maxBudgetUsd: 1.0,
    allowedTools: ["Read", "Edit", "Bash", "Glob"],
    workingDir,
  };
}
