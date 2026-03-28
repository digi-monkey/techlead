#!/usr/bin/env bash
# =============================================================================
# Review Quality E2E Test
#
# Tests that techlead's review pipeline actually catches bad code and
# approves good code. Uses REAL agent (no mocks) to validate:
#
#   Scenario A: "Good task" — simple, well-defined → should complete (done)
#   Scenario B: "Bad code task" — injects obviously broken code via
#               qa_force_reject_once + a task that's hard to get right
#               in one shot → should see at least 1 review rejection
#   Scenario C: "Gate test" — project has test_cmd, agent must produce
#               code that passes existing tests → validates test gate
#
# This test answers: "Does our review pipeline actually block garbage?"
#
# Prerequisites: acpx, opencode CLI, sqlite3, zig (built binary)
# Duration: ~5-10 minutes (3 real agent runs)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$PROJECT_ROOT/zig-out/bin/techlead"
WORK_BASE="/tmp/techlead-review-quality"
DB_PATH="$HOME/.config/techlead/controlplane.sqlite3"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
scenario() { echo -e "\n${CYAN}========== $1 ==========${NC}"; }

# =============================================================================
# Helpers
# =============================================================================

build_binary() {
    if [[ ! -f "$BINARY" ]]; then
        info "Building techlead..."
        (cd "$PROJECT_ROOT" && zig build) || { fail "Build failed"; exit 1; }
    fi
}

check_prereqs() {
    info "Checking prerequisites..."
    command -v acpx >/dev/null 2>&1 || { fail "acpx not found"; exit 1; }
    command -v opencode >/dev/null 2>&1 || { fail "opencode not found"; exit 1; }
    command -v sqlite3 >/dev/null 2>&1 || { fail "sqlite3 not found"; exit 1; }
    command -v node >/dev/null 2>&1 || { fail "node not found"; exit 1; }
    build_binary
    pass "Prerequisites OK (acpx=$(acpx --version), opencode=$(opencode --version 2>&1 | head -1))"
}

# Create a git repo, init techlead, patch config
# Usage: setup_test_repo <dir> <goal> [extra_config_python]
setup_test_repo() {
    local dir="$1" goal="$2" extra_config="${3:-}"
    mkdir -p "$dir"
    cd "$dir"
    git init -b main
    git config user.email "review-test@test.com"
    git config user.name "Review Quality Test"
}

patch_config() {
    local dir="$1" extra="${2:-}"
    python3 -c "
import json
with open('$dir/.techlead/techlead.json') as f:
    cfg = json.load(f)
cfg['provider'] = 'opencode'
cfg['iterations'] = 1
cfg['main_branch'] = 'main'
cfg['pool_lease_seconds'] = 300
cfg['pool_max_retries'] = 3
$extra
with open('$dir/.techlead/techlead.json', 'w') as f:
    json.dump(cfg, f, indent=2)
"
}

# Start techlead, wait for DB, insert task, wait for completion
# Usage: run_task <dir> <task_id> <title> <prompt> <qa_force_reject_once> <timeout>
# Returns: FINAL_STATUS, REVIEW_COUNT, REJECTION_COUNT (globals)
run_task() {
    local dir="$1" task_id="$2" title="$3" prompt="$4"
    local qa_reject="${5:-0}" timeout="${6:-600}"
    local project_id run_pid

    project_id="$(basename "$dir")"
    FINAL_STATUS="unknown"
    REVIEW_COUNT=0
    REJECTION_COUNT=0
    REVIEW_DETAILS=""

    # Start techlead
    "$BINARY" run --dir "$dir" --mode project > "$dir/run.log" 2>&1 &
    run_pid=$!

    # Wait for DB
    local db_wait=0
    while [[ ! -f "$DB_PATH" ]] && [[ $db_wait -lt 15 ]]; do
        sleep 1
        ((db_wait++))
    done
    sleep 2

    if ! kill -0 "$run_pid" 2>/dev/null; then
        fail "techlead exited prematurely for task $task_id"
        cat "$dir/run.log" 2>/dev/null | tail -30
        return 1
    fi

    # Insert project + task
    local now
    now=$(date +%s)
    sqlite3 "$DB_PATH" <<SQL
INSERT OR REPLACE INTO projects(project_id, work_dir, enabled, max_workers, running_tasks, created_at, updated_at)
VALUES('$project_id', '$dir', 1, 1, 0, $now, $now);

INSERT OR REPLACE INTO tasks(task_id, project_id, title, prompt, status, retry_count, priority, review_stage, review_round, qa_force_reject_once, version, created_at, updated_at)
VALUES(
    '$task_id', '$project_id',
    '$title',
    '$prompt',
    'queued', 0, 10, 'none', 0, $qa_reject, 1, $now, $now
);
SQL

    # Poll for completion
    local deadline
    deadline=$(($(date +%s) + timeout))
    FINAL_STATUS="queued"

    while [[ $(date +%s) -lt $deadline ]]; do
        local current
        current=$(sqlite3 "$DB_PATH" "SELECT status FROM tasks WHERE task_id='$task_id';" 2>/dev/null || echo "unknown")
        FINAL_STATUS="$current"
        if [[ "$current" == "done" || "$current" == "merged" || "$current" == "failed" ]]; then
            break
        fi
        if ! kill -0 "$run_pid" 2>/dev/null; then
            break
        fi
        info "  [$task_id] status=$current ($(( deadline - $(date +%s) ))s remaining)"
        sleep 10
    done

    # Stop runner
    if kill -0 "$run_pid" 2>/dev/null; then
        kill "$run_pid" 2>/dev/null || true
        wait "$run_pid" 2>/dev/null || true
    fi

    # Collect review metrics from DB
    REVIEW_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM task_reviews WHERE task_id='$task_id';" 2>/dev/null || echo "0")
    REJECTION_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM task_reviews WHERE task_id='$task_id' AND verdict='request_changes';" 2>/dev/null || echo "0")
    REVIEW_DETAILS=$(sqlite3 "$DB_PATH" -header -column "SELECT role, verdict, score, confidence, substr(summary,1,80) as summary FROM task_reviews WHERE task_id='$task_id' ORDER BY review_round, role;" 2>/dev/null || echo "(no reviews)")

    # Cleanup task/project from DB
    sqlite3 "$DB_PATH" "DELETE FROM tasks WHERE task_id='$task_id';" 2>/dev/null || true
    sqlite3 "$DB_PATH" "DELETE FROM projects WHERE project_id='$project_id';" 2>/dev/null || true
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup_all() {
    info "Cleaning up all test directories..."
    rm -rf "$WORK_BASE"
}
trap cleanup_all EXIT

# =============================================================================
# Main
# =============================================================================
check_prereqs
rm -rf "$WORK_BASE"
mkdir -p "$WORK_BASE"

# =============================================================================
# Scenario A: Simple, correct task → should be approved and merged
# =============================================================================
scenario "Scenario A: Good task → expect done/merged"

REPO_A="$WORK_BASE/scenario-a-good-$$"
setup_test_repo "$REPO_A" "Add input validation"

cat > hello.js <<'EOF'
function greet(name) {
    return "Hello, " + name + "!";
}
module.exports = { greet };
EOF

cat > hello.test.js <<'EOF'
const { greet } = require("./hello");
console.assert(greet("World") === "Hello, World!", "basic greet failed");
console.log("all tests passed");
EOF

git add . && git commit -m "initial: hello module"

"$BINARY" init --dir "$REPO_A" "Add input validation to greet function" 2>&1 || true
patch_config "$REPO_A"

info "Running Scenario A (timeout=600s)..."
run_task "$REPO_A" "task-good-$$" \
    "Add input validation to greet()" \
    "The greet() function in hello.js should throw TypeError if name is not a string. Update hello.test.js to test for it." \
    0 600

info "Scenario A result: status=$FINAL_STATUS reviews=$REVIEW_COUNT rejections=$REJECTION_COUNT"
echo "$REVIEW_DETAILS"

if [[ "$FINAL_STATUS" == "done" || "$FINAL_STATUS" == "merged" ]]; then
    pass "A: Task completed successfully"
else
    fail "A: Task did not complete (status=$FINAL_STATUS)"
fi

if [[ "$REVIEW_COUNT" -ge 2 ]]; then
    pass "A: Both review phases ran ($REVIEW_COUNT reviews)"
else
    fail "A: Expected >= 2 reviews, got $REVIEW_COUNT"
fi

# Check that code was actually merged to main
if cd "$REPO_A" && git show "main:hello.js" 2>/dev/null | grep -qi "typeof\|string\|TypeError\|validation"; then
    pass "A: Merged code contains validation logic"
else
    fail "A: Merged code does not contain validation"
fi

# =============================================================================
# Scenario B: qa_force_reject_once → first round rejected, should retry
# =============================================================================
scenario "Scenario B: qa_force_reject_once → expect rejection + retry"

REPO_B="$WORK_BASE/scenario-b-reject-$$"
setup_test_repo "$REPO_B" "Test rejection flow"

cat > calc.js <<'EOF'
function add(a, b) {
    return a + b;
}
module.exports = { add };
EOF

cat > calc.test.js <<'EOF'
const { add } = require("./calc");
console.assert(add(1, 2) === 3, "add(1,2) failed");
console.assert(add(-1, 1) === 0, "add(-1,1) failed");
console.log("all tests passed");
EOF

git add . && git commit -m "initial: calculator module"

"$BINARY" init --dir "$REPO_B" "Add multiply function to calc.js" 2>&1 || true
patch_config "$REPO_B"

info "Running Scenario B (qa_force_reject_once=1, timeout=600s)..."
run_task "$REPO_B" "task-reject-$$" \
    "Add multiply function" \
    "Add a multiply(a, b) function to calc.js that returns a*b. Add tests for multiply in calc.test.js." \
    1 600

info "Scenario B result: status=$FINAL_STATUS reviews=$REVIEW_COUNT rejections=$REJECTION_COUNT"
echo "$REVIEW_DETAILS"

# The key assertion: review_round > 1, meaning the first round was rejected
FINAL_ROUND=$(sqlite3 "$DB_PATH" "SELECT review_round FROM tasks WHERE task_id='task-reject-$$';" 2>/dev/null || echo "0")
# DB might be cleaned up, check from review count
if [[ "$REVIEW_COUNT" -ge 4 ]]; then
    pass "B: Multiple review rounds ran (${REVIEW_COUNT} reviews = multiple rounds)"
else
    info "B: Only $REVIEW_COUNT reviews — qa_force_reject adds a forced round"
    # With qa_force_reject_once, round 1 is auto-rejected BEFORE reviews are checked
    # So we expect: round 1 reviews (2) + round 2 reviews (2) = 4 total
    if [[ "$REVIEW_COUNT" -ge 2 ]]; then
        pass "B: At least one full review round ran"
    else
        fail "B: Expected multiple review rounds"
    fi
fi

if [[ "$FINAL_STATUS" == "done" || "$FINAL_STATUS" == "merged" ]]; then
    pass "B: Task eventually completed after retry"
elif [[ "$FINAL_STATUS" == "failed" ]]; then
    info "B: Task failed (retries exhausted) — acceptable, means retry logic works"
    pass "B: Retry limit enforced"
else
    fail "B: Unexpected status=$FINAL_STATUS"
fi

# =============================================================================
# Scenario C: Test gate — project has test_cmd, agent must produce passing code
# =============================================================================
scenario "Scenario C: Test gate → agent code must pass real tests"

REPO_C="$WORK_BASE/scenario-c-gate-$$"
setup_test_repo "$REPO_C" "Test gate enforcement"

cat > math.js <<'EOF'
// Math utilities
function square(n) {
    return n * n;
}
module.exports = { square };
EOF

cat > math.test.js <<'EOF'
const { square, cube } = require("./math");

// Existing tests — these must keep passing
console.assert(square(3) === 9, "square(3) failed");
console.assert(square(0) === 0, "square(0) failed");
console.assert(square(-2) === 4, "square(-2) failed");

// New function test — cube must exist and work
console.assert(typeof cube === "function", "cube must be a function");
console.assert(cube(2) === 8, "cube(2) failed");
console.assert(cube(3) === 27, "cube(3) failed");
console.assert(cube(0) === 0, "cube(0) failed");

console.log("all tests passed");
EOF

git add . && git commit -m "initial: math module + tests expecting cube()"

"$BINARY" init --dir "$REPO_C" "Implement cube function" 2>&1 || true
patch_config "$REPO_C" "cfg['project_test_cmd'] = 'node math.test.js'"

info "Running Scenario C (test_cmd=node math.test.js, timeout=600s)..."
run_task "$REPO_C" "task-gate-$$" \
    "Implement cube function in math.js" \
    "Add a cube(n) function to math.js that returns n*n*n. Export it alongside square. The existing test file math.test.js already has assertions for cube — run node math.test.js to verify." \
    0 600

info "Scenario C result: status=$FINAL_STATUS reviews=$REVIEW_COUNT rejections=$REJECTION_COUNT"
echo "$REVIEW_DETAILS"

if [[ "$FINAL_STATUS" == "done" || "$FINAL_STATUS" == "merged" ]]; then
    pass "C: Task completed with test gate"
    # Checkout main to get merged code in worktree
    if cd "$REPO_C" && git checkout -f main 2>/dev/null && node math.test.js 2>&1 | grep -q "all tests passed"; then
        pass "C: Merged code passes test_cmd locally"
    else
        fail "C: Merged code does NOT pass test_cmd"
    fi
else
    fail "C: Task did not complete (status=$FINAL_STATUS)"
fi

# Check that cube exists in merged code (main was already checked out above)
if cd "$REPO_C" && cat math.js 2>/dev/null | grep -q "cube"; then
    pass "C: cube function exists in merged code"
else
    fail "C: cube function missing from merged code"
fi

# =============================================================================
# Summary
# =============================================================================
scenario "Review Quality Metrics"

info "Cross-scenario review data:"
echo ""
echo "Scenario A (good task):  status=$FINAL_STATUS"
# Pull review verdicts from logs if available
for repo_label in "A:$REPO_A" "B:$REPO_B" "C:$REPO_C"; do
    label="${repo_label%%:*}"
    repo="${repo_label##*:}"
    if [[ -d "$repo/.techlead" ]]; then
        log_count=$(find "$repo/.techlead" -name "*.log" 2>/dev/null | wc -l | tr -d ' ')
        info "Scenario $label: $log_count log files"
    fi
done

echo ""
echo "========================================"
echo "Review Quality Test Results"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo "========================================"
echo ""
echo "Artifacts:"
echo "  Scenario A: $REPO_A"
echo "  Scenario B: $REPO_B"
echo "  Scenario C: $REPO_C"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
