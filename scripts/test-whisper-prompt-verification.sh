#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/steno-prompt-verification.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror \
  "$ROOT_DIR/scripts/test-whisper-prompt-verification.cpp" \
  -o "$TEST_DIR/prompt-verification-tests"

"$TEST_DIR/prompt-verification-tests"
