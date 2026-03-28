#!/usr/bin/env bash
# =============================================================================
# Mock acpx agent for E2E testing
# Simulates: acpx <agent> exec --approve-all --file <prompt_file>
# Reads the prompt file and produces a deterministic "improvement" output.
# Place this on PATH (or symlink as 'acpx') before running E2E tests.
# =============================================================================
set -euo pipefail

AGENT="${1:-unknown}"
shift || true

ACTION=""
FILE=""
APPROVE_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        exec)   ACTION="exec"; shift ;;
        --approve-all) APPROVE_ALL=true; shift ;;
        --file) FILE="$2"; shift 2 ;;
        *)      shift ;;
    esac
done

if [[ "$ACTION" != "exec" ]]; then
    echo "mock_acpx: unsupported action '$ACTION'" >&2
    exit 1
fi

if [[ -z "$FILE" ]]; then
    echo "mock_acpx: --file is required" >&2
    exit 1
fi

if [[ ! -f "$FILE" ]]; then
    echo "mock_acpx: prompt file not found: $FILE" >&2
    exit 1
fi

# Read the prompt file to simulate understanding
PROMPT_CONTENT=$(cat "$FILE")
PROMPT_LEN=${#PROMPT_CONTENT}

echo "[$AGENT] mock execution started"
echo "[$AGENT] prompt length: $PROMPT_LEN chars"
echo "[$AGENT] approve_all: $APPROVE_ALL"

# Simulate work: create a small commit if we're in a git repo
if git rev-parse --is-inside-work-tree &>/dev/null; then
    MOCK_FILE=".techlead/mock-output-$(date +%s).txt"
    mkdir -p "$(dirname "$MOCK_FILE")"
    echo "Mock improvement by $AGENT at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MOCK_FILE"
    echo "Prompt hash: $(echo "$PROMPT_CONTENT" | shasum -a 256 | cut -c1-16)" >> "$MOCK_FILE"
    git add "$MOCK_FILE" 2>/dev/null || true
    git commit -m "mock: $AGENT iteration output" --allow-empty 2>/dev/null || true
    echo "[$AGENT] committed mock improvement"
fi

echo "[$AGENT] mock execution completed successfully"
exit 0
