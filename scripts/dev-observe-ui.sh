#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${1:-$ROOT_DIR/demo-topk}"

OBSERVE_HOST="${OBSERVE_HOST:-127.0.0.1}"
OBSERVE_PORT="${OBSERVE_PORT:-7788}"
UI_PORT="${UI_PORT:-5173}"
BACKEND_URL="${VITE_BACKEND_URL:-http://${OBSERVE_HOST}:${OBSERVE_PORT}}"
TOKENS_FILE="$TARGET_DIR/.techlead/observe_tokens.json"

if ! command -v zig >/dev/null 2>&1; then
  echo "[error] missing dependency: zig"
  exit 1
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "[error] missing dependency: pnpm"
  exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
  echo "[error] target dir not found: $TARGET_DIR"
  exit 1
fi

if [ ! -d "$TARGET_DIR/.techlead" ]; then
  echo "[error] missing $TARGET_DIR/.techlead"
  echo "run: zig build run -- init --dir \"$TARGET_DIR\" \"observe ui smoke\" --force"
  exit 1
fi

cleanup() {
  if [ -n "${OBSERVE_PID:-}" ] && kill -0 "$OBSERVE_PID" >/dev/null 2>&1; then
    kill "$OBSERVE_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

cd "$ROOT_DIR"
echo "[1/2] starting observe backend: http://${OBSERVE_HOST}:${OBSERVE_PORT}"
zig build run -- observe start --dir "$TARGET_DIR" --host "$OBSERVE_HOST" --port "$OBSERVE_PORT" &
OBSERVE_PID=$!
sleep 1

if ! kill -0 "$OBSERVE_PID" >/dev/null 2>&1; then
  echo "[error] observe backend exited early"
  exit 1
fi

TOKEN=""
if [ -f "$TOKENS_FILE" ] && command -v python3 >/dev/null 2>&1; then
  TOKEN="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["observe_token"])' "$TOKENS_FILE" 2>/dev/null || true)"
fi

echo "[2/2] starting frontend dev server on port ${UI_PORT}"
echo "frontend: http://127.0.0.1:${UI_PORT}"
echo "backend : ${BACKEND_URL}"
if [ -n "$TOKEN" ]; then
  echo "quick url: http://127.0.0.1:${UI_PORT}/?token=${TOKEN}"
fi
echo "stop all: Ctrl+C"

cd "$ROOT_DIR/web"
if [ ! -d node_modules ]; then
  pnpm install
fi
VITE_BACKEND_URL="$BACKEND_URL" pnpm dev --host 0.0.0.0 --port "$UI_PORT"
