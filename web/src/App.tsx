import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

import { apiRequest, newRequestId, getErrorMessage } from './lib/api'
import { extractBootstrapParams, readAuthQuery } from './lib/auth'
import { useOutboxDispatcher } from './hooks/useOutboxDispatcher'
import { useQrScanner } from './hooks/useQrScanner'
import { useSessionOutbox } from './hooks/useSessionOutbox'
import { useSessionPolling } from './hooks/useSessionPolling'
import { ProjectList } from './views/ProjectList'
import { SessionView } from './views/SessionView'
import { TaskPoolView } from './views/TaskPoolView'
import type { JsonValue } from './types'

type SessionProvider = 'codex' | 'opencode'
type MainView = 'session' | 'projects' | 'project-detail'
const SESSION_PROVIDER_STORAGE_KEY = 'techlead.observe.session.provider'
const MAIN_VIEW_STORAGE_KEY = 'techlead.observe.main.view'
const PROJECT_ID_STORAGE_KEY = 'techlead.observe.project.id'
const OBSERVE_TOKEN_STORAGE_KEY = 'techlead.observe.auth.observe'
const CONTROL_TOKEN_STORAGE_KEY = 'techlead.observe.auth.control'
const AUTH_COOKIE_OBSERVE = 'tl_observe'
const AUTH_COOKIE_CONTROL = 'tl_control'

function getCookie(name: string): string | null {
  const value = `; ${document.cookie}`
  const parts = value.split(`; ${name}=`)
  if (parts.length === 2) return parts.pop()?.split(';').shift() ?? null
  return null
}

function getStoredToken(key: string): string {
  try {
    return window.localStorage.getItem(key) ?? ''
  } catch {
    return ''
  }
}

export default function App() {
  const query = useMemo(() => readAuthQuery(window.location.search), [])

  const cookieObserve = getCookie(AUTH_COOKIE_OBSERVE) ?? ''
  const cookieControl = getCookie(AUTH_COOKIE_CONTROL) ?? ''
  const storedObserve = getStoredToken(OBSERVE_TOKEN_STORAGE_KEY)
  const storedControl = getStoredToken(CONTROL_TOKEN_STORAGE_KEY)

  const [observeToken, setObserveToken] = useState(query.observe || cookieObserve || storedObserve)
  const [controlToken, setControlToken] = useState(query.control || cookieControl || storedControl)
  const [showTokenDebug, setShowTokenDebug] = useState(false)

  const [showScanner, setShowScanner] = useState(false)
  const [sessionInput, setSessionInput] = useState('')
  const [isStartingSession, setIsStartingSession] = useState(false)
  const [isEndingSession, setIsEndingSession] = useState(false)
  const [mainView, setMainView] = useState<MainView>(() => {
    const raw = window.localStorage.getItem(MAIN_VIEW_STORAGE_KEY)
    if (raw === 'projects') return 'projects'
    if (raw === 'project-detail') return 'project-detail'
    return 'session'
  })
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(() => {
    return window.localStorage.getItem(PROJECT_ID_STORAGE_KEY)
  })
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

  useEffect(() => {
    window.localStorage.setItem(MAIN_VIEW_STORAGE_KEY, mainView)
  }, [mainView])

  useEffect(() => {
    if (selectedProjectId) {
      window.localStorage.setItem(PROJECT_ID_STORAGE_KEY, selectedProjectId)
    } else {
      window.localStorage.removeItem(PROJECT_ID_STORAGE_KEY)
    }
  }, [selectedProjectId])

  useEffect(() => {
    const value = observeToken.trim()
    if (value) {
      window.localStorage.setItem(OBSERVE_TOKEN_STORAGE_KEY, value)
    } else {
      window.localStorage.removeItem(OBSERVE_TOKEN_STORAGE_KEY)
    }
  }, [observeToken])

  useEffect(() => {
    const value = controlToken.trim()
    if (value) {
      window.localStorage.setItem(CONTROL_TOKEN_STORAGE_KEY, value)
    } else {
      window.localStorage.removeItem(CONTROL_TOKEN_STORAGE_KEY)
    }
  }, [controlToken])

  const handleViewProject = useCallback((projectId: string) => {
    setSelectedProjectId(projectId)
    setMainView('project-detail')
  }, [])

  const handleBackFromProject = useCallback(() => {
    setSelectedProjectId(null)
    setMainView('projects')
  }, [])

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
  const hasBlockingPendingCommands = useMemo(
    () => pendingCommands.some((cmd) => cmd.state !== 'failed'),
    [pendingCommands]
  )
  const isSessionBusy = useMemo(() =>
    sessionStatus === 'processing' || (hasSession && hasBlockingPendingCommands),
    [sessionStatus, hasSession, hasBlockingPendingCommands]
  )

  const exchangeBootstrapTicket = useCallback(async (bootstrapId: string, code: string): Promise<boolean> => {
    try {
      await apiRequest<JsonValue>('/auth/token/exchange', null, {
        method: 'POST',
        body: JSON.stringify({ bootstrap_id: bootstrapId, code }),
      })
      const observe = getCookie(AUTH_COOKIE_OBSERVE)
      const control = getCookie(AUTH_COOKIE_CONTROL)
      if (observe) setObserveToken(observe)
      if (control) setControlToken(control)
      return true
    } catch {
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
    if (isStartingSession) return
    setIsStartingSession(true)
    clearOutbox()
    try {
      const requestId = newRequestId()
      await apiRequest<JsonValue>('/sessions/start', controlAuth ?? null, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ provider: sessionProvider, request_id: requestId }),
      })
      clearOutbox()
      setSessionInput('')
    } catch (err) {
      alert("Start Session Failed: " + getErrorMessage(err))
    } finally {
      setIsStartingSession(false)
    }
  }, [sessionProvider, clearOutbox, isStartingSession, controlAuth])

  const endSession = useCallback(async () => {
    if (isEndingSession) return
    setIsEndingSession(true)
    clearOutbox()
    try {
      const requestId = newRequestId()
      await apiRequest<JsonValue>('/sessions/current/end', controlAuth ?? null, {
        method: 'POST',
        headers: { 'X-Request-Id': requestId },
        body: JSON.stringify({ request_id: requestId }),
      })
      clearOutbox()
      setSessionInput('')
    } catch (err) {
      alert("End Session Failed: " + getErrorMessage(err))
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
    <div className="mx-auto flex min-h-dvh w-full max-w-425 flex-col">
      <header className="sticky top-0 z-20 bg-slate-900 py-3 text-white">
        <div className="flex items-center justify-between gap-2 px-3 sm:px-4">
          <div className="flex items-center gap-3">
            <h1 className="text-base font-semibold sm:text-lg">techlead</h1>
            <nav className="flex items-center gap-1 rounded-lg bg-slate-800 p-1">
              <button
                type="button"
                onClick={() => setMainView('session')}
                className={`rounded-md px-2.5 py-1 text-xs transition-colors ${
                  mainView === 'session' ? 'bg-white text-slate-900' : 'text-slate-200 hover:bg-slate-700'
                }`}
              >
                Session
              </button>
              <button
                type="button"
                onClick={() => setMainView('projects')}
                className={`rounded-md px-2.5 py-1 text-xs transition-colors ${
                  mainView === 'projects' || mainView === 'project-detail' ? 'bg-white text-slate-900' : 'text-slate-200 hover:bg-slate-700'
                }`}
              >
                Projects
              </button>
            </nav>
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

      <main className="min-h-0 flex-1 overflow-y-auto px-0 pb-[env(safe-area-inset-bottom)] sm:px-4 sm:pt-4">
        {mainView === 'session' && (
          <SessionView
            sessionState={sessionState}
            sessionMessages={sessionMessages}
            sessionInput={sessionInput}
            sessionProvider={sessionProvider}
            isSessionBusy={isSessionBusy}
            isStartingSession={isStartingSession}
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
        )}
        {mainView === 'projects' && (
          <ProjectList observeAuth={observeAuth} onViewProject={handleViewProject} />
        )}
        {mainView === 'project-detail' && selectedProjectId && (
          <TaskPoolView 
            projectId={selectedProjectId} 
            observeAuth={observeAuth} 
            controlAuth={controlAuth} 
            onBack={handleBackFromProject}
          />
        )}
        {mainView === 'project-detail' && !selectedProjectId && (
          <div className="flex h-full items-center justify-center">
            <div className="text-center">
              <p className="text-sm text-slate-500">No project selected</p>
              <button
                type="button"
                onClick={() => setMainView('projects')}
                className="mt-2 text-sm text-slate-600 hover:text-slate-800"
              >
                View all projects
              </button>
            </div>
          </div>
        )}
      </main>
    </div>
  )
}
