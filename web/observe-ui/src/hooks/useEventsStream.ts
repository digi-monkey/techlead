import { useEffect, useRef, useState } from 'react'

import { apiRequest, toEventRows } from '../lib/api'
import type { EventRow } from '../types'

export function useEventsStream(observeAuth?: string) {
  const [events, setEvents] = useState<EventRow[]>([])
  const afterRef = useRef(0)

  useEffect(() => {
    let cancelled = false
    let timer: number | null = null

    const tick = async () => {
      try {
        const eventBody = await apiRequest<{ events?: unknown[]; last_event_id?: number }>(
          `/runs/current/events?after=${afterRef.current}`,
          observeAuth,
        )
        if (cancelled) return

        const rows = toEventRows(eventBody.events ?? [])
        if (rows.length > 0) {
          setEvents((prev) => prev.concat(rows).slice(-300))
        }

        if (typeof eventBody.last_event_id === 'number' && eventBody.last_event_id > afterRef.current) {
          afterRef.current = eventBody.last_event_id
        }
      } catch {
        // Keep event stream best-effort. Session state is the source of truth.
      }

      if (!cancelled) {
        timer = window.setTimeout(() => void tick(), 2500)
      }
    }

    timer = window.setTimeout(() => void tick(), 0)
    return () => {
      cancelled = true
      if (timer != null) window.clearTimeout(timer)
    }
  }, [observeAuth])

  return events
}
