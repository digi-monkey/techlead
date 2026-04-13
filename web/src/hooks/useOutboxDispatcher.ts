import { useEffect, type MutableRefObject } from 'react'

import { apiRequest, isApiError } from '../lib/api'
import type { StatusTone } from '../types'
import { nextRetryDelayMs, type OutboxItem, type UpdateOutboxFn } from './useSessionOutbox'

type SessionSendResp = {
  ok?: boolean
  status?: string
  deduplicated?: boolean
  reply?: string | null
}

type UseOutboxDispatcherOptions = {
  controlAuth?: string
  hasSession: boolean
  outboxRef: MutableRefObject<OutboxItem[]>
  sessionStatus: string
  sessionInFlightRequestId: string
  updateOutbox: UpdateOutboxFn
  onStatusUpdate?: (tone: StatusTone, message: string) => void
}

const STALE_SENDING_RETRY_MS = 10_000
const STALE_PROCESSING_RETRY_MS = 15_000

function nowMs() {
  return Date.now()
}

function summarizeApiError(err: unknown): string {
  if (isApiError(err)) {
    if (err.errorCode) return `${err.status} ${err.errorCode}`
    return `${err.status} ${err.bodyText}`
  }
  return (err as Error).message
}

export function useOutboxDispatcher(options: UseOutboxDispatcherOptions) {
  const {
    controlAuth,
    hasSession,
    outboxRef,
    sessionStatus,
    sessionInFlightRequestId,
    updateOutbox,
    onStatusUpdate,
  } = options

  useEffect(() => {
    let cancelled = false
    let timer: number | null = null

    const loop = async () => {
      if (cancelled) return

      if (!hasSession) {
        timer = window.setTimeout(() => void loop(), 1200)
        return
      }

      const items = outboxRef.current.filter((item) => item.state !== 'completed')
      if (items.length === 0) {
        timer = window.setTimeout(() => void loop(), 1200)
        return
      }

      const now = nowMs()
      const ready = items.find((item) => {
        if (item.state === 'queued') return true
        if (item.state === 'retry_wait') return !item.nextRetryAt || item.nextRetryAt <= now
        if (item.state === 'sending') return now - item.updatedAt >= STALE_SENDING_RETRY_MS
        if (item.state === 'processing') {
          const stillInFlight = sessionStatus === 'processing' && sessionInFlightRequestId === item.requestId
          return !stillInFlight && now - item.updatedAt >= STALE_PROCESSING_RETRY_MS
        }
        return false
      })

      if (!ready) {
        timer = window.setTimeout(() => void loop(), 800)
        return
      }

      if (sessionStatus === 'processing' && sessionInFlightRequestId && sessionInFlightRequestId !== ready.requestId) {
        timer = window.setTimeout(() => void loop(), 900)
        return
      }

      updateOutbox(ready.requestId, (item) => ({
        ...item,
        state: 'sending',
        attempts: item.attempts + 1,
        nextRetryAt: undefined,
        lastError: undefined,
      }))

      try {
        const result = await apiRequest<SessionSendResp>('/sessions/current/message', controlAuth ?? null, {
          method: 'POST',
          headers: { 'X-Request-Id': ready.requestId },
          body: JSON.stringify({
            message: ready.text,
            request_id: ready.requestId,
          }),
        })

        if (cancelled) return

        const status = result.status ?? 'unknown'
        if (status === 'completed') {
          updateOutbox(ready.requestId, (item) => ({
            ...item,
            state: 'completed',
            nextRetryAt: undefined,
            lastError: undefined,
          }))
          onStatusUpdate?.('ok', result.deduplicated ? 'message already completed (deduplicated)' : 'message completed')
        } else if (status === 'processing') {
          updateOutbox(ready.requestId, (item) => ({
            ...item,
            state: 'processing',
            nextRetryAt: undefined,
            lastError: undefined,
          }))
          onStatusUpdate?.('idle', result.deduplicated ? 'message already processing (deduplicated)' : 'message accepted, processing')
        } else {
          const delay = nextRetryDelayMs(ready.attempts + 1)
          updateOutbox(ready.requestId, (item) => ({
            ...item,
            state: 'retry_wait',
            nextRetryAt: nowMs() + delay,
            lastError: `unexpected status=${status}`,
          }))
        }
      } catch (err) {
        if (cancelled) return

        if (isApiError(err) && err.status === 409 && err.errorCode === 'session_busy') {
          updateOutbox(ready.requestId, (item) => ({
            ...item,
            state: 'retry_wait',
            nextRetryAt: nowMs() + 1200,
            lastError: 'session busy',
          }))
          onStatusUpdate?.('warn', 'session busy, retry queued')
        } else if (isApiError(err) && err.status < 500) {
          // Client-side/session-state errors are usually deterministic; stop auto-retrying.
          updateOutbox(ready.requestId, (item) => ({
            ...item,
            state: 'failed',
            nextRetryAt: undefined,
            lastError: summarizeApiError(err),
          }))
          onStatusUpdate?.('warn', 'message failed, tap retry after session is ready')
        } else {
          const delay = nextRetryDelayMs(ready.attempts + 1)
          updateOutbox(ready.requestId, (item) => ({
            ...item,
            state: item.attempts >= 5 ? 'failed' : 'retry_wait',
            nextRetryAt: nowMs() + delay,
            lastError: summarizeApiError(err),
          }))
          onStatusUpdate?.('warn', 'network unstable, retrying queued message')
        }
      }

      if (!cancelled) timer = window.setTimeout(() => void loop(), 500)
    }

    timer = window.setTimeout(() => void loop(), 300)
    return () => {
      cancelled = true
      if (timer != null) window.clearTimeout(timer)
    }
  }, [controlAuth, hasSession, onStatusUpdate, outboxRef, sessionInFlightRequestId, sessionStatus, updateOutbox])
}
