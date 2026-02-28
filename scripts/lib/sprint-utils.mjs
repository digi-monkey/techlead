#!/usr/bin/env node
// Shared utilities for sprint-board.mjs and techlead-parallel-runner.mjs.

import fs from "node:fs";
import path from "node:path";
import { parse as parseYaml } from "yaml";

export function nowIso() {
  return new Date().toISOString();
}

/**
 * Strips surrounding quotes and trims whitespace from a scalar YAML value.
 * Kept for backward compatibility; the yaml package handles quoting internally
 * so this is no longer used by readSprintPathsFromConfig.
 */
export function stripYamlValue(value) {
  return value.replace(/^["']/, "").replace(/["']$/, "").trim();
}

/**
 * Reads the [sprint] section of a YAML config file using the yaml package.
 * Returns the sprint section as a plain object, or {} if the file is missing,
 * unparseable, or has no sprint section.
 */
export function readSprintPathsFromConfig(configPath) {
  if (!fs.existsSync(configPath)) {
    return {};
  }

  const raw = fs.readFileSync(configPath, "utf8");
  let parsed;
  try {
    parsed = parseYaml(raw);
  } catch {
    return {};
  }

  if (!parsed || typeof parsed !== "object" || !parsed.sprint || typeof parsed.sprint !== "object") {
    return {};
  }

  // Return only string-valued entries from the sprint section.
  const sprint = {};
  for (const [key, value] of Object.entries(parsed.sprint)) {
    if (typeof value === "string") {
      sprint[key] = value;
    }
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
    path.resolve(process.cwd(), ".techlead/config.yaml")
  );

  return {
    stateFile:
      process.env.AUTO_PILOT_SPRINT_STATE_FILE ??
      sprintFromConfig.stateFile ??
      ".techlead/sprint-state.json",
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
 * @param {string[]} argv         - argument list (process.argv.slice(2))
 * @param {Set<string>} boolFlags - keys that are boolean flags and take no value
 *
 * Rules:
 * - First token (argv[0]) is the sub-command, unless it starts with "--" in
 *   which case command is empty and parsing begins from index 0.
 * - `--key value`  → options["key"] = "value"
 * - `--key=value`  → options["key"] = "value"
 * - `--flag`       → flags.add("flag")  only when "flag" ∈ boolFlags
 * - `--key` with no value and key ∉ boolFlags → throws (prevents silent regression)
 *
 * No positional arguments beyond the sub-command are supported.
 */
export function parseArgv(argv, boolFlags = new Set(["json", "help"])) {
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

    if (boolFlags.has(key)) {
      // Guard: if the next token looks like a value (does not start with "--"),
      // the caller likely wrote `--flag value` expecting a key=value pair against
      // a boolean flag.  Silently skipping the value causes a hard-to-debug
      // regression where the value is dropped.  Reject it explicitly instead.
      const nextAfterBool = argv[i + 1];
      if (nextAfterBool !== undefined && !nextAfterBool.startsWith("--")) {
        throw new Error(
          `--${key} is a boolean flag and takes no value; got unexpected token '${nextAfterBool}'. Use --${key} alone or remove the trailing token.`
        );
      }
      parsed.flags.add(key);
      i += 1;
      continue;
    }

    const next = argv[i + 1];
    if (!next || next.startsWith("--")) {
      throw new Error(`Missing value for --${key}`);
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
