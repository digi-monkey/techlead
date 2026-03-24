import { useCallback, useEffect, useState } from 'react'

import { ProjectCard } from '../components/ProjectCard'
import { formatProjectError, getProjects, type Project } from '../lib/projectsApi'

type ProjectListProps = {
  observeAuth?: string
  onViewProject?: (projectId: string) => void
}

export function ProjectList({ observeAuth, onViewProject }: ProjectListProps) {
  const [projects, setProjects] = useState<Project[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')

  const fetchProjects = useCallback(async (silent: boolean) => {
    if (!silent) setLoading(true)
    try {
      const data = await getProjects(observeAuth)
      setProjects(data)
      setError('')
    } catch (err) {
      setError(formatProjectError(err, '加载项目列表失败'))
    } finally {
      if (!silent) setLoading(false)
    }
  }, [observeAuth])

  useEffect(() => {
    let cancelled = false
    let timer: number | null = null

    const loop = async (silent: boolean) => {
      await fetchProjects(silent)
      if (cancelled) return
      timer = window.setTimeout(() => {
        void loop(true)
      }, 10000)
    }

    void loop(false)

    return () => {
      cancelled = true
      if (timer !== null) window.clearTimeout(timer)
    }
  }, [fetchProjects])

  const filteredProjects = projects.filter((p) =>
    p.name.toLowerCase().includes(search.toLowerCase()) ||
    p.description.toLowerCase().includes(search.toLowerCase())
  )

  if (loading && projects.length === 0) {
    return (
      <div className="flex h-full items-center justify-center">
        <div className="text-center">
          <div className="mx-auto mb-3 h-8 w-8 animate-spin rounded-full border-2 border-slate-200 border-t-slate-600"></div>
          <p className="text-sm text-slate-500">Loading projects...</p>
        </div>
      </div>
    )
  }

  return (
    <div className="h-full overflow-y-auto px-2 py-4">
      <header className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-lg font-semibold text-slate-800">Projects</h1>
        <div className="flex items-center gap-2">
          <span className="text-xs text-slate-500">{projects.length} projects</span>
        </div>
      </header>

      {error && (
        <div className="mb-4 rounded-lg border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">
          {error}
        </div>
      )}

      <div className="mb-4">
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search projects..."
          className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm text-slate-700 outline-none focus:border-slate-500"
        />
      </div>

      {filteredProjects.length === 0 ? (
        <div className="rounded-xl border border-dashed border-slate-300 bg-slate-50 p-8 text-center">
          {search ? (
            <>
              <p className="text-sm text-slate-500">No projects match &quot;{search}&quot;</p>
              <button
                type="button"
                onClick={() => setSearch('')}
                className="mt-2 text-xs text-slate-600 hover:text-slate-800"
              >
                Clear search
              </button>
            </>
          ) : (
            <>
              <p className="text-sm text-slate-500">No projects yet.</p>
              <p className="mt-1 text-xs text-slate-400">Create your first project to get started.</p>
            </>
          )}
        </div>
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {filteredProjects.map((project) => (
            <ProjectCard
              key={project.project_id}
              project={project}
              onClick={() => onViewProject?.(project.project_id)}
            />
          ))}
        </div>
      )}
    </div>
  )
}
