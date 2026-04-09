import { apiRequest, isApiError, newRequestId, getErrorMessage } from './api'
import {
  ProjectSchema,
  ProjectSummarySchema,
  ProjectTaskSchema,
  ProjectTaskDetailSchema,
  TaskPoolListSchema,
} from './schemas'
import { z } from 'zod'

export type Project = z.infer<typeof ProjectSchema>
export type ProjectSummary = z.infer<typeof ProjectSummarySchema>
export type ProjectTask = z.infer<typeof ProjectTaskSchema>
export type ProjectTaskDetail = z.infer<typeof ProjectTaskDetailSchema>

export type ProjectTaskListResult = {
  tasks: ProjectTask[]
  total: number
  summary: Record<string, number>
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

const ProjectsResponseSchema = z.object({
  projects: z.array(ProjectSchema),
})

const ProjectResponseSchema = z.object({
  project: ProjectSchema,
})

const ProjectSummaryResponseSchema = ProjectSummarySchema

const TaskResponseSchema = z.object({
  task: ProjectTaskSchema,
})

const TaskDetailResponseSchema = z.object({
  task: ProjectTaskDetailSchema,
})

const RATE_LIMIT_RETRY_DELAYS_MS = [300, 900, 1800]

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

export async function getProjects(token?: string, signal?: AbortSignal): Promise<Project[]> {
  return requestWith429Backoff(async () => {
    const rec = await apiRequest('/projects', token ?? null, { signal }, ProjectsResponseSchema)
    return rec.projects.filter((p) => p.project_id.length > 0)
  })
}

export async function getProject(projectId: string, token?: string, signal?: AbortSignal): Promise<Project | null> {
  return requestWith429Backoff(async () => {
    try {
      const rec = await apiRequest(`/projects/${encodeURIComponent(projectId)}`, token ?? null, { signal }, ProjectResponseSchema)
      return rec.project
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
    const rec = await apiRequest('/projects', token ?? null, {
      method: 'POST',
      signal,
      body: JSON.stringify(data),
    }, ProjectResponseSchema)
    return rec.project
  })
}

export async function updateProject(
  projectId: string,
  data: UpdateProjectData,
  token?: string,
  signal?: AbortSignal
): Promise<Project> {
  return requestWith429Backoff(async () => {
    const rec = await apiRequest(`/projects/${encodeURIComponent(projectId)}`, token ?? null, {
      method: 'PATCH',
      signal,
      body: JSON.stringify(data),
    }, ProjectResponseSchema)
    return rec.project
  })
}

export async function deleteProject(projectId: string, token?: string, signal?: AbortSignal): Promise<void> {
  return requestWith429Backoff(async () => {
    await apiRequest(`/projects/${encodeURIComponent(projectId)}`, token ?? null, {
      method: 'DELETE',
      signal,
    })
  })
}

export async function getProjectSummary(token?: string, signal?: AbortSignal): Promise<ProjectSummary> {
  return requestWith429Backoff(async () => {
    return await apiRequest('/projects/summary', token ?? null, { signal }, ProjectSummaryResponseSchema)
  })
}

export async function getTasks(
  projectId: string,
  token?: string,
  signal?: AbortSignal
): Promise<ProjectTaskListResult> {
  return requestWith429Backoff(async () => {
    return await apiRequest(`/projects/${encodeURIComponent(projectId)}/tasks`, token ?? null, { signal }, TaskPoolListSchema)
  })
}

export async function createTask(
  projectId: string,
  data: CreateTaskData,
  token?: string,
  signal?: AbortSignal
): Promise<ProjectTask> {
  return requestWith429Backoff(async () => {
    const rec = await apiRequest(`/projects/${encodeURIComponent(projectId)}/tasks`, token ?? null, {
      method: 'POST',
      signal,
      body: JSON.stringify(data),
    }, TaskResponseSchema)
    return rec.task
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
      const rec = await apiRequest(
        `/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}`,
        token ?? null,
        { signal },
        TaskDetailResponseSchema
      )
      return rec.task
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
    await apiRequest(
      `/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/actions`,
      token ?? null,
      {
        method: 'POST',
        signal,
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ action, request_id: requestId }),
      }
    )
  })
}

export function formatProjectError(err: unknown, fallback: string): string {
  if (!isApiError(err)) return `${fallback}: ${getErrorMessage(err)}`
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

const ProjectsResponseSchema = z.object({
  projects: z.array(ProjectSchema),
})

const ProjectResponseSchema = z.object({
  project: ProjectSchema,
})

const ProjectSummaryResponseSchema = ProjectSummarySchema

const TaskResponseSchema = z.object({
  task: ProjectTaskSchema,
})

const TaskDetailResponseSchema = z.object({
  task: ProjectTaskDetailSchema,
})
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
    const rec = await apiRequest('/projects', token ?? null, { signal }, ProjectsResponseSchema)
    return rec.projects.filter((p) => p.project_id.length > 0)
  })
}

export async function getProject(projectId: string, token?: string, signal?: AbortSignal): Promise<Project | null> {
  return requestWith429Backoff(async () => {
    try {
      const rec = await apiRequest(`/projects/${encodeURIComponent(projectId)}`, token ?? null, { signal }, ProjectResponseSchema)
      return rec.project
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
    const rec = await apiRequest('/projects', token ?? null, {
      method: 'POST',
      signal,
      body: JSON.stringify(data),
    }, ProjectResponseSchema)
    return rec.project
  })
}

export async function updateProject(
  projectId: string,
  data: UpdateProjectData,
  token?: string,
  signal?: AbortSignal
): Promise<Project> {
  return requestWith429Backoff(async () => {
    const rec = await apiRequest(`/projects/${encodeURIComponent(projectId)}`, token ?? null, {
      method: 'PATCH',
      signal,
      body: JSON.stringify(data),
    }, ProjectResponseSchema)
    return rec.project
  })
}

export async function deleteProject(projectId: string, token?: string, signal?: AbortSignal): Promise<void> {
  return requestWith429Backoff(async () => {
    await apiRequest(`/projects/${encodeURIComponent(projectId)}`, token ?? null, {
      method: 'DELETE',
      signal,
    })
  })
}

export async function getProjectSummary(token?: string, signal?: AbortSignal): Promise<ProjectSummary> {
  return requestWith429Backoff(async () => {
    return await apiRequest('/projects/summary', token ?? null, { signal }, ProjectSummaryResponseSchema)
  })
}

// Project Task API functions

export async function getTasks(
  projectId: string,
  token?: string,
  signal?: AbortSignal
): Promise<ProjectTaskListResult> {
  return requestWith429Backoff(async () => {
    return await apiRequest(`/projects/${encodeURIComponent(projectId)}/tasks`, token ?? null, { signal }, TaskPoolListSchema)
  })
}

export async function createTask(
  projectId: string,
  data: CreateTaskData,
  token?: string,
  signal?: AbortSignal
): Promise<ProjectTask> {
  return requestWith429Backoff(async () => {
    const rec = await apiRequest(`/projects/${encodeURIComponent(projectId)}/tasks`, token ?? null, {
      method: 'POST',
      signal,
      body: JSON.stringify(data),
    }, TaskResponseSchema)
    return rec.task
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
      const rec = await apiRequest(
        `/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}`,
        token ?? null,
        { signal },
        TaskDetailResponseSchema
      )
      return rec.task
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
    await apiRequest(
      `/projects/${encodeURIComponent(projectId)}/tasks/${encodeURIComponent(taskId)}/actions`,
      token ?? null,
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
  if (!isApiError(err)) return `${fallback}: ${getErrorMessage(err)}`
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
