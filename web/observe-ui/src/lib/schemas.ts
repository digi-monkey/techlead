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
  name: z.string(),
  description: z.string(),
  repository_url: z.string().nullable(),
  base_branch: z.string(),
  created_at: z.number(),
  updated_at: z.number(),
  task_count: z.number(),
  running_count: z.number(),
  completed_count: z.number(),
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
  project_id: z.string(),
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
  title: z.string(),
  detail: z.string(),
  severity: z.string(),
  file: z.string(),
  line: z.number().nullable(),
  evidence: z.string(),
  clean_code_rule: z.string(),
})

export type TaskReviewBlocker = z.infer<typeof TaskReviewBlockerSchema>

export const TaskReviewSummarySchema = z.object({
  role: z.enum(['correctness_reviewer', 'maintainability_reviewer', 'unknown']),
  verdict: z.enum(['approve', 'request_changes', 'block', 'unknown']),
  score: z.number().nullable(),
  summary: z.string(),
  blockers: z.array(TaskReviewBlockerSchema),
  suggestions: z.array(z.string()),
  confidence: z.number().nullable(),
})

export type TaskReviewSummary = z.infer<typeof TaskReviewSummarySchema>

export const TaskPoolTaskSchema = z.object({
  task_id: z.string(),
  title: z.string(),
  prompt: z.string(),
  status: z.enum(['queued', 'running', 'review', 'done', 'failed', 'canceled', 'claimed', 'unknown']),
  review_stage: z.enum(['none', 'open', 'changes_requested', 'approved', 'merged', 'unknown']),
  review_round: z.number(),
  priority: z.number(),
  max_retries: z.number().nullable(),
  retry_count: z.number(),
  version: z.number(),
  created_at: z.number(),
  updated_at: z.number(),
  base_branch: z.string(),
  head_branch: z.string(),
  head_sha: z.string(),
  merge_commit: z.string(),
  review_feedback: z.string(),
  last_error: z.string(),
  latest_reviews: z.array(TaskReviewSummarySchema),
})

export type TaskPoolTask = z.infer<typeof TaskPoolTaskSchema>

export const TaskPoolEventSchema = z.object({
  id: z.number(),
  task_id: z.string(),
  run_id: z.string(),
  event_type: z.string(),
  payload_text: z.string(),
  payload_json: z.any().nullable(),
  operator: z.string(),
  source: z.string(),
  request_id: z.string(),
  created_at: z.number(),
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
  task: TaskPoolTaskSchema.nullable(),
  events: z.array(TaskPoolEventSchema),
})

export type TaskPoolDetailResult = z.infer<typeof TaskPoolDetailResultSchema>

export const TaskPoolEventsResultSchema = z.object({
  events: z.array(TaskPoolEventSchema),
  last_event_id: z.number(),
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
