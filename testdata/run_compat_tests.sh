#!/usr/bin/env bash
# Cross-language compatibility test suite for the Golf file format.
#
# This script:
# 1. Generates .golf fixtures from Rust, Go, Python, TypeScript, Swift, and Kotlin
# 2. Runs each language's test suite to validate it can read all fixtures
#
# Prerequisites: Rust, Go, Python 3 (with venv), Node.js/npm. The Swift and
# Kotlin suites are included automatically when `swift` / `kotlinc` are on PATH
# and skipped (with a notice) otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TESTDATA_DIR="$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

pass=0
fail=0

run_step() {
    local label="$1"
    shift
    echo -e "${BOLD}[$label]${NC} $*"
    if "$@"; then
        echo -e "${GREEN}  PASS${NC}"
        # Not `((pass++))`: with `set -e`, evaluating to 0 would abort the script.
        pass=$((pass + 1))
    else
        echo -e "${RED}  FAIL${NC}"
        fail=$((fail + 1))
    fi
}

echo "============================================="
echo " Golf Cross-Language Compatibility Tests"
echo "============================================="
echo ""

# ── Step 1: Generate fixtures from each language ──

echo -e "${BOLD}=== Generating fixtures ===${NC}"
echo ""

echo "--- Rust ---"
(cd "$ROOT_DIR/rust" && cargo run --bin generate_fixtures --quiet 2>&1)
echo ""

echo "--- Go ---"
(cd "$ROOT_DIR/go" && go run ./cmd/generate_fixtures "$TESTDATA_DIR" 2>&1)
echo ""

echo "--- Python ---"
(cd "$ROOT_DIR/python" && source .venv/bin/activate && python -m golf.generate_fixtures "$TESTDATA_DIR" 2>&1)
echo ""

echo "--- TypeScript ---"
(cd "$ROOT_DIR/typescript" && npx tsx src/generate_fixtures.ts "$TESTDATA_DIR" 2>&1)
echo ""

if command -v swift >/dev/null 2>&1; then
    echo "--- Swift ---"
    (cd "$ROOT_DIR/swift" && swift run -c release GolfFixtures "$TESTDATA_DIR" 2>&1)
    echo ""
else
    echo -e "${BOLD}--- Swift ---${NC} skipped (swift not found)"
fi

if command -v kotlinc >/dev/null 2>&1; then
    echo "--- Kotlin ---"
    bash "$ROOT_DIR/kotlin/scripts/generate-fixtures.sh" 2>&1
    echo ""
else
    echo -e "${BOLD}--- Kotlin ---${NC} skipped (kotlinc not found)"
fi

echo ""
echo "Generated fixtures:"
ls -la "$TESTDATA_DIR"/*.golf
echo ""

# ── Step 2: Run each language's tests (they read all fixtures) ──

echo -e "${BOLD}=== Running language test suites ===${NC}"
echo ""

run_step "Rust" bash -c "cd '$ROOT_DIR/rust' && cargo test --quiet 2>&1"
echo ""

run_step "Go" bash -c "cd '$ROOT_DIR/go' && go test -v ./... 2>&1"
echo ""

run_step "Python" bash -c "cd '$ROOT_DIR/python' && source .venv/bin/activate && pytest -v 2>&1"
echo ""

run_step "TypeScript" bash -c "cd '$ROOT_DIR/typescript' && npx tsx --test src/golf.test.ts 2>&1"
echo ""

if command -v swift >/dev/null 2>&1; then
    run_step "Swift" bash -c "cd '$ROOT_DIR/swift' && swift test 2>&1 | grep -Ev '^\[[0-9]+/[0-9]+\]|Building|Build complete'"
    echo ""
else
    echo -e "${BOLD}[Swift]${NC} skipped (swift not found)"
fi

if command -v kotlinc >/dev/null 2>&1; then
    run_step "Kotlin" bash -c "bash '$ROOT_DIR/kotlin/scripts/test.sh' 2>&1"
    echo ""
else
    echo -e "${BOLD}[Kotlin]${NC} skipped (kotlinc not found)"
fi

# ── Summary ──

echo "============================================="
echo -e " Results: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}"
echo "============================================="

if [ "$fail" -gt 0 ]; then
    exit 1
fi
