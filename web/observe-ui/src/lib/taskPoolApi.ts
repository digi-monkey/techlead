import { apiRequest, isApiError, newRequestId } from './api'
import {
  TaskPoolListResultSchema,
  TaskPoolDetailResultSchema,
  TaskPoolEventsResultSchema,
  DraftTaskResultSchema,
  CreateTaskResultSchema,
} from './schemas'
import type {
  TaskPoolTask,
  TaskPoolEvent,
  TaskPoolListResult,
  TaskPoolDetailResult,
  TaskPoolEventsResult,
  DraftTaskResult,
  CreateTaskResult,
} from './schemas'

export const TASK_STATUS_ORDER = ['queued', 'running', 'review', 'done', 'failed', 'canceled'] as const

export type TaskMainStatus = (typeof TASK_STATUS_ORDER)[number] | 'claimed' | 'unknown'
export type TaskListStatusFilter = 'all' | TaskMainStatus
export type ReviewStage = 'none' | 'open' | 'changes_requested' | 'approved' | 'merged' | 'unknown'
export type ReviewRole = 'correctness_reviewer' | 'maintainability_reviewer' | 'unknown'
export type ReviewVerdict = 'approve' | 'request_changes' | 'block' | 'unknown'
export type TaskPoolAction = 'retry_review' | 'requeue' | 'cancel'

export type TaskReviewBlocker = {
  title: string
  detail: string
  severity: string
  file: string
  line: number | null
  evidence: string
  clean_code_rule: string
}

export type TaskReviewSummary = {
  role: ReviewRole
  verdict: ReviewVerdict
  score: number | null
  summary: string
  blockers: TaskReviewBlocker[]
  suggestions: string[]
  confidence: number | null
}

export type { TaskPoolTask, TaskPoolEvent, TaskPoolListResult, TaskPoolDetailResult, TaskPoolEventsResult }

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

export async function listTaskPoolTasks(params: {
  projectId: string
  token?: string
  status?: TaskListStatusFilter
  q?: string
  cursor?: number
  limit?: number
  signal?: AbortSignal
}): Promise<TaskPoolListResult> {
  const search = new URLSearchParams()
  if (params.status && params.status !== 'all' && params.status !== 'unknown') {
    search.set('status', params.status)
  }
  if (params.q && params.q.trim().length > 0) {
    search.set('q', params.q.trim())
  }
  search.set('cursor', String(Math.max(0, params.cursor ?? 0)))
  search.set('limit', String(Math.max(1, Math.min(200, params.limit ?? 30))))
  const qs = search.toString()
  const basePath = `/projects/${encodeURIComponent(params.projectId)}/tasks`
  const path = qs.length > 0 ? `${basePath}?${qs}` : basePath

  return requestWith429Backoff(async () => {
    return await apiRequest(path, params.token ?? null, { signal: params.signal }, TaskPoolListResultSchema)
  })
}

export async function getTaskPoolDetail(params: {
  projectId: string
  token?: string
  taskId: string
  signal?: AbortSignal
}): Promise<TaskPoolDetailResult> {
  return requestWith429Backoff(async () => {
    const path = `/projects/${encodeURIComponent(params.projectId)}/tasks/${encodeURIComponent(params.taskId)}`
    const result = await apiRequest(path, params.token ?? null, { signal: params.signal }, TaskPoolDetailResultSchema)
    return {
      task: result.task,
      events: result.events.filter((evt) => evt.id > 0),
    }
  })
}

export async function getTaskPoolEvents(params: {
  projectId: string
  token?: string
  after?: number
  signal?: AbortSignal
}): Promise<TaskPoolEventsResult> {
  const after = Math.max(0, params.after ?? 0)
  return requestWith429Backoff(async () => {
    const path = `/projects/${encodeURIComponent(params.projectId)}/events?after=${after}`
    const result = await apiRequest(path, params.token ?? null, { signal: params.signal }, TaskPoolEventsResultSchema)
    return {
      events: result.events.filter((evt) => evt.id > 0),
      last_event_id: result.last_event_id,
    }
  })
}

export async function runTaskPoolAction(params: {
  projectId: string
  token?: string
  taskId: string
  action: TaskPoolAction
  signal?: AbortSignal
}): Promise<void> {
  const requestId = newRequestId()
  await requestWith429Backoff(async () => {
    await apiRequest(`/projects/${encodeURIComponent(params.projectId)}/tasks/${encodeURIComponent(params.taskId)}/actions`, params.token ?? null, {
      method: 'POST',
      signal: params.signal,
      headers: { 'X-Request-Id': requestId },
      body: JSON.stringify({ action: params.action, request_id: requestId }),
    })
  })
}

export async function draftTask(params: {
  projectId: string
  intent: string
  provider?: string
  token?: string
  signal?: AbortSignal
}): Promise<DraftTaskResult> {
  const requestId = newRequestId()
  return requestWith429Backoff(async () => {
    return await apiRequest(
      `/projects/${encodeURIComponent(params.projectId)}/tasks/draft`,
      params.token ?? null,
      {
        method: 'POST',
        signal: params.signal,
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({
          intent: params.intent,
          provider: params.provider,
          request_id: requestId,
        }),
      },
      DraftTaskResultSchema
    )
  })
}

export async function createTask(params: {
  projectId: string
  title: string
  prompt: string
  max_retries?: number
  token?: string
  signal?: AbortSignal
}): Promise<CreateTaskResult> {
  const requestId = newRequestId()
  return requestWith429Backoff(async () => {
    return await apiRequest(
      `/projects/${encodeURIComponent(params.projectId)}/tasks`,
      params.token ?? null,
      {
        method: 'POST',
        signal: params.signal,
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({
          title: params.title,
          prompt: params.prompt,
          max_retries: params.max_retries,
          request_id: requestId,
        }),
      },
      CreateTaskResultSchema
    )
  })
}
