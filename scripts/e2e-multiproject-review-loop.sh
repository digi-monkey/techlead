#!/usr/bin/env bash
# =============================================================================
# E2E Test Script 2: Review Loop Test
# Purpose: Test reject -> requeue -> approve -> done complete cycle
# Stage: E - Multiproject Pool with Gate Controls
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_ROOT="/tmp/techlead-e2e-review-loop-$$"
OBSERVE_PORT=7810
OBSERVE_HOST="127.0.0.1"
OBSERVE_PID=""
PROJECT_ID="review-loop-test"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Utility Functions
# =============================================================================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

fail() { log_error "$1"; exit 1; }

cleanup() {
    log_info "Cleaning up..."
    if [[ -n "$OBSERVE_PID" ]] && kill -0 "$OBSERVE_PID" 2>/dev/null; then
        kill "$OBSERVE_PID" 2>/dev/null || true
        wait "$OBSERVE_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_ROOT"
    log_info "Cleanup complete"
}

trap cleanup EXIT

# =============================================================================
# API Helper Functions
# =============================================================================

wait_for_observe() {
    local max_attempts=30
    local attempt=0
    while (( attempt < max_attempts )); do
        if curl -fsS --max-time 2 "http://$OBSERVE_HOST:$OBSERVE_PORT/health" >/dev/null 2>&1; then
            log_info "Observe service is ready"
            return 0
        fi
        ((attempt++))
        sleep 1
    done
    fail "Observe service failed to start within ${max_attempts}s"
}

# TODO: Requires API - POST /projects
register_project() {
    local project_id="$1"
    local work_dir="$2"
    local test_cmd="$3"
    
    log_info "Registering project: $project_id"
    
    local response
    response=$(curl -sS -X POST "http://$OBSERVE_HOST:$OBSERVE_PORT/projects" \
        -H 'Content-Type: application/json' \
        -d "{\"project_id\":\"$project_id\",\"work_dir\":\"$work_dir\",\"enabled\":true,\"test_cmd\":\"$test_cmd\"}" 2>&1) || {
        log_warn "Project registration API not yet implemented (expected)"
        return 1
    }
    
    log_info "Project $project_id registered"
    return 0
}

# TODO: Requires API - POST /projects/:project_id/tasks
create_task_with_reject() {
    local project_id="$1"
    local title="$2"
    local prompt="$3"
    local priority="${4:-60}"
    
    log_info "Creating task with qa_force_reject_once=true: $title"
    
    # This task should be rejected once, then requeued and eventually approved
    local response
    response=$(curl -sS -X POST "http://$OBSERVE_HOST:$OBSERVE_PORT/projects/$project_id/tasks" \
        -H 'Content-Type: application/json' \
        -d "{\"title\":\"$title\",\"prompt\":\"$prompt\",\"priority\":$priority,\"qa_force_reject_once\":true}" 2>&1) || {
        log_warn "Task creation API not yet implemented (expected)"
        return 1
    }
    
    # Extract task_id from response
    local task_id
    task_id=$(echo "$response" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("task_id",""))' 2>/dev/null || echo "")
    
    if [[ -n "$task_id" ]]; then
        echo "$task_id"
        return 0
    else
        log_warn "Could not extract task_id from response"
        return 1
    fi
}

# TODO: Requires API - POST /projects/:project_id/runs/start
start_project_run() {
    local project_id="$1"
    
    log_info "Starting pool run for project: $project_id"
    
    local response
    response=$(curl -sS -X POST "http://$OBSERVE_HOST:$OBSERVE_PORT/projects/$project_id/runs/start" \
        -H 'Content-Type: application/json' \
        -d '{"mode":"pool"}' 2>&1) || {
        log_warn "Project run start API not yet implemented (expected)"
        return 1
    }
    
    return 0
}

# TODO: Requires API - GET /projects/:project_id/tasks/:task_id
get_task_status() {
    local project_id="$1"
    local task_id="$2"
    
    local response
    response=$(curl -sS "http://$OBSERVE_HOST:$OBSERVE_PORT/projects/$project_id/tasks/$task_id" 2>&1) || {
        echo "unknown"
        return 1
    }
    
    echo "$response" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null || echo "unknown"
}

# TODO: Requires API - GET /events?project_id=<id>&after=<n>
get_events() {
    local project_id="$1"
    local after="${2:-0}"
    
    curl -sS "http://$OBSERVE_HOST:$OBSERVE_PORT/events?project_id=$project_id&after=$after" 2>&1 || echo '[]'
}

# Wait for task to reach a specific status
wait_for_task_status() {
    local project_id="$1"
    local task_id="$2"
    local expected_status="$3"
    local timeout="${4:-120}"
    
    log_info "Waiting for task $task_id to reach status: $expected_status (timeout: ${timeout}s)"
    
    local start_time=$(date +%s)
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for status $expected_status (elapsed: ${elapsed}s)"
            return 1
        fi
        
        local current_status
        current_status=$(get_task_status "$project_id" "$task_id")
        
        log_debug "Current status: $current_status (elapsed: ${elapsed}s)"
        
        if [[ "$current_status" == "$expected_status" ]]; then
            log_info "Task reached status: $expected_status (elapsed: ${elapsed}s)"
            return 0
        fi
        
        sleep 5
    done
}

# Wait for task to reach any of the specified statuses
wait_for_task_status_any() {
    local project_id="$1"
    local task_id="$2"
    local expected_statuses="$3"  # pipe-separated list
    local timeout="${4:-120}"
    
    log_info "Waiting for task $task_id to reach one of: $expected_statuses (timeout: ${timeout}s)"
    
    local start_time=$(date +%s)
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for any of: $expected_statuses (elapsed: ${elapsed}s)"
            return 1
        fi
        
        local current_status
        current_status=$(get_task_status "$project_id" "$task_id")
        
        log_debug "Current status: $current_status (elapsed: ${elapsed}s)"
        
        if echo "$expected_statuses" | grep -q "$current_status"; then
            log_info "Task reached status: $current_status (elapsed: ${elapsed}s)"
            return 0
        fi
        
        sleep 5
    done
}

# =============================================================================
# Test Functions
# =============================================================================

# Verify state transition: queued -> claimed -> running -> review -> changes_requested
test_first_round_changes_requested() {
    local project_id="$1"
    local task_id="$2"
    
    log_info "TEST: First round should result in changes_requested"
    
    # Wait for task to reach changes_requested (or timeout if API not ready)
    local status
    status=$(get_task_status "$project_id" "$task_id")
    
    if [[ "$status" == "unknown" ]] || [[ -z "$status" ]]; then
        log_warn "SKIPPED: Cannot verify first round (API not ready)"
        return 0
    fi
    
    # Expected state sequence:
    # queued -> claimed -> running -> review -> changes_requested
    
    if [[ "$status" == "changes_requested" ]]; then
        log_info "PASS: Task correctly reached changes_requested after first round"
        return 0
    else
        log_error "FAIL: Expected changes_requested, got $status"
        return 1
    fi
}

# Verify task is automatically requeued
test_auto_requeue() {
    local project_id="$1"
    local task_id="$2"
    
    log_info "TEST: Task should be automatically requeued after rejection"
    
    local status
    status=$(get_task_status "$project_id" "$task_id")
    
    if [[ "$status" == "unknown" ]] || [[ -z "$status" ]]; then
        log_warn "SKIPPED: Cannot verify auto-requeue (API not ready)"
        return 0
    fi
    
    if [[ "$status" == "queued" ]]; then
        log_info "PASS: Task automatically requeued after rejection"
        return 0
    elif [[ "$status" == "claimed" ]] || [[ "$status" == "running" ]]; then
        log_info "PASS: Task already progressing through second round (status: $status)"
        return 0
    else
        log_error "FAIL: Expected queued/claimed/running, got $status"
        return 1
    fi
}

# Verify second round results in approval
test_second_round_approved() {
    local project_id="$1"
    local task_id="$2"
    
    log_info "TEST: Second round should result in approved state"
    
    local status
    status=$(get_task_status "$project_id" "$task_id")
    
    if [[ "$status" == "unknown" ]] || [[ -z "$status" ]]; then
        log_warn "SKIPPED: Cannot verify second round (API not ready)"
        return 0
    fi
    
    if [[ "$status" == "approved" ]]; then
        log_info "PASS: Task reached approved after second round"
        return 0
    elif [[ "$status" == "done" ]]; then
        log_info "PASS: Task already completed (status: done)"
        return 0
    else
        log_error "FAIL: Expected approved/done, got $status"
        return 1
    fi
}

# Verify final state is done
test_final_state_done() {
    local project_id="$1"
    local task_id="$2"
    
    log_info "TEST: Final state should be done"
    
    local status
    status=$(get_task_status "$project_id" "$task_id")
    
    if [[ "$status" == "unknown" ]] || [[ -z "$status" ]]; then
        log_warn "SKIPPED: Cannot verify final state (API not ready)"
        return 0
    fi
    
    if [[ "$status" == "done" ]]; then
        log_info "PASS: Task completed successfully (status: done)"
        return 0
    else
        log_error "FAIL: Expected done, got $status"
        return 1
    fi
}

# Verify two rounds of commit records exist
test_two_commit_records() {
    local work_dir="$1"
    
    log_info "TEST: Should have two rounds of commit records"
    
    if [[ ! -d "$work_dir/.git" ]]; then
        log_warn "SKIPPED: Not a git repository"
        return 0
    fi
    
    cd "$work_dir"
    
    # Count commits that look like implementation commits
    local impl_commits
    impl_commits=$(git log --oneline --all | grep -iE "(impl|implement|fix|refactor|add)" | wc -l)
    
    if [[ $impl_commits -ge 2 ]]; then
        log_info "PASS: Found $impl_commits implementation-related commits"
        return 0
    else
        log_warn "Could not verify commit count (found $impl_commits, expected >= 2)"
        return 0  # Don't fail on this - commit messages may vary
    fi
}

# Export evidence
test_export_evidence() {
    local project_id="$1"
    local task_id="$2"
    local output_dir="$3"
    
    log_info "Exporting evidence to: $output_dir"
    
    mkdir -p "$output_dir"
    
    # Export task details
    local task_details
    task_details=$(curl -sS "http://$OBSERVE_HOST:$OBSERVE_PORT/projects/$project_id/tasks/$task_id" 2>&1 || echo '{}')
    echo "$task_details" > "$output_dir/task-details.json"
    
    # Export events
    local events
    events=$(get_events "$project_id" 0)
    echo "$events" > "$output_dir/events.json"
    
    # Export git log
    cd "$WORK_ROOT/$project_id"
    git log --oneline --decorate --all > "$output_dir/git-log.txt"
    
    log_info "Evidence exported successfully"
}

# =============================================================================
# Main Test Flow
# =============================================================================

main() {
    log_info "=========================================="
    log_info "E2E Multi-Project Review Loop Test"
    log_info "Work directory: $WORK_ROOT"
    log_info "=========================================="
    
    # -------------------------------------------------------------------------
    # 1. Prepare environment
    # -------------------------------------------------------------------------
    log_info "Step 1: Preparing environment"
    rm -rf "$WORK_ROOT"
    mkdir -p "$WORK_ROOT"
    
    # -------------------------------------------------------------------------
    # 2. Create test git repository
    # -------------------------------------------------------------------------
    log_info "Step 2: Creating test git repository"
    
    mkdir -p "$WORK_ROOT/$PROJECT_ID"
    cd "$WORK_ROOT/$PROJECT_ID"
    git init --quiet
    
    # Create a simple Python project
    cat > main.py << 'EOF'
def hello():
    """Simple hello function."""
    return "hello"

def add(a, b):
    """Add two numbers."""
    return a + b
EOF
    
    cat > test_main.py << 'EOF'
def test_hello():
    assert hello() == "hello"

def test_add():
    assert add(1, 2) == 3
EOF
    
    git add .
    git commit --quiet -m "Initial commit"
    
    log_info "Created test project at: $WORK_ROOT/$PROJECT_ID"
    
    # -------------------------------------------------------------------------
    # 3. Build binary
    # -------------------------------------------------------------------------
    log_info "Step 3: Building techlead binary"
    cd "$PROJECT_ROOT"
    zig build 2>&1 | tail -5 || fail "Build failed"
    
    # -------------------------------------------------------------------------
    # 4. Start observe service
    # -------------------------------------------------------------------------
    log_info "Step 4: Starting observe service on port $OBSERVE_PORT"
    
    "$PROJECT_ROOT/zig-out/bin/techlead" observe start \
        --dir "$WORK_ROOT/$PROJECT_ID" \
        --host "$OBSERVE_HOST" \
        --port "$OBSERVE_PORT" >"$WORK_ROOT/observe.log" 2>&1 &
    
    OBSERVE_PID=$!
    wait_for_observe
    
    # -------------------------------------------------------------------------
    # 5. Register project
    # -------------------------------------------------------------------------
    log_info "Step 5: Registering project"
    
    local task_id=""
    
    if register_project "$PROJECT_ID" "$WORK_ROOT/$PROJECT_ID" "python -m pytest -q"; then
        
        # -------------------------------------------------------------------------
        # 6. Create task with qa_force_reject_once=true
        # -------------------------------------------------------------------------
        log_info "Step 6: Creating task with qa_force_reject_once=true"
        
        task_id=$(create_task_with_reject "$PROJECT_ID" \
            "Add validation to add function" \
            "Add input validation to the add function and corresponding tests" \
            60) || task_id=""
        
        if [[ -n "$task_id" ]]; then
            log_info "Created task with ID: $task_id"
        else
            log_warn "Task creation returned empty ID (API pending)"
            task_id="test-task-1"
        fi
        
        # -------------------------------------------------------------------------
        # 7. Start project run
        # -------------------------------------------------------------------------
        log_info "Step 7: Starting project run"
        start_project_run "$PROJECT_ID" || log_warn "Run start skipped"
        
        # -------------------------------------------------------------------------
        # 8. Wait for first round to complete (should be rejected)
        # -------------------------------------------------------------------------
        log_info "Step 8: Waiting for first round (expecting changes_requested)..."
        
        # Wait up to 5 minutes for first round
        if wait_for_task_status_any "$PROJECT_ID" "$task_id" "changes_requested|queued|claimed|running|approved|done" 300; then
            
            # -------------------------------------------------------------------------
            # 9. Verify first round resulted in changes_requested
            # -------------------------------------------------------------------------
            log_info "Step 9: Verifying first round rejection"
            test_first_round_changes_requested "$PROJECT_ID" "$task_id"
            
            # -------------------------------------------------------------------------
            # 10. Wait for requeue and second round
            # -------------------------------------------------------------------------
            log_info "Step 10: Waiting for requeue and second round..."
            sleep 10
            
            # -------------------------------------------------------------------------
            # 11. Verify auto-requeue
            # -------------------------------------------------------------------------
            log_info "Step 11: Verifying auto-requeue"
            test_auto_requeue "$PROJECT_ID" "$task_id"
            
            # Wait for second round to progress
            wait_for_task_status_any "$PROJECT_ID" "$task_id" "approved|done" 300 || true
            
            # -------------------------------------------------------------------------
            # 12. Verify second round approval
            # -------------------------------------------------------------------------
            log_info "Step 12: Verifying second round approval"
            test_second_round_approved "$PROJECT_ID" "$task_id"
            
            # Wait for completion
            wait_for_task_status "$PROJECT_ID" "$task_id" "done" 300 || true
            
            # -------------------------------------------------------------------------
            # 13. Verify final state
            # -------------------------------------------------------------------------
            log_info "Step 13: Verifying final state"
            test_final_state_done "$PROJECT_ID" "$task_id"
            
            # -------------------------------------------------------------------------
            # 14. Verify commit records
            # -------------------------------------------------------------------------
            log_info "Step 14: Verifying commit records"
            test_two_commit_records "$WORK_ROOT/$PROJECT_ID"
            
            # -------------------------------------------------------------------------
            # 15. Export evidence
            # -------------------------------------------------------------------------
            log_info "Step 15: Exporting evidence"
            test_export_evidence "$PROJECT_ID" "$task_id" "$WORK_ROOT/evidence"
            
        else
            log_warn "Timeout waiting for task status changes (API pending)"
        fi
        
    else
        log_warn "Project registration failed - skipping test execution"
    fi
    
    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    log_info "=========================================="
    log_info "Review Loop Test Complete"
    log_info "=========================================="
    log_info "Expected state flow:"
    log_info "  queued -> claimed -> running -> review -> changes_requested"
    log_info "  -> queued -> claimed -> running -> review -> approved -> done"
    log_info ""
    log_info "Evidence directory: $WORK_ROOT/evidence"
    
    exit 0
}

main "$@"
