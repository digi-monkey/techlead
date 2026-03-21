import { useEffect, useRef } from 'react'
import { Panel } from '../components/Panel'
import type { JsonValue, SessionMessage } from '../types'

type SessionViewProps = {
  sessionState: JsonValue
  sessionMessages: SessionMessage[]
  sessionInput: string
  isSessionBusy: boolean
  onSessionInputChange: (value: string) => void
  onStartSession: () => void
  onSendMessage: () => void
}

export function SessionView(props: SessionViewProps) {
  const {
    sessionState,
    sessionMessages,
    sessionInput,
    isSessionBusy,
    onSessionInputChange,
    onStartSession,
    onSendMessage,
  } = props
  const listRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    const el = listRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [sessionMessages.length])

  return (
    <Panel
      title="Session Chat"
      right={
        <button
          type="button"
          onClick={onStartSession}
          disabled={isSessionBusy}
          className="rounded-lg border border-sky-300 bg-sky-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-sky-700 disabled:cursor-not-allowed disabled:border-slate-300 disabled:bg-slate-300"
        >
          Start Session
        </button>
      }
    >
      <div className="mb-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-600">
        session: {String(sessionState.session_id ?? '(none)')} | status: {String(sessionState.status ?? '-')} | provider:{' '}
        {String(sessionState.provider ?? '-')}
      </div>

      <div className="rounded-xl border border-slate-200 bg-slate-50 p-2">
        <div ref={listRef} className="h-[56vh] min-h-[340px] space-y-2 overflow-y-auto pr-1">
          {sessionMessages.length === 0 ? (
            <div className="rounded-lg border border-dashed border-slate-300 bg-white p-4 text-sm text-slate-500">(no messages)</div>
          ) : (
            sessionMessages.slice(-120).map((m, idx) => {
              const isUser = m.role === 'user'
              return (
                <article
                  key={`${m.role}-${idx}`}
                  className={`rounded-lg border p-3 ${
                    isUser ? 'border-sky-200 bg-sky-50' : 'border-slate-200 bg-white'
                  }`}
                >
                  <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-slate-500">{m.role}</div>
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
