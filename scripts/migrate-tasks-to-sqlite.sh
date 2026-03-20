#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-.}"
TASKS_JSON="${TARGET_DIR}/.techlead/tasks.json"
TASKS_DB="${TARGET_DIR}/.techlead/tasks.sqlite3"

if [[ ! -f "${TASKS_JSON}" ]]; then
  echo "tasks.json not found: ${TASKS_JSON}" >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 command not found" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq command not found" >&2
  exit 1
fi

mkdir -p "${TARGET_DIR}/.techlead"

sqlite3 "${TASKS_DB}" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS tasks (
  task_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  prompt TEXT,
  status TEXT NOT NULL,
  lease_owner TEXT,
  lease_until INTEGER,
  retry_count INTEGER NOT NULL DEFAULT 0,
  max_retries INTEGER,
  priority INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  version INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS task_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL,
  run_id TEXT,
  event_type TEXT NOT NULL,
  payload TEXT NOT NULL,
  operator TEXT,
  source TEXT,
  request_id TEXT,
  created_at INTEGER NOT NULL
);
SQL

now_ts="$(date +%s)"

jq -c '.tasks[]' "${TASKS_JSON}" | while IFS= read -r row; do
  task_id="$(jq -r '.id' <<<"${row}")"
  title="$(jq -r '.title // ""' <<<"${row}")"
  prompt="$(jq -r '.prompt // empty' <<<"${row}")"
  status="$(jq -r '.status // "queued"' <<<"${row}")"
  lease_owner="$(jq -r '.lease_owner // empty' <<<"${row}")"
  lease_until="$(jq -r '.lease_until // empty' <<<"${row}")"
  retry_count="$(jq -r '.retry_count // 0' <<<"${row}")"
  max_retries="$(jq -r '.max_retries // empty' <<<"${row}")"

  sqlite3 "${TASKS_DB}" <<SQL
INSERT OR REPLACE INTO tasks(
  task_id,title,prompt,status,lease_owner,lease_until,retry_count,max_retries,priority,last_error,version,created_at,updated_at
) VALUES (
  '$(printf "%s" "${task_id}" | sed "s/'/''/g")',
  '$(printf "%s" "${title}" | sed "s/'/''/g")',
  $(if [[ -n "${prompt}" ]]; then printf "'%s'" "$(printf "%s" "${prompt}" | sed "s/'/''/g")"; else printf "NULL"; fi),
  '$(printf "%s" "${status}" | sed "s/'/''/g")',
  $(if [[ -n "${lease_owner}" ]]; then printf "'%s'" "$(printf "%s" "${lease_owner}" | sed "s/'/''/g")"; else printf "NULL"; fi),
  $(if [[ -n "${lease_until}" ]]; then printf "%s" "${lease_until}"; else printf "NULL"; fi),
  ${retry_count},
  $(if [[ -n "${max_retries}" ]]; then printf "%s" "${max_retries}"; else printf "NULL"; fi),
  0,
  NULL,
  1,
  ${now_ts},
  ${now_ts}
);
INSERT INTO task_events(task_id,event_type,payload,operator,source,created_at)
VALUES (
  '$(printf "%s" "${task_id}" | sed "s/'/''/g")',
  'task.migrated',
  '{"source":"tasks.json"}',
  'migration-script',
  'offline-migration',
  ${now_ts}
);
SQL
done

echo "migration complete: ${TASKS_JSON} -> ${TASKS_DB}"
echo "please backup and remove ${TASKS_JSON}"
