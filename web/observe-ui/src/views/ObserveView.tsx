import { Panel } from '../components/Panel'
import type { EventRow } from '../types'

type ObserveViewProps = {
  events: EventRow[]
  tasksRaw: string
}

export function ObserveView({ events, tasksRaw }: ObserveViewProps) {
  return (
    <div className="grid gap-4 xl:grid-cols-[2fr_1fr]">
      <Panel title="Events Stream" right={<span className="text-xs text-slate-500">last {events.length}</span>}>
        <div className="max-h-[68vh] space-y-2 overflow-auto rounded-xl bg-slate-50 p-2">
          {events.length === 0 ? (
            <div className="rounded-lg border border-dashed border-slate-300 bg-white p-4 text-sm text-slate-500">(no events)</div>
          ) : (
            events.map((evt) => (
              <article key={`${evt.id}-${evt.ts}`} className="rounded-lg border border-slate-200 bg-white p-3">
                <div className="mb-2 text-xs text-slate-500">
                  #{evt.id} · {evt.source} · {evt.type} · {evt.ts || '-'}
                </div>
                <pre className="max-h-40 overflow-auto text-xs leading-5 text-slate-800">{evt.payload}</pre>
              </article>
            ))
          )}
        </div>
      </Panel>

      <Panel title="Tasks Snapshot">
        <pre className="max-h-[68vh] overflow-auto rounded-xl bg-slate-50 p-3 text-xs leading-5 text-slate-800">{tasksRaw}</pre>
      </Panel>
    </div>
  )
}
