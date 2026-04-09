import type { z } from 'zod'
import type { EventRow, JsonValue, StatusTone } from '../types'

export function newRequestId() {
  return `web-${Date.now()}-${Math.floor(Math.random() * 1e9)}`
}

export function toneClass(tone: StatusTone): string {
  if (tone === 'ok') return 'text-emerald-700 bg-emerald-50/90'
  if (tone === 'warn') return 'text-amber-700 bg-amber-50/90'
  if (tone === 'bad') return 'text-rose-700 bg-rose-50/90'
  return 'text-slate-600 bg-slate-100/90'
}

export function toEventRows(events: unknown[]): EventRow[] {
  return events
    .map((item) => {
      const rec = item as JsonValue
      const id = Number(rec.event_id ?? 0)
      const raw = typeof rec.event_jsonl === 'string' ? rec.event_jsonl : '{}'
      let parsed: JsonValue = {}
      try {
        parsed = JSON.parse(raw) as JsonValue
      } catch {
        parsed = { raw }
      }
      return {
        id,
        type: String(parsed.event_type ?? '-'),
        source: String(parsed.source ?? '-'),
        ts: Number(parsed.ts ?? 0),
        payload: JSON.stringify(parsed.payload ?? parsed.raw ?? parsed, null, 2),
      }
    })
    .filter((row) => Number.isFinite(row.id))
}

export class ApiError extends Error {
  status: number
  bodyText: string
  errorCode?: string

  constructor(status: number, bodyText: string, errorCode?: string) {
    super(`${status} ${bodyText}`)
    this.name = 'ApiError'
    this.status = status
    this.bodyText = bodyText
    this.errorCode = errorCode
  }
}

export function isApiError(err: unknown): err is ApiError {
  return err instanceof ApiError
}

export function getErrorMessage(err: unknown): string {
  if (err instanceof Error) {
    return err.message
  }
  return String(err)
}

export async function apiRequest<T>(
  path: string,
  token: string | null,
  options: RequestInit = {},
  schema?: z.ZodSchema<T>
): Promise<T> {
  const headers = new Headers(options.headers ?? {})
  if (token) headers.set('Authorization', `Bearer ${token}`)
  if (options.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json; charset=utf-8')
  if (!headers.has('Accept')) headers.set('Accept', 'application/json; charset=utf-8')

  const resp = await fetch(path, { ...options, headers, credentials: 'include' })
  const text = await resp.text()
  if (!resp.ok) {
    let errorCode: string | undefined
    try {
      const parsed = JSON.parse(text) as JsonValue
      const raw = parsed.error
      if (typeof raw === 'string' && raw.trim().length > 0) {
        errorCode = raw
      }
    } catch {
      // Keep raw body text in error.
    }
    throw new ApiError(resp.status, text, errorCode)
  }
  if (!text.trim()) return {} as T
  const parsed = JSON.parse(text)
  if (schema) {
    return schema.parse(parsed)
  }
  return parsed as T
}
