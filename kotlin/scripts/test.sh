#!/usr/bin/env bash
# Compile and run the Kotlin test suite against the repo's testdata fixtures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
TESTDATA="$(cd "$ROOT/.." && pwd)/testdata"

"$SCRIPT_DIR/build.sh"

echo "Running tests..."
exec java -cp "$ROOT/.build/golf-tests.jar" golf.TestMainKt "$TESTDATA"
