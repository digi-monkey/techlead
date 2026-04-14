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
      className="w-full rounded-md border border-slate-200 bg-white p-3 text-left transition-colors hover:border-slate-300"
    >
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <h3 className="truncate text-sm font-semibold text-slate-800">
            {project.name === 'Unnamed Project' ? project.project_id : project.name}
          </h3>
          {project.name !== 'Unnamed Project' && (
            <p className="truncate text-xs text-slate-400">{project.project_id}</p>
          )}
        </div>
        <span className={`shrink-0 rounded-md px-2 py-0.5 text-[11px] ${statusColor}`}>
          {status}
        </span>
      </div>
      
      {project.description && (
        <p className="mt-2 line-clamp-2 text-xs leading-relaxed text-slate-500">{project.description}</p>
      )}
      
      <div className="mt-3 flex items-center gap-3 text-[11px] text-slate-500">
        <span>{project.task_count} tasks</span>
        {project.running_count > 0 && (
          <span className="text-emerald-600">{project.running_count} running</span>
        )}
      </div>
      
      {project.repository_url && (
        <div className="mt-2 text-[11px] text-slate-400">
          <span className="truncate">{project.repository_url.replace(/^https?:\/\//, '')}</span>
        </div>
      )}
    </button>
  )
}
