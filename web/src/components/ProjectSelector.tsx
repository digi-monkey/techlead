import type { Project } from '../lib/projectsApi'

type ProjectSelectorProps = {
  projects: Project[]
  selectedId: string | null
  onSelect: (projectId: string) => void
  loading?: boolean
  disabled?: boolean
}

export function ProjectSelector({ projects, selectedId, onSelect, loading, disabled }: ProjectSelectorProps) {
  const selectedProject = projects.find((p) => p.project_id === selectedId)

  return (
    <div className="flex items-center gap-2">
      <div className="relative">
        <select
          value={selectedId || ''}
          onChange={(e) => onSelect(e.target.value)}
          disabled={loading || disabled || projects.length === 0}
          className="h-9 appearance-none rounded-lg border border-slate-300 bg-white pl-3 pr-10 text-sm text-slate-700 outline-none focus:border-slate-500 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {projects.length === 0 ? (
            <option value="">No projects</option>
          ) : (
            <>
              <option value="">Select a project...</option>
              {projects.map((project) => (
                <option key={project.project_id} value={project.project_id}>
                  {project.name}
                </option>
              ))}
            </>
          )}
        </select>
        <div className="pointer-events-none absolute inset-y-0 right-0 flex items-center px-2 text-slate-500">
          <svg className="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </div>
      </div>
      {loading && (
        <span className="text-xs text-slate-500">Loading...</span>
      )}
      {selectedProject && (
        <span className="text-xs text-slate-500">
          {selectedProject.task_count} tasks
        </span>
      )}
    </div>
  )
}
