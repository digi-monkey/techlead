import { useState } from 'react'
import { draftTask, createTask } from '../lib/taskPoolApi'

function errorMessage(err: unknown): string {
  if (err instanceof Error && err.message.trim().length > 0) return err.message
  return 'Unknown error'
}

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
    } catch (err) {
      setError(errorMessage(err) || 'Error drafting task')
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
    } catch (err) {
      setError(errorMessage(err) || 'Error creating task')
    } finally {
      setCreating(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-0 backdrop-blur-sm sm:items-center sm:p-4">
      <div className="relative flex h-[92dvh] max-h-[92dvh] w-full flex-col rounded-t-2xl border border-slate-200 bg-white p-4 shadow-2xl sm:h-auto sm:max-h-[90vh] sm:max-w-2xl sm:rounded-2xl sm:p-6">
        
        <header className="mb-4 flex items-center justify-between shrink-0">
          <h2 className="text-lg font-semibold text-slate-800">Create Task</h2>
          <button 
            onClick={onClose}
            className="tl-soft-btn rounded-full p-2 text-slate-500"
          >
            ✕
          </button>
        </header>

        {error && (
          <div className="mb-4 rounded-lg bg-red-50 p-3 text-sm text-red-600 shrink-0 border border-red-100">
            {error}
          </div>
        )}

        <div className="flex-1 space-y-6 overflow-y-auto pr-1 sm:pr-2">
          {/* Smart Draft Area */}
          <section className="rounded-xl border border-slate-200 bg-slate-50/70 p-4">
            <div className="flex flex-col gap-3">
              <label className="text-sm font-medium text-slate-700">Smart Draft</label>
              <textarea
                className="tl-textarea min-h-20"
                placeholder="E.g., Implement a quick sort algorithm in utils.js..."
                value={intent}
                onChange={(e) => setIntent(e.target.value)}
              />
              <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
                <div className="flex flex-wrap rounded-lg border border-slate-200 bg-white p-1">
                  {['opencode', 'codex', 'claude'].map(p => (
                    <button
                      key={p}
                      onClick={() => setProvider(p)}
                      className={`rounded-md px-3 py-2 text-xs font-medium transition ${
                        provider === p
                          ? 'bg-slate-900 text-white shadow-sm'
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
                  className="tl-primary-btn ml-auto flex h-10 items-center gap-2"
                >
                  {drafting ? (
                    <span className="animate-spin text-lg">◌</span>
                  ) : 'Generate Draft'}
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
                className="tl-input"
                placeholder="Task title..."
                value={title}
                onChange={(e) => setTitle(e.target.value)}
              />
            </div>

            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">Prompt (Task Details)</label>
              <textarea
                className="tl-textarea min-h-40 font-mono"
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
                className="tl-input sm:w-32"
                value={maxRetries}
                onChange={(e) => setMaxRetries(parseInt(e.target.value) || 0)}
              />
            </div>
          </section>
        </div>

        <footer className="mt-6 flex shrink-0 items-center justify-end gap-3 border-t border-slate-100 pt-4 pb-[env(safe-area-inset-bottom)]">
          <button
            onClick={onClose}
            className="tl-soft-btn h-10"
          >
            Cancel
          </button>
          <button
            onClick={handleCreate}
            disabled={creating || !title.trim() || !prompt.trim()}
            className="tl-primary-btn h-10 px-5 text-sm"
          >
            {creating ? 'Creating...' : 'Create Task'}
          </button>
        </footer>
      </div>
    </div>
  )
}
