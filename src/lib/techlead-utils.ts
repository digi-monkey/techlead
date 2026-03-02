import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import { getRuntimeRoot, getTasksDir } from "./techlead-paths.js";

export function generateTaskId(): string {
  const tasksDir = getTasksDir();
  if (!fs.existsSync(tasksDir)) {
    return "T-001";
  }

  const entries = fs.readdirSync(tasksDir, { withFileTypes: true });
  const maxNum = entries
    .filter((e) => e.isDirectory() && e.name.match(/^T-\d+/))
    .map((e) => {
      const match = e.name.match(/^T-(\d+)/);
      return match ? parseInt(match[1], 10) : 0;
    })
    .reduce((max, n) => Math.max(max, n), 0);

  return `T-${String(maxNum + 1).padStart(3, "0")}`;
}

export function sanitizeDirName(title: string): string {
  return title
    .replace(/[^a-zA-Z0-9\u4e00-\u9fa5]/g, "-")
    .replace(/-+/g, "-")
    .substring(0, 50);
}

export function readJson<T>(filePath: string): T | null {
  if (!fs.existsSync(filePath)) return null;
  return JSON.parse(fs.readFileSync(filePath, "utf8")) as T;
}

export function writeJson(filePath: string, data: unknown): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2) + "\n", "utf8");
}

export function loadPromptTemplate(relativePath: string): string | null {
  const promptPath = path.join(getRuntimeRoot(), relativePath);
  if (!fs.existsSync(promptPath)) return null;
  return fs.readFileSync(promptPath, "utf8");
}

export function renderTemplate(template: string, vars: Record<string, string>): string {
  let rendered = template;
  for (const [key, value] of Object.entries(vars)) {
    rendered = rendered.replaceAll(`{{${key}}}`, value);
  }
  return rendered;
}

export function extractTaggedJson(content: string, tag: "STATUS" | "VERDICT"): Record<string, unknown> | null {
  const regex = new RegExp(`<!--\\s*${tag}:\\s*(\\{[\\s\\S]*?\\})\\s*-->`, "i");
  const match = content.match(regex);
  if (!match?.[1]) return null;

  try {
    return JSON.parse(match[1]) as Record<string, unknown>;
  } catch {
    return null;
  }
}

export function isStepCompleted(content: string): boolean {
  const status = extractTaggedJson(content, "STATUS");
  const value = status?.completed;
  if (typeof value === "boolean") return value;
  return content.toLowerCase().includes("completed");
}

export function hasCriticalVerdict(content: string): boolean {
  const verdict = extractTaggedJson(content, "VERDICT");
  const result = verdict?.result;
  if (typeof result === "string") {
    return result.toUpperCase() === "CRITICAL";
  }
  const criticalCount = verdict?.critical_count;
  if (typeof criticalCount === "number") {
    return criticalCount > 0;
  }
  return content.toLowerCase().includes("critical");
}

export function detectQualityGateCommand(): string | null {
  const packageJsonPath = path.join(process.cwd(), "package.json");
  if (!fs.existsSync(packageJsonPath)) return null;

  try {
    const pkg = JSON.parse(fs.readFileSync(packageJsonPath, "utf8")) as {
      scripts?: Record<string, string>;
    };
    if (pkg.scripts?.["check:all"]) return "pnpm run check:all";
    if (pkg.scripts?.test) return "pnpm run test";
    if (pkg.scripts?.typecheck) return "pnpm run typecheck";
  } catch {
    return null;
  }

  return null;
}

export function runQualityGate(): { passed: boolean; command?: string; output?: string; error?: string } {
  const command = detectQualityGateCommand();
  if (!command) {
    return { passed: true };
  }

  try {
    const output = execSync(command, {
      cwd: process.cwd(),
      encoding: "utf8",
      stdio: "pipe",
      maxBuffer: 50 * 1024 * 1024,
    });
    return { passed: true, command, output };
  } catch (error: any) {
    const output = `${error?.stdout || ""}\n${error?.stderr || ""}`.trim();
    return {
      passed: false,
      command,
      output,
      error: error?.message || "Quality gate failed",
    };
  }
}

export function copyDir(src: string, dest: string): void {
  fs.mkdirSync(dest, { recursive: true });
  const entries = fs.readdirSync(src, { withFileTypes: true });

  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);

    if (entry.isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}
