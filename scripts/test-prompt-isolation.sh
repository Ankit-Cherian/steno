#!/usr/bin/env bash
# Opt-in production-coordinator replay with explicit, local fixture inputs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for key in STENO_TEST_RETAINED_HELPER STENO_TEST_WHISPER_MODEL STENO_TEST_PROMPT_MANIFEST STENO_TEST_PROMPT_RECEIPTS; do
  [[ -n "${!key:-}" ]] || { echo "Error: $key must be set explicitly." >&2; exit 1; }
done
[[ -x "$STENO_TEST_RETAINED_HELPER" ]] || { echo "Error: helper is not executable." >&2; exit 1; }
[[ -f "$STENO_TEST_WHISPER_MODEL" ]] || { echo "Error: model is missing." >&2; exit 1; }
[[ -f "$STENO_TEST_PROMPT_MANIFEST" ]] || { echo "Error: fixture manifest is missing." >&2; exit 1; }
if [[ -n "${STENO_TEST_WHISPER_VAD:-}" ]]; then
  [[ -f "$STENO_TEST_WHISPER_VAD" ]] || { echo "Error: VAD model is missing." >&2; exit 1; }
fi
[[ ! -e "$STENO_TEST_PROMPT_RECEIPTS" ]] || { echo "Error: use a new receipt directory for each run." >&2; exit 1; }

if [[ -n "${STENO_TEST_SWIFT_SCRATCH_PATH:-}" ]]; then
  TEST_SCRATCH="$STENO_TEST_SWIFT_SCRATCH_PATH"
else
  TEST_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/steno-prompt-integration.XXXXXX")"
  trap 'rm -rf "$TEST_SCRATCH"' EXIT
fi

export STENO_TEST_PROMPT_INTEGRATION=1
swift test --package-path "$ROOT_DIR/StenoKit" --scratch-path "$TEST_SCRATCH" \
  --filter PromptIsolationIntegrationTests
