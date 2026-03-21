export type Mode = 'observe' | 'control' | 'tasks' | 'session'
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
}

export type TaskStatus = 'queued' | 'claimed' | 'running' | 'review' | 'done' | 'failed' | 'canceled'

export type TaskItem = {
  task_id: string
  title: string
  prompt: string | null
  status: TaskStatus
  lease_owner: string | null
  lease_until: number | null
  retry_count: number
  max_retries: number | null
  priority: number
  last_error: string | null
  version: number
  created_at: number
  updated_at: number
}

export type TaskListResponse = {
  tasks: TaskItem[]
  summary: Record<string, number>
  cursor: number
  next_cursor: number | null
  limit: number
  total: number
}

export type TaskEvent = {
  id: number
  task_id: string
  run_id: string | null
  event_type: string
  payload: unknown
  operator: string | null
  source: string | null
  request_id: string | null
  created_at: number
}

export type TaskDetailResponse = {
  task: TaskItem
  events: TaskEvent[]
}

export const MODE_META: Record<Mode, { title: string; subtitle: string }> = {
  observe: {
    title: 'Observe',
    subtitle: '事件流和任务状态',
  },
  control: {
    title: 'Control',
    subtitle: '运行控制和人工干预',
  },
  tasks: {
    title: 'Tasks',
    subtitle: '远程任务管理',
  },
  session: {
    title: 'Session',
    subtitle: '远程 agent 对话',
  },
}
