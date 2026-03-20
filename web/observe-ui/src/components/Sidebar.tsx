import { ModeButton } from './ModeButton'
import { toneClass } from '../lib/api'
import { MODE_META, type Mode, type StatusTone } from '../types'

type SidebarProps = {
  mode: Mode
  onModeChange: (mode: Mode) => void
  statusText: string
  statusTone: StatusTone
  observeToken: string
  controlToken: string
  onObserveTokenChange: (token: string) => void
  onControlTokenChange: (token: string) => void
}

export function Sidebar(props: SidebarProps) {
  const {
    mode,
    onModeChange,
    statusText,
    statusTone,
    observeToken,
    controlToken,
    onObserveTokenChange,
    onControlTokenChange,
  } = props

  return (
    <aside className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
      <div className="mb-4">
        <div className="text-[11px] font-semibold uppercase tracking-[0.18em] text-slate-500">Techlead</div>
        <h1 className="mt-1 text-xl font-semibold text-slate-900">Remote Console</h1>
      </div>

      <div className={`mb-4 rounded-xl border px-3 py-2 text-xs ${toneClass(statusTone)}`}>
        <span className="font-semibold">Status</span>
        <div className="mt-1 break-all">{statusText}</div>
      </div>

      <div className="space-y-2">
        {(Object.keys(MODE_META) as Mode[]).map((k) => (
          <ModeButton
            key={k}
            active={mode === k}
            title={MODE_META[k].title}
            subtitle={MODE_META[k].subtitle}
            onClick={() => onModeChange(k)}
          />
        ))}
      </div>

      <div className="mt-4 space-y-3 border-t border-slate-200 pt-4">
        <label className="block text-xs font-medium text-slate-600">
          Observe Token
          <input
            className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm text-slate-900 outline-none focus:border-sky-400"
            value={observeToken}
            onChange={(e) => onObserveTokenChange(e.target.value.trim())}
            placeholder="observe token"
          />
        </label>
        <label className="block text-xs font-medium text-slate-600">
          Control Token
          <input
            className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm text-slate-900 outline-none focus:border-sky-400"
            value={controlToken}
            onChange={(e) => onControlTokenChange(e.target.value.trim())}
            placeholder="control token"
          />
        </label>
      </div>
    </aside>
  )
}
