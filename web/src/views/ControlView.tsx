import { Panel } from '../components/Panel'

type ControlViewProps = {
  runMode: 'optimize' | 'pool'
  askPrompt: string
  onRunModeChange: (mode: 'optimize' | 'pool') => void
  onAskPromptChange: (value: string) => void
  onStartRun: () => void
  onControlRun: (action: 'pause' | 'resume' | 'abort' | 'ask') => void
}

export function ControlView(props: ControlViewProps) {
  const {
    runMode,
    askPrompt,
    onRunModeChange,
    onAskPromptChange,
    onStartRun,
    onControlRun,
  } = props

  return (
    <div className="grid gap-4 xl:grid-cols-2">
      <Panel title="Run Bootstrap">
        <div className="flex flex-wrap items-center gap-2">
          <select
            className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm"
            value={runMode}
            onChange={(e) => onRunModeChange(e.target.value as 'optimize' | 'pool')}
          >
            <option value="optimize">optimize</option>
            <option value="pool">pool</option>
          </select>
          <button
            type="button"
            onClick={onStartRun}
            className="rounded-lg border border-sky-300 bg-sky-600 px-4 py-2 text-sm font-medium text-white hover:bg-sky-700"
          >
            Start Run
          </button>
        </div>
      </Panel>

      <Panel title="Run Actions">
        <div className="mb-3 flex flex-wrap gap-2">
          <button type="button" onClick={() => onControlRun('pause')} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm">
            Pause
          </button>
          <button type="button" onClick={() => onControlRun('resume')} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm">
            Resume
          </button>
          <button type="button" onClick={() => onControlRun('abort')} className="rounded-lg border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-700">
            Abort
          </button>
        </div>
        <div className="flex gap-2">
          <input
            className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm"
            value={askPrompt}
            onChange={(e) => onAskPromptChange(e.target.value)}
            placeholder="ask prompt"
          />
          <button
            type="button"
            onClick={() => onControlRun('ask')}
            className="rounded-lg border border-amber-300 bg-amber-100 px-3 py-2 text-sm text-amber-900"
          >
            Ask
          </button>
        </div>
      </Panel>
    </div>
  )
}
