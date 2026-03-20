import { Panel } from '../components/Panel'
import type { TaskDetailResponse, TaskItem, TaskListResponse } from '../types'

type TasksViewProps = {
  list: TaskListResponse
  selectedTaskId: string | null
  detail: TaskDetailResponse | null
  statusFilter: string
  search: string
  createTitle: string
  createPrompt: string
  createPriority: string
  createMaxRetries: string
  editTitle: string
  editPrompt: string
  editPriority: string
  editMaxRetries: string
  onStatusFilterChange: (v: string) => void
  onSearchChange: (v: string) => void
  onSelectTask: (taskId: string) => void
  onRefresh: () => void
  onCreateTitleChange: (v: string) => void
  onCreatePromptChange: (v: string) => void
  onCreatePriorityChange: (v: string) => void
  onCreateMaxRetriesChange: (v: string) => void
  onCreateTask: () => void
  onEditTitleChange: (v: string) => void
  onEditPromptChange: (v: string) => void
  onEditPriorityChange: (v: string) => void
  onEditMaxRetriesChange: (v: string) => void
  onPatchTask: () => void
  onTaskAction: (action: 'requeue' | 'cancel' | 'resume' | 'force_fail') => void
}

const GROUPS: Array<{ key: string; label: string }> = [
  { key: 'queued', label: 'Queued' },
  { key: 'running', label: 'Running' },
  { key: 'failed', label: 'Failed' },
  { key: 'done', label: 'Done' },
]

function renderTaskBadge(status: string) {
  const cls =
    status === 'done'
      ? 'border-emerald-200 bg-emerald-50 text-emerald-700'
      : status === 'failed'
        ? 'border-rose-200 bg-rose-50 text-rose-700'
        : status === 'running' || status === 'claimed'
          ? 'border-sky-200 bg-sky-50 text-sky-700'
          : 'border-slate-200 bg-slate-50 text-slate-700'
  return <span className={`rounded-full border px-2 py-0.5 text-[11px] ${cls}`}>{status}</span>
}

function TaskRow({ task, active, onClick }: { task: TaskItem; active: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`w-full rounded-lg border p-2 text-left ${
        active ? 'border-sky-300 bg-sky-50' : 'border-slate-200 bg-white hover:border-slate-300'
      }`}
    >
      <div className="mb-1 flex items-center justify-between gap-2">
        <div className="truncate text-sm font-medium text-slate-900">{task.title}</div>
        {renderTaskBadge(task.status)}
      </div>
      <div className="text-xs text-slate-500">
        {task.task_id} · p{task.priority} · retry {task.retry_count}
      </div>
    </button>
  )
}

export function TasksView(props: TasksViewProps) {
  const {
    list,
    selectedTaskId,
    detail,
    statusFilter,
    search,
    createTitle,
    createPrompt,
    createPriority,
    createMaxRetries,
    editTitle,
    editPrompt,
    editPriority,
    editMaxRetries,
    onStatusFilterChange,
    onSearchChange,
    onSelectTask,
    onRefresh,
    onCreateTitleChange,
    onCreatePromptChange,
    onCreatePriorityChange,
    onCreateMaxRetriesChange,
    onCreateTask,
    onEditTitleChange,
    onEditPromptChange,
    onEditPriorityChange,
    onEditMaxRetriesChange,
    onPatchTask,
    onTaskAction,
  } = props

  return (
    <div className="grid gap-4 xl:grid-cols-[1.2fr_1.1fr_1fr]">
      <Panel
        title="Task List"
        right={
          <button type="button" onClick={onRefresh} className="rounded border border-slate-300 bg-white px-2 py-1 text-xs">
            Refresh
          </button>
        }
      >
        <div className="mb-2 flex gap-2">
          <select
            className="rounded-lg border border-slate-300 bg-white px-2 py-1 text-xs"
            value={statusFilter}
            onChange={(e) => onStatusFilterChange(e.target.value)}
          >
            <option value="">all</option>
            <option value="queued">queued</option>
            <option value="claimed">claimed</option>
            <option value="running">running</option>
            <option value="review">review</option>
            <option value="done">done</option>
            <option value="failed">failed</option>
            <option value="canceled">canceled</option>
          </select>
          <input
            className="w-full rounded-lg border border-slate-300 px-2 py-1 text-xs"
            placeholder="search title/prompt"
            value={search}
            onChange={(e) => onSearchChange(e.target.value)}
          />
        </div>

        <div className="space-y-3">
          {GROUPS.map((g) => {
            const groupTasks = list.tasks.filter((t) => t.status === g.key)
            if (statusFilter && g.key !== statusFilter) return null
            return (
              <section key={g.key}>
                <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-slate-500">
                  {g.label} ({groupTasks.length})
                </div>
                <div className="space-y-1.5">
                  {groupTasks.map((task) => (
                    <TaskRow
                      key={task.task_id}
                      task={task}
                      active={selectedTaskId === task.task_id}
                      onClick={() => onSelectTask(task.task_id)}
                    />
                  ))}
                </div>
              </section>
            )
          })}
        </div>
      </Panel>

      <Panel title="Task Detail">
        {!detail ? (
          <div className="rounded-lg border border-dashed border-slate-300 bg-slate-50 p-4 text-sm text-slate-500">select one task</div>
        ) : (
          <div className="space-y-3">
            <div className="rounded-lg border border-slate-200 bg-slate-50 p-2 text-xs text-slate-600">
              <div>ID: {detail.task.task_id}</div>
              <div>Status: {detail.task.status}</div>
              <div>Version: {detail.task.version}</div>
              <div>Retry: {detail.task.retry_count}</div>
              <div>Lease Owner: {detail.task.lease_owner ?? '-'}</div>
            </div>

            <div className="space-y-2">
              <input
                className="w-full rounded-lg border border-slate-300 px-2 py-1 text-xs"
                value={editTitle}
                onChange={(e) => onEditTitleChange(e.target.value)}
                placeholder="title"
              />
              <textarea
                className="h-24 w-full rounded-lg border border-slate-300 px-2 py-1 text-xs"
                value={editPrompt}
                onChange={(e) => onEditPromptChange(e.target.value)}
                placeholder="prompt"
              />
              <div className="flex gap-2">
                <input
                  className="w-1/2 rounded-lg border border-slate-300 px-2 py-1 text-xs"
                  value={editPriority}
                  onChange={(e) => onEditPriorityChange(e.target.value)}
                  placeholder="priority"
                />
                <input
                  className="w-1/2 rounded-lg border border-slate-300 px-2 py-1 text-xs"
                  value={editMaxRetries}
                  onChange={(e) => onEditMaxRetriesChange(e.target.value)}
                  placeholder="max_retries"
                />
              </div>
              <button
                type="button"
                onClick={onPatchTask}
                className="w-full rounded-lg border border-sky-300 bg-sky-600 px-3 py-1.5 text-xs font-medium text-white"
              >
                Save Edit
              </button>
            </div>

            <div className="grid grid-cols-2 gap-2">
              <button type="button" onClick={() => onTaskAction('requeue')} className="rounded border border-slate-300 bg-white px-2 py-1 text-xs">
                Requeue
              </button>
              <button type="button" onClick={() => onTaskAction('resume')} className="rounded border border-slate-300 bg-white px-2 py-1 text-xs">
                Resume
              </button>
              <button type="button" onClick={() => onTaskAction('cancel')} className="rounded border border-amber-300 bg-amber-50 px-2 py-1 text-xs text-amber-800">
                Cancel
              </button>
              <button type="button" onClick={() => onTaskAction('force_fail')} className="rounded border border-rose-300 bg-rose-50 px-2 py-1 text-xs text-rose-700">
                Force Fail
              </button>
            </div>

            <div>
              <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-slate-500">Recent Events</div>
              <div className="max-h-48 space-y-1 overflow-auto rounded-lg border border-slate-200 bg-slate-50 p-2">
                {detail.events.length === 0 ? (
                  <div className="text-xs text-slate-500">(no events)</div>
                ) : (
                  detail.events.map((evt) => (
                    <article key={evt.id} className="rounded border border-slate-200 bg-white p-2 text-xs">
                      <div className="mb-1 text-slate-500">
                        #{evt.id} · {evt.event_type} · {evt.created_at}
                      </div>
                      <pre className="overflow-auto text-[11px] text-slate-700">{JSON.stringify(evt.payload, null, 2)}</pre>
                    </article>
                  ))
                )}
              </div>
            </div>
          </div>
        )}
      </Panel>

      <Panel title="Create Task">
        <div className="space-y-2">
          <input
            className="w-full rounded-lg border border-slate-300 px-2 py-1 text-xs"
            placeholder="title"
            value={createTitle}
            onChange={(e) => onCreateTitleChange(e.target.value)}
          />
          <textarea
            className="h-32 w-full rounded-lg border border-slate-300 px-2 py-1 text-xs"
            placeholder="prompt"
            value={createPrompt}
            onChange={(e) => onCreatePromptChange(e.target.value)}
          />
          <div className="flex gap-2">
            <input
              className="w-1/2 rounded-lg border border-slate-300 px-2 py-1 text-xs"
              placeholder="priority"
              value={createPriority}
              onChange={(e) => onCreatePriorityChange(e.target.value)}
            />
            <input
              className="w-1/2 rounded-lg border border-slate-300 px-2 py-1 text-xs"
              placeholder="max_retries"
              value={createMaxRetries}
              onChange={(e) => onCreateMaxRetriesChange(e.target.value)}
            />
          </div>
          <button
            type="button"
            onClick={onCreateTask}
            className="w-full rounded-lg border border-emerald-300 bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white"
          >
            Create
          </button>
        </div>
      </Panel>
    </div>
  )
}
