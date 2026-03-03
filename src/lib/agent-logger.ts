/**
 * Agent Execution Logger
 * Records all I/O with metadata for replay and analysis
 */

import { mkdirSync, appendFileSync } from "node:fs";
import { dirname } from "node:path";

export interface LogEntry {
  timestamp: number;
  taskId: string;
  sessionId?: string;
  type: "input" | "stdout" | "stderr" | "start" | "end" | "error";
  data?: string;
  metadata?: Record<string, unknown>;
  durationMs?: number;
  exitCode?: number | null;
}

export interface LoggerOptions {
  /**
   * Task ID for organizing logs
   * If provided, logs go to .techlead/tasks/{taskId}/logs/
   * If not provided, logs go to logs/agent-executions/
   */
  taskId?: string;
  sessionId?: string;
  logDir?: string;
  provider: string;
  model?: string;
  workingDir?: string;
}

export class AgentExecutionLogger {
  private logPath: string | null = null;
  private startTime: number;
  private options: LoggerOptions;
  private effectiveTaskId: string;

  constructor(options: LoggerOptions) {
    this.options = options;
    this.startTime = Date.now();
    this.effectiveTaskId = options.taskId ?? generateTaskId();
    this.initLogFile();
    this.logStart();
  }

  private initLogFile(): void {
    const executionId = generateTaskId();

    // If taskId is provided, store in task directory
    // Otherwise, use global logs directory
    if (this.options.taskId) {
      this.logPath = `.techlead/tasks/${this.options.taskId}/logs/execution-${executionId}.jsonl`;
    } else {
      const logDir = this.options.logDir || "logs/agent-executions";
      const date = new Date().toISOString().split("T")[0];
      this.logPath = `${logDir}/${date}/${this.effectiveTaskId}.jsonl`;
    }

    try {
      // Ensure all parent directories exist
      const dir = dirname(this.logPath);
      mkdirSync(dir, { recursive: true });
    } catch (error) {
      console.error("Failed to create log directory:", error);
      this.logPath = null;
    }
  }

  private writeEntry(entry: LogEntry): void {
    if (!this.logPath) return;

    const line = `${JSON.stringify(entry)}\n`;
    try {
      appendFileSync(this.logPath, line);
    } catch (error) {
      console.error("Failed to write log entry:", error);
    }
  }

  private logStart(): void {
    this.writeEntry({
      timestamp: this.startTime,
      taskId: this.effectiveTaskId,
      sessionId: this.options.sessionId,
      type: "start",
      metadata: {
        provider: this.options.provider,
        model: this.options.model,
        workingDir: this.options.workingDir,
        taskId: this.options.taskId,
      },
    });
  }

  logInput(data: string, metadata?: Record<string, unknown>): void {
    this.writeEntry({
      timestamp: Date.now(),
      taskId: this.effectiveTaskId,
      sessionId: this.options.sessionId,
      type: "input",
      data,
      metadata,
    });
  }

  logStdout(data: string): void {
    this.writeEntry({
      timestamp: Date.now(),
      taskId: this.effectiveTaskId,
      sessionId: this.options.sessionId,
      type: "stdout",
      data,
    });
  }

  logStderr(data: string): void {
    this.writeEntry({
      timestamp: Date.now(),
      taskId: this.effectiveTaskId,
      sessionId: this.options.sessionId,
      type: "stderr",
      data,
    });
  }

  logError(error: Error): void {
    this.writeEntry({
      timestamp: Date.now(),
      taskId: this.effectiveTaskId,
      sessionId: this.options.sessionId,
      type: "error",
      data: error.message,
      metadata: {
        stack: error.stack,
      },
    });
  }

  logEnd(exitCode: number | null): void {
    const durationMs = Date.now() - this.startTime;

    this.writeEntry({
      timestamp: Date.now(),
      taskId: this.effectiveTaskId,
      sessionId: this.options.sessionId,
      type: "end",
      durationMs,
      exitCode,
    });
  }

  getLogPath(): string | null {
    return this.logPath;
  }

  getTaskId(): string {
    return this.effectiveTaskId;
  }
}

/**
 * Generate a unique task ID
 */
export function generateTaskId(): string {
  const timestamp = Date.now().toString(36);
  const random = Math.random().toString(36).substring(2, 8);
  return `${timestamp}-${random}`;
}
