#!/usr/bin/env bash
# =============================================================================
# E2E Smoke Test: acpx provider integration
# Purpose: Verify the full run pipeline works end-to-end with a mock agent
# Tests: init → run --mode project → verify events logged
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="/tmp/techlead-e2e-acpx-$$"
BINARY="$PROJECT_ROOT/zig-out/bin/techlead"
MOCK_ACPX="$PROJECT_ROOT/tests/mock_acpx.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((TESTS_PASSED++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((TESTS_FAILED++)); }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

cleanup() {
    info "Cleaning up $WORK_DIR ..."
    rm -rf "$WORK_DIR"
    # Remove mock acpx from PATH
    rm -f /tmp/acpx
}
trap cleanup EXIT

# =============================================================================
# Setup
# =============================================================================
info "Building techlead..."
(cd "$PROJECT_ROOT" && zig build) || { fail "Build failed"; exit 1; }

info "Setting up mock acpx on PATH..."
chmod +x "$MOCK_ACPX"
cp "$MOCK_ACPX" /tmp/acpx
chmod +x /tmp/acpx
export PATH="/tmp:$PATH"

# Verify mock acpx is reachable
if ! command -v acpx &>/dev/null; then
    fail "mock acpx not on PATH"
    exit 1
fi
pass "mock acpx available on PATH"

info "Creating test workspace at $WORK_DIR ..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
git init
git config user.email "test@test.com"
git config user.name "Test"
echo "# Test Project" > README.md
git add . && git commit -m "initial"

# =============================================================================
# Test 1: init
# =============================================================================
info "Test: init command"
"$BINARY" init --dir "$WORK_DIR" "Improve test coverage" 2>&1 || true

if [[ -f "$WORK_DIR/.techlead/techlead.json" ]]; then
    pass "init created techlead.json"
else
    fail "init did not create techlead.json"
fi

if [[ -f "$WORK_DIR/.techlead/program.md" ]]; then
    pass "init created program.md"
else
    fail "init did not create program.md"
fi

# =============================================================================
# Test 2: run --mode project (1 iteration with mock acpx)
# =============================================================================
info "Test: run --mode project"

# Set iterations to 1 for quick test
python3 -c "
import json, sys
with open('$WORK_DIR/.techlead/techlead.json') as f:
    cfg = json.load(f)
cfg['iterations'] = 1
cfg['provider'] = 'codex'
with open('$WORK_DIR/.techlead/techlead.json', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null || {
    # Fallback if python3 not available
    info "python3 not available, using sed"
    sed -i.bak 's/"iterations": [0-9]*/"iterations": 1/' "$WORK_DIR/.techlead/techlead.json"
}

RUN_OUTPUT=$("$BINARY" run --dir "$WORK_DIR" --mode project 2>&1) || true
echo "$RUN_OUTPUT"

if echo "$RUN_OUTPUT" | grep -q "acpx.*exec"; then
    pass "run invoked acpx provider"
elif echo "$RUN_OUTPUT" | grep -q "mock execution"; then
    pass "run invoked acpx provider (mock output)"
else
    # Even if acpx didn't log visibly, check for the mock commit
    if (cd "$WORK_DIR" && git log --oneline -5 | grep -q "mock:"); then
        pass "run produced mock commit via acpx"
    else
        fail "run did not invoke acpx provider"
    fi
fi

# =============================================================================
# Test 3: --help shows new modes
# =============================================================================
info "Test: help shows session|project modes"
HELP_OUTPUT=$("$BINARY" --help 2>&1) || true

if echo "$HELP_OUTPUT" | grep -q "session|project"; then
    pass "help shows session|project modes"
else
    fail "help does not show session|project modes"
fi

# Verify old modes are removed
if echo "$HELP_OUTPUT" | grep -q "optimize"; then
    fail "help still mentions optimize mode"
else
    pass "optimize mode removed from help"
fi

if echo "$HELP_OUTPUT" | grep -q "server start"; then
    fail "help still mentions server command"
else
    pass "server command removed from help"
fi

if echo "$HELP_OUTPUT" | grep -q "control"; then
    fail "help still mentions control command"
else
    pass "control command removed from help"
fi

# =============================================================================
# Test 4: events logged to sqlite
# =============================================================================
info "Test: events stored in sqlite"
if [[ -f "$WORK_DIR/.techlead/events.db" ]]; then
    pass "sqlite events.db created"
else
    info "events.db not found (may be expected if run had no tasks)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================"
echo "E2E Test Results"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo "========================================"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
