import type { EventRow, JsonValue, StatusTone } from '../types'

export function newRequestId() {
  return `web-${Date.now()}-${Math.floor(Math.random() * 1e9)}`
}

export function toneClass(tone: StatusTone): string {
  if (tone === 'ok') return 'text-emerald-700 bg-emerald-50 border-emerald-200'
  if (tone === 'warn') return 'text-amber-700 bg-amber-50 border-amber-200'
  if (tone === 'bad') return 'text-rose-700 bg-rose-50 border-rose-200'
  return 'text-slate-600 bg-slate-50 border-slate-200'
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

export async function apiRequest<T>(path: string, token: string, options: RequestInit = {}): Promise<T> {
  if (!token) throw new Error('token missing')

  const headers = new Headers(options.headers ?? {})
  headers.set('Authorization', `Bearer ${token}`)
  if (options.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json')

  const resp = await fetch(path, { ...options, headers })
  const text = await resp.text()
  if (!resp.ok) throw new Error(`${resp.status} ${text}`)
  if (!text.trim()) return {} as T
  return JSON.parse(text) as T
}
