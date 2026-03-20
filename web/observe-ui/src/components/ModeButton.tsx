type ModeButtonProps = {
  active: boolean
  title: string
  subtitle: string
  onClick: () => void
}

export function ModeButton({ active, title, subtitle, onClick }: ModeButtonProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`w-full rounded-xl border px-3 py-3 text-left transition ${
        active
          ? 'border-sky-300 bg-sky-50 text-sky-900'
          : 'border-slate-200 bg-white text-slate-700 hover:bg-slate-50'
      }`}
    >
      <div className="text-sm font-semibold">{title}</div>
      <div className="mt-1 text-xs text-slate-500">{subtitle}</div>
    </button>
  )
}
