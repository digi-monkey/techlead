#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[smoke] run characterization tests"
zig build characterization

echo "[smoke] run full test suite"
zig build test

echo "[smoke] all checks passed"
