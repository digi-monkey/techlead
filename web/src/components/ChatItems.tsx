import { memo } from 'react'
import type { PendingOutboxCommand } from '../hooks/useSessionOutbox'
import type { SessionMessage } from '../types'

type ChatMessageItemProps = {
  item: SessionMessage
  defaultProvider?: string
}

export const ChatMessageItem = memo(function ChatMessageItem({ item, defaultProvider }: ChatMessageItemProps) {
  const role = String(item.role || '')
  const isUser = role === 'user'
  const isSystem = role === 'system'
  const isAssistant = role === 'assistant'
  const ts = typeof item.ts === 'number' ? new Date(item.ts * 1000).toLocaleTimeString() : '-'
  const provider = item.provider || defaultProvider
  const roleLabel = isAssistant && provider ? provider : role

  return (
    <div className={`flex ${isUser ? 'justify-end' : 'justify-start'}`}>
      <div
        className={`max-w-[90%] rounded-2xl px-4 py-3 md:max-w-[75%] ${
          isUser ? 'bg-slate-900 text-white' : isSystem ? 'bg-amber-100 text-amber-900' : 'bg-slate-50 text-slate-800'
        }`}
      >
        <div className={`mb-1 text-[11px] ${isUser ? 'text-slate-300' : 'text-slate-500'}`}>
          {roleLabel || 'unknown'} · {ts}
        </div>
        <div className="whitespace-pre-wrap break-words text-sm leading-relaxed">{item.content}</div>
      </div>
    </div>
  )
})

type ChatPendingItemProps = {
  item: PendingOutboxCommand
  onRetry: (requestId: string) => void
}

export const ChatPendingItem = memo(function ChatPendingItem({ item, onRetry }: ChatPendingItemProps) {
  const statusText = item.state === 'failed' ? 'failed' : item.state === 'sending' ? 'sending...' : item.state === 'processing' ? 'sent' : 'pending...'

  return (
    <div className="flex justify-end">
      <div className="max-w-[90%] rounded-2xl bg-slate-700/50 px-4 py-3 text-white/90 md:max-w-[75%]">
        <div className="mb-1 flex items-center gap-1.5 text-[11px] text-slate-300">
          <span>you</span>
          <span className="inline-block h-1.5 w-1.5 rounded-full bg-amber-400 animate-pulse" />
          <span>{statusText}</span>
          {item.state === 'failed' ? (
            <button
              type="button"
              onClick={() => onRetry(item.requestId)}
              className="ml-1 rounded bg-white/20 px-1.5 py-0 text-[10px] hover:bg-white/30"
            >
              Retry
            </button>
          ) : null}
        </div>
        <div className="whitespace-pre-wrap break-words text-sm leading-relaxed opacity-80">{item.text}</div>
      </div>
    </div>
  )
})

type ChatTypingIndicatorProps = {
  show: boolean
}

export const ChatTypingIndicator = memo(function ChatTypingIndicator({ show }: ChatTypingIndicatorProps) {
  if (!show) return null

  return (
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
  )
})
