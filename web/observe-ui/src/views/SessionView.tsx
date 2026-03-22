import { useEffect, useMemo, useRef } from 'react'
import { Panel } from '../components/Panel'
import type { PendingOutboxCommand } from '../hooks/useSessionOutbox'
import type { JsonValue, SessionMessage } from '../types'

export type PendingCommand = PendingOutboxCommand
type SessionProvider = 'codex' | 'opencode'

type SessionViewProps = {
  sessionState: JsonValue
  sessionMessages: SessionMessage[]
  sessionInput: string
  sessionProvider: SessionProvider
  isSessionBusy: boolean
  isEndingSession: boolean
  pendingCommands: PendingCommand[]
  syncHint: string
  onSessionInputChange: (value: string) => void
  onSessionProviderChange: (value: SessionProvider) => void
  onStartSession: () => void
  onEndSession: () => void
  onSendMessage: () => void
  onRetryCommand: (requestId: string) => void
}

function pendingTone(state: PendingCommand['state']): string {
  if (state === 'processing') return 'border-sky-200 bg-sky-50 text-sky-700'
  if (state === 'sending') return 'border-indigo-200 bg-indigo-50 text-indigo-700'
  if (state === 'retry_wait') return 'border-amber-200 bg-amber-50 text-amber-800'
  if (state === 'failed') return 'border-rose-200 bg-rose-50 text-rose-700'
  return 'border-slate-200 bg-slate-50 text-slate-700'
}

function pendingLabel(state: PendingCommand['state']): string {
  if (state === 'processing') return 'processing'
  if (state === 'sending') return 'sending'
  if (state === 'retry_wait') return 'retrying'
  if (state === 'failed') return 'failed'
  return 'queued'
}

export function SessionView(props: SessionViewProps) {
  const {
    sessionState,
    sessionMessages,
    sessionInput,
    sessionProvider,
    isSessionBusy,
    isEndingSession,
    pendingCommands,
    syncHint,
    onSessionInputChange,
    onSessionProviderChange,
    onStartSession,
    onEndSession,
    onSendMessage,
    onRetryCommand,
  } = props

  const listRef = useRef<HTMLDivElement | null>(null)
  const sessionStatus = String(sessionState.status ?? '-')
  const sessionId = String(sessionState.session_id ?? '')
  const hasSession = sessionId.trim().length > 0
  const canSend = hasSession && sessionStatus !== 'ended' && !isSessionBusy && !isEndingSession

  useEffect(() => {
    const el = listRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [sessionMessages.length, pendingCommands.length])

  const headerRight = useMemo(
    () => (
      <div className="flex flex-wrap items-center justify-end gap-2">
        <select
          value={sessionProvider}
          onChange={(e) => onSessionProviderChange(e.target.value as SessionProvider)}
          className="h-9 rounded-lg border border-slate-300 bg-white px-3 text-sm text-slate-800"
          title="session provider"
        >
          <option value="codex">codex</option>
          <option value="opencode">opencode</option>
        </select>
        <button
          type="button"
          onClick={onStartSession}
          disabled={isSessionBusy || isEndingSession}
          className="h-9 rounded-lg border border-slate-300 bg-white px-3 text-sm text-slate-700 hover:border-slate-400 disabled:cursor-not-allowed disabled:opacity-55"
        >
          New Session
        </button>
        <button
          type="button"
          onClick={onEndSession}
          disabled={!hasSession || isEndingSession}
          className="h-9 rounded-lg border border-rose-300 bg-rose-50 px-3 text-sm text-rose-700 hover:bg-rose-100 disabled:cursor-not-allowed disabled:opacity-55"
        >
          {isEndingSession ? 'Ending...' : 'End Session'}
        </button>
      </div>
    ),
    [hasSession, isEndingSession, isSessionBusy, onEndSession, onSessionProviderChange, onStartSession, sessionProvider],
  )

  return (
    <Panel title="Session" right={headerRight}>
      <div className="mb-3 rounded-xl border border-slate-200 bg-slate-50 p-3 text-xs text-slate-600">
        <div className="truncate">
          session: {hasSession ? sessionId : '(none)'} · status: {sessionStatus} · provider: {String(sessionState.provider ?? '-')}
        </div>
        <div className="mt-1">sync: {syncHint}</div>
      </div>

      {pendingCommands.length > 0 ? (
        <div className="mb-3 flex flex-wrap gap-2">
          {pendingCommands.slice(0, 6).map((cmd) => (
            <div key={cmd.requestId} className={`rounded-lg border px-2.5 py-1 text-[11px] ${pendingTone(cmd.state)}`}>
              {pendingLabel(cmd.state)} · {cmd.requestId.slice(0, 8)}
              {cmd.state === 'failed' ? (
                <button
                  type="button"
                  onClick={() => onRetryCommand(cmd.requestId)}
                  className="ml-2 rounded border border-rose-300 bg-white px-1.5 py-0.5 text-[10px] text-rose-700"
                >
                  Retry
                </button>
              ) : null}
            </div>
          ))}
          {pendingCommands.length > 6 ? <div className="rounded-lg border border-slate-200 bg-slate-50 px-2.5 py-1 text-[11px] text-slate-600">+{pendingCommands.length - 6} more</div> : null}
        </div>
      ) : null}

      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-2">
        <div ref={listRef} className="h-[52vh] min-h-[300px] space-y-2 overflow-y-auto p-1 md:h-[58vh]">
          {sessionMessages.length === 0 ? (
            <div className="rounded-xl border border-dashed border-slate-300 bg-white p-4 text-sm text-slate-500">(no messages)</div>
          ) : (
            sessionMessages.slice(-120).map((m, idx) => {
              const role = String(m.role || '')
              const isUser = role === 'user'
              const isSystem = role === 'system'
              const ts = typeof m.ts === 'number' ? new Date(m.ts * 1000).toLocaleTimeString() : '-'

              return (
                <article key={`${m.id ?? idx}-${role}`} className={`flex ${isUser ? 'justify-end' : 'justify-start'}`}>
                  <div
                    className={`max-w-[92%] rounded-2xl border px-3 py-2 shadow-sm md:max-w-[80%] ${
                      isUser
                        ? 'border-sky-200 bg-sky-50'
                        : isSystem
                          ? 'border-amber-200 bg-amber-50'
                          : 'border-slate-200 bg-white'
                    }`}
                  >
                    <div className="mb-1 flex items-center justify-between gap-2 text-[11px] text-slate-500">
                      <span className="font-medium uppercase tracking-wide">{role || 'unknown'}</span>
                      <span>
                        #{m.id ?? idx} · {ts}
                      </span>
                    </div>
                    <div className="whitespace-pre-wrap break-words text-sm leading-6 text-slate-800">{m.content}</div>
                  </div>
                </article>
              )
            })
          )}
        </div>

        <div className="mt-2 border-t border-slate-200 pt-2">
          <div className="flex items-end gap-2">
            <textarea
              className="min-h-[78px] w-full resize-none rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-800 outline-none focus:border-sky-400 disabled:cursor-not-allowed disabled:bg-slate-100"
              value={sessionInput}
              onChange={(e) => onSessionInputChange(e.target.value)}
              placeholder={
                !hasSession
                  ? 'create a new session first'
                  : sessionStatus === 'ended'
                    ? 'session ended, create a new one'
                    : isSessionBusy
                      ? 'agent is processing...'
                      : 'type your message'
              }
              disabled={!canSend}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.shiftKey) {
                  e.preventDefault()
                  onSendMessage()
                }
              }}
            />
            <button
              type="button"
              onClick={onSendMessage}
              disabled={!canSend || sessionInput.trim().length === 0}
              className="h-11 rounded-xl border border-slate-300 bg-white px-4 text-sm text-slate-700 hover:border-slate-400 disabled:cursor-not-allowed disabled:opacity-55"
            >
              Send
            </button>
          </div>
          {isSessionBusy ? <div className="mt-2 text-xs text-amber-700">Agent is processing previous message...</div> : null}
        </div>
      </div>
    </Panel>
  )
}
