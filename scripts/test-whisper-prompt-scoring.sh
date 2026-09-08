#!/usr/bin/env bash
# Real-inference tests for the prompt-verification scorer. Synthesizes the
# spoken fixtures with the system speech synthesizer so no recording is stored
# in the repository; the public jfk sample and generated silence complete the
# set. Requires the canonical whisper.cpp build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_ROOT="${STENO_WHISPER_ROOT:-$ROOT_DIR/vendor/whisper.cpp}"
BUILD_DIR="${STENO_WHISPER_BUILD_DIR:-$WHISPER_ROOT/build-steno}"
MODEL="${STENO_TEST_WHISPER_MODEL:-$WHISPER_ROOT/models/ggml-small.en.bin}"
VOICE="${STENO_TEST_SPEECH_VOICE:-Samantha}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/steno-prompt-scoring.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

[[ -f "$MODEL" ]] || { echo "Error: missing model $MODEL" >&2; exit 1; }
[[ -f "$WHISPER_ROOT/samples/jfk.wav" ]] || { echo "Error: missing jfk sample" >&2; exit 1; }

synthesize() {
  local name="$1" text="$2"
  say -v "$VOICE" -r 150 -o "$TEST_DIR/$name.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TEST_DIR/$name.aiff" "$TEST_DIR/$name.wav" >/dev/null
}

cp "$WHISPER_ROOT/samples/jfk.wav" "$TEST_DIR/jfk.wav"
synthesize terms_sentence "Please read the terms of the rental agreement before you sign anything."
synthesize repeated_terms "Terms. Terms. Terms."
synthesize language_sentence "The language of the quarterly report should stay simple and direct."
synthesize steno "Steno."
synthesize two_terms "StenoKit, Turso."
python3 - "$TEST_DIR/silence.wav" <<'EOF'
import struct, sys, wave
with wave.open(sys.argv[1], "wb") as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(16000)
    output.writeframes(struct.pack("<%dh" % 32000, *([0] * 32000)))
EOF

xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror \
  -I "$WHISPER_ROOT/include" -I "$WHISPER_ROOT/ggml/include" \
  "$ROOT_DIR/scripts/test-whisper-prompt-scoring.cpp" \
  -L "$BUILD_DIR/src" -lwhisper \
  -Wl,-rpath,"$BUILD_DIR/src" \
  -Wl,-rpath,"$BUILD_DIR/ggml/src" \
  -Wl,-rpath,"$BUILD_DIR/ggml/src/ggml-metal" \
  -o "$TEST_DIR/prompt-scoring-tests"

"$TEST_DIR/prompt-scoring-tests" "$MODEL" "$TEST_DIR"
