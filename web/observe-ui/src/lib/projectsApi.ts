import { apiRequest, isApiError, newRequestId } from './api'
import type { JsonValue } from '../types'

// Project types
export type Project = {
  project_id: string
  name: string
  description: string
  repository_url: string | null
  base_branch: string
  created_at: number
  updated_at: number
  task_count: number
  running_count: number
  completed_count: number
}

export type ProjectSummary = {
  total_projects: number
  total_tasks: number
  running_tasks: number
  completed_tasks: number
  failed_tasks: number
}

// Task types (for project-specific tasks)
export type ProjectTask = {
  task_id: string
  project_id: string
  title: string
  prompt: string
  status: 'queued' | 'running' | 'review' | 'done' | 'failed' | 'canceled' | 'claimed'
  review_stage: 'none' | 'open' | 'changes_requested' | 'approved' | 'merged'
  priority: number
  created_at: number
  updated_at: number
}

export type ProjectTaskListResult = {
  tasks: ProjectTask[]
  total: number
  summary: Record<string, number>
}

export type ProjectTaskDetail = ProjectTask & {
  head_branch: string
  head_sha: string
  base_branch: string
  merge_commit: string | null
  retry_count: number
  max_retries: number | null
  review_feedback: string
  last_error: string
}

export type CreateProjectData = {
  name: string
  description?: string
  repository_url?: string
  base_branch?: string
}

export type UpdateProjectData = Partial<CreateProjectData>

export type CreateTaskData = {
  title: string
  prompt: string
  priority?: number
}

export type TaskAction = 'start' | 'pause' | 'resume' | 'abort' | 'ask' | 'retry' | 'cancel'

// Helper functions
const RATE_LIMIT_RETRY_DELAYS_MS = [300, 900, 1800]

type JsonRecord = Record<string, unknown>

function asRecord(value: unknown): JsonRecord {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value as JsonRecord
  }
  return {}
}

function asString(value: unknown, fallback: string = ''): string {
  return typeof value === 'string' ? value : fallback
}

function asNumber(value: unknown, fallback: number = 0): number {
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value === 'string') {
    const n = Number(value)
    if (Number.isFinite(n)) return n
  }
  return fallback
}

function asNullableNumber(value: unknown): number | null {
  if (value === null || value === undefined) return null
  const n = asNumber(value, Number.NaN)
  return Number.isFinite(n) ? n : null
}

function asNullableString(value: unknown): string | null {
  if (value === null || value === undefined) return null
  return typeof value === 'string' ? value : null
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => {
    window.setTimeout(resolve, ms)
  })
}

async function requestWith429Backoff<T>(fn: () => Promise<T>): Promise<T> {
  let retries = 0
  while (true) {
    try {
      return await fn()
    } catch (err) {
      if (!isApiError(err) || err.status !== 429 || retries >= RATE_LIMIT_RETRY_DELAYS_MS.length) {
        throw err
      }
      const delay = RATE_LIMIT_RETRY_DELAYS_MS[retries]
      retries += 1
      await wait(delay)
    }
  }
}

function parseProject(raw: unknown): Project {
  const rec = asRecord(raw)
  return {
    project_id: asString(rec.project_id),
    name: asString(rec.name, 'Unnamed Project'),
    description: asString(rec.description),
    repository_url: asNullableString(rec.repository_url),
    base_branch: asString(rec.base_branch, 'main'),
    created_at: asNumber(rec.created_at, 0),
    updated_at: asNumber(rec.updated_at, 0),
    task_count: asNumber(rec.task_count, 0),
    running_count: asNumber(rec.running_count, 0),
    completed_count: asNumber(rec.completed_count, 0),
  }
}

function parseProjectTask(raw: unknown): ProjectTask {
  const rec = asRecord(raw)
  const status = asString(rec.status)
  const validStatus = ['queued', 'running', 'review', 'done', 'failed', 'canceled', 'claimed'].includes(status)
    ? status as ProjectTask['status']
    : 'queued'
  
  const reviewStage = asString(rec.review_stage)
  const validReviewStage = ['none', 'open', 'changes_requested', 'approved', 'merged'].includes(reviewStage)
    ? reviewStage as ProjectTask['review_stage']
    : 'none'

  return {
    task_id: asString(rec.task_id),
    project_id: asString(rec.project_id),
    title: asString(rec.title, 'Untitled Task'),
    prompt: asString(rec.prompt),
    status: validStatus,
    review_stage: validReviewStage,
    priority: asNumber(rec.priority, 0),
    created_at: asNumber(rec.created_at, 0),
    updated_at: asNumber(rec.updated_at, 0),
  }
}

// Project API functions

export async function getProjects(token?: string, signal?: AbortSignal): Promise<Project[]> {
  return requestWith429Backoff(async () => {
    const rec = asRecord(await apiRequest<JsonValue>('/projects', token, { signal }))
    const projectsRaw = Array.isArray(rec.projects) ? rec.projects : []
    return projectsRaw.map(parseProject).filter((p) => p.project_id.length > 0)
  })
}

export async function getProject(projectId: string, token?: string, signal?: AbortSignal): Promise<Project | null> {
  return requestWith429Backoff(async () => {
    try {
      const rec = asRecord(await apiRequest<JsonValue>(`/projects/${encodeURIComponent(projectId)}`, token, { signal }))
      const projectRaw = rec.project
      return projectRaw ? parseProject(projectRaw) : null
    } catch (err) {
      if (isApiError(err) && err.status === 404) {
        return null
      }
      throw err
    }
  })
}

export async function createProject(data: CreateProjectData, token?: string, signal?: AbortSignal): Promise<Project> {
  return requestWith429Backoff(async () => {
    const rec = asRecord(await apiRequest<JsonValue>('/projects', token, {
      method: 'POST',
      signal,
      body: JSON.stringify(data),
    }))
    return parseProject(rec.project ?? rec)
  })
}

export async function updateProject(
  projectId: string,
  data: UpdateProjectData,
  token?: string,
  signal?: AbortSignal
): Promise<Project> {
  return requestWith429Backoff(async () => {
    const rec = asRecord(await apiRequest<JsonValue>(`/projects/${encodeURIComponent(projectId)}`, token, {
      method: 'PATCH',
      signal,
      body: JSON.stringify(data),
    }))
    return parseProject(rec.project ?? rec)
  })
}

export async function deleteProject(projectId: string, token?: string, signal?: AbortSignal): Promise<void> {
  return requestWith429Backoff(async () => {
    await apiRequest<JsonValue>(`/projects/${encodeURIComponent(projectId)}`, token, {
      method: 'DELETE',
      signal,
    })
  })
}

export async function getProjectSummary(token?: string, signal?: AbortSignal): Promise<ProjectSummary> {
  return requestWith429Backoff(async () => {
    const rec = asRecord(await apiRequest<JsonValue>('/projects/summary', token, { signal }))
    return {
      total_projects: asNumber(rec.total_projects, 0),
      total_tasks: asNumber(rec.total_tasks, 0),
      running_tasks: asNumber(rec.running_tasks, 0),
      completed_tasks: asNumber(rec.completed_tasks, 0),
      failed_tasks: asNumber(rec.failed_tasks, 0),
    }
  })
}

// Project Task API functions

export async function getTasks(
  projectId: string,
  token?: string,
  signal?: AbortSignal
): Promise<ProjectTaskListResult> {
  return requestWith429Backoff(async () => {
    const rec = asRecord(await apiRequest<JsonValue>(`/projects/${encodeURIComponent(projectId)}/tasks`, token, { signal }))
    const tasksRaw = Array.isArray(rec.tasks) ? rec.tasks : []
    const summaryRaw = asRecord(rec.summary)
    const summary: Record<string, number> = {}
    for (const [key, value] of Object.entries(summaryRaw)) {
      summary[key] = asNumber(value, 0)
    }
    return {
      tasks: tasksRaw.map(parseProjectTask).filter((t) => t.task_id.length > 0),
      total: asNumber(rec.total, tasksRaw.length),
      summary,
    }
  })
}

export async function createTask(
  projectId: string,
  data: CreateTaskData,
  token?: string,
  signal?: AbortSignal
): Promise<ProjectTask> {
  return requestWith429Backoff(async () => {
    const rec = asRecord(await apiRequest<JsonValue>(`/projects/${encodeURIComponent(projectId)}/tasks`, token, {
      method: 'POST',
      signal,
      body: JSON.stringify(data),
    }))
    return parseProjectTask(rec.task ?? rec)
  })
}

export async function getTask(
  projectId: string,
  taskId: string,
  token?: string,
  signal?: AbortSignal
): Promise<ProjectTaskDetail | null> {
  return requestWith429Backoff(async () => {
    try {
      const rec = asRecord(await apiRequest<JsonValue>(
        `/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}`,
        token,
        { signal }
      ))
      const taskRaw = rec.task
      if (!taskRaw) return null
      
      const baseTask = parseProjectTask(taskRaw)
      const taskRec = asRecord(taskRaw)
      
      return {
        ...baseTask,
        head_branch: asString(taskRec.head_branch),
        head_sha: asString(taskRec.head_sha),
        base_branch: asString(taskRec.base_branch),
        merge_commit: asNullableString(taskRec.merge_commit),
        retry_count: asNumber(taskRec.retry_count, 0),
        max_retries: asNullableNumber(taskRec.max_retries),
        review_feedback: asString(taskRec.review_feedback),
        last_error: asString(taskRec.last_error),
      }
    } catch (err) {
      if (isApiError(err) && err.status === 404) {
        return null
      }
      throw err
    }
  })
}

export async function taskAction(
  projectId: string,
  taskId: string,
  action: TaskAction,
  token?: string,
  signal?: AbortSignal
): Promise<void> {
  const requestId = newRequestId()
  return requestWith429Backoff(async () => {
    await apiRequest<JsonValue>(
      `/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/actions`,
      token,
      {
        method: 'POST',
        signal,
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ action, request_id: requestId }),
      }
    )
  })
}

// Error formatting helper
export function formatProjectError(err: unknown, fallback: string): string {
  if (!isApiError(err)) return `${fallback}: ${(err as Error).message}`
  const code = err.errorCode?.trim() || 'unknown_error'
  if (err.status === 401) {
    return `未授权 401：请先扫码授权或提供有效 token（${code}）`
  }
  if (err.status === 404) {
    return `未找到：${code}`
  }
  if (err.status === 409) {
    return `冲突 409：请求与当前状态不一致（${code}）`
  }
  if (err.status === 429) {
    return `限流 429：已自动退避重试（${code}）`
  }
  if (err.status === 400) {
    return `请求错误 400：${code}`
  }
  return `${fallback}: ${err.status} ${code}`
}
