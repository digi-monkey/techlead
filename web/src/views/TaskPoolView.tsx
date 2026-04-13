import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

import { isApiError } from '../lib/api'
import {
  TASK_STATUS_ORDER,
  getTaskPoolDetail,
  getTaskPoolEvents,
  listTaskPoolTasks,
  runTaskPoolAction,
  type TaskListStatusFilter,
  type TaskPoolAction,
  type TaskPoolEvent,
  type TaskPoolTask,
  type TaskReviewSummary,
} from '../lib/taskPoolApi'
import { useDebouncedState } from '../hooks/useDebouncedState'
import { CreateTaskModal } from '../components/CreateTaskModal'

type TaskPoolViewProps = {
  projectId: string
  observeAuth?: string
  controlAuth?: string
  onBack?: () => void
}

const LIST_POLL_MS = 5000
const DETAIL_POLL_MS = 3000
const EVENTS_POLL_MS = 2000
const PAGE_LIMIT = 30
const TIMELINE_LIMIT = 300

const ALL_STATUS_FILTERS: TaskListStatusFilter[] = ['all', ...TASK_STATUS_ORDER, 'claimed']

function formatUnixTs(ts: number): string {
  if (!Number.isFinite(ts) || ts <= 0) return '-'
  return new Date(ts * 1000).toLocaleString()
}

function formatError(err: unknown, fallback: string): string {
  if (!isApiError(err)) return `${fallback}: ${(err as Error).message}`
  const code = err.errorCode?.trim() || 'unknown_error'
  if (err.status === 401) {
    return `未授权 401：请先扫码授权或提供有效 token（${code}）`
  }
  if (err.status === 409) {
    return `冲突 409：请求与当前任务状态不一致，请刷新后重试（${code}）`
  }
  if (err.status === 429) {
    return `限流 429：已自动退避重试 3 次，仍被限流（${code}）`
  }
  if (err.status === 400) {
    return `请求错误 400：${code}`
  }
  return `${fallback}: ${err.status} ${code}`
}

function stringifyPayload(evt: TaskPoolEvent): string {
  if (evt.payload_text.trim().length > 0 && evt.payload_text.trim() !== '{}') {
    try {
      const parsed = JSON.parse(evt.payload_text) as unknown
      return JSON.stringify(parsed, null, 2)
    } catch {
      return evt.payload_text
    }
  }
  if (evt.payload_json && JSON.stringify(evt.payload_json) !== '{}') {
    try {
      return JSON.stringify(evt.payload_json, null, 2)
    } catch {
      return '{}'
    }
  }
  // For events with no meaningful payload, show contextual info
  const parts: string[] = []
  const typeDesc = eventTypeDescription(evt.event_type)
  if (typeDesc) parts.push(typeDesc)
  if (evt.run_id) parts.push(`run: ${evt.run_id}`)
  if (evt.operator) parts.push(`by: ${evt.operator}`)
  if (evt.request_id) parts.push(`req: ${evt.request_id}`)
  return parts.length > 0 ? parts.join('\n') : '(no details)'
}

function eventTypeDescription(eventType: string): string {
  const map: Record<string, string> = {
    'task.running': '任务开始执行',
    'task.done': '任务完成',
    'task.failed': '任务失败',
    'task.requeue': '任务重新排队（将自动重试）',
    'task.created': '任务创建',
    'task.updated': '任务已更新',
    'task.review.opened': '代码审查已开启',
    'task.review.approved': '代码审查通过',
    'task.review.changes_requested.requeue': '审查要求修改 → 重新排队',
    'task.review.changes_requested.fail': '审查要求修改 → 已达最大重试次数',
    'task.merge.succeeded': '代码合并成功',
    'task.action.requeue': '手动重新排队',
    'task.action.cancel': '手动取消',
  }
  return map[eventType] ?? ''
}

function eventTone(eventType: string): string {
  const lower = eventType.toLowerCase()
  if (lower.includes('fail') || lower.includes('error') || lower.includes('block')) {
    return 'border-rose-300 bg-rose-50/70'
  }
  if (lower.includes('changes_requested') || lower.includes('retry') || lower.includes('requeue')) {
    return 'border-amber-300 bg-amber-50/70'
  }
  if (lower.includes('approve') || lower.includes('merge') || lower.includes('done')) {
    return 'border-emerald-300 bg-emerald-50/70'
  }
  return 'border-slate-200 bg-white'
}

function severityTone(severity: string): string {
  const lower = severity.toLowerCase()
  if (lower === 'high') return 'text-rose-700 bg-rose-50'
  if (lower === 'medium') return 'text-amber-700 bg-amber-50'
  if (lower === 'low') return 'text-emerald-700 bg-emerald-50'
  return 'text-slate-600 bg-slate-100'
}

function firstNonEmpty(...values: string[]): string {
  for (const value of values) {
    const next = value.trim()
    if (next.length > 0) return next
  }
  return '-'
}

function normalizeTimeline(events: TaskPoolEvent[]): TaskPoolEvent[] {
  const dedup = new Map<number, TaskPoolEvent>()
  for (const evt of events) {
    if (evt.id > 0) dedup.set(evt.id, evt)
  }
  return Array.from(dedup.values())
    .sort((a, b) => b.id - a.id)
    .slice(0, TIMELINE_LIMIT)
}

function isRetryReviewEnabled(task: TaskPoolTask | null): boolean {
  if (!task) return false
  return (task.status === 'review' || task.status === 'queued') && task.review_stage === 'changes_requested'
}

function isRequeueEnabled(task: TaskPoolTask | null): boolean {
  if (!task) return false
  return task.status === 'failed' || task.status === 'canceled' || task.status === 'review'
}

function isCancelEnabled(task: TaskPoolTask | null): boolean {
  if (!task) return false
  return task.status === 'queued' || task.status === 'running' || task.status === 'review'
}

function renderReviewCard(review: TaskReviewSummary, emptyTitle: string) {
  const blockers = review.blockers.slice(0, 3)
  return (
    <article key={review.role} className="rounded-xl border border-slate-200 bg-white p-3">
      <header className="flex flex-wrap items-center gap-2">
        <strong className="text-xs text-slate-700">{review.role}</strong>
        <span className="rounded-md bg-slate-100 px-2 py-0.5 text-[11px] text-slate-700">{review.verdict}</span>
        {review.score !== null ? (
          <span className="rounded-md bg-slate-100 px-2 py-0.5 text-[11px] text-slate-700">score {review.score}</span>
        ) : null}
      </header>
      <p className="mt-2 text-xs text-slate-700">{firstNonEmpty(review.summary, emptyTitle)}</p>
      {blockers.length > 0 ? (
        <div className="mt-2 space-y-1.5">
          {blockers.map((blocker, idx) => (
            <div key={`${review.role}-${idx}`} className="rounded-lg border border-slate-200 bg-slate-50 p-2 text-[11px]">
              <div className="flex flex-wrap items-center gap-1.5">
                <span className="font-medium text-slate-700">{firstNonEmpty(blocker.title, 'blocker')}</span>
                <span className={`rounded px-1.5 py-0.5 ${severityTone(blocker.severity)}`}>
                  {firstNonEmpty(blocker.severity, 'unknown')}
                </span>
                {blocker.file.trim().length > 0 ? (
                  <span className="text-slate-500">{`${blocker.file}${blocker.line !== null ? `:${blocker.line}` : ''}`}</span>
                ) : null}
              </div>
              <div className="mt-1 text-slate-600">{firstNonEmpty(blocker.detail, blocker.evidence, blocker.clean_code_rule)}</div>
            </div>
          ))}
        </div>
      ) : null}
    </article>
  )
}

export function TaskPoolView({ projectId, observeAuth, controlAuth, onBack }: TaskPoolViewProps) {
  const [statusFilter, setStatusFilter] = useState<TaskListStatusFilter>('all')
  const [searchInput, searchQuery, setSearchInput] = useDebouncedState('', 250)
  const [cursor, setCursor] = useState(0)
  const [cursorHistory, setCursorHistory] = useState<number[]>([])
  const [showCreateModal, setShowCreateModal] = useState(false)

  const [tasks, setTasks] = useState<TaskPoolTask[]>([])
  const [summary, setSummary] = useState<Record<string, number>>({})
  const [nextCursor, setNextCursor] = useState<number | null>(null)
  const [total, setTotal] = useState(0)
  const [listError, setListError] = useState('')
  const [listLoading, setListLoading] = useState(true)

  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null)
  const [selectedTask, setSelectedTask] = useState<TaskPoolTask | null>(null)
  const [detailError, setDetailError] = useState('')
  const [detailLoading, setDetailLoading] = useState(false)

  const [timeline, setTimeline] = useState<TaskPoolEvent[]>([])
  const [timelineError, setTimelineError] = useState('')

  const [actionBusy, setActionBusy] = useState<TaskPoolAction | null>(null)
  const [actionMessage, setActionMessage] = useState('')

  const timelineCursorRef = useRef(0)
  const knownEventIdsRef = useRef<Set<number>>(new Set())

  const grouped = useMemo(() => {
    const buckets: Record<string, TaskPoolTask[]> = {
      queued: [],
      running: [],
      review: [],
      done: [],
      failed: [],
      canceled: [],
      claimed: [],
      unknown: [],
    }
    for (const task of tasks) {
      const key = task.status in buckets ? task.status : 'unknown'
      buckets[key].push(task)
    }
    return buckets
  }, [tasks])

  const reviewMap = useMemo(() => {
    const map = new Map<string, TaskReviewSummary>()
    if (!selectedTask) return map
    for (const item of selectedTask.latest_reviews) {
      map.set(item.role, item)
    }
    return map
  }, [selectedTask])

  const correctnessReview = reviewMap.get('correctness_reviewer')
  const maintainabilityReview = reviewMap.get('maintainability_reviewer')

  const canRetryReview = isRetryReviewEnabled(selectedTask)
  const canRequeue = isRequeueEnabled(selectedTask)
  const canCancel = isCancelEnabled(selectedTask)

  useEffect(() => {
    setCursor(0)
    setCursorHistory([])
  }, [statusFilter, searchQuery])

  useEffect(() => {
    if (tasks.length === 0) {
      setSelectedTaskId(null)
      return
    }
    if (!selectedTaskId || !tasks.some((task) => task.task_id === selectedTaskId)) {
      setSelectedTaskId(tasks[0].task_id)
    }
  }, [tasks, selectedTaskId])

  useEffect(() => {
    knownEventIdsRef.current = new Set()
    timelineCursorRef.current = 0
    setTimeline([])
    setTimelineError('')
  }, [selectedTaskId])

  const refreshList = useCallback(async (silent: boolean) => {
    if (!silent) setListLoading(true)
    try {
      const data = await listTaskPoolTasks({
        projectId,
        token: observeAuth,
        status: statusFilter,
        q: searchQuery,
        cursor,
        limit: PAGE_LIMIT,
      })
      setTasks(data.tasks)
      setSummary(data.summary)
      setNextCursor(data.next_cursor)
      setTotal(data.total)
      setListError('')
    } catch (err) {
      setListError(formatError(err, '任务列表刷新失败'))
    } finally {
      if (!silent) setListLoading(false)
    }
  }, [observeAuth, statusFilter, searchQuery, cursor])

  const refreshDetail = useCallback(async (taskId: string, silent: boolean) => {
    if (!silent) setDetailLoading(true)
    try {
      const detail = await getTaskPoolDetail({ projectId, token: observeAuth, taskId })
      setSelectedTask(detail.task)
      const taskEvents = detail.events.filter((evt) => evt.task_id === taskId)
      const normalized = normalizeTimeline(taskEvents)
      setTimeline(normalized)
      const ids = new Set<number>()
      let maxId = 0
      for (const evt of normalized) {
        ids.add(evt.id)
        if (evt.id > maxId) maxId = evt.id
      }
      knownEventIdsRef.current = ids
      timelineCursorRef.current = maxId
      setDetailError('')
    } catch (err) {
      setDetailError(formatError(err, '任务详情刷新失败'))
    } finally {
      if (!silent) setDetailLoading(false)
    }
  }, [observeAuth])

  const refreshTimeline = useCallback(async (taskId: string) => {
    try {
      const stream = await getTaskPoolEvents({ projectId, token: observeAuth, after: timelineCursorRef.current })
      timelineCursorRef.current = Math.max(timelineCursorRef.current, stream.last_event_id)
      const incoming = stream.events.filter((evt) => evt.task_id === taskId)
      if (incoming.length > 0) {
        setTimeline((prev) => {
          const merged = [...prev]
          for (const evt of incoming) {
            if (!knownEventIdsRef.current.has(evt.id)) {
              knownEventIdsRef.current.add(evt.id)
              merged.push(evt)
            }
          }
          return normalizeTimeline(merged)
        })
      }
      setTimelineError('')
    } catch (err) {
      setTimelineError(formatError(err, '时间线刷新失败'))
    }
  }, [observeAuth])

  useEffect(() => {
    let cancelled = false
    let timer: number | null = null
    const loop = async (silent: boolean) => {
      await refreshList(silent)
      if (cancelled) return
      timer = window.setTimeout(() => {
        void loop(true)
      }, LIST_POLL_MS)
    }
    void loop(false)
    return () => {
      cancelled = true
      if (timer !== null) window.clearTimeout(timer)
    }
  }, [refreshList])

  useEffect(() => {
    if (!selectedTaskId) {
      setSelectedTask(null)
      setDetailError('')
      return undefined
    }
    let cancelled = false
    let timer: number | null = null
    const loop = async (silent: boolean) => {
      await refreshDetail(selectedTaskId, silent)
      if (cancelled) return
      timer = window.setTimeout(() => {
        void loop(true)
      }, DETAIL_POLL_MS)
    }
    void loop(false)
    return () => {
      cancelled = true
      if (timer !== null) window.clearTimeout(timer)
    }
  }, [selectedTaskId, refreshDetail])

  useEffect(() => {
    if (!selectedTaskId) return undefined
    let cancelled = false
    let timer: number | null = null
    const loop = async () => {
      await refreshTimeline(selectedTaskId)
      if (cancelled) return
      timer = window.setTimeout(() => {
        void loop()
      }, EVENTS_POLL_MS)
    }
    void loop()
    return () => {
      cancelled = true
      if (timer !== null) window.clearTimeout(timer)
    }
  }, [selectedTaskId, refreshTimeline])

  const executeAction = useCallback(async (action: TaskPoolAction) => {
    if (!selectedTaskId) return
    setActionBusy(action)
    setActionMessage('')
    try {
      await runTaskPoolAction({
        projectId,
        token: controlAuth,
        taskId: selectedTaskId,
        action,
      })
      setActionMessage(`动作已提交：${action}`)
      await Promise.all([
        refreshList(true),
        refreshDetail(selectedTaskId, true),
        refreshTimeline(selectedTaskId),
      ])
    } catch (err) {
      setActionMessage(formatError(err, `动作失败 ${action}`))
    } finally {
      setActionBusy(null)
    }
  }, [selectedTaskId, controlAuth, refreshList, refreshDetail, refreshTimeline])

  return (
    <div className="grid h-full min-h-0 grid-cols-1 gap-3 lg:grid-cols-2 xl:grid-cols-[320px_minmax(420px,1fr)_minmax(360px,1fr)]">
      <section className="flex min-h-0 flex-col rounded-2xl border border-slate-200 bg-slate-50 p-3">
        <header className="mb-2">
          {onBack && (
            <button
              type="button"
              onClick={onBack}
              className="mb-2 flex items-center gap-1 text-xs text-slate-500 hover:text-slate-700"
            >
              <svg className="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
              </svg>
              Back to Projects
            </button>
          )}
          <div className="flex items-center gap-2">
            <h2 className="text-sm font-semibold text-slate-800">Task Pool</h2>
            <span className="rounded-md bg-slate-200 px-1.5 py-0.5 text-[10px] text-slate-600">{projectId}</span>
            <button
              onClick={() => setShowCreateModal(true)}
              className="ml-auto rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-medium text-white shadow hover:bg-blue-700 transition"
            >
              + New Task
            </button>
          </div>
          <p className="mt-1 text-xs text-slate-500">分组列表 / 搜索 / 分页</p>
        </header>

        <div className="grid gap-2">
          <select
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value as TaskListStatusFilter)}
            className="h-9 rounded-lg border border-slate-300 bg-white px-2 text-xs text-slate-700 outline-none focus:border-slate-500"
          >
            {ALL_STATUS_FILTERS.map((status) => (
              <option key={status} value={status}>
                {status}
              </option>
            ))}
          </select>
          <input
            value={searchInput}
            onChange={(e) => setSearchInput(e.target.value)}
            placeholder="search title/prompt"
            className="h-9 rounded-lg border border-slate-300 bg-white px-2 text-xs text-slate-700 outline-none focus:border-slate-500"
          />
        </div>

        <div className="mt-2 flex items-center justify-between text-[11px] text-slate-500">
          <span>{`total ${total}`}</span>
          <span>{`page offset ${cursor}`}</span>
        </div>

        <div className="mt-2 min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
          {listLoading ? (
            <div className="rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs text-slate-500">loading tasks...</div>
          ) : null}
          {listError ? (
            <div className="rounded-lg border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-700">{listError}</div>
          ) : null}
          {['queued', 'running', 'review', 'done', 'failed', 'canceled', 'claimed', 'unknown'].map((group) => {
            const groupItems = grouped[group] ?? []
            if (groupItems.length === 0) return null
            return (
              <article key={group} className="rounded-xl border border-slate-200 bg-white p-2">
                <div className="mb-1.5 flex items-center justify-between text-[11px]">
                  <strong className="text-slate-700">{group}</strong>
                  <span className="text-slate-500">{summary[group] ?? groupItems.length}</span>
                </div>
                <div className="space-y-1.5">
                  {groupItems.map((task) => {
                    const selected = task.task_id === selectedTaskId
                    return (
                      <button
                        key={task.task_id}
                        type="button"
                        onClick={() => setSelectedTaskId(task.task_id)}
                        className={`w-full rounded-lg border px-2 py-2 text-left transition-colors ${
                          selected
                            ? 'border-slate-900 bg-slate-900 text-white'
                            : 'border-slate-200 bg-slate-50 text-slate-700 hover:border-slate-300 hover:bg-white'
                        }`}
                      >
                        <div className="truncate text-xs font-medium">{task.title || task.task_id}</div>
                        <div className={`mt-1 flex flex-wrap gap-1 text-[10px] ${selected ? 'text-slate-200' : 'text-slate-500'}`}>
                          <span>{task.status}</span>
                          <span>{`review:${task.review_stage}`}</span>
                          <span>{`round:${task.review_round}`}</span>
                          <span>{formatUnixTs(task.updated_at)}</span>
                        </div>
                      </button>
                    )
                  })}
                </div>
              </article>
            )
          })}
        </div>

        <footer className="mt-2 flex items-center justify-between gap-2">
          <button
            type="button"
            onClick={() => {
              setCursorHistory((prev) => {
                if (prev.length === 0) return prev
                const next = prev.slice(0, -1)
                const prevCursor = prev[prev.length - 1]
                setCursor(prevCursor)
                return next
              })
            }}
            disabled={cursorHistory.length === 0}
            className="h-8 rounded-lg border border-slate-300 bg-white px-3 text-xs text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Prev
          </button>
          <button
            type="button"
            onClick={() => {
              if (nextCursor === null) return
              setCursorHistory((prev) => [...prev, cursor])
              setCursor(nextCursor)
            }}
            disabled={nextCursor === null}
            className="h-8 rounded-lg border border-slate-300 bg-white px-3 text-xs text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Next
          </button>
        </footer>
      </section>

      <section className="flex min-h-0 flex-col rounded-2xl border border-slate-200 bg-slate-50 p-3">
        <header className="mb-2 flex items-center justify-between gap-2">
          <div>
            <h2 className="text-sm font-semibold text-slate-800">Task Detail</h2>
            <p className="text-xs text-slate-500">任务 / Git / 双角色 Review 摘要</p>
          </div>
          {detailLoading ? <span className="text-[11px] text-slate-500">refreshing...</span> : null}
        </header>

        {detailError ? (
          <div className="mb-2 rounded-lg border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-700">{detailError}</div>
        ) : null}
        {actionMessage ? (
          <div className={`mb-2 rounded-lg border px-3 py-2 text-xs ${actionMessage.includes('失败') ? 'border-rose-200 bg-rose-50 text-rose-700' : 'border-emerald-200 bg-emerald-50 text-emerald-700'}`}>
            {actionMessage}
          </div>
        ) : null}

        {!selectedTask ? (
          <div className="flex min-h-0 flex-1 items-center justify-center text-xs text-slate-500">请选择任务</div>
        ) : (
          <div className="min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
            <article className="rounded-xl border border-slate-200 bg-white p-3">
              <div className="grid gap-1 text-xs">
                <div><span className="text-slate-500">task_id: </span><span className="font-mono text-slate-800">{selectedTask.task_id}</span></div>
                <div><span className="text-slate-500">title: </span><span className="text-slate-800">{selectedTask.title}</span></div>
                <div><span className="text-slate-500">status: </span><span className="text-slate-800">{selectedTask.status}</span></div>
                <div><span className="text-slate-500">review_stage: </span><span className="text-slate-800">{selectedTask.review_stage}</span></div>
                <div><span className="text-slate-500">review_round: </span><span className="text-slate-800">{selectedTask.review_round}</span></div>
                <div><span className="text-slate-500">priority/max_retries/retry_count: </span><span className="text-slate-800">{`${selectedTask.priority}/${selectedTask.max_retries ?? '-'} / ${selectedTask.retry_count}`}</span></div>
                <div><span className="text-slate-500">updated_at: </span><span className="text-slate-800">{formatUnixTs(selectedTask.updated_at)}</span></div>
              </div>
              {selectedTask.prompt.trim().length > 0 ? (
                <pre className="mt-2 max-h-28 overflow-auto rounded-lg border border-slate-200 bg-slate-50 p-2 text-[11px] text-slate-700">{selectedTask.prompt}</pre>
              ) : null}
            </article>

            <article className="rounded-xl border border-slate-200 bg-white p-3">
              <h3 className="text-xs font-semibold text-slate-700">Git</h3>
              <div className="mt-1 grid gap-1 text-xs text-slate-700">
                <div><span className="text-slate-500">base_branch: </span>{firstNonEmpty(selectedTask.base_branch)}</div>
                <div><span className="text-slate-500">head_branch: </span>{firstNonEmpty(selectedTask.head_branch)}</div>
                <div><span className="text-slate-500">head_sha: </span><span className="font-mono">{firstNonEmpty(selectedTask.head_sha)}</span></div>
                <div><span className="text-slate-500">merge_commit: </span><span className="font-mono">{firstNonEmpty(selectedTask.merge_commit)}</span></div>
              </div>
            </article>

            <article className="rounded-xl border border-slate-200 bg-white p-3">
              <h3 className="text-xs font-semibold text-slate-700">Latest Reviews</h3>
              <div className="mt-2 space-y-2">
                {correctnessReview
                  ? renderReviewCard(correctnessReview, 'no correctness summary')
                  : <div className="rounded-lg border border-dashed border-slate-300 p-2 text-xs text-slate-500">correctness_reviewer: no data</div>}
                {maintainabilityReview
                  ? renderReviewCard(maintainabilityReview, 'no maintainability summary')
                  : <div className="rounded-lg border border-dashed border-slate-300 p-2 text-xs text-slate-500">maintainability_reviewer: no data</div>}
              </div>
              {selectedTask.review_feedback.trim().length > 0 ? (
                <div className="mt-2 rounded-lg border border-amber-200 bg-amber-50 p-2">
                  <div className="text-[11px] font-semibold text-amber-800">review_feedback</div>
                  <pre className="mt-1 max-h-28 overflow-auto text-[11px] text-amber-900">{selectedTask.review_feedback}</pre>
                </div>
              ) : null}
              {selectedTask.last_error.trim().length > 0 ? (
                <div className="mt-2 rounded-lg border border-rose-200 bg-rose-50 p-2 text-[11px] text-rose-700">
                  <span className="font-semibold">last_error: </span>
                  {selectedTask.last_error}
                </div>
              ) : null}
            </article>
          </div>
        )}

        <footer className="mt-2 grid grid-cols-3 gap-2">
          <button
            type="button"
            disabled={!canRetryReview || actionBusy !== null}
            onClick={() => void executeAction('retry_review')}
            className="h-9 rounded-lg border border-slate-300 bg-white text-xs text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {actionBusy === 'retry_review' ? 'retrying...' : 'retry_review'}
          </button>
          <button
            type="button"
            disabled={!canRequeue || actionBusy !== null}
            onClick={() => void executeAction('requeue')}
            className="h-9 rounded-lg border border-slate-300 bg-white text-xs text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {actionBusy === 'requeue' ? 'requeueing...' : 'requeue'}
          </button>
          <button
            type="button"
            disabled={!canCancel || actionBusy !== null}
            onClick={() => void executeAction('cancel')}
            className="h-9 rounded-lg border border-rose-300 bg-rose-50 text-xs text-rose-700 hover:bg-rose-100 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {actionBusy === 'cancel' ? 'canceling...' : 'cancel'}
          </button>
        </footer>
      </section>

      <section className="flex min-h-0 flex-col rounded-2xl border border-slate-200 bg-slate-50 p-3 lg:col-span-2 xl:col-span-1">
        <header className="mb-2">
          <h2 className="text-sm font-semibold text-slate-800">Timeline</h2>
          <p className="text-xs text-slate-500">task_events（2s polling）</p>
        </header>
        {timelineError ? (
          <div className="mb-2 rounded-lg border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-700">{timelineError}</div>
        ) : null}
        <div className="min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
          {timeline.length === 0 ? (
            <div className="rounded-lg border border-dashed border-slate-300 bg-white px-3 py-2 text-xs text-slate-500">no events</div>
          ) : (
            timeline.map((evt) => (
              <article key={evt.id} className={`rounded-xl border p-2 ${eventTone(evt.event_type)}`}>
                <div className="flex flex-wrap items-center gap-1 text-[11px]">
                  <span className="font-semibold text-slate-700">{`#${evt.id}`}</span>
                  <span className="rounded bg-slate-100 px-1.5 py-0.5 text-slate-700">{evt.event_type || '-'}</span>
                  <span className="text-slate-500">{evt.source || '-'}</span>
                  <span className="ml-auto text-slate-500">{formatUnixTs(evt.created_at)}</span>
                </div>
                <pre className="mt-1 max-h-28 overflow-auto rounded bg-white/80 p-2 text-[11px] text-slate-700">{stringifyPayload(evt)}</pre>
              </article>
            ))
          )}
        </div>
      </section>

      {showCreateModal && (
        <CreateTaskModal
          projectId={projectId}
          token={controlAuth}
          onClose={() => setShowCreateModal(false)}
          onSuccess={() => {
            setShowCreateModal(false)
            void refreshList(false)
          }}
        />
      )}
    </div>
  )
}
