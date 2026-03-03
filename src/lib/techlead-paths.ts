import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export function getRuntimeRoot(): string {
  return path.resolve(__dirname, "../..");
}

export function getTemplatesRoot(): string {
  return path.join(getRuntimeRoot(), "templates/.techlead");
}

export function getTechleadDir(): string {
  return path.join(process.cwd(), ".techlead");
}

export function getCurrentFile(): string {
  return path.join(getTechleadDir(), "current.json");
}

export function getTasksDir(): string {
  return path.join(getTechleadDir(), "tasks");
}

export function getKnowledgeDir(): string {
  return path.join(getTechleadDir(), "knowledge");
}

export function getTaskDir(taskId: string): string {
  const tasksDir = getTasksDir();
  if (!fs.existsSync(tasksDir)) {
    throw new Error(`Tasks directory not found: ${tasksDir}`);
  }

  const entries = fs.readdirSync(tasksDir, { withFileTypes: true });
  const match = entries.find((e) => e.isDirectory() && e.name.startsWith(taskId));

  if (!match) {
    throw new Error(`Task not found: ${taskId}`);
  }

  return path.join(tasksDir, match.name);
}

export function getTaskJsonPath(taskId: string): string {
  return path.join(getTaskDir(taskId), "task.json");
}
