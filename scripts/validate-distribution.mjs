#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = process.cwd();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const failures = [];
const warnings = [];

function fail(msg) { failures.push(msg); }
function warn(msg) { warnings.push(msg); }

function checkFile(relative) {
  if (!fs.existsSync(path.join(root, relative))) {
    fail(`Missing required file: ${relative}`);
    return false;
  }
  return true;
}

function readJson(relative) {
  try {
    return JSON.parse(fs.readFileSync(path.join(root, relative), "utf8"));
  } catch (e) {
    fail(`Cannot parse JSON: ${relative} — ${e.message}`);
    return null;
  }
}

// ---------------------------------------------------------------------------
// 1. Required file presence (single CLI system)
// ---------------------------------------------------------------------------

const requiredFiles = [
  "README.md",
  "docs/USAGE.md",
  "docs/design/v0.2.0-design.md",
  "skills/techlead/SKILL.md",
  "skills/techlead/claude-command.md",
  "src/cli.ts",
  "templates/.techlead/config.yaml",
  "prompts/plan/multirole.md",
  "prompts/exec/step.md",
  "prompts/review/adversarial.md",
  "prompts/test/adversarial.md"
];

for (const relative of requiredFiles) {
  checkFile(relative);
}

// ---------------------------------------------------------------------------
// 2. package.json bin + scripts check
// ---------------------------------------------------------------------------

const packageJson = readJson("package.json");
if (packageJson !== null) {
  if (packageJson.bin?.techlead !== "./dist/cli.js") {
    fail("package.json bin.techlead must point to ./dist/cli.js");
  }

  if (!packageJson.scripts?.["check:all"]) {
    fail("package.json missing scripts.check:all");
  }

  if (packageJson.scripts?.["check:sprint"]) {
    fail("package.json should not include legacy scripts.check:sprint");
  }
}

// ---------------------------------------------------------------------------
// 3. SKILL.md name check
// ---------------------------------------------------------------------------

if (fs.existsSync(path.join(root, "skills/techlead/SKILL.md"))) {
  const skill = fs.readFileSync(path.join(root, "skills/techlead/SKILL.md"), "utf8");
  if (!skill.includes("name: techlead")) {
    fail("skills/techlead/SKILL.md missing expected skill name");
  }
}

// ---------------------------------------------------------------------------
// 4. CLI smoke test — dist/cli.js --help must exit 0
// ---------------------------------------------------------------------------

const cliPath = path.join(root, "dist/cli.js");
if (!fs.existsSync(cliPath)) {
  fail("Missing build output: dist/cli.js (run pnpm run build first)");
} else {
  const result = spawnSync("node", [cliPath, "--help"], {
    encoding: "utf8",
    timeout: 10_000
  });

  if (result.status !== 0) {
    fail(
      `CLI smoke test failed: 'node dist/cli.js --help' exited ${result.status}.\n  stderr: ${String(result.stderr ?? "").slice(0, 200)}`
    );
  }
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

if (warnings.length > 0) {
  console.warn("Distribution validation warnings:\n");
  for (const w of warnings) {
    console.warn(`  [warn] ${w}`);
  }
}

if (failures.length > 0) {
  console.error("\nDistribution validation failed:\n");
  for (const f of failures) {
    console.error(`  [fail] ${f}`);
  }
  process.exit(1);
}

console.log("Distribution validation passed.");
