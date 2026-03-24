import type { ProjectSummary } from '../lib/projectsApi'

type GlobalStatsProps = {
  summary: ProjectSummary | null
  loading?: boolean
}

export function GlobalStats({ summary, loading }: GlobalStatsProps) {
  if (loading) {
    return (
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        {Array.from({ length: 4 }).map((_, i) => (
          <div key={i} className="animate-pulse rounded-xl bg-slate-100 p-4">
            <div className="h-4 w-16 rounded bg-slate-200"></div>
            <div className="mt-2 h-8 w-12 rounded bg-slate-200"></div>
          </div>
        ))}
      </div>
    )
  }

  if (!summary) {
    return null
  }

  const stats = [
    { label: 'Projects', value: summary.total_projects, color: 'text-slate-800' },
    { label: 'Total Tasks', value: summary.total_tasks, color: 'text-slate-800' },
    { label: 'Running', value: summary.running_tasks, color: 'text-emerald-600' },
    { label: 'Completed', value: summary.completed_tasks, color: 'text-slate-600' },
  ]

  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
      {stats.map((stat) => (
        <div
          key={stat.label}
          className="rounded-xl border border-slate-200 bg-white p-4 transition-shadow hover:shadow-sm"
        >
          <p className="text-xs font-medium text-slate-500">{stat.label}</p>
          <p className={`mt-1 text-2xl font-semibold ${stat.color}`}>{stat.value}</p>
        </div>
      ))}
    </div>
  )
}
