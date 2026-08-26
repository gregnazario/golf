#!/usr/bin/env bash
# Build the Kotlin implementation into two jars, without needing Gradle or any
# network access (kotlinc bundles the standard library):
#
#   .build/golf.jar           library + fixture generator
#   .build/golf-tests.jar     runnable test suite (java -jar golf-tests.jar)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
BUILD="$ROOT/.build"
mkdir -p "$BUILD"

echo "Compiling library + generator..."
kotlinc "$ROOT/src/main/kotlin" -include-runtime -d "$BUILD/golf.jar"

echo "Compiling test suite..."
kotlinc "$ROOT/src/main/kotlin" "$ROOT/src/test/kotlin" -include-runtime -d "$BUILD/golf-tests.jar"

echo "Built:"
ls -la "$BUILD"/*.jar
