import { useCallback, useEffect, useState } from 'react'

import { GlobalStats } from '../components/GlobalStats'
import { ProjectCard } from '../components/ProjectCard'
import { formatProjectError, getProjectSummary, getProjects, type Project, type ProjectSummary } from '../lib/projectsApi'

type GlobalDashboardProps = {
  observeAuth?: string
  onViewProject?: (projectId: string) => void
}

export function GlobalDashboard({ observeAuth, onViewProject }: GlobalDashboardProps) {
  const [projects, setProjects] = useState<Project[]>([])
  const [summary, setSummary] = useState<ProjectSummary | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const fetchData = useCallback(async (silent: boolean) => {
    if (!silent) setLoading(true)
    try {
      const [projectsData, summaryData] = await Promise.all([
        getProjects(observeAuth),
        getProjectSummary(observeAuth),
      ])
      setProjects(projectsData)
      setSummary(summaryData)
      setError('')
    } catch (err) {
      setError(formatProjectError(err, '加载数据失败'))
    } finally {
      if (!silent) setLoading(false)
    }
  }, [observeAuth])

  useEffect(() => {
    let cancelled = false
    let timer: number | null = null

    const loop = async (silent: boolean) => {
      await fetchData(silent)
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
  }, [fetchData])

  if (loading && projects.length === 0) {
    return (
      <div className="flex h-full items-center justify-center">
        <div className="text-center">
          <div className="mx-auto mb-3 h-8 w-8 animate-spin rounded-full border-2 border-slate-200 border-t-slate-600"></div>
          <p className="text-sm text-slate-500">Loading dashboard...</p>
        </div>
      </div>
    )
  }

  return (
    <div className="h-full overflow-y-auto px-2 py-4">
      <header className="mb-6">
        <h1 className="text-xl font-semibold text-slate-800">Techlead Multi-Project Dashboard</h1>
        <p className="mt-1 text-sm text-slate-500">Overview of all projects and tasks</p>
      </header>

      <section className="mb-6">
        <GlobalStats summary={summary} loading={loading && !summary} />
      </section>

      {error && (
        <div className="mb-4 rounded-lg border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">
          {error}
        </div>
      )}

      <section>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-sm font-semibold text-slate-700">Projects</h2>
          <span className="text-xs text-slate-500">{projects.length} total</span>
        </div>

        {projects.length === 0 ? (
          <div className="rounded-xl border border-dashed border-slate-300 bg-slate-50 p-8 text-center">
            <p className="text-sm text-slate-500">No projects yet.</p>
            <p className="mt-1 text-xs text-slate-400">Create your first project to get started.</p>
          </div>
        ) : (
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {projects.map((project) => (
              <ProjectCard
                key={project.project_id}
                project={project}
                onClick={() => onViewProject?.(project.project_id)}
              />
            ))}
          </div>
        )}
      </section>
    </div>
  )
}
