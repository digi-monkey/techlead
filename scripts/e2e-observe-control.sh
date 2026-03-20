#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TMP_DIR="$(mktemp -d /tmp/techlead-e2e.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

cp -R demo-topk "$TMP_DIR/project"
cd "$TMP_DIR/project"
git init >/dev/null 2>&1
git add .
git commit -m "baseline" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
zig build run -- init --dir "$TMP_DIR/project" "e2e observe/control" --force >/dev/null

mkdir -p "$TMP_DIR/project/.techlead/iteration-logs"
cat > "$TMP_DIR/project/.techlead/iteration-logs/events.jsonl" <<'EOF'
{"run_id":"r1","event_type":"boot"}
{"run_id":"r1","event_type":"ready"}
EOF

zig build run -- observe start --dir "$TMP_DIR/project" --host 127.0.0.1 --port 7810 >"$TMP_DIR/observe.log" 2>&1 &
OBS_PID=$!
trap 'kill $OBS_PID >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"' EXIT
sleep 1

OBS_TOKEN="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["observe_token"])' "$TMP_DIR/project/.techlead/observe_tokens.json")"
CTRL_TOKEN="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["control_token"])' "$TMP_DIR/project/.techlead/observe_tokens.json")"

curl -fsS --max-time 5 "http://127.0.0.1:7810/health" >/dev/null
curl -fsS --max-time 5 -H "Authorization: Bearer $OBS_TOKEN" "http://127.0.0.1:7810/runs/current/events?after=1" | grep -q '"event_id":2'
curl -fsS --max-time 5 -X POST -H "Authorization: Bearer $CTRL_TOKEN" -H "Content-Type: application/json" --data '{"action":"pause"}' "http://127.0.0.1:7810/runs/current/control" >/dev/null
grep -q '"action":"pause"' "$TMP_DIR/project/.techlead/control.json"

# Stop observe process before replay check to avoid command contention.
kill "$OBS_PID" >/dev/null 2>&1 || true

zig build >/dev/null
TRACE_OUT="$("$ROOT_DIR/zig-out/bin/techlead" trace show --dir "$TMP_DIR/project" 2>&1 || true)"
echo "$TRACE_OUT" | grep -q '"event_type":"boot"'

echo "[e2e] observe/control pipeline passed"
