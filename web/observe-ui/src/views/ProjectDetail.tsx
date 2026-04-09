import { useCallback, useEffect, useState } from 'react'

import { formatProjectError, getProject, getTasks, type Project, type ProjectTask, type ProjectTaskListResult } from '../lib/projectsApi'

type ProjectDetailProps = {
  projectId: string
  observeAuth?: string
  onBack?: () => void
}

function formatUnixTs(ts: number): string {
  if (!Number.isFinite(ts) || ts <= 0) return '-'
  return new Date(ts * 1000).toLocaleString()
}

function statusBadgeClass(status: string): string {
  const classes: Record<string, string> = {
    running: 'bg-emerald-100 text-emerald-700',
    queued: 'bg-blue-100 text-blue-700',
    review: 'bg-amber-100 text-amber-700',
    done: 'bg-slate-100 text-slate-700',
    failed: 'bg-rose-100 text-rose-700',
    canceled: 'bg-slate-100 text-slate-500',
    claimed: 'bg-purple-100 text-purple-700',
  }
  return classes[status] || 'bg-slate-100 text-slate-600'
}

export function ProjectDetail({ projectId, observeAuth, onBack }: ProjectDetailProps) {
  const [project, setProject] = useState<Project | null>(null)
  const [tasksResult, setTasksResult] = useState<ProjectTaskListResult | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const fetchData = useCallback(async (silent: boolean) => {
    if (!silent) setLoading(true)
    try {
      const [projectData, tasksData] = await Promise.all([
        getProject(projectId, observeAuth),
        getTasks(projectId, observeAuth),
      ])
      setProject(projectData)
      setTasksResult(tasksData)
      setError('')
    } catch (err) {
      setError(formatProjectError(err, '加载项目详情失败'))
    } finally {
      if (!silent) setLoading(false)
    }
  }, [projectId, observeAuth])

  useEffect(() => {
    let cancelled = false
    let timer: number | null = null

    const loop = async (silent: boolean) => {
      await fetchData(silent)
      if (cancelled) return
      timer = window.setTimeout(() => {
        void loop(true)
      }, 5000)
    }

    void loop(false)

    return () => {
      cancelled = true
      if (timer !== null) window.clearTimeout(timer)
    }
  }, [fetchData])

  if (loading && !project) {
    return (
      <div className="flex h-full items-center justify-center">
        <div className="text-center">
          <div className="mx-auto mb-3 h-8 w-8 animate-spin rounded-full border-2 border-slate-200 border-t-slate-600"></div>
          <p className="text-sm text-slate-500">Loading project...</p>
        </div>
      </div>
    )
  }

  if (error && !project) {
    return (
      <div className="flex h-full items-center justify-center p-4">
        <div className="text-center">
          <p className="text-sm text-rose-600">{error}</p>
          {onBack && (
            <button
              type="button"
              onClick={onBack}
              className="mt-3 text-sm text-slate-600 hover:text-slate-800"
            >
              Go back
            </button>
          )}
        </div>
      </div>
    )
  }

  if (!project) {
    return (
      <div className="flex h-full items-center justify-center p-4">
        <div className="text-center">
          <p className="text-sm text-slate-500">Project not found</p>
          {onBack && (
            <button
              type="button"
              onClick={onBack}
              className="mt-3 text-sm text-slate-600 hover:text-slate-800"
            >
              Go back
            </button>
          )}
        </div>
      </div>
    )
  }

  const tasks = tasksResult?.tasks || []
  const summary = tasksResult?.summary || {}

  return (
    <div className="h-full overflow-y-auto px-2 py-4">
      <header className="mb-4">
        {onBack && (
          <button
            type="button"
            onClick={onBack}
            className="mb-2 flex items-center gap-1 text-xs text-slate-500 hover:text-slate-700"
          >
            <svg className="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
            </svg>
            Back
          </button>
        )}
        <div className="flex items-start justify-between gap-3">
          <div>
            <h1 className="text-lg font-semibold text-slate-800">
              {project.name === 'Unnamed Project' ? project.project_id : project.name}
            </h1>
            {project.name !== 'Unnamed Project' && (
              <p className="mt-0.5 text-xs text-slate-400">{project.project_id}</p>
            )}
            {project.description && (
              <p className="mt-1 text-sm text-slate-500">{project.description}</p>
            )}
          </div>
          <span className="shrink-0 rounded-md bg-slate-100 px-2 py-1 text-[11px] text-slate-600">
            {project.base_branch}
          </span>
        </div>
      </header>

      {error && (
        <div className="mb-4 rounded-lg border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">
          {error}
        </div>
      )}

      <section className="mb-4 grid grid-cols-3 gap-2">
        <div className="rounded-lg border border-slate-200 bg-white p-3">
          <p className="text-[11px] font-medium text-slate-500">Total</p>
          <p className="text-lg font-semibold text-slate-800">{project.task_count}</p>
        </div>
        <div className="rounded-lg border border-slate-200 bg-white p-3">
          <p className="text-[11px] font-medium text-slate-500">Running</p>
          <p className="text-lg font-semibold text-emerald-600">{project.running_count}</p>
        </div>
        <div className="rounded-lg border border-slate-200 bg-white p-3">
          <p className="text-[11px] font-medium text-slate-500">Completed</p>
          <p className="text-lg font-semibold text-slate-600">{project.completed_count}</p>
        </div>
      </section>

      {Object.keys(summary).length > 0 && (
        <section className="mb-4 rounded-lg border border-slate-100 bg-slate-50 p-3">
          <p className="mb-2 text-[11px] font-medium text-slate-500">Status Breakdown</p>
          <div className="flex flex-wrap gap-2">
            {Object.entries(summary).map(([status, count]) => (
              <span key={status} className="rounded bg-white px-2 py-1 text-[11px] text-slate-600">
                {status}: {count}
              </span>
            ))}
          </div>
        </section>
      )}

      {project.repository_url && (
        <section className="mb-4 rounded-lg border border-slate-200 bg-white p-3">
          <p className="text-[11px] font-medium text-slate-500">Repository</p>
          <a
            href={project.repository_url}
            target="_blank"
            rel="noopener noreferrer"
            className="mt-1 flex items-center gap-1 text-sm text-slate-700 hover:text-slate-900"
          >
            <svg className="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
              <path fillRule="evenodd" d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z" clipRule="evenodd" />
            </svg>
            {project.repository_url.replace(/^https?:\/\//, '')}
          </a>
        </section>
      )}

      <section>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-sm font-semibold text-slate-700">Tasks</h2>
          <span className="text-xs text-slate-500">{tasks.length} tasks</span>
        </div>

        {tasks.length === 0 ? (
          <div className="rounded-xl border border-dashed border-slate-300 bg-slate-50 p-8 text-center">
            <p className="text-sm text-slate-500">No tasks in this project yet.</p>
          </div>
        ) : (
          <div className="space-y-2">
            {tasks.map((task) => (
              <TaskRow key={task.task_id} task={task} />
            ))}
          </div>
        )}
      </section>
    </div>
  )
}

function TaskRow({ task }: { task: ProjectTask }) {
  return (
    <div className="flex items-center justify-between rounded-lg border border-slate-200 bg-white p-3">
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <h3 className="truncate text-sm font-medium text-slate-800">{task.title}</h3>
          <span className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] ${statusBadgeClass(task.status)}`}>
            {task.status}
          </span>
        </div>
        <div className="mt-1 flex items-center gap-3 text-[11px] text-slate-500">
          <span>Priority: {task.priority}</span>
          <span>Updated: {formatUnixTs(task.updated_at)}</span>
        </div>
      </div>
    </div>
  )
}
