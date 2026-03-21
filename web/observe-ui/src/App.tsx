import { useEffect, useMemo, useRef, useState } from 'react'

import { Panel } from './components/Panel'
import { apiRequest, isApiError, newRequestId, toEventRows, toneClass } from './lib/api'
import { ControlView } from './views/ControlView'
import { SessionView, type PendingCommand } from './views/SessionView'
import type { EventRow, JsonValue, SessionMessage, StatusTone } from './types'

type BootstrapResp = {
  url?: string
  expires_at?: number
}

type SessionSendResp = {
  ok?: boolean
  status?: string
  deduplicated?: boolean
  reply?: string | null
}

type OutboxState = 'queued' | 'sending' | 'processing' | 'retry_wait' | 'failed' | 'completed'

type OutboxItem = {
  requestId: string
  text: string
  state: OutboxState
  attempts: number
  createdAt: number
  updatedAt: number
  nextRetryAt?: number
  lastError?: string
}

type SyncState = {
  lastOkAt: number | null
  consecutiveErrors: number
}

const OUTBOX_STORAGE_KEY = 'techlead.observe.session.outbox.v1'
const MAX_OUTBOX_ITEMS = 120

function safeNow() {
  return Date.now()
}

function sanitizeOutbox(raw: unknown): OutboxItem[] {
  if (!Array.isArray(raw)) return []
  const items: OutboxItem[] = []
  for (const it of raw) {
    const rec = it as Record<string, unknown>
    const requestId = typeof rec.requestId === 'string' ? rec.requestId.trim() : ''
    const text = typeof rec.text === 'string' ? rec.text : ''
    const state = typeof rec.state === 'string' ? rec.state : 'queued'
    const attempts = typeof rec.attempts === 'number' && Number.isFinite(rec.attempts) ? rec.attempts : 0
    const createdAt = typeof rec.createdAt === 'number' && Number.isFinite(rec.createdAt) ? rec.createdAt : safeNow()
    const updatedAt = typeof rec.updatedAt === 'number' && Number.isFinite(rec.updatedAt) ? rec.updatedAt : createdAt
    if (!requestId || !text) continue
    if (!['queued', 'sending', 'processing', 'retry_wait', 'failed', 'completed'].includes(state)) continue
    items.push({
      requestId,
      text,
      state: state as OutboxState,
      attempts,
      createdAt,
      updatedAt,
      nextRetryAt: typeof rec.nextRetryAt === 'number' ? rec.nextRetryAt : undefined,
      lastError: typeof rec.lastError === 'string' ? rec.lastError : undefined,
    })
  }
  return items.slice(-MAX_OUTBOX_ITEMS)
}

function loadOutboxFromStorage(): OutboxItem[] {
  try {
    const raw = localStorage.getItem(OUTBOX_STORAGE_KEY)
    if (!raw) return []
    return sanitizeOutbox(JSON.parse(raw))
  } catch {
    return []
  }
}

function summarizeApiError(err: unknown): string {
  if (isApiError(err)) {
    if (err.errorCode) return `${err.status} ${err.errorCode}`
    return `${err.status} ${err.bodyText}`
  }
  return (err as Error).message
}

function findAssistantReplyByRequestId(messages: SessionMessage[], requestId: string): string | null {
  for (const msg of messages) {
    if (msg.role !== 'assistant') continue
    if (msg.request_id !== requestId) continue
    return msg.content
  }
  return null
}

function syncHintLabel(sync: SyncState): string {
  if (sync.lastOkAt == null) {
    if (sync.consecutiveErrors === 0) return 'initializing'
    return `reconnecting (${sync.consecutiveErrors})`
  }
  const sec = Math.max(0, Math.floor((safeNow() - sync.lastOkAt) / 1000))
  if (sync.consecutiveErrors === 0) return `healthy · ${sec}s ago`
  if (sync.consecutiveErrors < 3) return `unstable · ${sec}s ago`
  return `degraded · ${sec}s ago`
}

function nextRetryDelayMs(attempts: number): number {
  const base = 1200
  const cappedPower = Math.min(5, Math.max(0, attempts - 1))
  return Math.min(30000, base * 2 ** cappedPower)
}

export default function App() {
  const query = useMemo(() => {
    const params = new URLSearchParams(window.location.search)
    const shared = params.get('token') ?? ''
    const observe = params.get('observe_token') ?? shared
    const control = params.get('control_token') ?? params.get('ctrl_token') ?? shared
    const bootstrapId = params.get('bootstrap_id') ?? params.get('bootstrap') ?? ''
    const code = params.get('code') ?? params.get('one_time_code') ?? ''
    const hasSensitive =
      Boolean(shared) ||
      Boolean(observe) ||
      Boolean(control) ||
      Boolean(bootstrapId) ||
      Boolean(code) ||
      params.has('observe_token') ||
      params.has('control_token') ||
      params.has('ctrl_token') ||
      params.has('token') ||
      params.has('bootstrap_id') ||
      params.has('bootstrap') ||
      params.has('one_time_code')
    return {
      observe,
      control,
      bootstrapId,
      code,
      hasSensitive,
    }
  }, [])

  const [observeToken, setObserveToken] = useState(query.observe)
  const [controlToken, setControlToken] = useState(query.control)
  const [showTokenDebug, setShowTokenDebug] = useState(false)

  const [statusText, setStatusText] = useState('connecting...')
  const [statusTone, setStatusTone] = useState<StatusTone>('idle')

  const [after, setAfter] = useState(0)
  const afterRef = useRef(0)
  const [events, setEvents] = useState<EventRow[]>([])

  const [runMode, setRunMode] = useState<'optimize' | 'pool'>('optimize')
  const [askPrompt, setAskPrompt] = useState('')

  const [connectUrl, setConnectUrl] = useState('')
  const [connectExpiresAt, setConnectExpiresAt] = useState<number | null>(null)
  const [copiedShareLink, setCopiedShareLink] = useState(false)
  const [nowTickMs, setNowTickMs] = useState(() => safeNow())

  const [sessionState, setSessionState] = useState<JsonValue>({})
  const [sessionInput, setSessionInput] = useState('')
  const [sessionSync, setSessionSync] = useState<SyncState>({
    lastOkAt: null,
    consecutiveErrors: 0,
  })

  const [outbox, setOutbox] = useState<OutboxItem[]>(() => loadOutboxFromStorage())
  const outboxRef = useRef<OutboxItem[]>(outbox)
  const sessionStatusRef = useRef('')
  const sessionSyncRef = useRef<SyncState>({
    lastOkAt: null,
    consecutiveErrors: 0,
  })

  const sessionMessages = (Array.isArray(sessionState.messages) ? sessionState.messages : []) as SessionMessage[]
  const sessionStatus = String(sessionState.status ?? '')
  const sessionInFlightRequestId = typeof sessionState.in_flight_request_id === 'string' ? sessionState.in_flight_request_id : ''

  const observeAuth = observeToken.trim() || undefined
  const controlAuth = controlToken.trim() || undefined

  const pendingCommands = useMemo<PendingCommand[]>(() => {
    return outbox
      .filter((item): item is OutboxItem & { state: Exclude<OutboxState, 'completed'> } => item.state !== 'completed')
      .sort((a, b) => a.createdAt - b.createdAt)
      .map((item) => ({
        requestId: item.requestId,
        text: item.text,
        state: item.state,
        attempts: item.attempts,
        nextRetryAt: item.nextRetryAt,
        lastError: item.lastError,
      }))
  }, [outbox])

  const isSessionBusy = pendingCommands.length > 0 || sessionStatus === 'processing'
  const sessionSyncHint = useMemo(() => syncHintLabel(sessionSync), [sessionSync])

  function normalizeStatus(message: string) {
    if (message.includes('401')) {
      setStatusTone('warn')
      setStatusText('waiting for authorization, please scan again')
      return
    }
    if (message.includes('429')) {
      setStatusTone('warn')
      setStatusText('rate limited, retry shortly')
      return
    }
    setStatusTone('bad')
    setStatusText(message)
  }

  function updateOutbox(requestId: string, updater: (item: OutboxItem) => OutboxItem): void {
    setOutbox((prev) =>
      prev.map((item) => {
        if (item.requestId !== requestId) return item
        const next = updater(item)
        return { ...next, updatedAt: safeNow() }
      }),
    )
  }

  function enqueueSessionMessage(text: string) {
    const trimmed = text.trim()
    if (!trimmed) {
      setStatusTone('warn')
      setStatusText('message empty')
      return
    }
    const requestId = newRequestId()
    const now = safeNow()
    setOutbox((prev) => {
      const next = prev
        .filter((item) => item.state !== 'completed' || now - item.updatedAt < 30_000)
        .concat([
          {
            requestId,
            text: trimmed,
            state: 'queued' as OutboxState,
            attempts: 0,
            createdAt: now,
            updatedAt: now,
          },
        ])
      return next.slice(-MAX_OUTBOX_ITEMS)
    })
    setSessionInput('')
    setStatusTone('idle')
    setStatusText('message queued')
  }

  function upsertFromSessionState(messages: SessionMessage[], inFlightRequestId: string, status: string) {
    setOutbox((prev) => {
      const now = safeNow()
      let changed = false
      const next: OutboxItem[] = prev.map((item): OutboxItem => {
        if (item.state === 'completed') return item

        const reply = findAssistantReplyByRequestId(messages, item.requestId)
        if (reply) {
          changed = true
          return {
            ...item,
            state: 'completed',
            nextRetryAt: undefined,
            lastError: undefined,
            updatedAt: now,
          }
        }

        if (status === 'processing' && inFlightRequestId && item.requestId === inFlightRequestId && item.state !== 'processing') {
          changed = true
          return {
            ...item,
            state: 'processing',
            nextRetryAt: undefined,
            lastError: undefined,
            updatedAt: now,
          }
        }

        if (item.state === 'processing' && (status !== 'processing' || inFlightRequestId !== item.requestId)) {
          const delay = nextRetryDelayMs(item.attempts + 1)
          changed = true
          return {
            ...item,
            state: 'retry_wait',
            nextRetryAt: now + delay,
            lastError: 'processing state cleared before reply, retrying',
            updatedAt: now,
          }
        }

        return item
      })

      if (!changed) return prev
      return next
    })
  }

  async function createShareLink() {
    try {
      const resp = await apiRequest<BootstrapResp>('/auth/qr/bootstrap', controlAuth ?? observeAuth, {
        method: 'POST',
        body: JSON.stringify({ ttl_seconds: 600 }),
      })
      if (resp.url) {
        setConnectUrl(resp.url)
        setConnectExpiresAt(typeof resp.expires_at === 'number' ? resp.expires_at : null)
        setCopiedShareLink(false)
        setStatusTone('ok')
        setStatusText('share link generated')
      } else {
        setStatusTone('warn')
        setStatusText('share link missing in response')
      }
    } catch (err) {
      normalizeStatus(`create share link failed: ${(err as Error).message}`)
    }
  }

  async function copyShareLink() {
    if (!connectUrl) return
    try {
      await navigator.clipboard.writeText(connectUrl)
      setCopiedShareLink(true)
      setStatusTone('ok')
      setStatusText('share link copied')
    } catch (err) {
      normalizeStatus(`copy link failed: ${(err as Error).message}`)
    }
  }

  function retryCommandNow(requestId: string) {
    updateOutbox(requestId, (item) => ({
      ...item,
      state: 'queued',
      nextRetryAt: undefined,
      lastError: undefined,
    }))
    setStatusTone('idle')
    setStatusText('retry queued')
  }

  async function startRun() {
    try {
      const requestId = newRequestId()
      const result = await apiRequest<JsonValue>('/runs/start', controlAuth, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ mode: runMode, request_id: requestId }),
      })
      setStatusTone('ok')
      setStatusText(JSON.stringify(result))
    } catch (err) {
      normalizeStatus((err as Error).message)
    }
  }

  async function controlRun(action: 'pause' | 'resume' | 'abort' | 'ask') {
    try {
      const requestId = newRequestId()
      const payload: JsonValue = { action, request_id: requestId }
      if (action === 'ask') payload.prompt = askPrompt
      const result = await apiRequest<JsonValue>('/runs/current/control', controlAuth, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify(payload),
      })
      setStatusTone('ok')
      setStatusText(JSON.stringify(result))
    } catch (err) {
      normalizeStatus((err as Error).message)
    }
  }

  async function startSession() {
    try {
      const requestId = newRequestId()
      const result = await apiRequest<JsonValue>('/sessions/start', controlAuth, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ provider: 'codex', request_id: requestId }),
      })
      setStatusTone('ok')
      setStatusText(JSON.stringify(result))
    } catch (err) {
      normalizeStatus((err as Error).message)
    }
  }

  function sendSessionMessage() {
    enqueueSessionMessage(sessionInput)
  }

  useEffect(() => {
    outboxRef.current = outbox
    try {
      localStorage.setItem(OUTBOX_STORAGE_KEY, JSON.stringify(outbox))
    } catch {
      // Ignore localStorage failures.
    }
  }, [outbox])

  useEffect(() => {
    let cancelled = false

    const removeQuerySecrets = () => {
      if (query.hasSensitive) {
        history.replaceState({}, '', location.pathname)
      }
    }

    const exchange = async () => {
      if (!query.bootstrapId || !query.code) {
        removeQuerySecrets()
        if (query.observe || query.control) {
          setStatusTone('warn')
          setStatusText('legacy token mode enabled')
        } else {
          setStatusTone('idle')
          setStatusText('ready, waiting for scan authorization')
        }
        return
      }

      setStatusTone('idle')
      setStatusText('exchanging QR ticket...')
      removeQuerySecrets()
      try {
        await apiRequest<JsonValue>('/auth/token/exchange', undefined, {
          method: 'POST',
          body: JSON.stringify({ bootstrap_id: query.bootstrapId, code: query.code }),
        })
        if (cancelled) return
        setObserveToken('')
        setControlToken('')
        setStatusTone('ok')
        setStatusText('connected via QR')
      } catch (err) {
        if (cancelled) return
        normalizeStatus(`exchange failed: ${(err as Error).message}`)
      }
    }

    void exchange()
    return () => {
      cancelled = true
    }
  }, [query.bootstrapId, query.code, query.hasSensitive, query.observe, query.control])

  useEffect(() => {
    afterRef.current = after
  }, [after])

  useEffect(() => {
    sessionStatusRef.current = sessionStatus
  }, [sessionStatus])

  useEffect(() => {
    sessionSyncRef.current = sessionSync
  }, [sessionSync])

  useEffect(() => {
    let cancelled = false
    let timer: number | null = null

    const tick = async () => {
      try {
        const eventBody = await apiRequest<{ events?: unknown[]; last_event_id?: number }>(
          `/runs/current/events?after=${afterRef.current}`,
          observeAuth,
        )
        if (cancelled) return

        const rows = toEventRows(eventBody.events ?? [])
        if (rows.length > 0) {
          setEvents((prev) => prev.concat(rows).slice(-300))
        }
        if (typeof eventBody.last_event_id === 'number' && eventBody.last_event_id > afterRef.current) {
          afterRef.current = eventBody.last_event_id
          setAfter(eventBody.last_event_id)
        }
      } catch {
        // Keep event stream best-effort. Session state is the source of truth.
      }
      if (!cancelled) timer = window.setTimeout(() => void tick(), 2500)
    }

    timer = window.setTimeout(() => void tick(), 0)
    return () => {
      cancelled = true
      if (timer != null) window.clearTimeout(timer)
    }
  }, [observeAuth])

  useEffect(() => {
    let cancelled = false
    let timer: number | null = null

    const poll = async () => {
      try {
        const resp = await apiRequest<JsonValue>('/sessions/current', observeAuth)
        if (cancelled) return

        setSessionState(resp)

        const messages = (Array.isArray(resp.messages) ? resp.messages : []) as SessionMessage[]
        const status = typeof resp.status === 'string' ? resp.status : ''
        const inFlight = typeof resp.in_flight_request_id === 'string' ? resp.in_flight_request_id : ''
        upsertFromSessionState(messages, inFlight, status)

        const now = safeNow()
        const nextSync = {
          lastOkAt: now,
          consecutiveErrors: 0,
        }
        sessionSyncRef.current = nextSync
        setSessionSync(nextSync)
      } catch (err) {
        if (cancelled) return
        setSessionSync((prev) => {
          const nextSync = {
            lastOkAt: prev.lastOkAt,
            consecutiveErrors: prev.consecutiveErrors + 1,
          }
          sessionSyncRef.current = nextSync
          return nextSync
        })
        if (!observeAuth) {
          setStatusTone('warn')
          setStatusText('waiting for scan authorization')
        } else {
          normalizeStatus(`refresh session failed: ${(err as Error).message}`)
        }
      }

      if (cancelled) return
      const hasPending = outboxRef.current.some((item) => item.state !== 'completed')
      const baseDelay = hasPending || sessionStatusRef.current === 'processing' ? 1200 : 2500
      const errMultiplier = Math.max(1, sessionSyncRef.current.consecutiveErrors)
      const delay = Math.min(20_000, baseDelay * errMultiplier)
      timer = window.setTimeout(() => void poll(), delay)
    }

    timer = window.setTimeout(() => void poll(), 0)
    return () => {
      cancelled = true
      if (timer != null) window.clearTimeout(timer)
    }
  }, [observeAuth])

  useEffect(() => {
    let cancelled = false
    let timer: number | null = null

    const loop = async () => {
      if (cancelled) return

      const items = outboxRef.current.filter((item) => item.state !== 'completed')
      if (items.length === 0) {
        timer = window.setTimeout(() => void loop(), 1200)
        return
      }

      const now = safeNow()
      const ready = items.find((item) => {
        if (item.state === 'queued') return true
        if (item.state === 'failed') return true
        if (item.state === 'retry_wait') return !item.nextRetryAt || item.nextRetryAt <= now
        return false
      })

      if (!ready) {
        timer = window.setTimeout(() => void loop(), 800)
        return
      }

      if (sessionStatus === 'processing' && sessionInFlightRequestId && sessionInFlightRequestId !== ready.requestId) {
        timer = window.setTimeout(() => void loop(), 900)
        return
      }

      updateOutbox(ready.requestId, (item) => ({
        ...item,
        state: 'sending',
        attempts: item.attempts + 1,
        nextRetryAt: undefined,
        lastError: undefined,
      }))

      try {
        const result = await apiRequest<SessionSendResp>('/sessions/current/message', controlAuth, {
          method: 'POST',
          headers: { 'X-Request-Id': ready.requestId },
          body: JSON.stringify({
            message: ready.text,
            request_id: ready.requestId,
          }),
        })

        if (cancelled) return

        const status = result.status ?? 'unknown'
        if (status === 'completed') {
          updateOutbox(ready.requestId, (item) => ({
            ...item,
            state: 'completed',
            nextRetryAt: undefined,
            lastError: undefined,
          }))
          setStatusTone('ok')
          setStatusText(result.deduplicated ? 'message already completed (deduplicated)' : 'message completed')
        } else if (status === 'processing') {
          updateOutbox(ready.requestId, (item) => ({
            ...item,
            state: 'processing',
            nextRetryAt: undefined,
            lastError: undefined,
          }))
          setStatusTone('idle')
          setStatusText(result.deduplicated ? 'message already processing (deduplicated)' : 'message accepted, processing')
        } else {
          const delay = nextRetryDelayMs(ready.attempts + 1)
          updateOutbox(ready.requestId, (item) => ({
            ...item,
            state: 'retry_wait',
            nextRetryAt: safeNow() + delay,
            lastError: `unexpected status=${status}`,
          }))
        }
      } catch (err) {
        if (cancelled) return

        if (isApiError(err) && err.status === 409 && err.errorCode === 'session_busy') {
          updateOutbox(ready.requestId, (item) => ({
            ...item,
            state: 'retry_wait',
            nextRetryAt: safeNow() + 1200,
            lastError: 'session busy',
          }))
          setStatusTone('warn')
          setStatusText('session busy, retry queued')
        } else {
          const delay = nextRetryDelayMs(ready.attempts + 1)
          updateOutbox(ready.requestId, (item) => ({
            ...item,
            state: item.attempts >= 5 ? 'failed' : 'retry_wait',
            nextRetryAt: safeNow() + delay,
            lastError: summarizeApiError(err),
          }))
          setStatusTone('warn')
          setStatusText('network unstable, retrying queued message')
        }
      }

      if (!cancelled) timer = window.setTimeout(() => void loop(), 500)
    }

    timer = window.setTimeout(() => void loop(), 300)
    return () => {
      cancelled = true
      if (timer != null) window.clearTimeout(timer)
    }
  }, [controlAuth, sessionInFlightRequestId, sessionStatus])

  const authModeLabel = useMemo(() => {
    if (observeToken || controlToken) return 'legacy token mode'
    return 'cookie session mode'
  }, [observeToken, controlToken])

  const connectRemainingSec = useMemo(() => {
    if (!connectExpiresAt) return null
    return Math.max(0, connectExpiresAt - Math.floor(nowTickMs / 1000))
  }, [connectExpiresAt, nowTickMs])

  useEffect(() => {
    if (!connectExpiresAt) return
    const timer = window.setInterval(() => {
      setNowTickMs(safeNow())
    }, 1000)
    return () => window.clearInterval(timer)
  }, [connectExpiresAt])

  return (
    <div className="mx-auto w-full max-w-7xl space-y-4 p-4 md:p-6">
      <header className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div>
            <div className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Techlead</div>
            <h1 className="mt-1 text-xl font-semibold text-slate-900">Agent Session Console</h1>
            <p className="mt-1 text-sm text-slate-600">Reliable session-first remote control for local AI</p>
          </div>
          <div className={`rounded-xl border px-3 py-2 text-xs ${toneClass(statusTone)}`}>
            <span className="font-semibold">Status</span>
            <div className="mt-1 break-all">{statusText}</div>
          </div>
        </div>

        <div className="mt-3 grid gap-2 border-t border-slate-200 pt-3 text-xs text-slate-600 md:grid-cols-3">
          <div className="rounded-lg border border-slate-200 bg-slate-50 px-2 py-1.5">auth: {authModeLabel}</div>
          <div className="rounded-lg border border-slate-200 bg-slate-50 px-2 py-1.5">session sync: {sessionSyncHint}</div>
          <div className="rounded-lg border border-slate-200 bg-slate-50 px-2 py-1.5">outbox pending: {pendingCommands.length}</div>
        </div>

        <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-slate-200 pt-3">
          <button
            type="button"
            onClick={() => void createShareLink()}
            className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs hover:border-slate-400"
          >
            Generate QR Link
          </button>
          <button
            type="button"
            onClick={() => setShowTokenDebug((v) => !v)}
            className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs hover:border-slate-400"
          >
            {showTokenDebug ? 'Hide Token Debug' : 'Show Token Debug'}
          </button>
          {connectUrl ? (
            <button
              type="button"
              onClick={() => void copyShareLink()}
              className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs hover:border-slate-400"
            >
              {copiedShareLink ? 'Copied' : 'Copy Link'}
            </button>
          ) : null}
        </div>

        {connectUrl ? (
          <div className="mt-2 rounded-lg border border-slate-200 bg-slate-50 p-2 text-xs text-slate-700">
            <div className="break-all">{connectUrl}</div>
            <div className="mt-1 text-slate-500">
              {connectRemainingSec == null ? 'ttl: unknown' : `ttl: ${connectRemainingSec}s`}
            </div>
          </div>
        ) : null}

        {showTokenDebug ? (
          <div className="mt-3 grid gap-2 border-t border-slate-200 pt-3 md:grid-cols-2">
            <label className="block text-xs font-medium text-slate-600">
              Observe Token
              <input
                className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm text-slate-900 outline-none focus:border-sky-400"
                value={observeToken}
                onChange={(e) => setObserveToken(e.target.value.trim())}
                placeholder="observe token"
              />
            </label>
            <label className="block text-xs font-medium text-slate-600">
              Control Token
              <input
                className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm text-slate-900 outline-none focus:border-sky-400"
                value={controlToken}
                onChange={(e) => setControlToken(e.target.value.trim())}
                placeholder="control token"
              />
            </label>
          </div>
        ) : null}
      </header>

      <div className="grid gap-4 xl:grid-cols-[1.4fr_1fr]">
        <SessionView
          sessionState={sessionState}
          sessionMessages={sessionMessages}
          sessionInput={sessionInput}
          isSessionBusy={isSessionBusy}
          pendingCommands={pendingCommands}
          syncHint={sessionSyncHint}
          onSessionInputChange={setSessionInput}
          onStartSession={startSession}
          onSendMessage={sendSessionMessage}
          onRetryCommand={retryCommandNow}
        />

        <div className="space-y-4">
          <ControlView
            runMode={runMode}
            askPrompt={askPrompt}
            onRunModeChange={setRunMode}
            onAskPromptChange={setAskPrompt}
            onStartRun={startRun}
            onControlRun={controlRun}
          />

          <Panel title="Events Stream" right={<span className="text-xs text-slate-500">last {events.length}</span>}>
            <div className="max-h-[48vh] space-y-2 overflow-auto rounded-xl bg-slate-50 p-2">
              {events.length === 0 ? (
                <div className="rounded-lg border border-dashed border-slate-300 bg-white p-4 text-sm text-slate-500">(no events)</div>
              ) : (
                events.map((evt) => (
                  <article key={`${evt.id}-${evt.ts}`} className="rounded-lg border border-slate-200 bg-white p-3">
                    <div className="mb-1 text-xs text-slate-500">
                      #{evt.id} · {evt.source} · {evt.type}
                    </div>
                    <pre className="max-h-28 overflow-auto text-xs leading-5 text-slate-800">{evt.payload}</pre>
                  </article>
                ))
              )}
            </div>
          </Panel>
        </div>
      </div>
    </div>
  )
}
