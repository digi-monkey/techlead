import { useEffect, useMemo, useRef, useState } from 'react'

import { Panel } from './components/Panel'
import { apiRequest, isApiError, newRequestId, toEventRows, toneClass } from './lib/api'
import { ControlView } from './views/ControlView'
import { SessionView } from './views/SessionView'
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

  const [sessionState, setSessionState] = useState<JsonValue>({})
  const [sessionInput, setSessionInput] = useState('')
  const [sessionSending, setSessionSending] = useState(false)

  const sessionMessages = (Array.isArray(sessionState.messages) ? sessionState.messages : []) as SessionMessage[]
  const sessionStatus = String(sessionState.status ?? '')
  const sessionIsProcessing = sessionStatus === 'processing'

  const observeAuth = observeToken.trim() || undefined
  const controlAuth = controlToken.trim() || undefined

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

  async function refreshSessionOnce() {
    try {
      const resp = await apiRequest<JsonValue>('/sessions/current', observeAuth)
      setSessionState(resp)
    } catch (err) {
      normalizeStatus(`refresh session failed: ${(err as Error).message}`)
    }
  }

  async function createShareLink() {
    try {
      const resp = await apiRequest<BootstrapResp>('/auth/qr/bootstrap', controlAuth ?? observeAuth, {
        method: 'POST',
        body: JSON.stringify({ ttl_seconds: 600 }),
      })
      if (resp.url) {
        setConnectUrl(resp.url)
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
      await refreshSessionOnce()
    } catch (err) {
      normalizeStatus((err as Error).message)
    }
  }

  async function sendSessionMessage() {
    if (sessionSending || sessionIsProcessing) {
      setStatusTone('warn')
      setStatusText('session is processing previous message')
      return
    }
    if (!sessionInput.trim()) {
      setStatusTone('warn')
      setStatusText('message empty')
      return
    }
    try {
      setSessionSending(true)
      const requestId = newRequestId()
      const result = await apiRequest<SessionSendResp>('/sessions/current/message', controlAuth, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ message: sessionInput, request_id: requestId }),
      })

      const status = result.status ?? 'unknown'
      const deduplicated = result.deduplicated === true
      const reply = typeof result.reply === 'string' ? result.reply : ''
      if (status === 'processing') {
        setStatusTone('idle')
        setStatusText(deduplicated ? 'message already in progress (deduplicated)' : 'message queued, waiting for agent reply')
      } else if (status === 'completed') {
        setStatusTone('ok')
        if (deduplicated) {
          setStatusText('message already processed (deduplicated)')
        } else {
          setStatusText('message sent')
        }
        if (reply.length > 0) {
          // Keep status short while still exposing that reply is available in latest state.
          setStatusText((prev) => `${prev} · reply updated`)
        }
      } else {
        setStatusTone('warn')
        setStatusText(`message accepted with status=${status}`)
      }
      setSessionInput('')
      await refreshSessionOnce()
    } catch (err) {
      if (isApiError(err) && err.status === 409 && err.errorCode === 'session_busy') {
        setStatusTone('warn')
        setStatusText('session busy, wait for current reply')
        await refreshSessionOnce()
        return
      }
      normalizeStatus((err as Error).message)
    } finally {
      setSessionSending(false)
    }
  }

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
    let cancelled = false
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
      } catch (err) {
        if (cancelled) return
        normalizeStatus(`refresh events failed: ${(err as Error).message}`)
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
  }, [observeAuth])

  useEffect(() => {
    let cancelled = false
    const tick = async () => {
      try {
        const resp = await apiRequest<JsonValue>('/sessions/current', observeAuth)
        if (cancelled) return
        setSessionState(resp)
      } catch (err) {
        if (cancelled) return
        normalizeStatus(`refresh session failed: ${(err as Error).message}`)
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
  }, [observeAuth])

  return (
    <div className="mx-auto w-full max-w-7xl space-y-4 p-4 md:p-6">
      <header className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div>
            <div className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Techlead</div>
            <h1 className="mt-1 text-xl font-semibold text-slate-900">Agent Session Console</h1>
            <p className="mt-1 text-sm text-slate-600">Browser remote control for local AI session</p>
          </div>
          <div className={`rounded-xl border px-3 py-2 text-xs ${toneClass(statusTone)}`}>
            <span className="font-semibold">Status</span>
            <div className="mt-1 break-all">{statusText}</div>
          </div>
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
          {connectUrl ? <span className="text-xs text-slate-700">{connectUrl}</span> : null}
        </div>

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
          isSessionBusy={sessionSending || sessionIsProcessing}
          onSessionInputChange={setSessionInput}
          onStartSession={startSession}
          onSendMessage={sendSessionMessage}
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
