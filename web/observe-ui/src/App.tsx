import { useEffect, useMemo, useState } from 'react'

import { Sidebar } from './components/Sidebar'
import { apiRequest, newRequestId, toEventRows } from './lib/api'
import { ControlView } from './views/ControlView'
import { ObserveView } from './views/ObserveView'
import { SessionView } from './views/SessionView'
import { TasksView } from './views/TasksView'
import {
  MODE_META,
  type EventRow,
  type JsonValue,
  type Mode,
  type SessionMessage,
  type StatusTone,
  type TaskDetailResponse,
  type TaskListResponse,
} from './types'

export default function App() {
  const queryTokens = useMemo(() => {
    const params = new URLSearchParams(window.location.search)
    const shared = params.get('token') ?? ''
    return {
      observe: params.get('observe_token') ?? shared,
      control: params.get('control_token') ?? params.get('ctrl_token') ?? shared,
    }
  }, [])

  const [mode, setMode] = useState<Mode>('observe')
  const [observeToken, setObserveToken] = useState(queryTokens.observe)
  const [controlToken, setControlToken] = useState(queryTokens.control)
  const [statusText, setStatusText] = useState('ready')
  const [statusTone, setStatusTone] = useState<StatusTone>('idle')

  const [after, setAfter] = useState(0)
  const [events, setEvents] = useState<EventRow[]>([])
  const [tasksRaw, setTasksRaw] = useState('{"tasks":[]}')
  const [tasksList, setTasksList] = useState<TaskListResponse>({
    tasks: [],
    summary: {},
    cursor: 0,
    next_cursor: null,
    limit: 50,
    total: 0,
  })
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null)
  const [taskDetail, setTaskDetail] = useState<TaskDetailResponse | null>(null)
  const [taskStatusFilter, setTaskStatusFilter] = useState('')
  const [taskSearch, setTaskSearch] = useState('')
  const [createTitle, setCreateTitle] = useState('')
  const [createPrompt, setCreatePrompt] = useState('')
  const [createPriority, setCreatePriority] = useState('0')
  const [createMaxRetries, setCreateMaxRetries] = useState('')
  const [editTitle, setEditTitle] = useState('')
  const [editPrompt, setEditPrompt] = useState('')
  const [editPriority, setEditPriority] = useState('0')
  const [editMaxRetries, setEditMaxRetries] = useState('')

  const [runMode, setRunMode] = useState<'optimize' | 'pool'>('optimize')
  const [askPrompt, setAskPrompt] = useState('')

  const [sessionState, setSessionState] = useState<JsonValue>({})
  const [sessionInput, setSessionInput] = useState('')

  const sessionMessages = (Array.isArray(sessionState.messages) ? sessionState.messages : []) as SessionMessage[]

  async function refreshSessionOnce() {
    try {
      const resp = await apiRequest<JsonValue>('/sessions/current', observeToken)
      setSessionState(resp)
    } catch (err) {
      setStatusTone('warn')
      setStatusText(`refresh session failed: ${(err as Error).message}`)
    }
  }

  async function refreshTasksList() {
    const params = new URLSearchParams()
    params.set('limit', '100')
    if (taskStatusFilter) params.set('status', taskStatusFilter)
    if (taskSearch.trim()) params.set('q', taskSearch.trim())
    const list = await apiRequest<TaskListResponse>(`/tasks?${params.toString()}`, observeToken)
    setTasksList(list)
    setTasksRaw(JSON.stringify(list, null, 2))
    if (selectedTaskId && !list.tasks.some((t) => t.task_id === selectedTaskId)) {
      setSelectedTaskId(null)
      setTaskDetail(null)
    }
  }

  async function refreshTaskDetail(taskId: string) {
    const detail = await apiRequest<TaskDetailResponse>(`/tasks/${encodeURIComponent(taskId)}`, observeToken)
    setTaskDetail(detail)
    setEditTitle(detail.task.title)
    setEditPrompt(detail.task.prompt ?? '')
    setEditPriority(String(detail.task.priority))
    setEditMaxRetries(detail.task.max_retries == null ? '' : String(detail.task.max_retries))
  }

  async function createTask() {
    if (!createTitle.trim()) {
      setStatusTone('warn')
      setStatusText('title required')
      return
    }
    try {
      const requestId = newRequestId()
      await apiRequest<JsonValue>('/tasks', controlToken, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({
          title: createTitle.trim(),
          prompt: createPrompt || null,
          priority: Number(createPriority || '0'),
          max_retries: createMaxRetries.trim() ? Number(createMaxRetries) : null,
          request_id: requestId,
        }),
      })
      setCreateTitle('')
      setCreatePrompt('')
      setCreatePriority('0')
      setCreateMaxRetries('')
      await refreshTasksList()
      setStatusTone('ok')
      setStatusText('task created')
    } catch (err) {
      setStatusTone('bad')
      setStatusText((err as Error).message)
    }
  }

  async function patchSelectedTask() {
    if (!selectedTaskId || !taskDetail) return
    try {
      const requestId = newRequestId()
      await apiRequest<JsonValue>(`/tasks/${encodeURIComponent(selectedTaskId)}`, controlToken, {
        method: 'PATCH',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({
          title: editTitle,
          prompt: editPrompt,
          priority: Number(editPriority || '0'),
          max_retries: editMaxRetries.trim() ? Number(editMaxRetries) : null,
          version: taskDetail.task.version,
          request_id: requestId,
        }),
      })
      await refreshTaskDetail(selectedTaskId)
      await refreshTasksList()
      setStatusTone('ok')
      setStatusText('task updated')
    } catch (err) {
      setStatusTone('bad')
      setStatusText((err as Error).message)
    }
  }

  async function runTaskAction(action: 'requeue' | 'cancel' | 'resume' | 'force_fail') {
    if (!selectedTaskId) return
    try {
      const requestId = newRequestId()
      await apiRequest<JsonValue>(`/tasks/${encodeURIComponent(selectedTaskId)}/actions`, controlToken, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ action, request_id: requestId }),
      })
      await refreshTaskDetail(selectedTaskId)
      await refreshTasksList()
      setStatusTone('ok')
      setStatusText(`task action: ${action}`)
    } catch (err) {
      setStatusTone('bad')
      setStatusText((err as Error).message)
    }
  }

  async function startRun() {
    try {
      const requestId = newRequestId()
      const result = await apiRequest<JsonValue>('/runs/start', controlToken, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ mode: runMode, request_id: requestId }),
      })
      setStatusTone('ok')
      setStatusText(JSON.stringify(result))
    } catch (err) {
      setStatusTone('bad')
      setStatusText((err as Error).message)
    }
  }

  async function controlRun(action: 'pause' | 'resume' | 'abort' | 'ask') {
    try {
      const requestId = newRequestId()
      const payload: JsonValue = { action, request_id: requestId }
      if (action === 'ask') payload.prompt = askPrompt
      const result = await apiRequest<JsonValue>('/runs/current/control', controlToken, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify(payload),
      })
      setStatusTone('ok')
      setStatusText(JSON.stringify(result))
    } catch (err) {
      setStatusTone('bad')
      setStatusText((err as Error).message)
    }
  }

  async function startSession() {
    try {
      const requestId = newRequestId()
      const result = await apiRequest<JsonValue>('/sessions/start', controlToken, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ provider: 'codex', request_id: requestId }),
      })
      setStatusTone('ok')
      setStatusText(JSON.stringify(result))
      await refreshSessionOnce()
    } catch (err) {
      setStatusTone('bad')
      setStatusText((err as Error).message)
    }
  }

  async function sendSessionMessage() {
    if (!sessionInput.trim()) {
      setStatusTone('warn')
      setStatusText('message empty')
      return
    }
    try {
      const requestId = newRequestId()
      const result = await apiRequest<JsonValue>('/sessions/current/message', controlToken, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ message: sessionInput, request_id: requestId }),
      })
      setStatusTone('ok')
      setStatusText(JSON.stringify(result))
      setSessionInput('')
      await refreshSessionOnce()
    } catch (err) {
      setStatusTone('bad')
      setStatusText((err as Error).message)
    }
  }

  useEffect(() => {
    if (!observeToken) return

    let cancelled = false
    const tick = async () => {
      try {
        const eventBody = await apiRequest<{ events?: unknown[]; last_event_id?: number }>(`/runs/current/events?after=${after}`, observeToken)
        if (cancelled) return

        const rows = toEventRows(eventBody.events ?? [])
        if (rows.length > 0) {
          setEvents((prev) => prev.concat(rows).slice(-300))
        }
        if (typeof eventBody.last_event_id === 'number' && eventBody.last_event_id > after) {
          setAfter(eventBody.last_event_id)
        }
      } catch (err) {
        if (cancelled) return
        setStatusTone('warn')
        setStatusText(`refresh observe failed: ${(err as Error).message}`)
      }
    }

    const warmup = window.setTimeout(() => {
      void tick()
    }, 0)
    const timer = window.setInterval(() => {
      void tick()
    }, 2500)

    return () => {
      cancelled = true
      window.clearTimeout(warmup)
      window.clearInterval(timer)
    }
  }, [observeToken, after])

  useEffect(() => {
    if (!observeToken) return
    let cancelled = false
    const tick = async () => {
      try {
        await refreshTasksList()
      } catch (err) {
        if (cancelled) return
        setStatusTone('warn')
        setStatusText(`refresh tasks failed: ${(err as Error).message}`)
      }
    }
    const warmup = window.setTimeout(() => {
      void tick()
    }, 0)
    const timer = window.setInterval(() => {
      void tick()
    }, 3000)
    return () => {
      cancelled = true
      window.clearTimeout(warmup)
      window.clearInterval(timer)
    }
  }, [observeToken, taskStatusFilter, taskSearch])

  useEffect(() => {
    if (!observeToken || !selectedTaskId) {
      setTaskDetail(null)
      return
    }
    let cancelled = false
    const tick = async () => {
      try {
        const detail = await apiRequest<TaskDetailResponse>(`/tasks/${encodeURIComponent(selectedTaskId)}`, observeToken)
        if (cancelled) return
        setTaskDetail(detail)
        setEditTitle(detail.task.title)
        setEditPrompt(detail.task.prompt ?? '')
        setEditPriority(String(detail.task.priority))
        setEditMaxRetries(detail.task.max_retries == null ? '' : String(detail.task.max_retries))
      } catch (err) {
        if (cancelled) return
        setStatusTone('warn')
        setStatusText(`refresh task detail failed: ${(err as Error).message}`)
      }
    }
    const warmup = window.setTimeout(() => {
      void tick()
    }, 0)
    const timer = window.setInterval(() => {
      void tick()
    }, 3000)
    return () => {
      cancelled = true
      window.clearTimeout(warmup)
      window.clearInterval(timer)
    }
  }, [observeToken, selectedTaskId])

  useEffect(() => {
    if (!observeToken) return

    let cancelled = false
    const tick = async () => {
      try {
        const resp = await apiRequest<JsonValue>('/sessions/current', observeToken)
        if (cancelled) return
        setSessionState(resp)
      } catch (err) {
        if (cancelled) return
        setStatusTone('warn')
        setStatusText(`refresh session failed: ${(err as Error).message}`)
      }
    }

    const warmup = window.setTimeout(() => {
      void tick()
    }, 0)
    const timer = window.setInterval(() => {
      void tick()
    }, 2500)

    return () => {
      cancelled = true
      window.clearTimeout(warmup)
      window.clearInterval(timer)
    }
  }, [observeToken])

  const meta = MODE_META[mode]

  return (
    <div className="mx-auto grid min-h-screen w-full max-w-7xl gap-4 p-4 md:p-6 lg:grid-cols-[280px_1fr]">
      <Sidebar
        mode={mode}
        onModeChange={setMode}
        statusText={statusText}
        statusTone={statusTone}
        observeToken={observeToken}
        controlToken={controlToken}
        onObserveTokenChange={setObserveToken}
        onControlTokenChange={setControlToken}
      />

      <main className="space-y-4">
        <header className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
          <h2 className="text-lg font-semibold text-slate-900">{meta.title}</h2>
          <p className="mt-1 text-sm text-slate-600">{meta.subtitle}</p>
        </header>

        {mode === 'observe' && <ObserveView events={events} tasksRaw={tasksRaw} />}

        {mode === 'control' && (
          <ControlView
            runMode={runMode}
            askPrompt={askPrompt}
            onRunModeChange={setRunMode}
            onAskPromptChange={setAskPrompt}
            onStartRun={startRun}
            onControlRun={controlRun}
          />
        )}

        {mode === 'tasks' && (
          <TasksView
            list={tasksList}
            selectedTaskId={selectedTaskId}
            detail={taskDetail}
            statusFilter={taskStatusFilter}
            search={taskSearch}
            createTitle={createTitle}
            createPrompt={createPrompt}
            createPriority={createPriority}
            createMaxRetries={createMaxRetries}
            editTitle={editTitle}
            editPrompt={editPrompt}
            editPriority={editPriority}
            editMaxRetries={editMaxRetries}
            onStatusFilterChange={setTaskStatusFilter}
            onSearchChange={setTaskSearch}
            onSelectTask={setSelectedTaskId}
            onRefresh={() => void refreshTasksList()}
            onCreateTitleChange={setCreateTitle}
            onCreatePromptChange={setCreatePrompt}
            onCreatePriorityChange={setCreatePriority}
            onCreateMaxRetriesChange={setCreateMaxRetries}
            onCreateTask={() => void createTask()}
            onEditTitleChange={setEditTitle}
            onEditPromptChange={setEditPrompt}
            onEditPriorityChange={setEditPriority}
            onEditMaxRetriesChange={setEditMaxRetries}
            onPatchTask={() => void patchSelectedTask()}
            onTaskAction={(action) => void runTaskAction(action)}
          />
        )}

        {mode === 'session' && (
          <SessionView
            sessionState={sessionState}
            sessionMessages={sessionMessages}
            sessionInput={sessionInput}
            onSessionInputChange={setSessionInput}
            onStartSession={startSession}
            onSendMessage={sendSessionMessage}
          />
        )}
      </main>
    </div>
  )
}
