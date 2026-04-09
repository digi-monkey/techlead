import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

import { newRequestId } from '../lib/api'
import type { SessionMessage } from '../types'

export type OutboxState = 'queued' | 'sending' | 'processing' | 'retry_wait' | 'failed' | 'completed'

export type OutboxItem = {
  requestId: string
  text: string
  state: OutboxState
  attempts: number
  createdAt: number
  updatedAt: number
  nextRetryAt?: number
  lastError?: string
}

export type UpdateOutboxFn = (requestId: string, updater: (item: OutboxItem) => OutboxItem) => void

export type PendingOutboxCommand = {
  requestId: string
  text: string
  state: 'queued' | 'sending' | 'processing' | 'retry_wait' | 'failed'
  attempts: number
  nextRetryAt?: number
  lastError?: string
}

type EnqueueResult =
  | {
      ok: true
      requestId: string
    }
  | {
      ok: false
      reason: string
    }

const OUTBOX_STORAGE_KEY = 'techlead.observe.session.outbox.v1'
const MAX_OUTBOX_ITEMS = 120

function nowMs() {
  return Date.now()
}

function recoverStaleState(state: OutboxState): OutboxState {
  // Local storage may retain transient states from old crashes/bugs.
  // Recover them into retryable states so dispatcher can continue.
  if (state === 'sending' || state === 'processing') return 'retry_wait'
  return state
}

function sanitizeOutbox(raw: unknown): OutboxItem[] {
  if (!Array.isArray(raw)) return []
  const items: OutboxItem[] = []
  for (const it of raw) {
    const rec = it as Record<string, unknown>
    const requestId = typeof rec.requestId === 'string' ? rec.requestId.trim() : ''
    const text = typeof rec.text === 'string' ? rec.text : ''
    const state = typeof rec.state === 'string' ? rec.state : 'queued'
    const attempts = typeof rec.attempts === 'number' && Number.isFinite(rec.attempts) ? rec.attempts : 0
    const createdAt = typeof rec.createdAt === 'number' && Number.isFinite(rec.createdAt) ? rec.createdAt : nowMs()
    const updatedAt = typeof rec.updatedAt === 'number' && Number.isFinite(rec.updatedAt) ? rec.updatedAt : createdAt

    if (!requestId || !text) continue
    if (!['queued', 'sending', 'processing', 'retry_wait', 'failed', 'completed'].includes(state)) continue

    const normalizedState = recoverStaleState(state as OutboxState)
    items.push({
      requestId,
      text,
      state: normalizedState,
      attempts,
      createdAt,
      updatedAt,
      nextRetryAt:
        normalizedState === 'retry_wait'
          ? typeof rec.nextRetryAt === 'number'
            ? rec.nextRetryAt
            : nowMs()
          : typeof rec.nextRetryAt === 'number'
            ? rec.nextRetryAt
            : undefined,
      lastError:
        normalizedState === 'retry_wait' && (state === 'sending' || state === 'processing')
          ? 'recovered from stale local state, retrying'
          : typeof rec.lastError === 'string'
            ? rec.lastError
            : undefined,
    })
  }
  return items.slice(-MAX_OUTBOX_ITEMS)
}

function loadOutboxFromStorage(): OutboxItem[] {
  try {
    const raw = localStorage.getItem(OUTBOX_STORAGE_KEY)
    if (!raw) return []
    return sanitizeOutbox(JSON.parse(raw))
  } catch (err) {
    console.error('[useSessionOutbox] Failed to load outbox from localStorage:', err);
    return []
  }
}

function findAssistantReplyByRequestId(messages: SessionMessage[], requestId: string): string | null {
  for (const msg of messages) {
    if (msg.role !== 'assistant') continue
    if (msg.request_id !== requestId) continue
    return msg.content
  }
  return null
}

export function nextRetryDelayMs(attempts: number): number {
  const base = 1200
  const cappedPower = Math.min(5, Math.max(0, attempts - 1))
  return Math.min(30000, base * 2 ** cappedPower)
}

export function useSessionOutbox() {
  const [outbox, setOutbox] = useState<OutboxItem[]>(() => loadOutboxFromStorage())
  const outboxRef = useRef<OutboxItem[]>(outbox)

  useEffect(() => {
    outboxRef.current = outbox
    const timer = setTimeout(() => {
      try {
        localStorage.setItem(OUTBOX_STORAGE_KEY, JSON.stringify(outbox))
      } catch (err) {
        console.error('[useSessionOutbox] Failed to save outbox to localStorage:', err);
      }
    }, 500)
    return () => clearTimeout(timer)
  }, [outbox])

  const pendingCommands = useMemo<PendingOutboxCommand[]>(() => {
    return outbox
      .filter((item): item is OutboxItem & { state: Exclude<OutboxState, 'completed'> } => item.state !== 'completed')
      .sort((a, b) => a.createdAt - b.createdAt)
      .map((item) => ({
        requestId: item.requestId,
        text: item.text,
        state: item.state,
        attempts: item.attempts,
        nextRetryAt: item.nextRetryAt,
        lastError: item.lastError,
      }))
  }, [outbox])

  const updateOutbox: UpdateOutboxFn = useCallback((requestId: string, updater: (item: OutboxItem) => OutboxItem) => {
    setOutbox((prev) =>
      prev.map((item) => {
        if (item.requestId !== requestId) return item
        const next = updater(item)
        return { ...next, updatedAt: nowMs() }
      }),
    )
  }, [])

  const enqueueMessage = useCallback((text: string): EnqueueResult => {
    const trimmed = text.trim()
    if (!trimmed) return { ok: false, reason: 'message empty' }

    const requestId = newRequestId()
    const now = nowMs()

    setOutbox((prev) => {
      const next = prev
        .filter((item) => item.state !== 'completed' || now - item.updatedAt < 30_000)
        .concat([
          {
            requestId,
            text: trimmed,
            state: 'queued' as OutboxState,
            attempts: 0,
            createdAt: now,
            updatedAt: now,
          },
        ])
      return next.slice(-MAX_OUTBOX_ITEMS)
    })

    return { ok: true, requestId }
  }, [])

  const retryCommandNow = useCallback(
    (requestId: string) => {
      updateOutbox(requestId, (item) => ({
        ...item,
        state: 'queued',
        nextRetryAt: undefined,
        lastError: undefined,
      }))
    },
    [updateOutbox],
  )

  const clearOutbox = useCallback(() => {
    setOutbox([])
  }, [])

  const reconcileFromSessionState = useCallback((messages: SessionMessage[], inFlightRequestId: string, status: string) => {
    setOutbox((prev) => {
      const now = nowMs()
      let changed = false

      const next: OutboxItem[] = prev.map((item): OutboxItem => {
        if (item.state === 'completed') return item

        const reply = findAssistantReplyByRequestId(messages, item.requestId)
        if (reply) {
          changed = true
          return {
            ...item,
            state: 'completed',
            nextRetryAt: undefined,
            lastError: undefined,
            updatedAt: now,
          }
        }

        if (status === 'processing' && inFlightRequestId && item.requestId === inFlightRequestId && item.state !== 'processing') {
          changed = true
          return {
            ...item,
            state: 'processing',
            nextRetryAt: undefined,
            lastError: undefined,
            updatedAt: now,
          }
        }

        if (item.state === 'processing' && (status !== 'processing' || inFlightRequestId !== item.requestId)) {
          const delay = nextRetryDelayMs(item.attempts + 1)
          changed = true
          return {
            ...item,
            state: 'retry_wait',
            nextRetryAt: now + delay,
            lastError: 'processing state cleared before reply, retrying',
            updatedAt: now,
          }
        }

        return item
      })

      if (!changed) return prev
      return next
    })
  }, [])

  return {
    outboxRef,
    pendingCommands,
    updateOutbox,
    enqueueMessage,
    retryCommandNow,
    clearOutbox,
    reconcileFromSessionState,
  }
}
