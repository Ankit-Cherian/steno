#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_ROOT="${STENO_WHISPER_ROOT:-$ROOT_DIR/vendor/whisper.cpp}"
BUILD_DIR="${STENO_WHISPER_BUILD_DIR:-$WHISPER_ROOT/build-steno}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/steno-vad-integrity.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun clang++ -std=c++17 -O2 \
  -I "$WHISPER_ROOT/include" -I "$WHISPER_ROOT/ggml/include" \
  "$ROOT_DIR/scripts/test-whisper-vad-integrity.cpp" \
  -L "$BUILD_DIR/src" -lwhisper \
  -Wl,-rpath,"$BUILD_DIR/src" \
  -Wl,-rpath,"$BUILD_DIR/ggml/src" \
  -Wl,-rpath,"$BUILD_DIR/ggml/src/ggml-metal" \
  -o "$TEST_DIR/vad-integrity-tests"

"$TEST_DIR/vad-integrity-tests"
