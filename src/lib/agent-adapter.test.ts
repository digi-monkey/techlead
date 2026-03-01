/**
 * Tests for agent-adapter
 */

import { describe, it, expect, beforeAll } from "vitest";
import {
  isAgentAvailable,
  detectAgent,
  createDefaultConfig,
  buildClaudeCommand,
  buildCodexCommand,
  parseClaudeOutput,
  parseCodexOutput,
} from "./agent-adapter.js";
import type { AgentConfig, AgentOptions } from "./agent-adapter.js";

describe("Agent Adapter", () => {
  describe("Detection", () => {
    it("should detect if claude is available", () => {
      const available = isAgentAvailable("claude");
      console.log("Claude available:", available);
      // Just verify it doesn't throw
      expect(typeof available).toBe("boolean");
    });

    it("should detect if codex is available", () => {
      const available = isAgentAvailable("codex");
      console.log("Codex available:", available);
      expect(typeof available).toBe("boolean");
    });

    it("should detect agent", () => {
      const agent = detectAgent();
      console.log("Detected agent:", agent);
      // Should be null, "claude", or "codex"
      expect([null, "claude", "codex"]).toContain(agent);
    });
  });

  describe("Config creation", () => {
    it("should create default config for detected agent", () => {
      const config = createDefaultConfig("/tmp/test");
      if (config) {
        expect(config.workingDir).toBe("/tmp/test");
        expect(["claude", "codex"]).toContain(config.provider);
        expect(config.maxBudgetUsd).toBe(1.0);
        expect(config.allowedTools).toBeDefined();
      }
    });
  });

  describe("Command building", () => {
    const mockConfig: AgentConfig = {
      provider: "claude",
      model: "sonnet",
      maxBudgetUsd: 0.5,
      workingDir: "/tmp/test",
    };

    const mockOptions: AgentOptions = {
      systemPrompt: "You are a test assistant.",
      outputFormat: "json",
    };

    it("should build Claude command with all options", () => {
      const cmd = buildClaudeCommand("Test prompt", mockConfig, mockOptions);
      console.log("Claude command:", cmd);

      expect(cmd).toContain("claude");
      expect(cmd).toContain("-p");
      expect(cmd).toContain("--output-format=json");
      expect(cmd).toContain("--model=sonnet");
      expect(cmd).toContain("--max-budget-usd=0.5");
      expect(cmd).toContain("--system-prompt");
      expect(cmd).toContain("Test prompt");
    });

    it("should build Codex command with all options", () => {
      const codexConfig: AgentConfig = {
        ...mockConfig,
        provider: "codex",
        model: "gpt-4o",
      };

      const cmd = buildCodexCommand("Test prompt", codexConfig, mockOptions);
      console.log("Codex command:", cmd);

      expect(cmd).toContain("codex");
      expect(cmd).toContain("exec");
      expect(cmd).toContain("--json");
      expect(cmd).toContain("--full-auto");
      expect(cmd).toContain("-m=gpt-4o");
      expect(cmd).toContain("Test prompt");
    });

    it("should escape special characters in prompts", () => {
      const prompt = 'Test "quoted" and \n newline';
      const cmd = buildClaudeCommand(prompt, mockConfig, {});

      expect(cmd).toContain('\\"quoted\\"');
    });
  });

  describe("Output parsing", () => {
    it("should parse Claude JSON output", () => {
      const mockOutput = JSON.stringify({
        type: "result",
        subtype: "success",
        is_error: false,
        result: "Test response",
        session_id: "test-session-123",
        total_cost_usd: 0.01,
        usage: {
          input_tokens: 100,
          output_tokens: 50,
        },
      });

      const result = parseClaudeOutput(mockOutput);

      expect(result.success).toBe(true);
      expect(result.content).toBe("Test response");
      expect(result.sessionId).toBe("test-session-123");
      expect(result.costUsd).toBe(0.01);
      expect(result.inputTokens).toBe(100);
      expect(result.outputTokens).toBe(50);
    });

    it("should handle Claude error output", () => {
      const mockOutput = JSON.stringify({
        type: "result",
        subtype: "error",
        is_error: true,
        result: "Error occurred",
      });

      const result = parseClaudeOutput(mockOutput);

      expect(result.success).toBe(false);
      expect(result.content).toBe("Error occurred");
    });

    it("should parse Codex JSONL output", () => {
      const mockOutput = `
{"type": "message", "content": "Starting..."}
{"type": "result", "content": "Final result", "session_id": "codex-123"}
      `.trim();

      const result = parseCodexOutput(mockOutput);

      expect(result.success).toBe(true);
      expect(result.content).toBe("Final result");
      expect(result.sessionId).toBe("codex-123");
    });

    it("should handle invalid JSON gracefully", () => {
      const result = parseClaudeOutput("invalid json");

      expect(result.success).toBe(false);
      expect(result.error).toContain("Failed to parse");
    });
  });
});
