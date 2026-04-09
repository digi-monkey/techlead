import { useEffect, useRef, useState, type MutableRefObject } from 'react'

import { apiRequest } from '../lib/api'
import type { OutboxItem } from './useSessionOutbox'
import type { JsonValue, SessionMessage } from '../types'

function useDeepMemo<T>(factory: () => T, deps: React.DependencyList): T {
  const ref = useRef<{ deps: React.DependencyList; value: T } | null>(null)
  const depsString = JSON.stringify(deps)

  if (ref.current === null || JSON.stringify(ref.current.deps) !== depsString) {
    ref.current = { deps, value: factory() }
  }

  return ref.current.value
}

export type SessionSyncState = {
  lastOkAt: number | null
  consecutiveErrors: number
}

type UseSessionPollingOptions = {
  observeAuth?: string
  outboxRef: MutableRefObject<OutboxItem[]>
  reconcileFromSessionState: (messages: SessionMessage[], inFlightRequestId: string, status: string) => void
  onRequireAuthorization?: () => void
  onRefreshError?: (message: string) => void
}

function nowMs() {
  return Date.now()
}

export function useSessionPolling(options: UseSessionPollingOptions) {
  const {
    observeAuth,
    outboxRef,
    reconcileFromSessionState,
    onRequireAuthorization,
    onRefreshError,
  } = options

  const [sessionState, setSessionState] = useState<JsonValue>({})
  const [sessionSync, setSessionSync] = useState<SessionSyncState>({
    lastOkAt: null,
    consecutiveErrors: 0,
  })

  const sessionStatus = String(sessionState.status ?? '')
  const sessionInFlightRequestId = typeof sessionState.in_flight_request_id === 'string' ? sessionState.in_flight_request_id : ''
  const sessionMessages = useDeepMemo(
    () => (Array.isArray(sessionState.messages) ? sessionState.messages : []) as SessionMessage[],
    [sessionState.messages],
  )

  const sessionStatusRef = useRef(sessionStatus)
  const sessionSyncRef = useRef<SessionSyncState>(sessionSync)

  useEffect(() => {
    sessionStatusRef.current = sessionStatus
  }, [sessionStatus])

  useEffect(() => {
    sessionSyncRef.current = sessionSync
  }, [sessionSync])

  useEffect(() => {
    let cancelled = false
    let timer: number | null = null
    let isVisible = !document.hidden

    const handleVisibilityChange = () => {
      isVisible = !document.hidden
    }

    document.addEventListener('visibilitychange', handleVisibilityChange)

    const poll = async () => {
      try {
        const resp = await apiRequest<JsonValue>('/sessions/current', observeAuth ?? null)
        if (cancelled) return

        setSessionState(resp)

        const messages = (Array.isArray(resp.messages) ? resp.messages : []) as SessionMessage[]
        const status = typeof resp.status === 'string' ? resp.status : ''
        const inFlight = typeof resp.in_flight_request_id === 'string' ? resp.in_flight_request_id : ''
        reconcileFromSessionState(messages, inFlight, status)

        const nextSync = {
          lastOkAt: nowMs(),
          consecutiveErrors: 0,
        }
        sessionSyncRef.current = nextSync
        setSessionSync(nextSync)
      } catch (err) {
        if (cancelled) return

        setSessionSync((prev) => {
          const nextSync = {
            lastOkAt: prev.lastOkAt,
            consecutiveErrors: prev.consecutiveErrors + 1,
          }
          sessionSyncRef.current = nextSync
          return nextSync
        })

        if (!observeAuth) {
          onRequireAuthorization?.()
        } else {
          onRefreshError?.(`refresh session failed: ${(err as Error).message}`)
        }
      }

      if (cancelled) return

      const hasPending = outboxRef.current.some((item) => item.state !== 'completed')
      const baseDelay = hasPending || sessionStatusRef.current === 'processing' ? 1200 : 2500
      const errMultiplier = Math.max(1, sessionSyncRef.current.consecutiveErrors)

      const visibleDelay = Math.min(20_000, baseDelay * errMultiplier)
      const backgroundDelay = Math.max(10_000, visibleDelay * 4)
      const delay = isVisible ? visibleDelay : backgroundDelay

      timer = window.setTimeout(() => void poll(), delay)
    }

    timer = window.setTimeout(() => void poll(), 0)
    return () => {
      cancelled = true
      document.removeEventListener('visibilitychange', handleVisibilityChange)
      if (timer != null) window.clearTimeout(timer)
    }
  }, [observeAuth, onRefreshError, onRequireAuthorization, outboxRef, reconcileFromSessionState])

  return {
    sessionState,
    sessionSync,
    sessionStatus,
    sessionInFlightRequestId,
    sessionMessages,
  }
}
