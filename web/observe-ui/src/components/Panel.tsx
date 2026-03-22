import type { ReactNode } from 'react'

type PanelProps = {
  title: string
  right?: ReactNode
  children: ReactNode
}

export function Panel({ title, right, children }: PanelProps) {
  return (
    <section className="p-0">
      <header className="mb-3 flex flex-col items-start justify-between gap-2 sm:flex-row sm:items-center">
        <h3 className="m-0 text-sm font-semibold tracking-wide text-slate-800/95">{title}</h3>
        {right}
      </header>
      {children}
    </section>
  )
}
