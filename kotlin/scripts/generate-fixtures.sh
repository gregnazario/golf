#!/usr/bin/env bash
# Regenerate the Kotlin-authored cross-language fixtures into ../testdata.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
TESTDATA="$(cd "$ROOT/.." && pwd)/testdata"

"$SCRIPT_DIR/build.sh"

exec java -cp "$ROOT/.build/golf.jar" golf.GenerateFixturesKt "$TESTDATA"
