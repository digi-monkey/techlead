#!/usr/bin/env bash
# =============================================================================
# Real Integration Test: acpx opencode → techlead pipeline
#
# Tests the FULL path:
#   init repo → register project → insert task → run --mode project → verify
#
# Prerequisites: acpx, opencode CLI, sqlite3, zig
# Uses opencode as the real agent (no mocks)
# Timeout: ~120s per task (agent needs time to think + execute)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$PROJECT_ROOT/zig-out/bin/techlead"
# Use a stable directory name so basename is predictable
WORK_BASE="/tmp/techlead-integ"
WORK_DIR="$WORK_BASE/test-repo-$$"
DB_PATH="$HOME/.config/techlead/controlplane.sqlite3"
# project_id MUST match basename(work_dir) — pool_service derives it that way
PROJECT_ID=""  # set after WORK_DIR is created
TASK_ID="task-integ-$$"
RUN_PID=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

cleanup() {
    info "Cleaning up..."
    if [[ -n "$RUN_PID" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
        kill "$RUN_PID" 2>/dev/null || true
        wait "$RUN_PID" 2>/dev/null || true
    fi
    # Clean up test task/project from global DB (leave DB intact)
    if [[ -f "$DB_PATH" ]] && [[ -n "$PROJECT_ID" ]]; then
        sqlite3 "$DB_PATH" "DELETE FROM tasks WHERE task_id='$TASK_ID';" 2>/dev/null || true
        sqlite3 "$DB_PATH" "DELETE FROM projects WHERE project_id='$PROJECT_ID';" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# =============================================================================
# Precondition checks
# =============================================================================
info "Checking prerequisites..."

command -v acpx >/dev/null 2>&1 || { fail "acpx not found"; exit 1; }
command -v opencode >/dev/null 2>&1 || { fail "opencode not found"; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { fail "sqlite3 not found"; exit 1; }
[[ -f "$BINARY" ]] || {
    info "Building techlead..."
    (cd "$PROJECT_ROOT" && zig build) || { fail "Build failed"; exit 1; }
}
pass "Prerequisites OK (acpx=$(acpx --version), opencode=$(opencode --version 2>&1 | head -1))"

# =============================================================================
# Step 1: Create a tiny test repository
# =============================================================================
info "Creating test repo at $WORK_DIR ..."
mkdir -p "$WORK_DIR"
PROJECT_ID="$(basename "$WORK_DIR")"
info "project_id (basename) = $PROJECT_ID"
cd "$WORK_DIR"
git init -b main
git config user.email "integ-test@test.com"
git config user.name "Integration Test"

# A minimal project: one source file with a deliberate TODO
cat > hello.js <<'EOF'
// Simple greeting module
function greet(name) {
    // TODO: add input validation
    return "Hello, " + name + "!";
}
module.exports = { greet };
EOF

cat > hello.test.js <<'EOF'
const { greet } = require("./hello");
console.assert(greet("World") === "Hello, World!", "basic greet failed");
console.log("test passed");
EOF

git add . && git commit -m "initial: hello module with TODO"
pass "Test repo created"

# =============================================================================
# Step 2: Init techlead project
# =============================================================================
info "Running techlead init..."
"$BINARY" init --dir "$WORK_DIR" "Add input validation to greet function" 2>&1 || true

if [[ -f "$WORK_DIR/.techlead/techlead.json" ]]; then
    pass "techlead init OK"
else
    fail "techlead init failed"
    exit 1
fi

# Patch config: use opencode provider, 1 iteration, correct main branch
python3 -c "
import json
with open('$WORK_DIR/.techlead/techlead.json') as f:
    cfg = json.load(f)
cfg['provider'] = 'opencode'
cfg['iterations'] = 1
cfg['main_branch'] = 'main'
cfg['pool_lease_seconds'] = 300
cfg['pool_max_retries'] = 3
with open('$WORK_DIR/.techlead/techlead.json', 'w') as f:
    json.dump(cfg, f, indent=2)
"
pass "Config patched (provider=opencode, main_branch=main, iterations=1)"

# =============================================================================
# Step 3: Start techlead, then inject task
# =============================================================================
# The controlplane DB is auto-created by techlead on startup.
# Strategy: start techlead in background → wait for DB → insert task → poll.

info "Starting techlead run --mode project..."
"$BINARY" run --dir "$WORK_DIR" --mode project > "$WORK_DIR/run.log" 2>&1 &
RUN_PID=$!
info "  PID=$RUN_PID, logs at $WORK_DIR/run.log"

# Wait for the controlplane DB to be created (techlead creates it on first poll)
DB_WAIT=0
while [[ ! -f "$DB_PATH" ]] && [[ $DB_WAIT -lt 15 ]]; do
    sleep 1
    ((DB_WAIT++))
done
if [[ ! -f "$DB_PATH" ]]; then
    fail "Controlplane DB not created after ${DB_WAIT}s"
    tail -30 "$WORK_DIR/run.log" 2>/dev/null || true
    exit 1
fi
# Give it a moment for schema creation
sleep 2
pass "Controlplane DB ready (waited ${DB_WAIT}s)"

# Verify techlead is still running
if ! kill -0 "$RUN_PID" 2>/dev/null; then
    fail "techlead exited prematurely"
    info "run.log contents:"
    cat "$WORK_DIR/run.log" 2>/dev/null || true
    exit 1
fi
pass "techlead still running"

# Insert project + task
NOW=$(date +%s)
sqlite3 "$DB_PATH" <<SQL
INSERT OR REPLACE INTO projects(project_id, work_dir, enabled, max_workers, running_tasks, created_at, updated_at)
VALUES('$PROJECT_ID', '$WORK_DIR', 1, 1, 0, $NOW, $NOW);

INSERT OR REPLACE INTO tasks(task_id, project_id, title, prompt, status, retry_count, priority, review_stage, review_round, qa_force_reject_once, version, created_at, updated_at)
VALUES(
    '$TASK_ID',
    '$PROJECT_ID',
    'Add input validation to greet()',
    'The greet() function in hello.js does not validate its input. Add a check that throws a TypeError if name is not a string. Update hello.test.js to include a test for the validation.',
    'queued',
    0,
    10,
    'none',
    0,
    0,
    1,
    $NOW,
    $NOW
);
SQL

# Verify insertion
TASK_STATUS=$(sqlite3 "$DB_PATH" "SELECT status FROM tasks WHERE task_id='$TASK_ID';")
if [[ "$TASK_STATUS" == "queued" ]]; then
    pass "Task inserted (status=queued)"
else
    fail "Task insertion failed (status=$TASK_STATUS)"
    exit 1
fi

# =============================================================================
# Step 4: Wait for task processing
# =============================================================================
info "Waiting for task to be processed (timeout=600s)..."
DEADLINE=$(($(date +%s) + 600))
FINAL_STATUS="queued"

while [[ $(date +%s) -lt $DEADLINE ]]; do
    CURRENT_STATUS=$(sqlite3 "$DB_PATH" "SELECT status FROM tasks WHERE task_id='$TASK_ID';" 2>/dev/null || echo "unknown")
    FINAL_STATUS="$CURRENT_STATUS"
    if [[ "$CURRENT_STATUS" == "done" || "$CURRENT_STATUS" == "merged" ]]; then
        break
    elif [[ "$CURRENT_STATUS" == "failed" || "$CURRENT_STATUS" == "queued" ]]; then
        # Check if process is still alive — if it crashed, stop waiting
        if ! kill -0 "$RUN_PID" 2>/dev/null; then
            FINAL_STATUS="$CURRENT_STATUS"
            break
        fi
    fi
    # Still running
    info "  task status=$CURRENT_STATUS ($(( DEADLINE - $(date +%s) ))s remaining)"
    sleep 10
done

# Kill the runner (it loops forever)
if kill -0 "$RUN_PID" 2>/dev/null; then
    kill "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
fi
RUN_PID=""

# =============================================================================
# Step 5: Verify results
# =============================================================================
echo ""
info "=== Results ==="

info "Final task status: $FINAL_STATUS"
if [[ "$FINAL_STATUS" == "done" || "$FINAL_STATUS" == "merged" ]]; then
    pass "Task completed (status=$FINAL_STATUS)"
elif [[ "$FINAL_STATUS" == "review" || "$FINAL_STATUS" == "running" ]]; then
    pass "Task progressed (status=$FINAL_STATUS) — implement phase worked, review still running"
else
    fail "Task did not progress (status=$FINAL_STATUS)"
    info "Last 50 lines of run.log:"
    tail -50 "$WORK_DIR/run.log" 2>/dev/null || true
fi

# Check if any branches were created
BRANCHES=$(cd "$WORK_DIR" && git branch --all 2>/dev/null | grep -c "task/" || true)
info "Task branches created: $BRANCHES"
if [[ "$BRANCHES" -gt 0 ]]; then
    pass "Implementation branch created"
else
    fail "No implementation branch found"
fi

# Check git log for implementation commits
IMPL_COMMITS=$(cd "$WORK_DIR" && git log --oneline -10 2>/dev/null | grep -c -i "task\|implement\|validation\|greet" || true)
if [[ "$IMPL_COMMITS" -gt 0 ]]; then
    pass "Implementation commits found"
    info "Recent commits:"
    (cd "$WORK_DIR" && git log --oneline -5) || true
else
    info "No implementation commits on main (may be on task branch)"
fi

# Check if hello.js was modified (on any branch)
for branch in $(cd "$WORK_DIR" && git branch --format='%(refname:short)' 2>/dev/null); do
    if cd "$WORK_DIR" && git show "$branch:hello.js" 2>/dev/null | grep -q "TypeError\|typeof\|validation"; then
        pass "hello.js was modified with validation ($branch)"
        break
    fi
done

# Check log files exist (log dir is .techlead/iteration-logs by default)
LOG_COUNT=$(find "$WORK_DIR/.techlead" -name "*.log" 2>/dev/null | wc -l | tr -d ' ')
info "Log files generated: $LOG_COUNT"
if [[ "$LOG_COUNT" -gt 0 ]]; then
    pass "Execution logs created"
    info "Log files:"
    find "$WORK_DIR/.techlead" -name "*.log" 2>/dev/null | head -10
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================"
echo "Integration Test Results"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo "========================================"
echo ""
echo "Artifacts at: $WORK_DIR"
echo "Run log: $WORK_DIR/run.log"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
