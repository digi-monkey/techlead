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
  taskId: string;
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

  constructor(options: LoggerOptions) {
    this.options = options;
    this.startTime = Date.now();
    this.initLogFile();
    this.logStart();
  }

  private initLogFile(): void {
    const logDir = this.options.logDir || "logs/agent-executions";
    const date = new Date().toISOString().split("T")[0];
    this.logPath = `${logDir}/${date}/${this.options.taskId}.jsonl`;

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
      taskId: this.options.taskId,
      sessionId: this.options.sessionId,
      type: "start",
      metadata: {
        provider: this.options.provider,
        model: this.options.model,
        workingDir: this.options.workingDir,
      },
    });
  }

  logInput(data: string, metadata?: Record<string, unknown>): void {
    this.writeEntry({
      timestamp: Date.now(),
      taskId: this.options.taskId,
      sessionId: this.options.sessionId,
      type: "input",
      data,
      metadata,
    });
  }

  logStdout(data: string): void {
    this.writeEntry({
      timestamp: Date.now(),
      taskId: this.options.taskId,
      sessionId: this.options.sessionId,
      type: "stdout",
      data,
    });
  }

  logStderr(data: string): void {
    this.writeEntry({
      timestamp: Date.now(),
      taskId: this.options.taskId,
      sessionId: this.options.sessionId,
      type: "stderr",
      data,
    });
  }

  logError(error: Error): void {
    this.writeEntry({
      timestamp: Date.now(),
      taskId: this.options.taskId,
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
      taskId: this.options.taskId,
      sessionId: this.options.sessionId,
      type: "end",
      durationMs,
      exitCode,
    });
  }

  getLogPath(): string | null {
    return this.logPath;
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
