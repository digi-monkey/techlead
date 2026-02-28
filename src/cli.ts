#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { cac } from "cac";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");
const templatesRoot = path.join(repoRoot, "templates");
const scriptsRoot = path.join(repoRoot, "scripts");

interface Defaults {
  PROJECT_PREFIX: string;
  SPRINT_STATE_FILE: string;
  SPRINT_BOARD_FILE: string;
  RUN_JOURNAL_FILE: string;
  BUILD_COMMAND: string;
  REVIEW_COMMAND: string;
  TEST_COMMAND: string;
  DOMAIN_ROLE_NAME: string;
  DOMAIN_EXPERT_PROMPT: string;
  DEBUG_SETUP_ENDPOINT: string;
  DEBUG_CHAT_ENDPOINT: string;
  TEST_RESULTS_DIR: string;
}

const DEFAULTS: Defaults = {
  PROJECT_PREFIX: "TASK",
  SPRINT_STATE_FILE: ".va-auto-pilot/sprint-state.json",
  SPRINT_BOARD_FILE: "docs/todo/sprint.md",
  RUN_JOURNAL_FILE: "docs/todo/run-journal.md",
  BUILD_COMMAND: "pnpm typecheck && pnpm lint && pnpm test",
  REVIEW_COMMAND: "codex review --uncommitted",
  TEST_COMMAND: "npx tsx scripts/test-runner.ts --flow test-flows/{feature}.yaml",
  DOMAIN_ROLE_NAME: "Domain Expert",
  DOMAIN_EXPERT_PROMPT:
    "You are the domain expert for this product. Review behavioral correctness, user impact, and product consistency.",
  DEBUG_SETUP_ENDPOINT: "/api/debug/setup",
  DEBUG_CHAT_ENDPOINT: "/api/debug/chat",
  TEST_RESULTS_DIR: "docs/quality/query-tests/results",
};

interface Context {
  DATE_ISO: string;
  PROJECT_PREFIX: string;
  SPRINT_STATE_FILE: string;
  SPRINT_BOARD_FILE: string;
  RUN_JOURNAL_FILE: string;
  BUILD_COMMAND: string;
  REVIEW_COMMAND: string;
  TEST_COMMAND: string;
  DOMAIN_ROLE_NAME: string;
  DOMAIN_EXPERT_PROMPT: string;
  DEBUG_SETUP_ENDPOINT: string;
  DEBUG_CHAT_ENDPOINT: string;
  TEST_RESULTS_DIR: string;
}

interface WriteOptions {
  force: boolean;
  dryRun: boolean;
}

interface WrittenFile {
  destination: string;
  dryRun: boolean;
}

function walkFiles(dir: string, base: string = dir): string[] {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const files: string[] = [];

  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkFiles(fullPath, base));
      continue;
    }
    files.push(path.relative(base, fullPath));
  }

  return files;
}

function applyTemplate(raw: string, context: Context): string {
  let output = raw;
  for (const [key, value] of Object.entries(context)) {
    output = output.replaceAll(`{{${key}}}`, value);
  }
  return output;
}

function resolveContext(opts: Record<string, string | undefined>): Context {
  return {
    DATE_ISO: new Date().toISOString().slice(0, 10),
    PROJECT_PREFIX: opts["project-prefix"] ?? DEFAULTS.PROJECT_PREFIX,
    SPRINT_STATE_FILE: DEFAULTS.SPRINT_STATE_FILE,
    SPRINT_BOARD_FILE: DEFAULTS.SPRINT_BOARD_FILE,
    RUN_JOURNAL_FILE: DEFAULTS.RUN_JOURNAL_FILE,
    BUILD_COMMAND: opts["build-cmd"] ?? DEFAULTS.BUILD_COMMAND,
    REVIEW_COMMAND: opts["review-cmd"] ?? DEFAULTS.REVIEW_COMMAND,
    TEST_COMMAND: opts["test-cmd"] ?? DEFAULTS.TEST_COMMAND,
    DOMAIN_ROLE_NAME: opts["domain-role"] ?? DEFAULTS.DOMAIN_ROLE_NAME,
    DOMAIN_EXPERT_PROMPT: opts["domain-prompt"] ?? DEFAULTS.DOMAIN_EXPERT_PROMPT,
    DEBUG_SETUP_ENDPOINT: opts["debug-setup-endpoint"] ?? DEFAULTS.DEBUG_SETUP_ENDPOINT,
    DEBUG_CHAT_ENDPOINT: opts["debug-chat-endpoint"] ?? DEFAULTS.DEBUG_CHAT_ENDPOINT,
    TEST_RESULTS_DIR: opts["results-dir"] ?? DEFAULTS.TEST_RESULTS_DIR,
  };
}

function writeTemplateFiles(
  targetDir: string,
  context: Context,
  { force, dryRun }: WriteOptions
): WrittenFile[] {
  const written: WrittenFile[] = [];

  // 1. Per-project template files (support {{TOKEN}} substitution).
  const templateFiles = walkFiles(templatesRoot);
  for (const relativePath of templateFiles) {
    const source = path.join(templatesRoot, relativePath);
    const destination = path.join(targetDir, relativePath);

    if (fs.existsSync(destination) && !force) {
      throw new Error(
        `Refusing to overwrite existing file: ${destination}. Use --force to overwrite.`
      );
    }

    const raw = fs.readFileSync(source, "utf8");
    const rendered = applyTemplate(raw, context);

    if (dryRun) {
      written.push({ destination, dryRun: true });
      continue;
    }

    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, rendered, "utf8");
    written.push({ destination, dryRun: false });
  }

  // 2. Scripts — copied verbatim from the package's own scripts/ directory.
  const scriptFiles = walkFiles(scriptsRoot);
  for (const relativePath of scriptFiles) {
    const source = path.join(scriptsRoot, relativePath);
    const destination = path.join(targetDir, "scripts", relativePath);

    if (fs.existsSync(destination) && !force) {
      throw new Error(
        `Refusing to overwrite existing file: ${destination}. Use --force to overwrite.`
      );
    }

    if (dryRun) {
      written.push({ destination, dryRun: true });
      continue;
    }

    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(source, destination);
    written.push({ destination, dryRun: false });
  }

  return written;
}

function main(): void {
  const cli = cac("va-auto-pilot");

  cli
    .command("init [target-dir]", "Initialize VA Auto-Pilot scaffold")
    .option("--project-prefix <prefix>", "Task ID prefix", { default: DEFAULTS.PROJECT_PREFIX })
    .option("--build-cmd <command>", "Build/quality gate command")
    .option("--review-cmd <command>", "Code review command")
    .option("--test-cmd <command>", "Acceptance test command")
    .option("--domain-role <name>", "3rd review role name")
    .option("--domain-prompt <prompt>", "3rd review role prompt")
    .option("--debug-setup-endpoint <url>", "Setup endpoint for test runner")
    .option("--debug-chat-endpoint <url>", "Chat endpoint for test runner")
    .option("--results-dir <path>", "Test result output directory")
    .option("--force", "Overwrite existing files")
    .option("--dry-run", "Print planned file writes only")
    .action((targetDir: string = ".", options: Record<string, string | boolean | undefined>) => {
      const force = Boolean(options.force);
      const dryRun = Boolean(options.dryRun);
      const resolvedTargetDir = path.resolve(process.cwd(), targetDir);

      const context = resolveContext(
        Object.fromEntries(
          Object.entries(options).map(([k, v]) => [k, v?.toString()])
        )
      );

      if (!dryRun) {
        fs.mkdirSync(resolvedTargetDir, { recursive: true });
      }

      const written = writeTemplateFiles(resolvedTargetDir, context, { force, dryRun });

      console.log("VA Auto-Pilot scaffold complete.");
      console.log(`Target: ${resolvedTargetDir}`);
      console.log(`Mode: ${dryRun ? "dry-run" : "write"}`);
      console.log(`Files: ${written.length}`);
      for (const file of written) {
        const prefix = file.dryRun ? "[dry-run]" : "[write]";
        console.log(`${prefix} ${path.relative(resolvedTargetDir, file.destination)}`);
      }

      if (!dryRun) {
        console.log("\nNext steps:");
        console.log(`1. Fill backlog in ${context.SPRINT_STATE_FILE}`);
        console.log(
          `2. Render board with node scripts/sprint-board.mjs render --state-file ${context.SPRINT_STATE_FILE} --board-file ${context.SPRINT_BOARD_FILE}`
        );
        console.log("3. Add human instructions in docs/todo/human-board.md");
        console.log("4. Run your first acceptance flow with scripts/test-runner.ts");
        console.log(
          "5. Start a new agent session and run the decision loop in docs/operations/va-auto-pilot-protocol.md"
        );
      }
    });

  cli.help();
  cli.parse();
}

main();
