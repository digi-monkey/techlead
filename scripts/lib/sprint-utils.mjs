#!/usr/bin/env node
// Shared utilities for sprint-board.mjs and va-parallel-runner.mjs.
// Keep this file dependency-free (Node built-ins only).

import fs from "node:fs";
import path from "node:path";

export function nowIso() {
  return new Date().toISOString();
}

export function stripYamlValue(value) {
  return value.replace(/^["']/, "").replace(/["']$/, "").trim();
}

/**
 * Reads the [sprint] section of a flat YAML config file.
 * Supports only top-level sections and single-level key: value pairs
 * with 2-space indentation.  Multi-line values, nested mappings, and
 * YAML anchors are NOT supported.
 */
export function readSprintPathsFromConfig(configPath) {
  if (!fs.existsSync(configPath)) {
    return {};
  }

  const raw = fs.readFileSync(configPath, "utf8");
  const lines = raw.split(/\r?\n/);
  const sprint = {};
  let inSprint = false;

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const sectionMatch = line.match(/^([A-Za-z][A-Za-z0-9_-]*):\s*$/);
    if (sectionMatch) {
      inSprint = sectionMatch[1] === "sprint";
      continue;
    }

    if (!inSprint) continue;

    const keyMatch = line.match(/^\s{2}([A-Za-z][A-Za-z0-9_-]*):\s*(.+)\s*$/);
    if (!keyMatch) continue;

    sprint[keyMatch[1]] = stripYamlValue(keyMatch[2]);
  }

  return sprint;
}

/**
 * Resolves the default paths for the sprint state file, board file, and
 * journal file.  Priority: env var > config.yaml > hard-coded default.
 *
 * Reads config once per process; callers should cache the result if
 * calling frequently.
 */
export function resolveDefaults() {
  const sprintFromConfig = readSprintPathsFromConfig(
    path.resolve(process.cwd(), ".va-auto-pilot/config.yaml")
  );

  return {
    stateFile:
      process.env.AUTO_PILOT_SPRINT_STATE_FILE ??
      sprintFromConfig.stateFile ??
      ".va-auto-pilot/sprint-state.json",
    boardFile:
      process.env.AUTO_PILOT_SPRINT_BOARD_FILE ??
      sprintFromConfig.boardFile ??
      "docs/todo/sprint.md",
    journalFile:
      process.env.AUTO_PILOT_RUN_JOURNAL_FILE ??
      sprintFromConfig.runJournalFile ??
      "docs/todo/run-journal.md"
  };
}

/**
 * Minimal argv parser.
 *
 * Rules:
 * - First token (argv[0]) is the sub-command.
 * - `--key value`  → options["key"] = "value"
 * - `--key=value`  → options["key"] = "value"
 * - `--flag`       → flags.add("flag")  (when next token starts with "--" or is absent)
 *
 * No positional arguments beyond the sub-command are supported.
 */
export function parseArgv(argv) {
  // If the first token looks like a flag (starts with "--"), leave command
  // empty and start parsing from index 0 so that e.g. `--help` is handled
  // as a boolean flag rather than silently becoming the command name.
  const firstArg = argv[0] ?? "";
  const startsWithFlag = firstArg.startsWith("--");

  const parsed = {
    command: startsWithFlag ? "" : firstArg,
    options: {},
    flags: new Set()
  };

  let i = startsWithFlag ? 0 : 1;
  while (i < argv.length) {
    const token = argv[i];

    if (!token.startsWith("--")) {
      i += 1;
      continue;
    }

    if (token.includes("=")) {
      const eqIdx = token.indexOf("=");
      const key = token.slice(2, eqIdx);
      const value = token.slice(eqIdx + 1);
      parsed.options[key] = value;
      i += 1;
      continue;
    }

    const key = token.slice(2);
    const next = argv[i + 1];

    // Boolean flag: no next token, or next token is itself a flag.
    if (!next || next.startsWith("--")) {
      parsed.flags.add(key);
      i += 1;
      continue;
    }

    parsed.options[key] = next;
    i += 2;
  }

  return parsed;
}

export function requireOption(options, key) {
  const value = options[key];
  if (!value) {
    throw new Error(`Missing required option --${key}`);
  }
  return value;
}
