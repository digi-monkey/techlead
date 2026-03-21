import { useCallback, useEffect, useMemo, useState } from 'react'

import { Panel } from './components/Panel'
import { apiRequest, newRequestId, toneClass } from './lib/api'
import { extractBootstrapParams, readAuthQuery } from './lib/auth'
import { useEventsStream } from './hooks/useEventsStream'
import { useOutboxDispatcher } from './hooks/useOutboxDispatcher'
import { useQrScanner } from './hooks/useQrScanner'
import { useSessionOutbox } from './hooks/useSessionOutbox'
import { useSessionPolling, type SessionSyncState } from './hooks/useSessionPolling'
import { ControlView } from './views/ControlView'
import { SessionView } from './views/SessionView'
import type { JsonValue, StatusTone } from './types'

type ConsolePhase = 'connecting' | 'ready' | 'degraded' | 'expired'

function safeNow() {
  return Date.now()
}

function syncHintLabel(sync: SessionSyncState): string {
  if (sync.lastOkAt == null) {
    if (sync.consecutiveErrors === 0) return 'initializing'
    return `reconnecting (${sync.consecutiveErrors})`
  }
  const sec = Math.max(0, Math.floor((safeNow() - sync.lastOkAt) / 1000))
  if (sync.consecutiveErrors === 0) return `healthy · ${sec}s ago`
  if (sync.consecutiveErrors < 3) return `unstable · ${sec}s ago`
  return `degraded · ${sec}s ago`
}

export default function App() {
  const query = useMemo(() => readAuthQuery(window.location.search), [])

  const [observeToken, setObserveToken] = useState(query.observe)
  const [controlToken, setControlToken] = useState(query.control)
  const [showTokenDebug, setShowTokenDebug] = useState(false)

  const [statusPhase, setStatusPhase] = useState<ConsolePhase>('connecting')
  const [statusText, setStatusText] = useState('connecting...')
  const [statusTone, setStatusTone] = useState<StatusTone>('idle')

  const [runMode, setRunMode] = useState<'optimize' | 'pool'>('optimize')
  const [askPrompt, setAskPrompt] = useState('')

  const [showScanner, setShowScanner] = useState(false)

  const [sessionInput, setSessionInput] = useState('')

  const observeAuth = observeToken.trim() || undefined
  const controlAuth = controlToken.trim() || undefined

  const {
    outboxRef,
    pendingCommands,
    updateOutbox,
    enqueueMessage,
    retryCommandNow,
    reconcileFromSessionState,
  } = useSessionOutbox()

  const applyStatus = useCallback((phase: ConsolePhase, tone: StatusTone, text: string) => {
    setStatusPhase(phase)
    setStatusTone(tone)
    setStatusText(text)
  }, [])

  const onSessionStatusUpdate = useCallback((tone: StatusTone, message: string) => {
    const phase: ConsolePhase = tone === 'warn' || tone === 'bad' ? 'degraded' : 'ready'
    applyStatus(phase, tone, message)
  }, [applyStatus])

  const normalizeStatus = useCallback((message: string) => {
    if (message.includes('401')) {
      applyStatus('expired', 'warn', 'waiting for authorization, please scan again')
      return
    }
    if (message.includes('429')) {
      applyStatus('degraded', 'warn', 'rate limited, retry shortly')
      return
    }
    applyStatus('degraded', 'bad', message)
  }, [applyStatus])

  const {
    sessionState,
    sessionSync,
    sessionStatus,
    sessionInFlightRequestId,
    sessionMessages,
  } = useSessionPolling({
    observeAuth,
    outboxRef,
    reconcileFromSessionState,
    onRequireAuthorization: () => {
      if (observeAuth || controlAuth) {
        applyStatus('expired', 'warn', 'waiting for scan authorization')
      } else {
        applyStatus('connecting', 'idle', 'waiting for scan authorization')
      }
    },
    onRefreshError: (message) => {
      normalizeStatus(message)
    },
  })

  const events = useEventsStream(observeAuth)
  const isDebugBuild = import.meta.env.DEV

  const isSessionBusy = pendingCommands.length > 0 || sessionStatus === 'processing'
  const sessionSyncHint = useMemo(() => syncHintLabel(sessionSync), [sessionSync])

  const exchangeBootstrapTicket = useCallback(async (bootstrapId: string, code: string): Promise<boolean> => {
    applyStatus('connecting', 'idle', 'exchanging QR ticket...')
    try {
      await apiRequest<JsonValue>('/auth/token/exchange', undefined, {
        method: 'POST',
        body: JSON.stringify({ bootstrap_id: bootstrapId, code }),
      })
      setObserveToken('')
      setControlToken('')
      applyStatus('ready', 'ok', 'connected via QR')
      return true
    } catch (err) {
      normalizeStatus(`exchange failed: ${(err as Error).message}`)
      return false
    }
  }, [applyStatus, normalizeStatus])

  const applyScannedPayload = useCallback(async (rawPayload: string, setScannerHint: (status: string) => void) => {
    const parsed = extractBootstrapParams(rawPayload)
    if (!parsed) {
      applyStatus('degraded', 'warn', 'invalid QR payload')
      setScannerHint('invalid payload: missing bootstrap_id/code')
      return
    }

    setScannerHint('ticket parsed, authorizing...')
    const ok = await exchangeBootstrapTicket(parsed.bootstrapId, parsed.code)
    setScannerHint(ok ? 'connected via scan' : 'authorization failed')
  }, [applyStatus, exchangeBootstrapTicket])

  const { scannerStatus, scannerActive, scannerVideoRef, startScanner, stopScanner } = useQrScanner({ onPayload: applyScannedPayload })

  function handleRetryCommand(requestId: string) {
    retryCommandNow(requestId)
    applyStatus('ready', 'idle', 'retry queued')
  }

  async function startRun() {
    try {
      const requestId = newRequestId()
      const result = await apiRequest<JsonValue>('/runs/start', controlAuth, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ mode: runMode, request_id: requestId }),
      })
      applyStatus('ready', 'ok', JSON.stringify(result))
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
      applyStatus('ready', 'ok', JSON.stringify(result))
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
      applyStatus('ready', 'ok', JSON.stringify(result))
    } catch (err) {
      normalizeStatus((err as Error).message)
    }
  }

  function sendSessionMessage() {
    const result = enqueueMessage(sessionInput)
    if (!result.ok) {
      applyStatus('degraded', 'warn', result.reason)
      return
    }
    setSessionInput('')
    applyStatus('ready', 'idle', 'message queued')
  }

  useEffect(() => {
    const removeQuerySecrets = () => {
      if (query.hasSensitive) {
        history.replaceState({}, '', location.pathname)
      }
    }

    const exchange = async () => {
      if (!query.bootstrapId || !query.code) {
        removeQuerySecrets()
        if (query.observe || query.control) {
          applyStatus('ready', 'warn', 'legacy token mode enabled')
        } else {
          applyStatus('connecting', 'idle', 'ready, waiting for scan authorization')
        }
        return
      }

      removeQuerySecrets()
      await exchangeBootstrapTicket(query.bootstrapId, query.code)
    }

    void exchange()
    return undefined
  }, [applyStatus, exchangeBootstrapTicket, query.bootstrapId, query.code, query.hasSensitive, query.observe, query.control])

  const effectivePhase = useMemo<ConsolePhase>(() => {
    if (statusPhase === 'expired') return 'expired'
    if (sessionSync.lastOkAt == null) return statusPhase
    if (sessionSync.consecutiveErrors > 0) return 'degraded'
    if (statusPhase === 'connecting') return 'ready'
    return statusPhase
  }, [sessionSync.consecutiveErrors, sessionSync.lastOkAt, statusPhase])

  useOutboxDispatcher({
    controlAuth,
    outboxRef,
    sessionStatus,
    sessionInFlightRequestId,
    updateOutbox,
    onStatusUpdate: onSessionStatusUpdate,
  })

  const authModeLabel = useMemo(() => {
    if (observeToken || controlToken) return 'legacy token mode'
    return 'cookie session mode'
  }, [observeToken, controlToken])

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
          <div className="rounded-lg border border-slate-200 bg-slate-50 px-2 py-1.5">phase: {effectivePhase}</div>
          <div className="rounded-lg border border-slate-200 bg-slate-50 px-2 py-1.5">outbox pending: {pendingCommands.length}</div>
        </div>

        <div className="mt-2 text-xs text-slate-500">session sync: {sessionSyncHint}</div>

        <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-slate-200 pt-3">
          <button
            type="button"
            onClick={() => {
              setShowScanner((prev) => {
                const next = !prev
                if (!next) stopScanner()
                return next
              })
            }}
            className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs hover:border-slate-400"
          >
            {showScanner ? 'Hide Scanner' : 'Scan QR'}
          </button>
          {isDebugBuild ? (
            <button
              type="button"
              onClick={() => setShowTokenDebug((v) => !v)}
              className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs hover:border-slate-400"
            >
              {showTokenDebug ? 'Hide Token Debug' : 'Show Token Debug'}
            </button>
          ) : null}
        </div>

        {showScanner ? (
          <div className="mt-3 rounded-lg border border-slate-200 bg-slate-50 p-3 text-xs text-slate-700">
            <div className="flex flex-wrap items-center gap-2">
              <button
                type="button"
                onClick={() => void startScanner()}
                disabled={scannerActive}
                className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs hover:border-slate-400 disabled:cursor-not-allowed disabled:opacity-60"
              >
                Start Camera Scan
              </button>
              <button
                type="button"
                onClick={() => stopScanner()}
                disabled={!scannerActive}
                className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs hover:border-slate-400 disabled:cursor-not-allowed disabled:opacity-60"
              >
                Stop Scan
              </button>
              <span className="text-slate-500">{scannerStatus}</span>
            </div>

            <video
              ref={scannerVideoRef}
              muted
              playsInline
              autoPlay
              className={`mt-2 max-h-56 w-full rounded-lg border border-slate-200 bg-black object-cover ${scannerActive ? '' : 'hidden'}`}
            />
          </div>
        ) : null}

        {isDebugBuild && showTokenDebug ? (
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
          onRetryCommand={handleRetryCommand}
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
