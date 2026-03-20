import type { ReactNode } from 'react'

type PanelProps = {
  title: string
  right?: ReactNode
  children: ReactNode
}

export function Panel({ title, right, children }: PanelProps) {
  return (
    <section className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
      <header className="mb-3 flex items-center justify-between gap-2">
        <h3 className="m-0 text-sm font-semibold tracking-wide text-slate-800">{title}</h3>
        {right}
      </header>
      {children}
    </section>
  )
}
