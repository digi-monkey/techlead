import fs from 'node:fs';
import { Current, Task } from './techlead-types.js';
import { getCurrentFile, getTaskJsonPath, getTasksDir } from './techlead-paths.js';
import { readJson, writeJson } from './techlead-utils.js';

export function readCurrent(): Current {
  return readJson<Current>(getCurrentFile()) || { task_id: null, phase: null };
}

export function writeCurrent(current: Current): void {
  writeJson(getCurrentFile(), current);
}

export function readTask(taskId: string): Task {
  const task = readJson<Task>(getTaskJsonPath(taskId));
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }
  return task;
}

export function writeTask(taskId: string, task: Task): void {
  writeJson(getTaskJsonPath(taskId), task);
}

export function listAllTasks(): (Task & { dir: string })[] {
  const tasksDir = getTasksDir();
  if (!fs.existsSync(tasksDir)) return [];

  return fs
    .readdirSync(tasksDir, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => {
      const match = e.name.match(/^(T-\d+)-(.+)$/);
      if (!match) return null;

      const taskId = match[1];
      try {
        const task = readTask(taskId);
        return { ...task, dir: e.name };
      } catch {
        return null;
      }
    })
    .filter((t): t is Task & { dir: string } => t !== null)
    .sort((a, b) => a.id.localeCompare(b.id));
}

export function findNextTask(): Task | null {
  const tasks = listAllTasks();

  const current = readCurrent();
  if (current.task_id) {
    const currentTask = tasks.find((t) => t.id === current.task_id);
    if (currentTask && currentTask.status !== 'done') {
      return currentTask;
    }
  }

  const backlogTask = tasks.find((t) => t.status === 'backlog');
  if (backlogTask) {
    return backlogTask;
  }

  const failedTask = tasks.find((t) => t.status === 'failed');
  if (failedTask) {
    return failedTask;
  }

  return null;
}

export function getTaskById(taskId: string): Task | null {
  const tasks = listAllTasks();
  return tasks.find((task) => task.id === taskId) || null;
}

export function resolveTaskForCommand(taskId?: string): Task | null {
  if (taskId) {
    return getTaskById(taskId);
  }

  const current = readCurrent();
  if (current.task_id) {
    return getTaskById(current.task_id);
  }

  return findNextTask();
}

export function selectTaskForExecution(task: Task): void {
  writeCurrent({ task_id: task.id, phase: task.phase });
}
