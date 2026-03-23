import { apiRequest, isApiError, newRequestId } from './api'
import type { JsonValue } from '../types'

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

export type TaskPoolTask = {
  task_id: string
  title: string
  prompt: string
  status: TaskMainStatus
  review_stage: ReviewStage
  review_round: number
  priority: number
  max_retries: number | null
  retry_count: number
  version: number
  created_at: number
  updated_at: number
  base_branch: string
  head_branch: string
  head_sha: string
  merge_commit: string
  review_feedback: string
  last_error: string
  latest_reviews: TaskReviewSummary[]
}

export type TaskPoolEvent = {
  id: number
  task_id: string
  run_id: string
  event_type: string
  payload_text: string
  payload_json: JsonValue | null
  operator: string
  source: string
  request_id: string
  created_at: number
}

export type TaskPoolListResult = {
  tasks: TaskPoolTask[]
  summary: Record<string, number>
  cursor: number
  next_cursor: number | null
  limit: number
  total: number
}

export type TaskPoolDetailResult = {
  task: TaskPoolTask | null
  events: TaskPoolEvent[]
}

export type TaskPoolEventsResult = {
  events: TaskPoolEvent[]
  last_event_id: number
}

type JsonRecord = Record<string, unknown>

const RATE_LIMIT_RETRY_DELAYS_MS = [300, 900, 1800]

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

function toTaskStatus(raw: unknown): TaskMainStatus {
  const text = asString(raw)
  if (text === 'queued' || text === 'claimed' || text === 'running' || text === 'review' || text === 'done' || text === 'failed' || text === 'canceled') return text
  return 'unknown'
}

function toReviewStage(raw: unknown): ReviewStage {
  const text = asString(raw)
  if (text === 'none' || text === 'open' || text === 'changes_requested' || text === 'approved' || text === 'merged') return text
  return 'unknown'
}

function toReviewRole(raw: unknown): ReviewRole {
  const text = asString(raw)
  if (text === 'correctness_reviewer' || text === 'maintainability_reviewer') return text
  return 'unknown'
}

function toVerdict(raw: unknown): ReviewVerdict {
  const text = asString(raw)
  if (text === 'approve' || text === 'request_changes' || text === 'block') return text
  return 'unknown'
}

function parseBlocker(raw: unknown): TaskReviewBlocker {
  const rec = asRecord(raw)
  return {
    title: asString(rec.title),
    detail: asString(rec.detail),
    severity: asString(rec.severity),
    file: asString(rec.file),
    line: asNullableNumber(rec.line),
    evidence: asString(rec.evidence),
    clean_code_rule: asString(rec.clean_code_rule),
  }
}

function parseBlockers(raw: unknown): TaskReviewBlocker[] {
  if (Array.isArray(raw)) return raw.map(parseBlocker)
  if (typeof raw === 'string' && raw.trim().length > 0) {
    try {
      const parsed = JSON.parse(raw) as unknown
      if (Array.isArray(parsed)) return parsed.map(parseBlocker)
    } catch {
      return []
    }
  }
  return []
}

function parseSuggestions(raw: unknown): string[] {
  if (Array.isArray(raw)) {
    return raw
      .filter((v) => typeof v === 'string')
      .map((v) => asString(v).trim())
      .filter((v) => v.length > 0)
  }
  if (typeof raw === 'string' && raw.trim().length > 0) {
    try {
      const parsed = JSON.parse(raw) as unknown
      if (Array.isArray(parsed)) {
        return parsed
          .filter((v) => typeof v === 'string')
          .map((v) => asString(v).trim())
          .filter((v) => v.length > 0)
      }
    } catch {
      return []
    }
  }
  return []
}

function parseReview(raw: unknown): TaskReviewSummary {
  const rec = asRecord(raw)
  return {
    role: toReviewRole(rec.role),
    verdict: toVerdict(rec.verdict),
    score: asNullableNumber(rec.score),
    summary: asString(rec.summary),
    blockers: parseBlockers(rec.blockers ?? rec.blockers_json),
    suggestions: parseSuggestions(rec.suggestions ?? rec.suggestions_json),
    confidence: asNullableNumber(rec.confidence),
  }
}

function parseLatestReviews(raw: unknown): TaskReviewSummary[] {
  if (Array.isArray(raw)) {
    return raw.map(parseReview).filter((review) => review.role !== 'unknown')
  }
  const rec = asRecord(raw)
  const candidateValues = Object.values(rec)
  if (candidateValues.length === 0) return []
  return candidateValues
    .map(parseReview)
    .filter((review) => review.role !== 'unknown')
}

function parseTask(raw: unknown): TaskPoolTask {
  const rec = asRecord(raw)
  return {
    task_id: asString(rec.task_id),
    title: asString(rec.title, asString(rec.task_id, '-')),
    prompt: asString(rec.prompt),
    status: toTaskStatus(rec.status),
    review_stage: toReviewStage(rec.review_stage),
    review_round: asNumber(rec.review_round, 0),
    priority: asNumber(rec.priority, 0),
    max_retries: asNullableNumber(rec.max_retries),
    retry_count: asNumber(rec.retry_count, 0),
    version: asNumber(rec.version, 0),
    created_at: asNumber(rec.created_at, 0),
    updated_at: asNumber(rec.updated_at, 0),
    base_branch: asString(rec.base_branch),
    head_branch: asString(rec.head_branch),
    head_sha: asString(rec.head_sha),
    merge_commit: asString(rec.merge_commit),
    review_feedback: asString(rec.review_feedback),
    last_error: asString(rec.last_error),
    latest_reviews: parseLatestReviews(rec.latest_reviews),
  }
}

function parseEvent(raw: unknown): TaskPoolEvent {
  const rec = asRecord(raw)
  const payloadRaw = rec.payload
  if (typeof payloadRaw === 'string') {
    let payloadJson: JsonValue | null = null
    try {
      const parsed = JSON.parse(payloadRaw) as unknown
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) payloadJson = parsed as JsonValue
    } catch {
      payloadJson = null
    }
    return {
      id: asNumber(rec.id, 0),
      task_id: asString(rec.task_id),
      run_id: asString(rec.run_id),
      event_type: asString(rec.event_type),
      payload_text: payloadRaw,
      payload_json: payloadJson,
      operator: asString(rec.operator),
      source: asString(rec.source),
      request_id: asString(rec.request_id),
      created_at: asNumber(rec.created_at, 0),
    }
  }

  if (payloadRaw && typeof payloadRaw === 'object') {
    let payloadText = ''
    try {
      payloadText = JSON.stringify(payloadRaw)
    } catch {
      payloadText = ''
    }
    return {
      id: asNumber(rec.id, 0),
      task_id: asString(rec.task_id),
      run_id: asString(rec.run_id),
      event_type: asString(rec.event_type),
      payload_text: payloadText,
      payload_json: asRecord(payloadRaw),
      operator: asString(rec.operator),
      source: asString(rec.source),
      request_id: asString(rec.request_id),
      created_at: asNumber(rec.created_at, 0),
    }
  }

  return {
    id: asNumber(rec.id, 0),
    task_id: asString(rec.task_id),
    run_id: asString(rec.run_id),
    event_type: asString(rec.event_type),
    payload_text: '',
    payload_json: null,
    operator: asString(rec.operator),
    source: asString(rec.source),
    request_id: asString(rec.request_id),
    created_at: asNumber(rec.created_at, 0),
  }
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

export async function listTaskPoolTasks(params: {
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
  const path = qs.length > 0 ? `/tasks?${qs}` : '/tasks'

  return requestWith429Backoff(async () => {
    const rec = asRecord(await apiRequest<JsonValue>(path, params.token, { signal: params.signal }))
    const tasksRaw = Array.isArray(rec.tasks) ? rec.tasks : []
    const summaryRaw = asRecord(rec.summary)
    const summary: Record<string, number> = {}
    for (const [key, value] of Object.entries(summaryRaw)) {
      summary[key] = asNumber(value, 0)
    }
    return {
      tasks: tasksRaw.map(parseTask).filter((task) => task.task_id.length > 0),
      summary,
      cursor: asNumber(rec.cursor, 0),
      next_cursor: asNullableNumber(rec.next_cursor),
      limit: asNumber(rec.limit, params.limit ?? 30),
      total: asNumber(rec.total, tasksRaw.length),
    }
  })
}

export async function getTaskPoolDetail(params: {
  token?: string
  taskId: string
  signal?: AbortSignal
}): Promise<TaskPoolDetailResult> {
  return requestWith429Backoff(async () => {
    const path = `/tasks/${encodeURIComponent(params.taskId)}`
    const rec = asRecord(await apiRequest<JsonValue>(path, params.token, { signal: params.signal }))
    const taskRaw = rec.task
    const task = taskRaw ? parseTask(taskRaw) : null
    const topReviews = parseLatestReviews(rec.latest_reviews)
    if (task && task.latest_reviews.length === 0 && topReviews.length > 0) {
      task.latest_reviews = topReviews
    }
    const eventsRaw = Array.isArray(rec.events) ? rec.events : []
    return {
      task,
      events: eventsRaw.map(parseEvent).filter((evt) => evt.id > 0),
    }
  })
}

export async function getTaskPoolEvents(params: {
  token?: string
  after?: number
  signal?: AbortSignal
}): Promise<TaskPoolEventsResult> {
  const after = Math.max(0, params.after ?? 0)
  return requestWith429Backoff(async () => {
    const path = `/tasks/events?after=${after}`
    const rec = asRecord(await apiRequest<JsonValue>(path, params.token, { signal: params.signal }))
    const eventsRaw = Array.isArray(rec.events) ? rec.events : []
    return {
      events: eventsRaw.map(parseEvent).filter((evt) => evt.id > 0),
      last_event_id: asNumber(rec.last_event_id, after),
    }
  })
}

export async function runTaskPoolAction(params: {
  token?: string
  taskId: string
  action: TaskPoolAction
  signal?: AbortSignal
}): Promise<void> {
  const requestId = newRequestId()
  await requestWith429Backoff(async () => {
    await apiRequest<JsonValue>(`/tasks/${encodeURIComponent(params.taskId)}/actions`, params.token, {
      method: 'POST',
      signal: params.signal,
      headers: { 'X-Request-Id': requestId },
      body: JSON.stringify({ action: params.action, request_id: requestId }),
    })
  })
}
