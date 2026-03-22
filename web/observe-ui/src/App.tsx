import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

import { apiRequest, newRequestId } from './lib/api'
import { extractBootstrapParams, readAuthQuery } from './lib/auth'
import { useOutboxDispatcher } from './hooks/useOutboxDispatcher'
import { useQrScanner } from './hooks/useQrScanner'
import { useSessionOutbox } from './hooks/useSessionOutbox'
import { useSessionPolling } from './hooks/useSessionPolling'
import { SessionView } from './views/SessionView'
import type { JsonValue } from './types'

type SessionProvider = 'codex' | 'opencode'
const SESSION_PROVIDER_STORAGE_KEY = 'techlead.observe.session.provider'

export default function App() {
  const query = useMemo(() => readAuthQuery(window.location.search), [])

  const [observeToken, setObserveToken] = useState(query.observe)
  const [controlToken, setControlToken] = useState(query.control)
  const [showTokenDebug, setShowTokenDebug] = useState(false)

  const [showScanner, setShowScanner] = useState(false)
  const [sessionInput, setSessionInput] = useState('')
  const [isEndingSession, setIsEndingSession] = useState(false)
  const [sessionProvider, setSessionProvider] = useState<SessionProvider>(() => {
    const raw = window.localStorage.getItem(SESSION_PROVIDER_STORAGE_KEY)
    return raw === 'opencode' ? 'opencode' : 'codex'
  })

  const sessionInputRef = useRef(sessionInput)
  sessionInputRef.current = sessionInput

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
  })

  const hasSession = typeof sessionState.session_id === 'string' && sessionState.session_id.trim().length > 0
  const isSessionBusy = useMemo(() =>
    sessionStatus === 'processing' || (hasSession && pendingCommands.length > 0),
    [sessionStatus, hasSession, pendingCommands.length]
  )

  const exchangeBootstrapTicket = useCallback(async (bootstrapId: string, code: string): Promise<boolean> => {
    try {
      await apiRequest<JsonValue>('/auth/token/exchange', undefined, {
        method: 'POST',
        body: JSON.stringify({ bootstrap_id: bootstrapId, code }),
      })
      setObserveToken('')
      setControlToken('')
      return true
    } catch (err) {
      return false
    }
  }, [])

  const applyScannedPayload = useCallback(async (rawPayload: string, setScannerHint: (status: string) => void) => {
    const parsed = extractBootstrapParams(rawPayload)
    if (!parsed) {
      setScannerHint('invalid payload: missing bootstrap_id/code')
      return
    }

    setScannerHint('ticket parsed, authorizing...')
    const ok = await exchangeBootstrapTicket(parsed.bootstrapId, parsed.code)
    setScannerHint(ok ? 'connected via scan' : 'authorization failed')
  }, [exchangeBootstrapTicket])

  const { scannerStatus, scannerActive, scannerVideoRef, startScanner, stopScanner } = useQrScanner({ onPayload: applyScannedPayload })

  const handleRetryCommand = useCallback((requestId: string) => {
    retryCommandNow(requestId)
  }, [retryCommandNow])

  const handleSessionInputChange = useCallback((value: string) => {
    setSessionInput(value)
  }, [])

  const handleSessionProviderChange = useCallback((value: SessionProvider) => {
    setSessionProvider(value)
  }, [])

  const startSession = useCallback(async () => {
    // Starting a new session should not replay stale local outbox items from old bugs/reloads.
    clearOutbox()
    try {
      const requestId = newRequestId()
      await apiRequest<JsonValue>('/sessions/start', controlAuth, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ provider: sessionProvider, request_id: requestId }),
      })
      clearOutbox()
      setSessionInput('')
    } catch {
      void 0
    }
  }, [controlAuth, sessionProvider, clearOutbox])

  const endSession = useCallback(async () => {
    if (isEndingSession) return
    setIsEndingSession(true)
    try {
      const requestId = newRequestId()
      await apiRequest<JsonValue>('/sessions/current/end', controlAuth, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ request_id: requestId }),
      })
      clearOutbox()
      setSessionInput('')
    } catch {
      void 0
    } finally {
      setIsEndingSession(false)
    }
  }, [controlAuth, clearOutbox, isEndingSession])

  const sendSessionMessage = useCallback(() => {
    const result = enqueueMessage(sessionInputRef.current)
    if (!result.ok) return
    setSessionInput('')
  }, [enqueueMessage])

  useEffect(() => {
    if (sessionState.error === 'session_not_found') {
      clearOutbox()
    }
  }, [clearOutbox, sessionState.error])

  useEffect(() => {
    const removeQuerySecrets = () => {
      if (query.hasSensitive) {
        history.replaceState({}, '', location.pathname)
      }
    }

    const exchange = async () => {
      if (!query.bootstrapId || !query.code) {
        removeQuerySecrets()
        return
      }

      removeQuerySecrets()
      await exchangeBootstrapTicket(query.bootstrapId, query.code)
    }

    void exchange()
    return undefined
  }, [exchangeBootstrapTicket, query.bootstrapId, query.code, query.hasSensitive])

  useOutboxDispatcher({
    controlAuth,
    hasSession,
    outboxRef,
    sessionStatus,
    sessionInFlightRequestId,
    updateOutbox,
  })

  return (
    <div className="mx-auto flex h-full max-h-dvh w-full max-w-4xl flex-col">
      <header className="bg-slate-900 py-3 text-white">
        <div className="flex items-center justify-between gap-2 px-3 sm:px-4">
          <div className="flex items-center gap-2">
            <h1 className="text-base font-semibold sm:text-lg">techlead</h1>
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
              className="rounded-xl bg-slate-800 px-2.5 py-1.5 text-xs text-slate-200 transition-colors hover:bg-slate-700 sm:px-3"
            >
              {showScanner ? 'Hide QR' : 'Scan QR'}
            </button>
            {isDebugBuild ? (
              <button
                type="button"
                onClick={() => setShowTokenDebug((v) => !v)}
                className="rounded-xl bg-slate-800 px-2.5 py-1.5 text-xs text-slate-200 transition-colors hover:bg-slate-700 sm:px-3"
              >
                {showTokenDebug ? 'Hide' : 'Debug'}
              </button>
            ) : null}
          </div>
        </div>

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

      <div className="min-h-0 flex-1 overflow-hidden px-3 py-3 sm:px-4 sm:py-4">
        <SessionView
          sessionState={sessionState}
          sessionMessages={sessionMessages}
          sessionInput={sessionInput}
          sessionProvider={sessionProvider}
          isSessionBusy={isSessionBusy}
          isEndingSession={isEndingSession}
          pendingCommands={pendingCommands}
          syncState={sessionSync}
          onSessionInputChange={handleSessionInputChange}
          onSessionProviderChange={handleSessionProviderChange}
          onStartSession={startSession}
          onEndSession={endSession}
          onSendMessage={sendSessionMessage}
          onRetryCommand={handleRetryCommand}
        />
      </div>
    </div>
  )
}
