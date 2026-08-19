#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_ROOT="${STENO_WHISPER_ROOT:-$ROOT_DIR/vendor/whisper.cpp}"
BUILD_DIR="${STENO_WHISPER_BUILD_DIR:-$WHISPER_ROOT/build-steno}"
HELPER="${STENO_TEST_RETAINED_HELPER:-$BUILD_DIR/bin/steno-whisper-runtime}"
MODEL="${STENO_TEST_WHISPER_MODEL:-$WHISPER_ROOT/models/ggml-small.en.bin}"
AUDIO="${STENO_TEST_WHISPER_AUDIO:-$WHISPER_ROOT/samples/jfk.wav}"

if [[ "${STENO_SKIP_HELPER_BUILD:-0}" != "1" ]]; then
  STENO_WHISPER_RUNTIME_OUTPUT="$HELPER" "$ROOT_DIR/scripts/build-whisper-runtime-helper.sh" >/dev/null
fi

exec python3 "$ROOT_DIR/scripts/test-whisper-runtime-helper-v2.py" \
  --helper "$HELPER" \
  --model "$MODEL" \
  --audio "$AUDIO" \
  "$@"
