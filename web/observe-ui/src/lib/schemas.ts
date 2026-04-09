import { z } from 'zod'

export const EventRowSchema = z.object({
  id: z.number(),
  type: z.string(),
  source: z.string(),
  ts: z.number(),
  payload: z.string(),
})

export type EventRow = z.infer<typeof EventRowSchema>

export const ProjectSchema = z.object({
  project_id: z.string(),
  name: z.string().catch('Unnamed Project').optional().transform(v => v || 'Unnamed Project'),
  description: z.string().catch('').optional().transform(v => v || ''),
  repository_url: z.string().nullable().catch(null),
  base_branch: z.string().catch('master').optional().transform(v => v || 'master'),
  created_at: z.number().catch(0),
  updated_at: z.number().catch(0),
  task_count: z.number().catch(0),
  running_count: z.number().catch(0),
  completed_count: z.number().catch(0),
})

export type Project = z.infer<typeof ProjectSchema>

export const ProjectSummarySchema = z.object({
  total_projects: z.number(),
  total_tasks: z.number(),
  running_tasks: z.number(),
  completed_tasks: z.number(),
  failed_tasks: z.number(),
})

export type ProjectSummary = z.infer<typeof ProjectSummarySchema>

export const ProjectTaskSchema = z.object({
  task_id: z.string(),
  project_id: z.string().catch('').optional().transform(v => v || ''),
  title: z.string(),
  prompt: z.string(),
  status: z.enum(['queued', 'running', 'review', 'done', 'failed', 'canceled', 'claimed']),
  review_stage: z.enum(['none', 'open', 'changes_requested', 'approved', 'merged']),
  priority: z.number(),
  created_at: z.number(),
  updated_at: z.number(),
})

export type ProjectTask = z.infer<typeof ProjectTaskSchema>

export const TaskPoolListSchema = z.object({
  tasks: z.array(ProjectTaskSchema),
  total: z.number(),
  summary: z.record(z.string(), z.number()),
})

export type TaskPoolList = z.infer<typeof TaskPoolListSchema>

export const ProjectTaskDetailSchema = ProjectTaskSchema.extend({
  head_branch: z.string(),
  head_sha: z.string(),
  base_branch: z.string(),
  merge_commit: z.string().nullable(),
  retry_count: z.number(),
  max_retries: z.number().nullable(),
  review_feedback: z.string(),
  last_error: z.string(),
})

export type ProjectTaskDetail = z.infer<typeof ProjectTaskDetailSchema>

export const SessionMessageSchema = z.object({
  id: z.number().optional(),
  role: z.string(),
  content: z.string(),
  ts: z.number().optional(),
  request_id: z.string().nullable().optional(),
  provider: z.string().optional(),
})

export type SessionMessage = z.infer<typeof SessionMessageSchema>

export const SessionStateSchema = z.object({
  status: z.string().optional(),
  in_flight_request_id: z.string().optional(),
  messages: z.array(SessionMessageSchema).optional(),
})

export type SessionState = z.infer<typeof SessionStateSchema>

export const CreateProjectSchema = z.object({
  name: z.string(),
  description: z.string().optional(),
  repository_url: z.string().optional(),
  base_branch: z.string().optional(),
})

export type CreateProjectData = z.infer<typeof CreateProjectSchema>

export const UpdateProjectSchema = CreateProjectSchema.partial()

export type UpdateProjectData = z.infer<typeof UpdateProjectSchema>

export const CreateTaskSchema = z.object({
  title: z.string(),
  prompt: z.string(),
  priority: z.number().optional(),
})

export type CreateTaskData = z.infer<typeof CreateTaskSchema>

export const TaskActionSchema = z.enum(['start', 'pause', 'resume', 'abort', 'ask', 'retry', 'cancel'])

export type TaskAction = z.infer<typeof TaskActionSchema>

export const TaskReviewBlockerSchema = z.object({
  title: z.string().catch(''),
  detail: z.string().catch(''),
  severity: z.string().catch(''),
  file: z.string().catch(''),
  line: z.number().nullable().catch(null),
  evidence: z.string().catch(''),
  clean_code_rule: z.string().catch(''),
})

export type TaskReviewBlocker = z.infer<typeof TaskReviewBlockerSchema>

export const TaskReviewSummarySchema = z.object({
  role: z.enum(['correctness_reviewer', 'maintainability_reviewer', 'unknown']).catch('unknown'),
  verdict: z.enum(['approve', 'request_changes', 'block', 'unknown']).catch('unknown'),
  score: z.number().nullable().catch(null),
  summary: z.string().catch(''),
  blockers: z.array(TaskReviewBlockerSchema).catch([]),
  suggestions: z.array(z.string()).catch([]),
  confidence: z.number().nullable().catch(null),
})

export type TaskReviewSummary = z.infer<typeof TaskReviewSummarySchema>

export const TaskPoolTaskSchema = z.object({
  task_id: z.string(),
  title: z.string().catch(''),
  prompt: z.string().catch(''),
  status: z.enum(['queued', 'running', 'review', 'done', 'failed', 'canceled', 'claimed', 'unknown']).catch('unknown'),
  review_stage: z.enum(['none', 'open', 'changes_requested', 'approved', 'merged', 'unknown']).catch('unknown'),
  review_round: z.number().catch(0),
  priority: z.number().catch(0),
  max_retries: z.number().nullable().catch(null),
  retry_count: z.number().catch(0),
  version: z.number().catch(0),
  created_at: z.number().catch(0),
  updated_at: z.number().catch(0),
  base_branch: z.string().nullable().catch(null).transform(v => v || ''),
  head_branch: z.string().nullable().catch(null).transform(v => v || ''),
  head_sha: z.string().nullable().catch(null).transform(v => v || ''),
  merge_commit: z.string().nullable().catch(null).transform(v => v || ''),
  review_feedback: z.string().nullable().catch(null).transform(v => v || ''),
  last_error: z.string().nullable().catch(null).transform(v => v || ''),
  latest_reviews: z.array(TaskReviewSummarySchema).nullable().catch([]).transform(v => v || []),
})

export type TaskPoolTask = z.infer<typeof TaskPoolTaskSchema>

export const TaskPoolEventSchema = z.object({
  id: z.number().catch(0),
  task_id: z.string().catch(''),
  run_id: z.string().nullable().catch(null).transform(v => v || ''),
  event_type: z.string().nullable().catch(null).transform(v => v || ''),
  payload_text: z.string().nullable().catch(null).transform(v => v || ''),
  payload_json: z.any().nullable().catch(null),
  operator: z.string().nullable().catch(null).transform(v => v || ''),
  source: z.string().nullable().catch(null).transform(v => v || ''),
  request_id: z.string().nullable().catch(null).transform(v => v || ''),
  created_at: z.number().catch(0),
})

export type TaskPoolEvent = z.infer<typeof TaskPoolEventSchema>

export const TaskPoolListResultSchema = z.object({
  tasks: z.array(TaskPoolTaskSchema),
  summary: z.record(z.string(), z.number()),
  cursor: z.number(),
  next_cursor: z.number().nullable(),
  limit: z.number(),
  total: z.number(),
})

export type TaskPoolListResult = z.infer<typeof TaskPoolListResultSchema>

export const TaskPoolDetailResultSchema = z.object({
  task: TaskPoolTaskSchema.nullable().catch(null),
  events: z.array(TaskPoolEventSchema).nullable().catch([]).transform(v => v || []),
})

export type TaskPoolDetailResult = z.infer<typeof TaskPoolDetailResultSchema>

export const TaskPoolEventsResultSchema = z.object({
  events: z.array(TaskPoolEventSchema).nullable().catch([]).transform(v => v || []),
  last_event_id: z.number().catch(0),
})

export type TaskPoolEventsResult = z.infer<typeof TaskPoolEventsResultSchema>

export const EventsStreamResponseSchema = z.object({
  events: z.array(z.unknown()).optional(),
  last_event_id: z.number().optional(),
})

export type EventsStreamResponse = z.infer<typeof EventsStreamResponseSchema>

export const SessionSyncStateSchema = z.object({
  lastOkAt: z.number().nullable(),
  consecutiveErrors: z.number(),
})

export type SessionSyncState = z.infer<typeof SessionSyncStateSchema>
