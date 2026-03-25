#!/usr/bin/env bash
# =============================================================================
# E2E Test Script 1: Basic Multi-Project Smoke Test
# Purpose: Verify basic multi-project pool functionality
# Stage: E - Multiproject Pool with Gate Controls
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_ROOT="/tmp/techlead-e2e-smoke-$$"
OBSERVE_PORT=7810
OBSERVE_HOST="127.0.0.1"
OBSERVE_PID=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# Utility Functions
# =============================================================================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

fail() {
    log_error "$1"
    exit 1
}

cleanup() {
    log_info "Cleaning up..."
    if [[ -n "$OBSERVE_PID" ]] && kill -0 "$OBSERVE_PID" 2>/dev/null; then
        kill "$OBSERVE_PID" 2>/dev/null || true
        wait "$OBSERVE_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_ROOT"
    log_info "Cleanup complete"
}

# Set trap for cleanup
trap cleanup EXIT

# =============================================================================
# API Helper Functions
# =============================================================================

# Wait for observe service to be ready
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

# Register a project
register_project() {
    local project_id="$1"
    local work_dir="$2"
    local test_cmd="$3"
    
    log_info "Registering project: $project_id"
    
    local response
    response=$(curl -sS -X POST "http://$OBSERVE_HOST:$OBSERVE_PORT/projects" \
        -H 'Content-Type: application/json' \
        -d "{\"project_id\":\"$project_id\",\"work_dir\":\"$work_dir\",\"enabled\":true,\"test_cmd\":\"$test_cmd\"}") || {
        fail "Failed to register project $project_id"
    }
    
    log_info "Project $project_id registered successfully"
    return 0
}

# Create a task
create_task() {
    local project_id="$1"
    local title="$2"
    local prompt="$3"
    local priority="${4:-50}"
    
    log_info "Creating task '$title' for project: $project_id"
    
    local response
    response=$(curl -sS -X POST "http://$OBSERVE_HOST:$OBSERVE_PORT/projects/$project_id/tasks" \
        -H 'Content-Type: application/json' \
        -d "{\"title\":\"$title\",\"prompt\":\"$prompt\",\"priority\":$priority}") || {
        fail "Failed to create task for project $project_id"
    }
    
    log_info "Task created for project $project_id"
    return 0
}

# Get project tasks
get_project_tasks() {
    local project_id="$1"
    curl -sS "http://$OBSERVE_HOST:$OBSERVE_PORT/projects/$project_id/tasks" 2>/dev/null || echo '[]'
}

# Get events
get_events() {
    local project_id="$1"
    local after="${2:-0}"
    curl -sS "http://$OBSERVE_HOST:$OBSERVE_PORT/events?project_id=$project_id&after=$after" 2>/dev/null || echo '[]'
}

# =============================================================================
# Test Functions
# =============================================================================

# Test 1: Verify project registration
test_project_registration() {
    log_info "TEST: Project registration"
    
    # List projects and verify both are registered
    local projects
    projects=$(curl -sS "http://$OBSERVE_HOST:$OBSERVE_PORT/projects")
    
    if ! echo "$projects" | grep -q "project-a"; then
        fail "Project A not found in projects list"
    fi
    
    if ! echo "$projects" | grep -q "project-b"; then
        fail "Project B not found in projects list"
    fi
    
    log_info "PASS: Both projects registered successfully"
    return 0
}

# Test 2: Verify task creation
test_task_creation() {
    log_info "TEST: Task creation"
    
    # Create tasks for both projects
    create_task "project-a" "Test Task A" "Implement a simple function" 100
    create_task "project-b" "Test Task B" "Refactor the codebase" 50
    
    # Verify tasks exist
    local tasks_a
    tasks_a=$(get_project_tasks "project-a")
    if ! echo "$tasks_a" | grep -q "Test Task A"; then
        fail "Task not found in project-a"
    fi
    
    local tasks_b
    tasks_b=$(get_project_tasks "project-b")
    if ! echo "$tasks_b" | grep -q "Test Task B"; then
        fail "Task not found in project-b"
    fi
    
    log_info "PASS: Tasks created successfully in both projects"
    return 0
}

# Test 3: Verify no cross-project data contamination
test_no_cross_contamination() {
    log_info "TEST: Cross-project isolation"
    
    # Verify tasks in project A don't appear in project B
    local tasks_a
    tasks_a=$(get_project_tasks "project-a")
    if echo "$tasks_a" | grep -q "Test Task B"; then
        fail "Cross-contamination: Task B found in project A"
    fi
    
    local tasks_b
    tasks_b=$(get_project_tasks "project-b")
    if echo "$tasks_b" | grep -q "Test Task A"; then
        fail "Cross-contamination: Task A found in project B"
    fi
    
    log_info "PASS: No cross-project data contamination"
    return 0
}

# =============================================================================
# Main Test Flow
# =============================================================================

main() {
    log_info "=========================================="
    log_info "E2E Multi-Project Smoke Test"
    log_info "Work directory: $WORK_ROOT"
    log_info "=========================================="
    
    # -------------------------------------------------------------------------
    # 1. Prepare environment
    # -------------------------------------------------------------------------
    log_info "Step 1: Preparing environment"
    rm -rf "$WORK_ROOT"
    mkdir -p "$WORK_ROOT"
    
    # -------------------------------------------------------------------------
    # 2. Create two temporary git repositories
    # -------------------------------------------------------------------------
    log_info "Step 2: Creating test git repositories"
    
    # Project A: Simple Node.js-like project
    mkdir -p "$WORK_ROOT/project-a"
    cd "$WORK_ROOT/project-a"
    git init --quiet
    echo '{"name": "project-a", "version": "1.0.0"}' > package.json
    echo 'console.log("hello")' > index.js
    git add .
    git commit --quiet -m "Initial commit"
    
    # Project B: Simple Python-like project
    mkdir -p "$WORK_ROOT/project-b"
    cd "$WORK_ROOT/project-b"
    git init --quiet
    echo 'name = "project-b"' > setup.py
    echo 'print("hello")' > main.py
    git add .
    git commit --quiet -m "Initial commit"
    
    log_info "Created two test projects"
    
    # -------------------------------------------------------------------------
    # 3. Build the binary
    # -------------------------------------------------------------------------
    log_info "Step 3: Building techlead binary"
    cd "$PROJECT_ROOT"
    zig build 2>&1 | tail -5 || fail "Build failed"
    
    # -------------------------------------------------------------------------
    # 4. Start observe service
    # -------------------------------------------------------------------------
    log_info "Step 4: Starting observe service on port $OBSERVE_PORT"
    
    ./zig-out/bin/techlead observe start \
        --dir "$WORK_ROOT" \
        --host "$OBSERVE_HOST" \
        --port "$OBSERVE_PORT" &
    OBSERVE_PID=$!
    
    wait_for_observe
    
    # -------------------------------------------------------------------------
    # 5. Register projects
    # -------------------------------------------------------------------------
    log_info "Step 5: Registering projects"
    
    register_project "project-a" "$WORK_ROOT/project-a" "echo 'test passed'"
    register_project "project-b" "$WORK_ROOT/project-b" "echo 'test passed'"
    
    # -------------------------------------------------------------------------
    # 6. Run tests
    # -------------------------------------------------------------------------
    log_info "Step 6: Running tests"
    
    test_project_registration
    test_task_creation
    test_no_cross_contamination
    
    # -------------------------------------------------------------------------
    # 7. Success
    # -------------------------------------------------------------------------
    log_info "=========================================="
    log_info "All tests PASSED!"
    log_info "=========================================="
    
    return 0
}

main "$@"
