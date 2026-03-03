/**
 * Tests for agent-logger
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AgentExecutionLogger, generateTaskId } from "./agent-logger.js";

describe("Agent Execution Logger", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "agent-logger-test-"));
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  describe("generateTaskId", () => {
    it("should generate unique task IDs", () => {
      const id1 = generateTaskId();
      const id2 = generateTaskId();

      expect(id1).toBeDefined();
      expect(id2).toBeDefined();
      expect(id1).not.toBe(id2);
      expect(id1).toContain("-");
    });
  });

  describe("Logger initialization", () => {
    it("should create logger with options", () => {
      const logger = new AgentExecutionLogger({
        provider: "claude",
        model: "sonnet",
        logDir: tempDir,
      });

      expect(logger).toBeDefined();
    });

    it("should create log file in correct directory (without taskId)", () => {
      const logger = new AgentExecutionLogger({
        provider: "codex",
        logDir: tempDir,
      });

      const logPath = logger.getLogPath();
      expect(logPath).not.toBeNull();
      expect(logPath!.startsWith(tempDir)).toBe(true);
      expect(existsSync(logPath!)).toBe(true);
    });

    it("should create log file in task directory (with taskId)", () => {
      const taskId = "test-task-456";
      const logger = new AgentExecutionLogger({
        taskId,
        provider: "codex",
      });

      const logPath = logger.getLogPath();
      expect(logPath).not.toBeNull();
      expect(logPath!.includes(`.techlead/tasks/${taskId}/logs/`)).toBe(true);
      expect(existsSync(logPath!)).toBe(true);

      // Cleanup
      rmSync(`.techlead/tasks/${taskId}`, { recursive: true, force: true });
    });
  });

  describe("Log entry types", () => {
    it("should log start entry", () => {
      const logger = new AgentExecutionLogger({
        provider: "claude",
        logDir: tempDir,
      });

      const logPath = logger.getLogPath()!;
      const content = readFileSync(logPath, "utf8");
      const lines = content
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l));

      expect(lines[0].type).toBe("start");
      expect(lines[0].metadata.provider).toBe("claude");
    });

    it("should log input entry", () => {
      const logger = new AgentExecutionLogger({
        provider: "claude",
        logDir: tempDir,
      });

      logger.logInput("Test prompt", { key: "value" });

      const logPath = logger.getLogPath()!;
      const content = readFileSync(logPath, "utf8");
      const lines = content
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l));

      const inputLine = lines.find((l) => l.type === "input");
      expect(inputLine).toBeDefined();
      expect(inputLine.data).toBe("Test prompt");
      expect(inputLine.metadata.key).toBe("value");
    });

    it("should log stdout entry", () => {
      const logger = new AgentExecutionLogger({
        provider: "claude",
        logDir: tempDir,
      });

      logger.logStdout("Output chunk");

      const logPath = logger.getLogPath()!;
      const content = readFileSync(logPath, "utf8");
      const lines = content
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l));

      const stdoutLine = lines.find((l) => l.type === "stdout");
      expect(stdoutLine).toBeDefined();
      expect(stdoutLine.data).toBe("Output chunk");
    });

    it("should log stderr entry", () => {
      const logger = new AgentExecutionLogger({
        provider: "claude",
        logDir: tempDir,
      });

      logger.logStderr("Error message");

      const logPath = logger.getLogPath()!;
      const content = readFileSync(logPath, "utf8");
      const lines = content
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l));

      const stderrLine = lines.find((l) => l.type === "stderr");
      expect(stderrLine).toBeDefined();
      expect(stderrLine.data).toBe("Error message");
    });

    it("should log end entry with duration", () => {
      const logger = new AgentExecutionLogger({
        provider: "claude",
        logDir: tempDir,
      });

      // Small delay to ensure duration > 0
      const start = Date.now();
      while (Date.now() - start < 10) {
        // busy wait
      }

      logger.logEnd(0);

      const logPath = logger.getLogPath()!;
      const content = readFileSync(logPath, "utf8");
      const lines = content
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l));

      const endLine = lines.find((l) => l.type === "end");
      expect(endLine).toBeDefined();
      expect(endLine.exitCode).toBe(0);
      expect(endLine.durationMs).toBeGreaterThanOrEqual(0);
    });

    it("should log error entry", () => {
      const logger = new AgentExecutionLogger({
        provider: "claude",
        logDir: tempDir,
      });

      const error = new Error("Test error");
      logger.logError(error);

      const logPath = logger.getLogPath()!;
      const content = readFileSync(logPath, "utf8");
      const lines = content
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l));

      const errorLine = lines.find((l) => l.type === "error");
      expect(errorLine).toBeDefined();
      expect(errorLine.data).toBe("Test error");
      expect(errorLine.metadata.stack).toBeDefined();
    });
  });

  describe("Session ID", () => {
    it("should include sessionId in all entries", () => {
      const sessionId = "session-abc-123";
      const logger = new AgentExecutionLogger({
        sessionId,
        provider: "claude",
        logDir: tempDir,
      });

      logger.logInput("test");
      logger.logEnd(0);

      const logPath = logger.getLogPath()!;
      const content = readFileSync(logPath, "utf8");
      const lines = content
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l));

      for (const line of lines) {
        expect(line.sessionId).toBe(sessionId);
      }
    });
  });
});
