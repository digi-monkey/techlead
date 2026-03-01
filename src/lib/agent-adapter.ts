/**
 * Agent Adapter - Unified interface for Claude Code and Codex CLI
 */

import { execSync, spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

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

  // System prompt
  const systemPrompt = loadSystemPrompt(options);
  if (systemPrompt) {
    // Escape for shell
    const escaped = systemPrompt.replace(/"/g, '\\"').replace(/\n/g, "\\n");
    args.push(`--system-prompt="${escaped}"`);
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

  // Add the prompt
  const escapedPrompt = prompt.replace(/"/g, '\\"');
  args.push(`"${escapedPrompt}"`);

  return `claude ${args.join(" ")}`;
}

/**
 * Build Codex CLI command
 */
export function buildCodexCommand(
  prompt: string,
  config: AgentConfig,
  options: AgentOptions
): string {
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

  // Config overrides
  if (config.allowedTools) {
    // Codex uses different mechanism, skip for now
  }

  // System prompt via config
  const systemPrompt = loadSystemPrompt(options);
  if (systemPrompt) {
    const escaped = systemPrompt.replace(/"/g, '\\"').replace(/\n/g, "\\n");
    args.push(`-c=system_prompt="${escaped}"`);
  }

  // Add the prompt
  const escapedPrompt = prompt.replace(/"/g, '\\"');
  args.push(`"${escapedPrompt}"`);

  return `codex ${args.join(" ")}`;
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

  const command =
    config.provider === "claude"
      ? buildClaudeCommand(prompt, config, options)
      : buildCodexCommand(prompt, config, options);

  try {
    const output = execSync(command, {
      encoding: "utf8",
      timeout: options.timeoutMs || 300000, // 5 min default
      cwd: config.workingDir,
      env: { ...process.env, ...options.env },
      maxBuffer: 50 * 1024 * 1024, // 50MB buffer
    });

    if (options.outputFormat === "json") {
      return config.provider === "claude"
        ? parseClaudeOutput(output)
        : parseCodexOutput(output);
    }

    return {
      success: true,
      content: output,
    };
  } catch (error: any) {
    return {
      success: false,
      content: error.stdout || "",
      error: error.message,
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

  const command =
    config.provider === "claude"
      ? buildClaudeCommand(prompt, config, options)
      : buildCodexCommand(prompt, config, options);

  return new Promise((resolve) => {
    const chunks: string[] = [];
    const child = spawn(command, {
      shell: true,
      cwd: config.workingDir,
      env: { ...process.env, ...options.env },
    });

    child.stdout.on("data", (data: Buffer) => {
      const chunk = data.toString();
      chunks.push(chunk);
      onChunk?.(chunk);
    });

    child.stderr.on("data", (data: Buffer) => {
      const chunk = data.toString();
      chunks.push(chunk);
      onChunk?.(chunk);
    });

    child.on("close", (code) => {
      const output = chunks.join("");

      if (options.outputFormat === "json") {
        const result =
          config.provider === "claude"
            ? parseClaudeOutput(output)
            : parseCodexOutput(output);
        resolve(result);
        return;
      }

      resolve({
        success: code === 0,
        content: output,
      });
    });

    child.on("error", (error) => {
      resolve({
        success: false,
        content: chunks.join(""),
        error: error.message,
      });
    });

    // Timeout
    setTimeout(() => {
      child.kill();
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
export function createDefaultConfig(
  workingDir?: string
): AgentConfig | null {
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
