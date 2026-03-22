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
  if (state === 'processing') return 'bg-sky-100 text-sky-700'
  if (state === 'sending') return 'bg-indigo-100 text-indigo-700'
  if (state === 'retry_wait') return 'bg-amber-100 text-amber-800'
  if (state === 'failed') return 'bg-rose-100 text-rose-700'
  return 'bg-slate-100 text-slate-600'
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
  const provider = String(sessionState.provider ?? '-')
  const hasSession = sessionId.trim().length > 0
  const canSend = hasSession && sessionStatus !== 'ended' && !isSessionBusy && !isEndingSession
  const showTyping = hasSession && sessionStatus === 'processing'

  useEffect(() => {
    const el = listRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [sessionMessages.length, pendingCommands.length, showTyping])

  const headerRight = useMemo(
    () => (
      <div className="flex flex-wrap items-center justify-end gap-2">
        <select
          value={sessionProvider}
          onChange={(e) => onSessionProviderChange(e.target.value as SessionProvider)}
          className="h-9 rounded-xl bg-slate-100 px-3 text-sm text-slate-700 outline-none transition-colors hover:bg-slate-200 focus:bg-slate-200"
          title="Session provider"
        >
          <option value="codex">codex</option>
          <option value="opencode">opencode</option>
        </select>
        <button
          type="button"
          onClick={onStartSession}
          disabled={isSessionBusy || isEndingSession}
          className="h-9 rounded-xl bg-slate-900 px-3 text-sm font-medium text-white transition-colors hover:bg-slate-800 disabled:cursor-not-allowed disabled:opacity-50"
        >
          New
        </button>
        <button
          type="button"
          onClick={onEndSession}
          disabled={!hasSession || isEndingSession}
          className="h-9 rounded-xl bg-rose-100 px-3 text-sm font-medium text-rose-700 transition-colors hover:bg-rose-200 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {isEndingSession ? 'Ending...' : 'End'}
        </button>
      </div>
    ),
    [hasSession, isEndingSession, isSessionBusy, onEndSession, onSessionProviderChange, onStartSession, sessionProvider],
  )

  return (
    <Panel title="Session" right={headerRight}>
      <div className="flex h-full flex-col">
        <div className="mb-2 px-0.5 text-xs text-slate-500">
          <div className="truncate">{hasSession ? sessionId : '(no session)'} · {provider} · {sessionStatus}</div>
          <div className="mt-0.5">sync: {syncHint}</div>
        </div>

        {pendingCommands.length > 0 ? (
          <div className="mb-2 flex flex-wrap gap-1.5">
            {pendingCommands.slice(0, 8).map((cmd) => (
              <div key={cmd.requestId} className={`inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-[11px] ${pendingTone(cmd.state)}`}>
                <span>{pendingLabel(cmd.state)}</span>
                <span className="font-mono opacity-75">{cmd.requestId.slice(0, 6)}</span>
                {cmd.state === 'failed' ? (
                  <button
                    type="button"
                    onClick={() => onRetryCommand(cmd.requestId)}
                    className="rounded bg-white/80 px-1.5 py-0 text-[10px] text-rose-700 hover:bg-white"
                  >
                    Retry
                  </button>
                ) : null}
              </div>
            ))}
            {pendingCommands.length > 8 ? (
              <div className="rounded-md bg-slate-100 px-2 py-1 text-[11px] text-slate-600">+{pendingCommands.length - 8} more</div>
            ) : null}
          </div>
        ) : null}

        <div ref={listRef} className="min-h-0 flex-1 space-y-3 overflow-y-auto px-0.5 py-1">
          {sessionMessages.length === 0 ? (
            <div className="flex h-full items-center justify-center text-sm text-slate-400">No messages yet</div>
          ) : (
            sessionMessages.slice(-120).map((m, idx) => {
              const role = String(m.role || '')
              const isUser = role === 'user'
              const isSystem = role === 'system'
              const ts = typeof m.ts === 'number' ? new Date(m.ts * 1000).toLocaleTimeString() : '-'

              return (
                <div key={`${m.id ?? idx}-${role}`} className={`flex ${isUser ? 'justify-end' : 'justify-start'}`}>
                  <div
                    className={`max-w-[90%] rounded-2xl px-4 py-3 md:max-w-[75%] ${
                      isUser ? 'bg-slate-900 text-white' : isSystem ? 'bg-amber-100 text-amber-900' : 'bg-slate-50 text-slate-800'
                    }`}
                  >
                    <div className={`mb-1 text-[11px] ${isUser ? 'text-slate-300' : 'text-slate-500'}`}>
                      {role || 'unknown'} · {ts}
                    </div>
                    <div className="whitespace-pre-wrap break-words text-sm leading-relaxed">{m.content}</div>
                  </div>
                </div>
              )
            })
          )}

          {showTyping ? (
            <div className="flex justify-start">
              <div className="max-w-[90%] rounded-2xl bg-slate-50 px-4 py-3 text-slate-700 md:max-w-[75%]">
                <div className="mb-1 text-[11px] text-slate-500">assistant · typing</div>
                <div className="flex items-center gap-1.5">
                  <span className="typing-dot" />
                  <span className="typing-dot" />
                  <span className="typing-dot" />
                </div>
              </div>
            </div>
          ) : null}
        </div>

        <div className="mt-3 pt-2">
          <div className="flex items-end gap-2">
            <textarea
            className="min-h-[80px] w-full resize-none rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-800 outline-none placeholder:text-slate-400 focus:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-70"
            value={sessionInput}
            onChange={(e) => onSessionInputChange(e.target.value)}
            placeholder={!hasSession ? 'Create a new session first...' : sessionStatus === 'ended' ? 'Session ended. Start a new one.' : isSessionBusy ? 'Agent is thinking...' : 'Type your message...'}
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
            className="flex h-10 w-10 items-center justify-center rounded-xl bg-slate-900 text-white transition-colors hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-300"
            title="Send message"
          >
            <svg className="h-4 w-4" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">
              <path d="M4.5 10h11M12.5 7l3 3-3 3" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </button>
        </div>
      </div>
      </div>
    </Panel>
  )
}
