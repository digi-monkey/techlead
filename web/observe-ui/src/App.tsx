import { useCallback, useEffect, useMemo, useState } from 'react'

import { apiRequest, newRequestId, toneClass } from './lib/api'
import { extractBootstrapParams, readAuthQuery } from './lib/auth'
import { useOutboxDispatcher } from './hooks/useOutboxDispatcher'
import { useQrScanner } from './hooks/useQrScanner'
import { useSessionOutbox } from './hooks/useSessionOutbox'
import { useSessionPolling, type SessionSyncState } from './hooks/useSessionPolling'
import { SessionView } from './views/SessionView'
import type { JsonValue, StatusTone } from './types'

type ConsolePhase = 'connecting' | 'ready' | 'degraded' | 'expired'
type SessionProvider = 'codex' | 'opencode'
const SESSION_PROVIDER_STORAGE_KEY = 'techlead.observe.session.provider'

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


  const [statusText, setStatusText] = useState('connecting...')
  const [statusTone, setStatusTone] = useState<StatusTone>('idle')

  const [showScanner, setShowScanner] = useState(false)
  const [sessionInput, setSessionInput] = useState('')
  const [isEndingSession, setIsEndingSession] = useState(false)
  const [sessionProvider, setSessionProvider] = useState<SessionProvider>(() => {
    const raw = window.localStorage.getItem(SESSION_PROVIDER_STORAGE_KEY)
    return raw === 'opencode' ? 'opencode' : 'codex'
  })

  const observeAuth = observeToken.trim() || undefined
  const controlAuth = controlToken.trim() || undefined
  const isDebugBuild = import.meta.env.DEV

  useEffect(() => {
    window.localStorage.setItem(SESSION_PROVIDER_STORAGE_KEY, sessionProvider)
  }, [sessionProvider])

  const {
    outboxRef,
    pendingCommands,
    updateOutbox,
    enqueueMessage,
    retryCommandNow,
    clearOutbox,
    reconcileFromSessionState,
  } = useSessionOutbox()

  const applyStatus = useCallback((_phase: ConsolePhase, tone: StatusTone, text: string) => {
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

  async function startSession() {
    try {
      const requestId = newRequestId()
      const result = await apiRequest<JsonValue>('/sessions/start', controlAuth, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ provider: sessionProvider, request_id: requestId }),
      })
      clearOutbox()
      setSessionInput('')
      applyStatus('ready', 'ok', JSON.stringify(result))
    } catch (err) {
      normalizeStatus((err as Error).message)
    }
  }

  async function endSession() {
    if (isEndingSession) return
    setIsEndingSession(true)
    try {
      const requestId = newRequestId()
      const result = await apiRequest<JsonValue>('/sessions/current/end', controlAuth, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ request_id: requestId }),
      })
      const status = String(result.status ?? 'ended')
      clearOutbox()
      setSessionInput('')
      if (status === 'not_found') {
        applyStatus('ready', 'warn', 'no active session')
      } else {
        applyStatus('ready', 'ok', 'session ended')
      }
    } catch (err) {
      normalizeStatus((err as Error).message)
    } finally {
      setIsEndingSession(false)
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

  useOutboxDispatcher({
    controlAuth,
    outboxRef,
    sessionStatus,
    sessionInFlightRequestId,
    updateOutbox,
    onStatusUpdate: onSessionStatusUpdate,
  })

  return (
    <div className="mx-auto flex h-full max-h-dvh w-full max-w-4xl flex-col px-3 py-3 sm:px-4 sm:py-4">
      <header className="py-1">
        <div className="flex items-center justify-between gap-2">
          <div className="flex items-center gap-2">
            <h1 className="text-base font-semibold text-slate-900 sm:text-lg">Session</h1>
            <span className={`hidden rounded-full px-2 py-1 text-xs sm:inline-block ${toneClass(statusTone)}`}>{statusText}</span>
          </div>
          <div className="flex items-center gap-1.5 sm:gap-2">
            <button
              type="button"
              onClick={() => {
                setShowScanner((prev) => {
                  const next = !prev
                  if (!next) stopScanner()
                  return next
                })
              }}
              className="rounded-xl bg-slate-100 px-2.5 py-1.5 text-xs text-slate-700 transition-colors hover:bg-slate-200 sm:px-3"
            >
              {showScanner ? 'Hide QR' : 'Scan QR'}
            </button>
            {isDebugBuild ? (
              <button
                type="button"
                onClick={() => setShowTokenDebug((v) => !v)}
                className="rounded-xl bg-slate-100 px-2.5 py-1.5 text-xs text-slate-700 transition-colors hover:bg-slate-200 sm:px-3"
              >
                {showTokenDebug ? 'Hide' : 'Debug'}
              </button>
            ) : null}
          </div>
        </div>
        <div className={`mt-2 rounded-full px-2 py-1 text-xs sm:hidden ${toneClass(statusTone)}`}>{statusText}</div>

        {showScanner ? (
          <div className="mt-2 bg-slate-50 p-2 text-xs text-slate-700 sm:mt-3 sm:p-3">
            <div className="flex flex-wrap items-center gap-2">
              <button
                type="button"
                onClick={() => void startScanner()}
                disabled={scannerActive}
                className="rounded-xl bg-white px-3 py-1.5 text-xs hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-60"
              >
                Start Camera
              </button>
              <button
                type="button"
                onClick={() => stopScanner()}
                disabled={!scannerActive}
                className="rounded-xl bg-white px-3 py-1.5 text-xs hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-60"
              >
                Stop
              </button>
              <span className="text-slate-500">{scannerStatus}</span>
            </div>

            <video
              ref={scannerVideoRef}
              muted
              playsInline
              autoPlay
              className={`mt-2 max-h-48 w-full rounded-xl bg-black object-cover sm:max-h-56 ${scannerActive ? '' : 'hidden'}`}
            />
          </div>
        ) : null}

        {isDebugBuild && showTokenDebug ? (
          <div className="mt-2 grid gap-2 bg-slate-50 p-2 sm:mt-3 sm:grid-cols-2 sm:p-3">
            <label className="block text-xs font-medium text-slate-600">
              Observe Token
              <input
                className="mt-1 w-full rounded-xl bg-white px-3 py-2 text-sm text-slate-900 outline-none focus:bg-white"
                value={observeToken}
                onChange={(e) => setObserveToken(e.target.value.trim())}
                placeholder="observe token"
              />
            </label>
            <label className="block text-xs font-medium text-slate-600">
              Control Token
              <input
                className="mt-1 w-full rounded-xl bg-white px-3 py-2 text-sm text-slate-900 outline-none focus:bg-white"
                value={controlToken}
                onChange={(e) => setControlToken(e.target.value.trim())}
                placeholder="control token"
              />
            </label>
          </div>
        ) : null}
      </header>

      <div className="min-h-0 flex-1 overflow-hidden">
        <SessionView
          sessionState={sessionState}
          sessionMessages={sessionMessages}
          sessionInput={sessionInput}
          sessionProvider={sessionProvider}
          isSessionBusy={isSessionBusy}
          isEndingSession={isEndingSession}
          pendingCommands={pendingCommands}
          syncHint={sessionSyncHint}
          onSessionInputChange={setSessionInput}
          onSessionProviderChange={setSessionProvider}
          onStartSession={startSession}
          onEndSession={endSession}
          onSendMessage={sendSessionMessage}
          onRetryCommand={handleRetryCommand}
        />
      </div>
    </div>
  )
}
