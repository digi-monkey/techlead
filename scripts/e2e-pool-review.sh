#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[e2e] running pool review scenarios"
zig build test -- --test-filter "pool e2e"
echo "[e2e] pool review scenarios passed"
