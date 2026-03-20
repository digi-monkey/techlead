import { useEffect, useMemo, useState } from 'react'

type Mode = 'observe' | 'control' | 'session'
type StatusTone = 'ok' | 'warn' | 'bad' | 'idle'

type JsonValue = Record<string, unknown>

type EventRow = {
  id: number
  type: string
  source: string
  ts: number
  payload: string
}

const MODE_LABEL: Record<Mode, string> = {
  observe: 'Observe',
  control: 'Control',
  session: 'Session',
}

function newRequestId() {
  return `web-${Date.now()}-${Math.floor(Math.random() * 1e9)}`
}

function statusClass(tone: StatusTone): string {
  if (tone === 'ok') return 'text-[var(--ok)]'
  if (tone === 'warn') return 'text-[var(--warn)]'
  if (tone === 'bad') return 'text-[var(--bad)]'
  return 'text-[var(--muted)]'
}

function toEventRows(events: unknown[]): EventRow[] {
  return events
    .map((item) => {
      const rec = item as JsonValue
      const id = Number(rec.event_id ?? 0)
      const raw = typeof rec.event_jsonl === 'string' ? rec.event_jsonl : '{}'
      let parsed: JsonValue = {}
      try {
        parsed = JSON.parse(raw) as JsonValue
      } catch {
        parsed = { raw }
      }
      return {
        id,
        type: String(parsed.event_type ?? '-'),
        source: String(parsed.source ?? '-'),
        ts: Number(parsed.ts ?? 0),
        payload: JSON.stringify(parsed.payload ?? parsed.raw ?? parsed, null, 2),
      }
    })
    .filter((row) => Number.isFinite(row.id))
}

async function apiRequest<T>(path: string, token: string, options: RequestInit = {}): Promise<T> {
  if (!token) throw new Error('token missing')

  const headers = new Headers(options.headers ?? {})
  headers.set('Authorization', `Bearer ${token}`)
  if (options.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json')

  const resp = await fetch(path, { ...options, headers })
  const text = await resp.text()
  if (!resp.ok) throw new Error(`${resp.status} ${text}`)
  if (!text.trim()) return {} as T
  return JSON.parse(text) as T
}

export default function App() {
  const tokenFromQuery = useMemo(() => new URLSearchParams(window.location.search).get('token') ?? '', [])

  const [mode, setMode] = useState<Mode>('observe')
  const [observeToken, setObserveToken] = useState(tokenFromQuery)
  const [controlToken, setControlToken] = useState(tokenFromQuery)
  const [statusText, setStatusText] = useState('ready')
  const [statusTone, setStatusTone] = useState<StatusTone>('idle')

  const [after, setAfter] = useState(0)
  const [events, setEvents] = useState<EventRow[]>([])
  const [tasksRaw, setTasksRaw] = useState('{"tasks":[]}')

  const [runMode, setRunMode] = useState<'optimize' | 'pool'>('optimize')
  const [askPrompt, setAskPrompt] = useState('')

  const [sessionState, setSessionState] = useState<JsonValue>({})
  const [sessionInput, setSessionInput] = useState('')

  async function refreshSessionOnce() {
    try {
      const resp = await apiRequest<JsonValue>('/sessions/current', observeToken)
      setSessionState(resp)
    } catch (err) {
      setStatusTone('warn')
      setStatusText(`refresh session failed: ${(err as Error).message}`)
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
        const [eventBody, tasksBody] = await Promise.all([
          apiRequest<{ events?: unknown[]; last_event_id?: number }>(`/runs/current/events?after=${after}`, observeToken),
          apiRequest<JsonValue>('/tasks', observeToken),
        ])
        if (cancelled) return

        const rows = toEventRows(eventBody.events ?? [])
        if (rows.length > 0) {
          setEvents((prev) => prev.concat(rows).slice(-300))
        }
        if (typeof eventBody.last_event_id === 'number' && eventBody.last_event_id > after) {
          setAfter(eventBody.last_event_id)
        }
        setTasksRaw(JSON.stringify(tasksBody, null, 2))
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

  const sessionMessages = Array.isArray(sessionState.messages)
    ? (sessionState.messages as JsonValue[])
    : []

  return (
    <div className="mx-auto flex min-h-screen w-full max-w-7xl flex-col px-4 py-6 md:px-8">
      <header className="rounded-2xl border border-[var(--line)] bg-[var(--panel)]/85 p-5 shadow-sm backdrop-blur">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <div className="text-xs uppercase tracking-[0.2em] text-[var(--muted)]">Techlead Observe UI</div>
            <h1 className="m-0 text-2xl font-semibold">Remote Agent Console</h1>
          </div>
          <div className={`text-sm font-medium ${statusClass(statusTone)}`}>status: {statusText}</div>
        </div>
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          <label className="flex flex-col gap-1 text-sm text-[var(--muted)]">
            observe token
            <input
              className="rounded-lg border border-[var(--line)] bg-white px-3 py-2 text-[var(--ink)] outline-none focus:border-[var(--accent)]"
              value={observeToken}
              onChange={(e) => setObserveToken(e.target.value.trim())}
              placeholder="observe token"
            />
          </label>
          <label className="flex flex-col gap-1 text-sm text-[var(--muted)]">
            control token
            <input
              className="rounded-lg border border-[var(--line)] bg-white px-3 py-2 text-[var(--ink)] outline-none focus:border-[var(--accent)]"
              value={controlToken}
              onChange={(e) => setControlToken(e.target.value.trim())}
              placeholder="control token"
            />
          </label>
        </div>
      </header>

      <nav className="mt-5 grid grid-cols-3 gap-2">
        {(Object.keys(MODE_LABEL) as Mode[]).map((k) => (
          <button
            key={k}
            type="button"
            onClick={() => setMode(k)}
            className={`rounded-lg border px-3 py-2 text-sm font-medium transition ${
              mode === k
                ? 'border-[var(--accent)] bg-[var(--accent)] text-white'
                : 'border-[var(--line)] bg-white text-[var(--ink)] hover:bg-slate-50'
            }`}
          >
            {MODE_LABEL[k]}
          </button>
        ))}
      </nav>

      {mode === 'observe' && (
        <section className="mt-5 grid gap-4 lg:grid-cols-[2fr_1fr]">
          <article className="rounded-2xl border border-[var(--line)] bg-[var(--panel)] p-4 shadow-sm">
            <div className="mb-2 text-sm font-semibold">Events Stream</div>
            <div className="max-h-[560px] overflow-auto rounded-lg border border-[var(--line)] bg-slate-50 p-3">
              {events.length === 0 ? (
                <div className="text-sm text-[var(--muted)]">(no events)</div>
              ) : (
                <div className="space-y-3">
                  {events.map((evt) => (
                    <div key={`${evt.id}-${evt.ts}`} className="rounded-lg border border-slate-200 bg-white p-3">
                      <div className="mb-1 text-xs text-[var(--muted)]">
                        #{evt.id} | {evt.source} | {evt.type} | {evt.ts || '-'}
                      </div>
                      <pre className="text-xs leading-5 text-slate-800">{evt.payload}</pre>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </article>

          <article className="rounded-2xl border border-[var(--line)] bg-[var(--panel)] p-4 shadow-sm">
            <div className="mb-2 text-sm font-semibold">Tasks</div>
            <div className="max-h-[560px] overflow-auto rounded-lg border border-[var(--line)] bg-slate-50 p-3">
              <pre className="text-xs leading-5 text-slate-800">{tasksRaw}</pre>
            </div>
          </article>
        </section>
      )}

      {mode === 'control' && (
        <section className="mt-5 grid gap-4 lg:grid-cols-2">
          <article className="rounded-2xl border border-[var(--line)] bg-[var(--panel)] p-4 shadow-sm">
            <div className="text-sm font-semibold">Run Bootstrap</div>
            <div className="mt-3 flex items-center gap-2">
              <select
                className="rounded-lg border border-[var(--line)] bg-white px-3 py-2 text-sm"
                value={runMode}
                onChange={(e) => setRunMode(e.target.value as 'optimize' | 'pool')}
              >
                <option value="optimize">optimize</option>
                <option value="pool">pool</option>
              </select>
              <button
                type="button"
                onClick={startRun}
                className="rounded-lg border border-[var(--accent)] bg-[var(--accent)] px-4 py-2 text-sm font-medium text-white"
              >
                start run
              </button>
            </div>
          </article>

          <article className="rounded-2xl border border-[var(--line)] bg-[var(--panel)] p-4 shadow-sm">
            <div className="text-sm font-semibold">Run Controls</div>
            <div className="mt-3 flex flex-wrap gap-2">
              <button type="button" onClick={() => controlRun('pause')} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm">
                pause
              </button>
              <button type="button" onClick={() => controlRun('resume')} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm">
                resume
              </button>
              <button type="button" onClick={() => controlRun('abort')} className="rounded-lg border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-700">
                abort
              </button>
            </div>
            <div className="mt-4 flex gap-2">
              <input
                className="w-full rounded-lg border border-[var(--line)] bg-white px-3 py-2 text-sm"
                value={askPrompt}
                onChange={(e) => setAskPrompt(e.target.value)}
                placeholder="ask prompt"
              />
              <button
                type="button"
                onClick={() => controlRun('ask')}
                className="rounded-lg border border-amber-400 bg-amber-100 px-3 py-2 text-sm text-amber-900"
              >
                ask
              </button>
            </div>
          </article>
        </section>
      )}

      {mode === 'session' && (
        <section className="mt-5 rounded-2xl border border-[var(--line)] bg-[var(--panel)] p-4 shadow-sm">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="text-sm font-semibold">Session Chat</div>
            <button
              type="button"
              onClick={startSession}
              className="rounded-lg border border-[var(--accent)] bg-[var(--accent)] px-3 py-2 text-sm font-medium text-white"
            >
              start session
            </button>
          </div>

          <div className="mt-3 rounded-lg border border-[var(--line)] bg-slate-50 p-3 text-xs text-[var(--muted)]">
            session: {String(sessionState.session_id ?? '(none)')} | status: {String(sessionState.status ?? '-')} | provider:{' '}
            {String(sessionState.provider ?? '-')}
          </div>

          <div className="mt-3 max-h-[420px] overflow-auto rounded-lg border border-[var(--line)] bg-slate-50 p-3">
            {sessionMessages.length === 0 ? (
              <div className="text-sm text-[var(--muted)]">(no messages)</div>
            ) : (
              <div className="space-y-3">
                {sessionMessages.slice(-80).map((m, idx) => (
                  <div key={idx} className="rounded-lg border border-slate-200 bg-white p-3">
                    <div className="mb-1 text-xs uppercase tracking-wide text-[var(--muted)]">{String(m.role ?? '-')}</div>
                    <pre className="text-sm leading-6 text-slate-800">{String(m.content ?? '')}</pre>
                  </div>
                ))}
              </div>
            )}
          </div>

          <div className="mt-3 flex gap-2">
            <input
              className="w-full rounded-lg border border-[var(--line)] bg-white px-3 py-2 text-sm"
              value={sessionInput}
              onChange={(e) => setSessionInput(e.target.value)}
              placeholder="say something to agent"
              onKeyDown={(e) => {
                if (e.key === 'Enter') void sendSessionMessage()
              }}
            />
            <button
              type="button"
              onClick={sendSessionMessage}
              className="rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm"
            >
              send
            </button>
          </div>
        </section>
      )}
    </div>
  )
}
