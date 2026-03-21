import { useEffect, useMemo, useRef } from 'react'
import { Panel } from '../components/Panel'
import type { JsonValue, SessionMessage } from '../types'

export type PendingCommand = {
  requestId: string
  text: string
  state: 'queued' | 'sending' | 'processing' | 'retry_wait' | 'failed'
  attempts: number
  nextRetryAt?: number
  lastError?: string
}

type SessionViewProps = {
  sessionState: JsonValue
  sessionMessages: SessionMessage[]
  sessionInput: string
  isSessionBusy: boolean
  pendingCommands: PendingCommand[]
  syncHint: string
  onSessionInputChange: (value: string) => void
  onStartSession: () => void
  onSendMessage: () => void
  onRetryCommand: (requestId: string) => void
}

function statusChip(state: PendingCommand['state']): string {
  if (state === 'processing') return 'bg-sky-100 text-sky-700 border-sky-200'
  if (state === 'sending') return 'bg-indigo-100 text-indigo-700 border-indigo-200'
  if (state === 'retry_wait') return 'bg-amber-100 text-amber-800 border-amber-200'
  if (state === 'failed') return 'bg-rose-100 text-rose-700 border-rose-200'
  return 'bg-slate-100 text-slate-700 border-slate-200'
}

function stateLabel(state: PendingCommand['state']): string {
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
    isSessionBusy,
    pendingCommands,
    syncHint,
    onSessionInputChange,
    onStartSession,
    onSendMessage,
    onRetryCommand,
  } = props
  const listRef = useRef<HTMLDivElement | null>(null)

  const pendingCount = pendingCommands.length
  const sessionStatus = String(sessionState.status ?? '-')
  const providerSessionId = String(sessionState.provider_session_id ?? '')

  useEffect(() => {
    const el = listRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [sessionMessages.length, pendingCount])

  const headerRight = useMemo(
    () => (
      <button
        type="button"
        onClick={onStartSession}
        disabled={isSessionBusy}
        className="rounded-lg border border-sky-300 bg-sky-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-sky-700 disabled:cursor-not-allowed disabled:border-slate-300 disabled:bg-slate-300"
      >
        Start Session
      </button>
    ),
    [isSessionBusy, onStartSession],
  )

  return (
    <Panel title="Session Chat" right={headerRight}>
      <div className="mb-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-600">
        session: {String(sessionState.session_id ?? '(none)')} | status: {sessionStatus} | provider: {String(sessionState.provider ?? '-')}
        <div className="mt-1">
          sync: {syncHint}
          {providerSessionId ? ` | provider_session: ${providerSessionId.slice(0, 8)}...` : ' | provider_session: (pending)'}
        </div>
      </div>

      {pendingCount > 0 ? (
        <div className="mb-3 space-y-2 rounded-xl border border-amber-200 bg-amber-50 p-3">
          <div className="text-xs font-semibold text-amber-900">Pending Commands ({pendingCount})</div>
          {pendingCommands.map((cmd) => (
            <article key={cmd.requestId} className="rounded-lg border border-amber-200 bg-white p-2">
              <div className="mb-1 flex flex-wrap items-center justify-between gap-2">
                <span className={`rounded border px-1.5 py-0.5 text-[10px] ${statusChip(cmd.state)}`}>{stateLabel(cmd.state)}</span>
                <span className="text-[10px] text-slate-500">{cmd.requestId}</span>
              </div>
              <div className="text-xs text-slate-700">{cmd.text}</div>
              <div className="mt-1 flex flex-wrap items-center justify-between gap-2 text-[10px] text-slate-500">
                <span>attempts: {cmd.attempts}</span>
                {cmd.state === 'retry_wait' && cmd.nextRetryAt ? <span>retry at: {new Date(cmd.nextRetryAt).toLocaleTimeString()}</span> : null}
                {cmd.state === 'failed' ? (
                  <button
                    type="button"
                    onClick={() => onRetryCommand(cmd.requestId)}
                    className="rounded border border-rose-300 bg-rose-50 px-2 py-0.5 text-[10px] text-rose-700"
                  >
                    Retry Now
                  </button>
                ) : null}
              </div>
              {cmd.lastError ? <div className="mt-1 text-[10px] text-rose-700">{cmd.lastError}</div> : null}
            </article>
          ))}
        </div>
      ) : null}

      <div className="rounded-xl border border-slate-200 bg-slate-50 p-2">
        <div ref={listRef} className="h-[56vh] min-h-[340px] space-y-2 overflow-y-auto pr-1">
          {sessionMessages.length === 0 ? (
            <div className="rounded-lg border border-dashed border-slate-300 bg-white p-4 text-sm text-slate-500">(no messages)</div>
          ) : (
            sessionMessages.slice(-120).map((m, idx) => {
              const isUser = m.role === 'user'
              const ts = typeof m.ts === 'number' ? new Date(m.ts * 1000).toLocaleTimeString() : '-'
              return (
                <article
                  key={`${m.id ?? idx}-${m.role}`}
                  className={`rounded-lg border p-3 ${isUser ? 'border-sky-200 bg-sky-50' : 'border-slate-200 bg-white'}`}
                >
                  <div className="mb-1 flex flex-wrap items-center justify-between gap-2 text-xs text-slate-500">
                    <span className="font-semibold uppercase tracking-wide">{m.role}</span>
                    <span>
                      #{m.id ?? idx} · {ts}
                    </span>
                  </div>
                  {m.request_id ? <div className="mb-1 text-[10px] text-slate-500">request_id: {m.request_id}</div> : null}
                  <pre className="text-sm leading-6 text-slate-800">{m.content}</pre>
                </article>
              )
            })
          )}
        </div>

        <div className="mt-2 flex gap-2 border-t border-slate-200 pt-2">
          <input
            className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm disabled:cursor-not-allowed disabled:bg-slate-100"
            value={sessionInput}
            onChange={(e) => onSessionInputChange(e.target.value)}
            placeholder={isSessionBusy ? 'agent is processing...' : 'say something to agent'}
            disabled={isSessionBusy}
            onKeyDown={(e) => {
              if (e.key === 'Enter') void onSendMessage()
            }}
          />
          <button
            type="button"
            onClick={onSendMessage}
            disabled={isSessionBusy}
            className="rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm disabled:cursor-not-allowed disabled:bg-slate-100"
          >
            Send
          </button>
        </div>
        {isSessionBusy ? <div className="mt-2 text-xs text-amber-700">Agent is processing previous message...</div> : null}
      </div>
    </Panel>
  )
}
