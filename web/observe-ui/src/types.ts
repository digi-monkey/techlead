export type StatusTone = 'ok' | 'warn' | 'bad' | 'idle'

export type JsonValue = Record<string, unknown>

export type EventRow = {
  id: number
  type: string
  source: string
  ts: number
  payload: string
}

export type SessionMessage = {
  id?: number
  role: string
  content: string
  ts?: number
  request_id?: string | null
  provider?: string
}
