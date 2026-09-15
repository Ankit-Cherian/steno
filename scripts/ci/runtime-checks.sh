#!/usr/bin/env bash
# Native checks use only upstream public audio, system speech, and generated silence.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WHISPER_ROOT="$ROOT_DIR/vendor/whisper.cpp"
OUTPUT=""
BACKEND="metal"
RECEIPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) WHISPER_ROOT="${2:?--root requires a path}"; shift 2 ;;
    --output) OUTPUT="${2:?--output requires a path}"; shift 2 ;;
    --backend) BACKEND="${2:?--backend requires cpu or metal}"; shift 2 ;;
    --verify-receipt) RECEIPT="${2:?--verify-receipt requires a path}"; shift 2 ;;
    *) echo "Usage: $0 [--root PATH] [--backend cpu|metal] --output NEW_DIRECTORY
       $0 [--backend cpu|metal] --verify-receipt RECEIPT_JSON" >&2; exit 2 ;;
  esac
done
case "$BACKEND" in
  cpu) export GGML_METAL_DEVICES=0 ;;
  metal) unset GGML_METAL_DEVICES ;;
  *) echo "Error: --backend must be cpu or metal" >&2; exit 2 ;;
esac

verify_receipt() {
  python3 - "$1" "$BACKEND" <<'PY'
import json, sys

def require(condition, message):
    if not condition:
        raise ValueError(message)

try:
    with open(sys.argv[1]) as source:
        receipt = json.load(source)
    backend = sys.argv[2]
    cases, execution = receipt["cases"], receipt["execution"]
    require(execution["matrix"] == "full-adversarial", "Full adversarial matrix is required")
    require(cases["expected"] == cases["passed"] == 26, "All 26 helper cases must pass")
    require(cases["failed"] == cases["skipped"] == 0, "Failed or skipped helper cases are not allowed")
    require(cases["failureRows"] == cases["skipRows"] == [], "Failure or skip evidence is present")
    rows = cases["rows"]
    require(len(rows) == len({row["name"] for row in rows}) == 26,
            "Helper case rows must contain 26 unique cases")
    require(all(row["status"] == "passed" and row["failureReason"] is None
                and row["skipReason"] is None for row in rows), "Helper case rows did not all pass")
    counts = execution["observedBackends"]
    eligible = execution["backendEligibleProcessCount"]
    require(type(eligible) is int and eligible > 0, "Missing eligible backend process evidence")
    require(execution["attestedProcessCount"] == eligible, "Not all eligible processes were attested")
    require(set(counts) == {"cpu", "metal", "unknown"}, "Backend evidence is incomplete")
    require(all(type(count) is int and count >= 0 for count in counts.values()), "Backend counts are invalid")
    require(counts[backend] == eligible and sum(counts.values()) == eligible,
            "Observed processes do not match the requested backend")
    require(execution["backend"] == "observed-" + backend, "Observed backend summary mismatch")
    if backend == "cpu":
        require(execution["requestedDeviceMode"] == "cpu-device-suppressed", "CPU device mode was not requested")
        require(execution["qualification"] == "nonqualifying-cpu-diagnostic"
                and execution["productionMetalSmokePerformed"] is False,
                "CPU evidence must not claim production Metal qualification")
    else:
        require(execution["requestedDeviceMode"] == "default", "Metal device mode was not requested")
        require(execution["qualification"] == "qualifying-production-metal"
                and execution["productionMetalSmokePerformed"] is True,
                "Metal production qualification is missing")
    print(f"Verified all 26 helper cases and {eligible} attested {backend} processes")
except (OSError, ValueError, KeyError, TypeError) as error:
    raise SystemExit(f"Error: invalid runtime receipt: {error}")
PY
}

# Read-only receipt validation is also available for CI evidence review and tests.
if [[ -n "$RECEIPT" ]]; then
  verify_receipt "$RECEIPT"
  exit
fi
[[ -n "$OUTPUT" ]] || { echo "Error: --output is required" >&2; exit 2; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo "Error: Native runtime checks require an Apple Silicon macOS runner" >&2; exit 1;
}
bash "$ROOT_DIR/scripts/ci/prepare-runtime.sh" --root "$WHISPER_ROOT" --verify-only
WHISPER_ROOT="$(cd "$WHISPER_ROOT" && pwd)"
OUTPUT="$(python3 - "$OUTPUT" "$WHISPER_ROOT" <<'PY'
import os, pathlib, sys
p = pathlib.Path(os.path.abspath(sys.argv[1]))
runtime = pathlib.Path(sys.argv[2])
if p.exists() or any(x.is_symlink() for x in [p, *p.parents]):
    raise SystemExit("Error: runtime check output must be a new directory without symlinks")
if p == runtime or runtime in p.parents or p in runtime.parents:
    raise SystemExit("Error: runtime check output must not overlap runtime sources")
p.mkdir(parents=True)
print(p)
PY
)"
export STENO_WHISPER_ROOT="$WHISPER_ROOT"
export STENO_WHISPER_BUILD_DIR="$OUTPUT/build-steno"
export STENO_WHISPER_RUNTIME_OUTPUT="$STENO_WHISPER_BUILD_DIR/bin/steno-whisper-runtime"
export STENO_TEST_RETAINED_HELPER="$STENO_WHISPER_RUNTIME_OUTPUT"
export STENO_TEST_WHISPER_CLI="$STENO_WHISPER_BUILD_DIR/bin/whisper-cli"
export STENO_TEST_WHISPER_MODEL="$WHISPER_ROOT/models/ggml-small.en.bin"
export STENO_TEST_WHISPER_VAD="$WHISPER_ROOT/models/ggml-silero-v6.2.0.bin"
export STENO_TEST_WHISPER_AUDIO="$WHISPER_ROOT/samples/jfk.wav"
export STENO_SKIP_HELPER_BUILD=1

run_check() {
  local name="$1"; shift
  echo "==> $name"
  "$@" 2>&1 | tee "$OUTPUT/$name.log"
}
run_check build bash "$ROOT_DIR/scripts/build-whisper-runtime-helper.sh"
PATCHED_SOURCE="$(python3 "$ROOT_DIR/scripts/ci/prepare-patched-runtime.py" \
  --root "$WHISPER_ROOT" --build-dir "$STENO_WHISPER_BUILD_DIR" \
  --revision "$(git -C "$WHISPER_ROOT" rev-parse HEAD)")"
run_check allocation-failures python3 "$ROOT_DIR/scripts/ci/test-vendor-allocation-failures.py" \
  --whisper-root "$PATCHED_SOURCE" --build-dir "$STENO_WHISPER_BUILD_DIR"
run_check prompt-verification bash "$ROOT_DIR/scripts/test-whisper-prompt-verification.sh"
run_check vad-integrity bash "$ROOT_DIR/scripts/test-whisper-vad-integrity.sh"
if run_check helper-protocol bash "$ROOT_DIR/scripts/test-whisper-runtime-helper-v2.sh" \
  --vad-model "$STENO_TEST_WHISPER_VAD" --receipt "$OUTPUT/helper-protocol.json"; then
  :
else
  protocol_status=$?
  # Additional evidence cannot turn the failed protocol gate into a pass.
  run_check helper-diagnostic python3 "$ROOT_DIR/scripts/ci/diagnose-runtime-inference.py" \
    --helper "$STENO_TEST_RETAINED_HELPER" --model "$STENO_TEST_WHISPER_MODEL" \
    --audio "$STENO_TEST_WHISPER_AUDIO" || echo "Runtime diagnostic did not complete successfully."
  exit "$protocol_status"
fi
verify_receipt "$OUTPUT/helper-protocol.json" | tee "$OUTPUT/backend-verification.log"
run_check prompt-scoring bash "$ROOT_DIR/scripts/test-whisper-prompt-scoring.sh"

python3 - "$OUTPUT/silence.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1], "wb") as audio:
    audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
    audio.writeframes(b"\0\0" * 32000)
PY
export STENO_TEST_WHISPER_AUDIO="$OUTPUT/silence.wav"
export STENO_TEST_WHISPER_EXPECT_EMPTY=1
export STENO_TEST_WHISPER_REPETITIONS=5
run_check retained-silence swift test --package-path "$ROOT_DIR/StenoKit" \
  --scratch-path "$OUTPUT/swift-build" --filter retainedProcessRuntimeMatchesCLIContract
echo "All native runtime checks passed with $BACKEND inference. Evidence: $OUTPUT"
if [[ "$BACKEND" == cpu ]]; then
  echo "CPU checks do not qualify production Metal performance or manual app acceptance."
fi
