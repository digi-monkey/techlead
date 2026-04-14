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
            className="tl-select w-auto px-3 text-sm"
            value={runMode}
            onChange={(e) => onRunModeChange(e.target.value as 'optimize' | 'pool')}
          >
            <option value="optimize">optimize</option>
            <option value="pool">pool</option>
          </select>
          <button
            type="button"
            onClick={onStartRun}
            className="tl-primary-btn px-4 py-2 text-sm"
          >
            Start Run
          </button>
        </div>
      </Panel>

      <Panel title="Run Actions">
        <div className="mb-3 flex flex-wrap gap-2">
          <button type="button" onClick={() => onControlRun('pause')} className="tl-soft-btn px-3 py-2 text-sm">
            Pause
          </button>
          <button type="button" onClick={() => onControlRun('resume')} className="tl-soft-btn px-3 py-2 text-sm">
            Resume
          </button>
          <button type="button" onClick={() => onControlRun('abort')} className="tl-danger-btn px-3 py-2 text-sm">
            Abort
          </button>
        </div>
        <div className="flex gap-2">
          <input
            className="tl-input"
            value={askPrompt}
            onChange={(e) => onAskPromptChange(e.target.value)}
            placeholder="ask prompt"
          />
          <button
            type="button"
            onClick={() => onControlRun('ask')}
            className="tl-soft-btn px-3 py-2 text-sm"
          >
            Ask
          </button>
        </div>
      </Panel>
    </div>
  )
}
