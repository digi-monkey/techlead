import { useEffect, useMemo, useRef, useCallback } from 'react'
import { Panel } from '../components/Panel'
import { ChatMessageItem, ChatPendingItem, ChatTypingIndicator } from '../components/ChatItems'
import type { PendingOutboxCommand } from '../hooks/useSessionOutbox'
import type { SessionSyncState } from '../hooks/useSessionPolling'
import type { JsonValue, SessionMessage } from '../types'

const MAX_VISIBLE_MESSAGES = 15
const SCROLL_THRESHOLD_PX = 100

export type PendingCommand = PendingOutboxCommand
type SessionProvider = 'codex' | 'opencode'

type ChatItem =
  | { type: 'message'; data: SessionMessage; key: string }
  | { type: 'pending'; data: PendingCommand; key: string }

type SessionViewProps = {
  sessionState: JsonValue
  sessionMessages: SessionMessage[]
  sessionInput: string
  sessionProvider: SessionProvider
  isSessionBusy: boolean
  isStartingSession: boolean
  isEndingSession: boolean
  pendingCommands: PendingCommand[]
  syncState: SessionSyncState
  onSessionInputChange: (value: string) => void
  onSessionProviderChange: (value: SessionProvider) => void
  onStartSession: () => void
  onEndSession: () => void
  onSendMessage: () => void
  onRetryCommand: (requestId: string) => void
}

function syncStatusDot(sync: SessionSyncState): string {
  if (sync.consecutiveErrors === 0) return 'bg-emerald-500'
  if (sync.consecutiveErrors < 3) return 'bg-amber-500'
  return 'bg-rose-500'
}

export function SessionView(props: SessionViewProps) {
  const {
    sessionState,
    sessionMessages,
    sessionInput,
    sessionProvider,
    isSessionBusy,
    isStartingSession,
    isEndingSession,
    pendingCommands,
    syncState,
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
  const showTyping = hasSession && sessionStatus === 'processing'

  const chatItems = useMemo<ChatItem[]>(() => {
    const items: ChatItem[] = []
    const seenRequestIds = new Set<string>()

    for (const m of sessionMessages.slice(-MAX_VISIBLE_MESSAGES)) {
      const key = String(m.id ?? `${m.ts}-${m.role}`)
      items.push({ type: 'message', data: m, key })
      if (typeof m.request_id === 'string') {
        seenRequestIds.add(m.request_id)
      }
    }

    for (const cmd of pendingCommands) {
      if (!seenRequestIds.has(cmd.requestId)) {
        items.push({ type: 'pending', data: cmd, key: `pending-${cmd.requestId}` })
      }
    }

    return items
  }, [sessionMessages, pendingCommands])

  useEffect(() => {
    const el = listRef.current
    if (!el) return
    // Only auto-scroll if user is already near the bottom (within SCROLL_THRESHOLD_PX)
    // This prevents aggressive scrolling during typing while preserving auto-scroll for new messages
    const isNearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < SCROLL_THRESHOLD_PX
    if (isNearBottom) {
      el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
    }
  }, [sessionMessages.length, pendingCommands.length])

  const handleRetry = useCallback((requestId: string) => {
    onRetryCommand(requestId)
  }, [onRetryCommand])

  const handleSessionToggle = useCallback(() => {
    if (hasSession && sessionStatus !== 'ended') {
      onEndSession()
    } else {
      onStartSession()
    }
  }, [hasSession, sessionStatus, onEndSession, onStartSession])

  const isToggleBusy = isStartingSession || isEndingSession
  const showEnd = hasSession && sessionStatus !== 'ended'

  const headerRight = useMemo(
    () => (
      <div className="flex items-center gap-2">
        <div
          className={`h-2 w-2 rounded-full ${syncStatusDot(syncState)}`}
          title={syncState.consecutiveErrors === 0 ? 'healthy' : `errors: ${syncState.consecutiveErrors}`}
        />
        <select
          value={sessionProvider}
          onChange={(e) => onSessionProviderChange(e.target.value as SessionProvider)}
          className="tl-select h-8 min-h-0 w-auto px-2 text-xs font-medium"
          title="Session provider"
        >
          <option value="codex">codex</option>
          <option value="opencode">opencode</option>
        </select>
        <button
          type="button"
          onClick={handleSessionToggle}
          disabled={isToggleBusy}
          className={`flex h-8 items-center justify-center px-2 text-xs font-medium disabled:cursor-not-allowed disabled:opacity-50 ${
            showEnd
              ? 'tl-danger-btn'
              : 'tl-soft-btn'
          } ${isStartingSession || isEndingSession ? 'w-auto whitespace-nowrap' : 'w-7'}`}
          title={showEnd ? 'End session' : 'New session'}
        >
          {isStartingSession ? (
            <span className="whitespace-nowrap text-[10px]">Starting...</span>
          ) : isEndingSession ? (
            <span className="whitespace-nowrap text-[10px]">Ending...</span>
          ) : showEnd ? (
            <svg className="h-3.5 w-3.5" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">
              <path d="M4 4l12 12M16 4L4 16" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
            </svg>
          ) : (
            <svg className="h-3.5 w-3.5" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">
              <path d="M10 4v12M4 10h12" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
            </svg>
          )}
        </button>
      </div>
    ),
    [isToggleBusy, isStartingSession, isEndingSession, showEnd, onSessionProviderChange, sessionProvider, syncState, handleSessionToggle],
  )

  const panelTitle = hasSession ? sessionId : 'Session'

  return (
    <Panel title={panelTitle} right={headerRight}>
      <div className="flex h-full flex-col">

        <div ref={listRef} className="min-h-0 flex-1 space-y-2 overflow-y-auto py-1">
          {chatItems.length === 0 ? (
            <div className="flex h-full items-center justify-center text-sm text-slate-400">No messages yet. Start with a clear goal.</div>
          ) : (
            chatItems.map((item) => {
              if (item.type === 'pending') {
                return <ChatPendingItem key={item.key} item={item.data} onRetry={handleRetry} />
              }
              return <ChatMessageItem key={item.key} item={item.data} defaultProvider={sessionProvider} />
            })
          )}

          <ChatTypingIndicator show={showTyping} />
        </div>

        <div className="mt-3 pt-2">
          <div className="relative">
            <textarea
              className="tl-textarea min-h-25 pr-14 text-sm placeholder:text-slate-400"
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
              className="tl-primary-btn absolute right-2 bottom-2 h-8 px-3 text-[11px]"
              title="Send message"
            >
              Send
            </button>
          </div>
        </div>
      </div>
    </Panel>
  )
}
