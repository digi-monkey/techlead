import { useState } from 'react'
import { draftTask, createTask } from '../lib/taskPoolApi'

// Use lucid react icons if available, else emojis
export function CreateTaskModal({
  projectId,
  token,
  onClose,
  onSuccess,
}: {
  projectId: string
  token?: string
  onClose: () => void
  onSuccess: () => void
}) {
  const [intent, setIntent] = useState('')
  const [provider, setProvider] = useState('opencode')
  
  const [title, setTitle] = useState('')
  const [prompt, setPrompt] = useState('')
  const [maxRetries, setMaxRetries] = useState(3)

  const [drafting, setDrafting] = useState(false)
  const [creating, setCreating] = useState(false)
  const [error, setError] = useState('')

  const handleDraft = async () => {
    if (!intent.trim()) {
      setError('Please enter an intent first')
      return
    }
    setDrafting(true)
    setError('')
    try {
      const res = await draftTask({
        projectId,
        intent,
        provider: provider.trim() || undefined,
        token,
      })
      if (res.ok && res.draft) {
        setTitle(res.draft.title)
        setPrompt(res.draft.prompt)
      } else {
        setError('Failed to draft task')
      }
    } catch (err: any) {
      setError(err?.message || 'Error drafting task')
    } finally {
      setDrafting(false)
    }
  }

  const handleCreate = async () => {
    if (!title.trim() || !prompt.trim()) {
      setError('Title and prompt are required')
      return
    }
    setCreating(true)
    setError('')
    try {
      const res = await createTask({
        projectId,
        title,
        prompt,
        max_retries: maxRetries,
        token,
      })
      if (res.ok) {
        onSuccess()
      } else {
        setError('Failed to create task')
      }
    } catch (err: any) {
      setError(err?.message || 'Error creating task')
    } finally {
      setCreating(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm p-4">
      <div className="w-full max-w-2xl rounded-2xl bg-white shadow-2xl p-6 relative flex flex-col max-h-[90vh]">
        
        <header className="flex items-center justify-between mb-4 shrink-0">
          <h2 className="text-lg font-semibold text-slate-800">Create New Task</h2>
          <button 
            onClick={onClose}
            className="text-slate-400 hover:text-slate-600 rounded-full p-1 transition"
          >
            ✕
          </button>
        </header>

        {error && (
          <div className="mb-4 rounded-lg bg-red-50 p-3 text-sm text-red-600 shrink-0 border border-red-100">
            {error}
          </div>
        )}

        <div className="flex-1 overflow-y-auto pr-2 space-y-6">
          {/* Smart Draft Area */}
          <section className="rounded-xl border border-blue-100 bg-blue-50/50 p-4 relative overflow-hidden">
            <div className="absolute top-0 right-0 p-2 opacity-10">✨</div>
            <div className="flex flex-col gap-3 relative z-10">
              <label className="text-sm font-medium text-slate-700">🔮 Smart Draft</label>
              <textarea
                className="w-full rounded-lg border border-blue-200 bg-white p-3 text-sm outline-none focus:border-blue-500 focus:ring-1 focus:ring-blue-500 min-h-[80px]"
                placeholder="E.g., Implement a quick sort algorithm in utils.js..."
                value={intent}
                onChange={(e) => setIntent(e.target.value)}
              />
              <div className="flex items-center gap-3">
                <div className="flex bg-white rounded-lg border border-blue-200 p-1">
                  {['opencode', 'codex', 'claude'].map(p => (
                    <button
                      key={p}
                      onClick={() => setProvider(p)}
                      className={`px-3 py-1.5 text-xs font-medium rounded-md transition ${
                        provider === p
                          ? 'bg-blue-100 text-blue-700 shadow-sm'
                          : 'text-slate-500 hover:text-slate-700 hover:bg-slate-50'
                      }`}
                    >
                      {p}
                    </button>
                  ))}
                </div>
                <button
                  onClick={handleDraft}
                  disabled={drafting || !intent.trim()}
                  className="flex items-center gap-2 rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-blue-700 disabled:opacity-50 transition ml-auto"
                >
                  {drafting ? (
                    <span className="animate-spin text-lg">⚙️</span>
                  ) : '✨ Generate Detailed Task'}
                </button>
              </div>
            </div>
          </section>

          {/* Form Area */}
          <section className="space-y-4">
            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">Title</label>
              <input
                type="text"
                className="w-full rounded-lg border border-slate-200 bg-slate-50 p-3 text-sm outline-none focus:border-blue-500 focus:bg-white transition"
                placeholder="Task title..."
                value={title}
                onChange={(e) => setTitle(e.target.value)}
              />
            </div>

            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">Prompt (Task Details)</label>
              <textarea
                className="w-full rounded-lg border border-slate-200 bg-slate-50 p-3 text-sm outline-none focus:border-blue-500 focus:bg-white transition min-h-[160px] font-mono"
                placeholder="Detailed instructions for the AI..."
                value={prompt}
                onChange={(e) => setPrompt(e.target.value)}
              />
            </div>

            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">Max Retries</label>
              <input
                type="number"
                min="0"
                max="10"
                className="w-32 rounded-lg border border-slate-200 bg-slate-50 p-2 text-sm outline-none focus:border-blue-500 focus:bg-white transition"
                value={maxRetries}
                onChange={(e) => setMaxRetries(parseInt(e.target.value) || 0)}
              />
            </div>
          </section>
        </div>

        <footer className="mt-6 flex items-center justify-end gap-3 shrink-0 pt-4 border-t border-slate-100">
          <button
            onClick={onClose}
            className="rounded-lg px-4 py-2 text-sm font-medium text-slate-600 hover:bg-slate-100 transition"
          >
            Cancel
          </button>
          <button
            onClick={handleCreate}
            disabled={creating || !title.trim() || !prompt.trim()}
            className="rounded-lg bg-slate-800 px-5 py-2 text-sm font-medium text-white shadow hover:bg-slate-900 disabled:opacity-50 transition"
          >
            {creating ? 'Creating...' : 'Create Task'}
          </button>
        </footer>
      </div>
    </div>
  )
}
