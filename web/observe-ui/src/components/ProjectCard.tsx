import type { Project } from '../lib/projectsApi'

type ProjectCardProps = {
  project: Project
  onClick?: () => void
}

export function ProjectCard({ project, onClick }: ProjectCardProps) {
  const statusColors: Record<string, string> = {
    running: 'text-emerald-700 bg-emerald-50',
    completed: 'text-slate-600 bg-slate-100',
    failed: 'text-rose-700 bg-rose-50',
  }

  const status = project.running_count > 0 ? 'running' : project.completed_count > 0 ? 'completed' : 'idle'
  const statusColor = statusColors[status] || 'text-slate-600 bg-slate-100'

  return (
    <button
      type="button"
      onClick={onClick}
      className="w-full rounded-xl border border-slate-200 bg-white p-4 text-left transition-all hover:border-slate-300 hover:shadow-sm"
    >
      <div className="flex items-start justify-between gap-2">
        <h3 className="truncate text-sm font-semibold text-slate-800">{project.name}</h3>
        <span className={`shrink-0 rounded-md px-2 py-0.5 text-[11px] ${statusColor}`}>
          {status}
        </span>
      </div>
      
      {project.description && (
        <p className="mt-1 line-clamp-2 text-xs text-slate-500">{project.description}</p>
      )}
      
      <div className="mt-3 flex items-center gap-3 text-[11px] text-slate-500">
        <span className="flex items-center gap-1">
          <svg className="h-3.5 w-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2" />
          </svg>
          {project.task_count} tasks
        </span>
        {project.running_count > 0 && (
          <span className="flex items-center gap-1 text-emerald-600">
            <svg className="h-3.5 w-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z" />
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            {project.running_count} running
          </span>
        )}
      </div>
      
      {project.repository_url && (
        <div className="mt-2 flex items-center gap-1 text-[11px] text-slate-400">
          <svg className="h-3 w-3" fill="currentColor" viewBox="0 0 24 24">
            <path fillRule="evenodd" d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z" clipRule="evenodd" />
          </svg>
          <span className="truncate">{project.repository_url.replace(/^https?:\/\//, '')}</span>
        </div>
      )}
    </button>
  )
}
