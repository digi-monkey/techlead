import type { ReactNode } from 'react'

type PanelProps = {
  title: string
  right?: ReactNode
  children: ReactNode
}

export function Panel({ title, right, children }: PanelProps) {
  return (
    <section className="tl-card flex h-full min-h-0 flex-col p-3">
      <header className="mb-2 flex items-center justify-between gap-3">
        <h3 className="m-0 min-w-0 flex-1 truncate text-sm font-semibold tracking-wide text-slate-800/95" title={title}>{title}</h3>
        {right}
      </header>
      <div className="min-h-0 flex-1">{children}</div>
    </section>
  )
}
