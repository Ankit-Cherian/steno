#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-release-eval.sh [--smoke-only] [--latency-iterations N]

Required environment for full release eval:
  STENO_WHISPER_CLI       Absolute path to whisper-cli
  STENO_WHISPER_MODEL     Absolute path to a canonical Whisper model
  STENO_LIBRISPEECH_ROOT  Absolute path to the LibriSpeech clean WAV corpus root

Optional environment:
  STENO_VAD_MODEL         Absolute path to the Silero VAD model

Notes:
  - --smoke-only skips the release-signoff run and only exercises package tests plus the smoke fixture benchmark.
  - Full release eval uses real whisper-cli, real model, real audio, and coordinator-owned latency iterations.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  local label="$2"
  [[ -n "$path" ]] || die "$label is required."
  [[ -f "$path" ]] || die "$label not found at: $path"
}

require_dir() {
  local path="$1"
  local label="$2"
  [[ -n "$path" ]] || die "$label is required."
  [[ -d "$path" ]] || die "$label directory not found at: $path"
}

SMOKE_ONLY=0
LATENCY_ITERATIONS=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke-only)
      SMOKE_ONLY=1
      shift
      ;;
    --latency-iterations)
      [[ $# -ge 2 ]] || die "--latency-iterations requires a value."
      LATENCY_ITERATIONS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ "$LATENCY_ITERATIONS" =~ ^[0-9]+$ ]] || die "--latency-iterations must be a positive integer."
(( LATENCY_ITERATIONS >= 1 )) || die "--latency-iterations must be at least 1."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

RUN_DATE="$(date +%F)"
HOST_SLUG="$(hostname -s | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
PYTHON_BIN="${PYTHON_BIN:-python3}"

SMOKE_MANIFEST="$REPO_ROOT/research/benchmarks/manifest.json"
SMOKE_LEXICON="$REPO_ROOT/research/benchmarks/lexicon.json"
SMOKE_CLI="$REPO_ROOT/research/benchmarks/fixtures/fake-whisper-cli.sh"
SMOKE_MODEL="$REPO_ROOT/research/benchmarks/fixtures/fake-model.bin"

require_file "$SMOKE_MANIFEST" "Smoke manifest"
require_file "$SMOKE_LEXICON" "Smoke lexicon"
require_file "$SMOKE_CLI" "Smoke fake whisper-cli"
require_file "$SMOKE_MODEL" "Smoke fake model"
[[ -x "$SMOKE_CLI" ]] || die "Smoke fake whisper-cli is not executable: $SMOKE_CLI"

MODEL_ID=""
MODEL_SLUG=""
CHIP_CLASS=""
MEMORY_GB=""
STENO_VAD_MODEL="${STENO_VAD_MODEL:-}"

if [[ "$SMOKE_ONLY" -eq 0 ]]; then
  STENO_WHISPER_CLI="${STENO_WHISPER_CLI:-}"
  STENO_WHISPER_MODEL="${STENO_WHISPER_MODEL:-}"
  STENO_LIBRISPEECH_ROOT="${STENO_LIBRISPEECH_ROOT:-}"

  require_file "$STENO_WHISPER_CLI" "STENO_WHISPER_CLI"
  [[ -x "$STENO_WHISPER_CLI" ]] || die "STENO_WHISPER_CLI is not executable: $STENO_WHISPER_CLI"
  require_file "$STENO_WHISPER_MODEL" "STENO_WHISPER_MODEL"
  require_dir "$STENO_LIBRISPEECH_ROOT" "STENO_LIBRISPEECH_ROOT"

  if [[ -z "$STENO_VAD_MODEL" ]]; then
    STENO_VAD_MODEL="$(dirname "$STENO_WHISPER_MODEL")/ggml-silero-v6.2.0.bin"
  fi
  require_file "$STENO_VAD_MODEL" "STENO_VAD_MODEL"

  CHIP_CLASS="$("$PYTHON_BIN" - "$(
    sysctl -n machdep.cpu.brand_string
  )" <<'PY'
import re
import sys

brand = sys.argv[1].strip().lower()
match = re.search(r"apple (m\d)(?: (pro|max|ultra))?", brand)
if not match:
    raise SystemExit(1)
chip = match.group(1)
tier = match.group(2)
print(chip if not tier else f"{chip}-{tier}")
PY
  )" || die "Could not classify current chip into an Apple silicon compatibility row."

  MEMORY_GB="$("$PYTHON_BIN" - <<'PY'
import subprocess

mem_bytes = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]).decode().strip())
print(mem_bytes // (1024 ** 3))
PY
  )"

  MODEL_ID="$("$PYTHON_BIN" - "$STENO_WHISPER_MODEL" <<'PY'
from pathlib import Path
import sys

name = Path(sys.argv[1]).name
mapping = {
    "ggml-base.en.bin": "base.en",
    "ggml-small.en.bin": "small.en",
    "ggml-medium.en.bin": "medium.en",
    "ggml-large-v3-turbo.bin": "large-v3-turbo",
}
model_id = mapping.get(name)
if model_id is None:
    raise SystemExit(1)
print(model_id)
PY
  )" || die "STENO_WHISPER_MODEL must point to a canonical model file (base.en, small.en, medium.en, or large-v3-turbo)."

  MODEL_SLUG="${MODEL_ID//./-}"
fi

if [[ "$SMOKE_ONLY" -eq 1 ]]; then
  BUNDLE_ROOT="$REPO_ROOT/research/benchmarks/generated/smoke-${RUN_DATE}-${HOST_SLUG}"
else
  BUNDLE_ROOT="$REPO_ROOT/research/benchmarks/generated/release-signoff-${RUN_DATE}-${HOST_SLUG}-${CHIP_CLASS}-${MEMORY_GB}gb-${MODEL_SLUG}"
fi

rm -rf "$BUNDLE_ROOT"
mkdir -p "$BUNDLE_ROOT"

SMOKE_ROOT="$BUNDLE_ROOT/smoke"
mkdir -p "$SMOKE_ROOT"

SMOKE_RAW="$SMOKE_ROOT/raw_engine.json"
SMOKE_PIPELINE="$SMOKE_ROOT/steno_pipeline.json"
SMOKE_MAC="$SMOKE_ROOT/mac_sanity.json"
SMOKE_REPORT="$SMOKE_ROOT/REPORT.md"

echo "==> swift test"
swift test --package-path StenoKit

echo "==> smoke benchmark"
swift run --package-path StenoKit StenoBenchmarkCLI run-all \
  --manifest "$SMOKE_MANIFEST" \
  --raw-output "$SMOKE_RAW" \
  --pipeline-output "$SMOKE_PIPELINE" \
  --mac-sanity "$SMOKE_MAC" \
  --report-output "$SMOKE_REPORT" \
  --whisper-cli "$SMOKE_CLI" \
  --model "$SMOKE_MODEL" \
  --default-language en \
  --lexicon "$SMOKE_LEXICON"

swift run --package-path StenoKit StenoBenchmarkCLI validate-report --report "$SMOKE_REPORT"
swift run --package-path StenoKit StenoBenchmarkCLI validate-pipeline \
  --pipeline "$SMOKE_PIPELINE" \
  --max-wer-delta 0 \
  --max-cer-delta 0 \
  --max-regressed-samples 0

if [[ "$SMOKE_ONLY" -eq 1 ]]; then
  echo "Smoke-only eval complete."
  echo "Artifacts: $BUNDLE_ROOT"
  exit 0
fi

RELEASE_ROOT="$BUNDLE_ROOT/release"
RELEASE_AUDIO_DIR="$RELEASE_ROOT/audio"
RELEASE_RESULTS_DIR="$RELEASE_ROOT/results"
mkdir -p "$RELEASE_AUDIO_DIR" "$RELEASE_RESULTS_DIR"

RELEASE_MANIFEST="$RELEASE_ROOT/manifest.json"
RELEASE_LEXICON="$RELEASE_ROOT/lexicon.json"
RELEASE_NOTES="$RELEASE_ROOT/corpus_notes.json"
RELEASE_RAW="$RELEASE_RESULTS_DIR/raw_engine.json"
RELEASE_PIPELINE="$RELEASE_RESULTS_DIR/steno_pipeline.json"
RELEASE_MAC="$RELEASE_RESULTS_DIR/mac_sanity.json"
RELEASE_REPORT="$RELEASE_ROOT/REPORT.md"
RELEASE_VALIDATE_LOG="$RELEASE_ROOT/validate_pipeline.log"
SUMMARY_JSON="$RELEASE_ROOT/release_eval_summary.json"
SUMMARY_REPORT="$RELEASE_ROOT/release_eval_report.md"

echo "==> generate local release-signoff corpus"
REPO_ROOT="$REPO_ROOT" \
RELEASE_AUDIO_DIR="$RELEASE_AUDIO_DIR" \
RELEASE_MANIFEST="$RELEASE_MANIFEST" \
RELEASE_LEXICON="$RELEASE_LEXICON" \
RELEASE_NOTES="$RELEASE_NOTES" \
STENO_LIBRISPEECH_ROOT="$STENO_LIBRISPEECH_ROOT" \
CHIP_CLASS="$CHIP_CLASS" \
MEMORY_GB="$MEMORY_GB" \
MODEL_ID="$MODEL_ID" \
"$PYTHON_BIN" - <<'PY'
import json
import math
import os
import random
import subprocess
import wave
from pathlib import Path

audio_dir = Path(os.environ["RELEASE_AUDIO_DIR"])
manifest_path = Path(os.environ["RELEASE_MANIFEST"])
lexicon_path = Path(os.environ["RELEASE_LEXICON"])
notes_path = Path(os.environ["RELEASE_NOTES"])
librispeech_root = Path(os.environ["STENO_LIBRISPEECH_ROOT"])

audio_dir.mkdir(parents=True, exist_ok=True)

say_samples = [
    {
        "id": "repair-zero-token-scratch-that",
        "dataset": "repair-intent",
        "text": "scratch that Jane",
        "referenceText": "Jane",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "repair-one-token-scratch-that",
        "dataset": "repair-intent",
        "text": "Bob scratch that Jane",
        "referenceText": "Jane",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "repair-two-token-scratch-that",
        "dataset": "repair-intent",
        "text": "Call Bob scratch that Jane",
        "referenceText": "Call Jane",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "repair-three-token-scratch-that",
        "dataset": "repair-intent",
        "text": "Send it to Bob scratch that Jane",
        "referenceText": "Send it to Jane",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "repair-four-token-scratch-that",
        "dataset": "repair-intent",
        "text": "Send it to Bob Smith scratch that Jane",
        "referenceText": "Send it to Jane",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "repair-punctuated-scratch-that",
        "dataset": "repair-intent",
        "text": "Bob, scratch that, Jane.",
        "referenceText": "Jane.",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "repair-delete-that",
        "dataset": "repair-intent",
        "text": "Call Bob delete that Jane",
        "referenceText": "Call Jane",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "repair-erase-that",
        "dataset": "repair-intent",
        "text": "Call Bob erase that Jane",
        "referenceText": "Call Jane",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "repair-never-mind",
        "dataset": "repair-intent",
        "text": "Call Bob never mind Jane",
        "referenceText": "Call Jane",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "repair-actually",
        "dataset": "repair-intent",
        "text": "Call Bob actually Jane",
        "referenceText": "Call Jane",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "repair-i-mean",
        "dataset": "repair-intent",
        "text": "Call Bob I mean Jane",
        "referenceText": "Call Jane",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "repair-no-comma",
        "dataset": "repair-intent",
        "text": "Call Bob no, Jane",
        "referenceText": "Call Jane",
        "intentLabels": ["repair"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "literal-scratch-that",
        "dataset": "literal-counterexamples",
        "text": "type scratch that literally",
        "referenceText": "type scratch that literally",
        "intentLabels": ["literal"],
        "preservedPhrases": ["scratch that"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "literal-delete-that",
        "dataset": "literal-counterexamples",
        "text": "write delete that literally",
        "referenceText": "write delete that literally",
        "intentLabels": ["literal"],
        "preservedPhrases": ["delete that"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "literal-i-mean",
        "dataset": "literal-counterexamples",
        "text": "say I mean literally",
        "referenceText": "say I mean literally",
        "intentLabels": ["literal"],
        "preservedPhrases": ["I mean"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "filler-removable-um-uh",
        "dataset": "fillers",
        "text": "um uh I think this should ship today",
        "referenceText": "I think this should ship today",
        "intentLabels": ["fillerRemovable"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "filler-meaning-like",
        "dataset": "fillers",
        "text": "I like this plan",
        "referenceText": "I like this plan",
        "intentLabels": ["fillerMeaningBearing"],
        "preservedPhrases": ["like"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "filler-meaning-you-know",
        "dataset": "fillers",
        "text": "you know if we ship today that is fine",
        "referenceText": "you know if we ship today that is fine",
        "intentLabels": ["fillerMeaningBearing"],
        "preservedPhrases": ["you know"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "term-turso",
        "dataset": "term-recall",
        "text": "send it to Jane and ping TURSO",
        "referenceText": "send it to Jane and ping TURSO",
        "intentLabels": ["termRecall"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "term-rt",
        "dataset": "term-recall",
        "text": "RT should stay literal",
        "referenceText": "RT should stay literal",
        "intentLabels": ["termRecall"],
        "audioSource": "syntheticSpeech",
    },
    {
        "id": "command-slash-build",
        "dataset": "command-safety",
        "text": "/build target",
        "referenceText": "/build target",
        "intentLabels": ["command"],
        "audioSource": "syntheticSpeech",
        "appContextPreset": "ide",
    },
    {
        "id": "transport-editor-plain",
        "dataset": "transport-behavior",
        "text": "hello world",
        "referenceText": "hello world",
        "audioSource": "syntheticSpeech",
        "appContextPreset": "editor",
    },
    {
        "id": "transport-terminal-plain",
        "dataset": "transport-behavior",
        "text": "hello world",
        "referenceText": "hello world",
        "audioSource": "syntheticSpeech",
        "appContextPreset": "terminal",
    },
]

no_speech_samples = [
    {
        "id": "no-speech-silence",
        "dataset": "no-speech",
        "kind": "silence",
        "duration_s": 2.0,
        "referenceText": "",
        "intentLabels": ["noSpeech"],
        "audioSource": "syntheticSilence",
        "appContextPreset": "editor",
    },
    {
        "id": "no-speech-background-noise",
        "dataset": "no-speech",
        "kind": "noise",
        "duration_s": 2.0,
        "referenceText": "",
        "intentLabels": ["noSpeech"],
        "audioSource": "syntheticNoise",
        "appContextPreset": "editor",
    },
    {
        "id": "no-speech-blank-audio",
        "dataset": "no-speech",
        "kind": "blank",
        "duration_s": 0.25,
        "referenceText": "",
        "intentLabels": ["noSpeech"],
        "audioSource": "syntheticSilence",
        "appContextPreset": "editor",
    },
]

librispeech_ids = [
    "0000",
    "0006",
    "0007",
    "0008",
    "0010",
    "0024",
    "0026",
]

def make_tts_wav(sample):
    aiff_path = audio_dir / f"{sample['id']}.aiff"
    wav_path = audio_dir / f"{sample['id']}.wav"
    subprocess.run(
        ["/usr/bin/say", "-o", str(aiff_path), sample["text"]],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [
            "/usr/bin/afconvert",
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            str(aiff_path),
            str(wav_path),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    aiff_path.unlink(missing_ok=True)
    return wav_path

def make_pcm_wav(path, duration_s, mode):
    sample_rate = 16000
    frame_count = max(1, int(duration_s * sample_rate))
    rng = random.Random(17)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        frames = bytearray()
        for _ in range(frame_count):
            if mode == "noise":
                value = rng.randint(-220, 220)
            else:
                value = 0
            frames.extend(int(value).to_bytes(2, byteorder="little", signed=True))
        handle.writeframes(bytes(frames))

def duration_ms(path):
    with wave.open(str(path), "rb") as handle:
        frames = handle.getnframes()
        rate = handle.getframerate()
    return int(round((frames / rate) * 1000))

manifest_samples = []

for sample in say_samples:
    wav_path = make_tts_wav(sample)
    manifest_samples.append(
        {
            "id": sample["id"],
            "dataset": sample["dataset"],
            "audioPath": str(wav_path),
            "referenceText": sample["referenceText"],
            "languageHint": "en",
            "audioDurationMS": duration_ms(wav_path),
            "audioSource": sample["audioSource"],
            "intentLabels": sample.get("intentLabels", []),
            "preservedPhrases": sample.get("preservedPhrases", []),
            "appContextPreset": sample.get("appContextPreset"),
        }
    )

for sample in no_speech_samples:
    wav_path = audio_dir / f"{sample['id']}.wav"
    mode = "noise" if sample["kind"] == "noise" else "silence"
    make_pcm_wav(wav_path, sample["duration_s"], mode)
    manifest_samples.append(
        {
            "id": sample["id"],
            "dataset": sample["dataset"],
            "audioPath": str(wav_path),
            "referenceText": sample["referenceText"],
            "languageHint": "en",
            "audioDurationMS": duration_ms(wav_path),
            "audioSource": sample["audioSource"],
            "intentLabels": sample.get("intentLabels", []),
            "preservedPhrases": sample.get("preservedPhrases", []),
            "appContextPreset": sample.get("appContextPreset"),
        }
    )

for sample_id in librispeech_ids:
    wav_path = librispeech_root / f"librispeech-test-clean-{sample_id}.wav"
    if not wav_path.exists():
        raise SystemExit(f"Missing required LibriSpeech sample: {wav_path}")
    transcript = {
        "0000": "CONCORD RETURNED TO ITS PLACE AMIDST THE TENTS",
        "0006": "THIS HAS INDEED BEEN A HARASSING DAY CONTINUED THE YOUNG MAN HIS EYES FIXED UPON HIS FRIEND",
        "0007": "YOU WILL BE FRANK WITH ME I ALWAYS AM",
        "0008": "CAN YOU IMAGINE WHY BUCKINGHAM HAS BEEN SO VIOLENT I SUSPECT",
        "0010": "I CAN PERCEIVE LOVE CLEARLY ENOUGH",
        "0024": "NOW WHAT WAS THE SENSE OF IT TWO INNOCENT BABIES LIKE THAT",
        "0026": "THE TWIN BROTHER DID SOMETHING SHE DIDN'T LIKE AND SHE TURNED HIS PICTURE TO THE WALL",
    }[sample_id]
    manifest_samples.append(
        {
            "id": f"librispeech-test-clean-{sample_id}",
            "dataset": "librispeech-test-clean",
            "audioPath": str(wav_path),
            "referenceText": transcript,
            "languageHint": "en",
            "audioDurationMS": duration_ms(wav_path),
            "audioSource": "librispeech",
            "intentLabels": [],
            "preservedPhrases": [],
            "appContextPreset": "editor",
        }
    )

manifest = {
    "schemaVersion": "steno-benchmark-manifest/v1",
    "benchmarkName": f"Steno Release Eval - {os.environ['CHIP_CLASS']} {os.environ['MEMORY_GB']}GB {os.environ['MODEL_ID']}",
    "evidenceTier": "releaseSignoff",
    "hardwareProfile": {
        "chipClass": os.environ["CHIP_CLASS"],
        "memoryGB": int(os.environ["MEMORY_GB"]),
        "modelID": os.environ["MODEL_ID"],
    },
    "scoring": {
        "normalization": {
            "version": "steno-normalization-v1",
            "lowercase": True,
            "collapseWhitespace": True,
            "trimWhitespace": True,
            "stripPunctuation": True,
            "keepApostrophes": True,
        }
    },
    "samples": manifest_samples,
}

lexicon = {
    "schemaVersion": "steno-lexicon-v1",
    "entries": [
        {
            "term": "TURSO",
            "preferred": "TURSO",
            "phoneticRecovery": "properNounEnglish",
        },
        {
            "term": "RT",
            "preferred": "RT",
            "phoneticRecovery": "properNounEnglish",
        },
    ],
}

notes = {
    "syntheticSpeech": "Targeted speech samples were generated locally with /usr/bin/say and converted to 16 kHz mono WAV with /usr/bin/afconvert.",
    "syntheticSilence": "Silence and blank-audio samples were generated locally as 16 kHz mono PCM WAVs with zero-valued frames via Python's wave module.",
    "syntheticNoise": "Background-noise samples were generated locally as 16 kHz mono PCM WAVs with low-amplitude pseudo-random PCM noise via Python's wave module.",
    "librispeech": "Raw-ASR baseline samples were taken from the user-provided LibriSpeech clean WAV corpus root.",
}

manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
lexicon_path.write_text(json.dumps(lexicon, indent=2) + "\n", encoding="utf-8")
notes_path.write_text(json.dumps(notes, indent=2) + "\n", encoding="utf-8")
PY

echo "==> release benchmark"
swift run --package-path StenoKit StenoBenchmarkCLI run-all \
  --manifest "$RELEASE_MANIFEST" \
  --raw-output "$RELEASE_RAW" \
  --pipeline-output "$RELEASE_PIPELINE" \
  --mac-sanity "$RELEASE_MAC" \
  --report-output "$RELEASE_REPORT" \
  --whisper-cli "$STENO_WHISPER_CLI" \
  --model "$STENO_WHISPER_MODEL" \
  --threads 8 \
  --default-language en \
  --latency-iterations "$LATENCY_ITERATIONS" \
  --lexicon "$RELEASE_LEXICON" \
  --extra-arg --vad \
  --extra-arg --vad-model \
  --extra-arg "$STENO_VAD_MODEL"

swift run --package-path StenoKit StenoBenchmarkCLI validate-report --report "$RELEASE_REPORT"

RELEASE_VALIDATION_STATUS="pass"
if ! swift run --package-path StenoKit StenoBenchmarkCLI validate-pipeline \
  --pipeline "$RELEASE_PIPELINE" \
  --max-wer-delta 0 \
  --max-cer-delta 0 \
  --max-regressed-samples 0 \
  --min-term-recall-accuracy 1 \
  --min-repair-resolution-rate 1 \
  --max-unintended-rewrite-rate 0 \
  --min-literal-repair-phrase-preservation-rate 1 \
  --max-punctuation-artifact-rate 0 \
  --min-command-passthrough-accuracy 1 \
  --max-no-speech-false-insert-rate 0 \
  >"$RELEASE_VALIDATE_LOG" 2>&1; then
  RELEASE_VALIDATION_STATUS="fail"
fi

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild build"
xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

echo "==> summarize release eval"
REPO_ROOT="$REPO_ROOT" \
RUN_DATE="$RUN_DATE" \
CHIP_CLASS="$CHIP_CLASS" \
MEMORY_GB="$MEMORY_GB" \
MODEL_ID="$MODEL_ID" \
SUMMARY_JSON="$SUMMARY_JSON" \
SUMMARY_REPORT="$SUMMARY_REPORT" \
RELEASE_MANIFEST="$RELEASE_MANIFEST" \
RELEASE_RAW="$RELEASE_RAW" \
RELEASE_PIPELINE="$RELEASE_PIPELINE" \
RELEASE_MAC="$RELEASE_MAC" \
RELEASE_REPORT="$RELEASE_REPORT" \
RELEASE_NOTES="$RELEASE_NOTES" \
SMOKE_REPORT="$SMOKE_REPORT" \
SMOKE_PIPELINE="$SMOKE_PIPELINE" \
RELEASE_VALIDATION_STATUS="$RELEASE_VALIDATION_STATUS" \
RELEASE_VALIDATE_LOG="$RELEASE_VALIDATE_LOG" \
"$PYTHON_BIN" - <<'PY'
import json
import os
import re
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
manifest = json.loads(Path(os.environ["RELEASE_MANIFEST"]).read_text())
raw = json.loads(Path(os.environ["RELEASE_RAW"]).read_text())
pipeline = json.loads(Path(os.environ["RELEASE_PIPELINE"]).read_text())
mac = json.loads(Path(os.environ["RELEASE_MAC"]).read_text())
notes = json.loads(Path(os.environ["RELEASE_NOTES"]).read_text())
summary_json_path = Path(os.environ["SUMMARY_JSON"])
summary_report_path = Path(os.environ["SUMMARY_REPORT"])

matrix = json.loads((repo_root / "StenoKit/Sources/StenoKit/Resources/whisper-compatibility-matrix.json").read_text())
rows = matrix["rows"] if isinstance(matrix, dict) else matrix

hardware = manifest["hardwareProfile"]
compat_row = None
for row in rows:
    if row["chipClass"] != hardware["chipClass"] or row["modelID"] != hardware["modelID"]:
        continue
    min_gb = row["memoryRangeGB"]["minGB"]
    max_gb = row["memoryRangeGB"].get("maxGB")
    if hardware["memoryGB"] < min_gb:
        continue
    if max_gb is not None and hardware["memoryGB"] > max_gb:
        continue
    compat_row = row
    break

sample_truth = {sample["id"]: sample for sample in manifest["samples"]}
raw_samples = {sample["id"]: sample for sample in raw["samples"]}
normalization_policy = manifest.get("scoring", {}).get("normalization", {})
punctuation_pattern = re.compile(r"[^\w\s']") if normalization_policy.get("keepApostrophes", True) else re.compile(r"[^\w\s]")

def fmt_number(value):
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.4f}"
    return str(value)

def fmt_percent(value):
    if value is None:
        return "n/a"
    return f"{value * 100:.2f}%"

def normalize_text(text):
    value = text or ""
    if normalization_policy.get("lowercase", True):
        value = value.lower()
    if normalization_policy.get("stripPunctuation", True):
        value = punctuation_pattern.sub(" ", value)
    if normalization_policy.get("collapseWhitespace", True):
        value = " ".join(value.split())
    if normalization_policy.get("trimWhitespace", True):
        value = value.strip()
    return value

def truncate_text(text, limit=80):
    if text is None:
        return None
    compact = " ".join(str(text).split())
    if len(compact) <= limit:
        return compact
    return compact[: limit - 1] + "…"

def format_timing_breakdown(breakdown):
    if not breakdown:
        return None
    parts = []
    for key, label in [
        ("transcriptionMS", "tx"),
        ("cleanupMS", "clean"),
        ("insertionMS", "insert"),
        ("historyMS", "history"),
    ]:
        value = breakdown.get(key)
        if value is not None:
            parts.append(f"{label}={value}")
    return ", ".join(parts) if parts else None

def gate(status, gate_id, label, actual, threshold, comparison, message):
    return {
        "id": gate_id,
        "label": label,
        "status": status,
        "actual": actual,
        "threshold": threshold,
        "comparison": comparison,
        "message": message,
    }

summary = pipeline["summary"]
pipeline_metrics = {
    "rawWER": summary.get("rawWER"),
    "cleanedWER": summary.get("cleanedWER"),
    "werDelta": summary.get("werDelta"),
    "rawCER": summary.get("rawCER"),
    "cleanedCER": summary.get("cleanedCER"),
    "cerDelta": summary.get("cerDelta"),
    "termRecallAccuracy": summary.get("termRecallAccuracy"),
    "repairMarkerPreservationRate": summary.get("repairMarkerPreservationRate"),
    "repairResolutionRate": summary.get("repairResolutionRate"),
    "repairExactMatchRate": summary.get("repairExactMatchRate"),
    "unintendedRewriteRate": summary.get("unintendedRewriteRate"),
    "literalRepairPhrasePreservationRate": summary.get("literalRepairPhrasePreservationRate"),
    "punctuationArtifactRate": summary.get("punctuationArtifactRate"),
}
coordinator_metrics = {
    "commandPassthroughCoverageRate": summary.get("commandPassthroughCoverageRate"),
    "commandPassthroughAccuracy": summary.get("commandPassthroughAccuracy"),
    "noSpeechFalseInsertRate": summary.get("noSpeechFalseInsertRate"),
    "p50LatencyMS": summary.get("p50LatencyMS"),
    "p90LatencyMS": summary.get("p90LatencyMS"),
    "p99LatencyMS": summary.get("p99LatencyMS"),
}
coordinator_latency_aggregation = "per-sample median across coordinator replay iterations"
gates = []

def add_threshold_gate(gate_id, label, actual, threshold, comparison):
    if actual is None:
        gates.append(gate("missing", gate_id, label, None, threshold, comparison, f"Missing metric: {gate_id}"))
        return
    if comparison == "<=":
        status = "pass" if actual <= threshold else "fail"
    else:
        status = "pass" if actual >= threshold else "fail"
    message = f"{label} {'met' if status == 'pass' else 'missed'} the release threshold."
    gates.append(gate(status, gate_id, label, actual, threshold, comparison, message))

add_threshold_gate("werDelta", "WER delta", summary.get("werDelta"), 0.0, "<=")
add_threshold_gate("cerDelta", "CER delta", summary.get("cerDelta"), 0.0, "<=")
add_threshold_gate("regressedSamples", "Regressed samples", summary.get("regressed"), 0, "<=")
add_threshold_gate("termRecallAccuracy", "Term recall accuracy", summary.get("termRecallAccuracy"), 1.0, ">=")
add_threshold_gate("repairResolutionRate", "Repair trigger detection rate", summary.get("repairResolutionRate"), 1.0, ">=")
add_threshold_gate("unintendedRewriteRate", "Unintended rewrite rate", summary.get("unintendedRewriteRate"), 0.0, "<=")
add_threshold_gate(
    "literalRepairPhrasePreservationRate",
    "Literal repair phrase preservation rate",
    summary.get("literalRepairPhrasePreservationRate"),
    1.0,
    ">=",
)
add_threshold_gate("punctuationArtifactRate", "Punctuation artifact rate", summary.get("punctuationArtifactRate"), 0.0, "<=")
if coordinator_metrics.get("commandPassthroughCoverageRate") == 0:
    gates.append(
        gate(
            "not_evaluable",
            "commandPassthroughAccuracy",
            "Command passthrough accuracy",
            None,
            1.0,
            ">=",
            "Command passthrough was not exercised because the raw benchmark pass never preserved a leading slash.",
        )
    )
else:
    add_threshold_gate("commandPassthroughAccuracy", "Command passthrough accuracy", summary.get("commandPassthroughAccuracy"), 1.0, ">=")
add_threshold_gate("noSpeechFalseInsertRate", "No-speech false insert rate", summary.get("noSpeechFalseInsertRate"), 0.0, "<=")

if compat_row is not None:
    add_threshold_gate("p90LatencyMS", "Coordinator p90 latency (ms)", summary.get("p90LatencyMS"), compat_row.get("p90BudgetMS"), "<=")
    add_threshold_gate("p99LatencyMS", "Coordinator p99 latency (ms)", summary.get("p99LatencyMS"), compat_row.get("p99BudgetMS"), "<=")

failing_gates = [item["id"] for item in gates if item["status"] == "fail"]
not_evaluable_gates = [item["id"] for item in gates if item["status"] == "not_evaluable"]
missing_metrics = [item["id"] for item in gates if item["status"] == "missing"]

def command_text_matches(observations, reference):
    cleaned_reference = " ".join(reference.strip().split())
    successful = [obs.get("insertResult") for obs in observations if obs.get("insertResult")]
    if not successful:
        return False
    return all(" ".join(result.get("insertedText", "").strip().split()) == cleaned_reference for result in successful)

def command_passthrough_contract_exercised(observations):
    successful = [obs.get("insertResult") for obs in observations if obs.get("insertResult")]
    if not successful:
        return False
    return all((result.get("cleanupOutcome") or {}).get("source") == "localOnly" for result in successful)

def no_speech_false_insert(observations):
    if not observations:
        return True
    for observation in observations:
        result = observation.get("insertResult")
        if result is None:
            return True
        if result.get("status") != "noSpeech" or result.get("method") != "none" or result.get("insertedText", "").strip():
            return True
    return False

def punctuation_artifact(text):
    if not text or not text.strip():
        return False
    stripped = text.strip()
    if stripped[:1] in ",;:!?":
        return True
    if ", " in stripped and stripped.endswith(","):
        return True
    if any(token in stripped for token in [" ,", " .", " !", " ?"]):
        return True
    if "!!" in stripped or "??" in stripped:
        return True
    return False

def build_sample_record(sample, truth, notes_for_sample):
    observations = sample.get("coordinatorObservations", [])
    insert_results = [obs.get("insertResult") for obs in observations if obs.get("insertResult")]
    last_insert = insert_results[-1] if insert_results else None
    raw_metrics = sample.get("rawMetrics") or {}
    cleaned_metrics = sample.get("cleanedMetrics") or {}
    latencies = [obs.get("latencyMS") for obs in observations if obs.get("latencyMS") is not None]
    peak_observation = max(
        [obs for obs in observations if obs.get("latencyMS") is not None],
        key=lambda obs: obs["latencyMS"],
        default=None,
    )
    return {
        "id": sample["id"],
        "dataset": sample["dataset"],
        "audioSource": truth.get("audioSource"),
        "intentLabels": truth.get("intentLabels", []),
        "notes": notes_for_sample,
        "rawWER": raw_metrics.get("wer"),
        "cleanedWER": cleaned_metrics.get("wer"),
        "status": sample.get("status"),
        "outcome": sample.get("outcome"),
        "coordinatorInsertStatus": last_insert["status"] if last_insert else None,
        "coordinatorInsertMethod": last_insert["method"] if last_insert else None,
        "coordinatorLastInsertedText": last_insert.get("insertedText") if last_insert else None,
        "pipelineRawText": sample.get("rawText"),
        "pipelineCleanedText": sample.get("cleanedText"),
        "peakLatencyMS": max(latencies) if latencies else None,
        "peakTimingBreakdownMS": peak_observation.get("timingBreakdownMS") if peak_observation else None,
    }

all_sample_records = []
for sample in pipeline["samples"]:
    truth = sample_truth.get(sample["id"], {})
    notes_for_sample = []
    if sample.get("status") != "success":
        notes_for_sample.append(sample.get("errorMessage") or "Pipeline sample was not scored.")
    if "repair" in truth.get("intentLabels", []):
        raw_text = sample.get("rawText") or ""
        repair_marker_survived = any(
            marker in raw_text.lower()
            for marker in ["scratch that", "delete that", "erase that", "never mind", "i mean", "actually", "no,"]
        )
        if not repair_marker_survived:
            notes_for_sample.append("raw pipeline output did not preserve a recognizable repair marker")
        elif not any(edit.get("kind") == "repairResolution" for edit in sample.get("edits", [])):
            notes_for_sample.append("repair parser did not fire after a recognizable marker survived ASR")
        if repair_marker_survived and normalize_text(sample.get("cleanedText", "")) != normalize_text(truth.get("referenceText", "")):
            notes_for_sample.append("repair exact match missed the reference")
    if "literal" in truth.get("intentLabels", []):
        cleaned_lower = normalize_text(sample.get("cleanedText", ""))
        preserved = truth.get("preservedPhrases", [])
        if any(normalize_text(phrase) not in cleaned_lower for phrase in preserved):
            notes_for_sample.append("literal repair phrase not preserved")
    if "command" in truth.get("intentLabels", []):
        observations = sample.get("coordinatorObservations", [])
        if not command_passthrough_contract_exercised(observations):
            notes_for_sample.append("command passthrough contract was not exercised in coordinator replay")
        elif not command_text_matches(observations, truth.get("referenceText", "")):
            notes_for_sample.append("command text was not passed through exactly once the slash contract was exercised")
    if "noSpeech" in truth.get("intentLabels", []) and no_speech_false_insert(sample.get("coordinatorObservations", [])):
        notes_for_sample.append("no-speech sample produced an insert")
    if punctuation_artifact(sample.get("cleanedText", "")):
        notes_for_sample.append("punctuation artifact detected")
    latencies = [obs.get("latencyMS") for obs in sample.get("coordinatorObservations", []) if obs.get("latencyMS") is not None]
    peak_latency = max(latencies) if latencies else None
    if compat_row is not None and peak_latency is not None and peak_latency > compat_row.get("p99BudgetMS", peak_latency):
        notes_for_sample.append("peak coordinator latency exceeded the p99 budget")
    if sample.get("outcome") == "regressed":
        notes_for_sample.append("pipeline cleanup regressed the raw transcript")
    all_sample_records.append(build_sample_record(sample, truth, notes_for_sample))

failing_samples = [item for item in all_sample_records if item["notes"]]
worst_samples = list(all_sample_records)

worst_samples.sort(
    key=lambda item: (
        item["peakLatencyMS"] if item["peakLatencyMS"] is not None else -1,
        item["cleanedWER"] if item["cleanedWER"] is not None else -1,
        item["rawWER"] if item["rawWER"] is not None else -1,
    ),
    reverse=True,
)
failing_samples.sort(
    key=lambda item: (
        len(item["notes"]),
        item["peakLatencyMS"] if item["peakLatencyMS"] is not None else -1,
        item["cleanedWER"] if item["cleanedWER"] is not None else -1,
        item["rawWER"] if item["rawWER"] is not None else -1,
    ),
    reverse=True,
)

latency_outliers = []
for sample in pipeline["samples"]:
    observations = [obs for obs in sample.get("coordinatorObservations", []) if obs.get("latencyMS") is not None]
    if not observations:
        continue
    peak = max(observations, key=lambda obs: obs["latencyMS"])
    insert_result = peak.get("insertResult") or {}
    latency_outliers.append(
        {
            "id": sample["id"],
            "dataset": sample["dataset"],
            "audioSource": sample_truth.get(sample["id"], {}).get("audioSource"),
            "peakLatencyMS": peak["latencyMS"],
            "iteration": peak["iteration"],
            "insertStatus": insert_result.get("status"),
            "insertMethod": insert_result.get("method"),
            "insertedText": insert_result.get("insertedText"),
            "timingBreakdownMS": peak.get("timingBreakdownMS"),
        }
    )
latency_outliers.sort(key=lambda item: item["peakLatencyMS"], reverse=True)

likely_causes = []
recommended_next_fixes = []
if "repairResolutionRate" in failing_gates:
    likely_causes.append("Repair resolution misses one or more zero-token, multi-token, or alternate-marker correction patterns.")
    recommended_next_fixes.append("Audit repair parsing across scratch/delete/erase/never mind/actually/I mean/no, variants before changing ranking or ASR behavior.")
if "literalRepairPhrasePreservationRate" in failing_gates:
    likely_causes.append("Literal counterexamples are still being interpreted as destructive repair commands.")
    recommended_next_fixes.append("Add explicit literal-intent protections before cleanup rewrites fire.")
if "commandPassthroughAccuracy" in failing_gates:
    likely_causes.append("Slash-command samples are not preserving exact command text through coordinator insertion.")
    recommended_next_fixes.append("Audit command passthrough from raw transcript to InsertResult, especially exact leading slash preservation.")
if "noSpeechFalseInsertRate" in failing_gates:
    likely_causes.append("No-speech gating still allows one or more silent or noisy clips to produce inserted text.")
    recommended_next_fixes.append("Audit no-speech gating on silence, short blank clips, and low-amplitude noise before any cleanup runs.")
if "termRecallAccuracy" in failing_gates:
    likely_causes.append("Lexicon or phonetic recovery missed one or more proper noun or acronym recovery cases.")
    recommended_next_fixes.append("Audit lexicon hot terms, phonetic opt-in behavior, and short-acronym suppression against the failing samples.")
if "punctuationArtifactRate" in failing_gates:
    likely_causes.append("Cleanup left visible punctuation artifacts in one or more outputs.")
    recommended_next_fixes.append("Audit filler and repair cleanup punctuation normalization on the failing samples.")
if any(gate_id in failing_gates for gate_id in ["werDelta", "cerDelta", "regressedSamples"]):
    likely_causes.append("Post-processing is regressing raw ASR on at least one measured sample.")
    recommended_next_fixes.append("Investigate the failing regressed samples before making any broader cleanup or ranking changes.")
if any(gate_id in failing_gates for gate_id in ["p90LatencyMS", "p99LatencyMS"]):
    likely_causes.append("Coordinator stop-to-insert latency is over the hardware row budget on this machine/model pair.")
    recommended_next_fixes.append("Profile coordinator replay latencies on the worst samples before making any compatibility claim changes.")

audio_source_counts = {}
for sample in manifest["samples"]:
    audio_source_counts[sample.get("audioSource", "unknown")] = audio_source_counts.get(sample.get("audioSource", "unknown"), 0) + 1

phase_status = {
    "swiftTest": "pass",
    "smokeBenchmark": "pass",
    "releaseBenchmark": os.environ["RELEASE_VALIDATION_STATUS"],
    "xcodeBuild": "pass",
    "manualMacSanity": mac.get("overallStatus", "pending"),
}

overall_status = "pass"
if phase_status["releaseBenchmark"] != "pass" or failing_gates or missing_metrics:
    overall_status = "fail"

release_root = Path(os.environ["RELEASE_MANIFEST"]).parent
bundle_root = release_root.parent
legacy_typo_bundle_root = Path(str(bundle_root).replace(
    f"-{hardware['chipClass']}-",
    f"--{hardware['chipClass']}-",
    1,
))
deprecated_artifact_roots = []
if legacy_typo_bundle_root != bundle_root and legacy_typo_bundle_root.exists():
    deprecated_artifact_roots.append(str(legacy_typo_bundle_root))

summary_payload = {
    "schemaVersion": "steno-release-eval-summary/v1",
    "generatedAt": os.environ["RUN_DATE"],
    "overallStatus": overall_status,
    "phaseStatus": phase_status,
    "benchmarkName": manifest["benchmarkName"],
    "evidenceTier": manifest["evidenceTier"],
    "hardwareProfile": hardware,
    "compatibilityRow": compat_row,
    "canonicalRun": {
        "bundleRoot": str(bundle_root),
        "releaseRoot": str(release_root),
        "deprecatedArtifactRoots": deprecated_artifact_roots,
    },
    "metricSources": {
        "pipelineCleanup": [
            "rawWER",
            "cleanedWER",
            "werDelta",
            "rawCER",
            "cleanedCER",
            "cerDelta",
            "termRecallAccuracy",
            "repairMarkerPreservationRate",
            "repairResolutionRate",
            "repairExactMatchRate",
            "unintendedRewriteRate",
            "literalRepairPhrasePreservationRate",
            "punctuationArtifactRate",
        ],
    "coordinatorReplay": [
            "commandPassthroughCoverageRate",
            "commandPassthroughAccuracy",
            "noSpeechFalseInsertRate",
            "p50LatencyMS",
            "p90LatencyMS",
            "p99LatencyMS",
        ],
    },
    "pipelineMetrics": pipeline_metrics,
    "coordinatorMetrics": coordinator_metrics,
    "coordinatorLatencyAggregation": coordinator_latency_aggregation,
    "artifacts": {
        "smokeReport": os.environ["SMOKE_REPORT"],
        "smokePipeline": os.environ["SMOKE_PIPELINE"],
        "raw": os.environ["RELEASE_RAW"],
        "pipeline": os.environ["RELEASE_PIPELINE"],
        "macSanity": os.environ["RELEASE_MAC"],
        "benchmarkReport": os.environ["RELEASE_REPORT"],
    },
    "audioSourceBreakdown": audio_source_counts,
    "rawSummary": raw["summary"],
    "rawDatasetBreakdown": raw["datasetBreakdown"],
    "pipelineSummary": summary,
    "gates": gates,
    "failingGates": failing_gates,
    "notEvaluableGates": not_evaluable_gates,
    "missingMetrics": missing_metrics,
    "failingSamples": failing_samples,
    "worstSamples": worst_samples[:12],
    "latencyOutliers": latency_outliers[:10],
    "analysis": {
        "likelyCauses": likely_causes,
        "recommendedNextFixes": recommended_next_fixes,
        "validationStatement": (
            f"This run {'validates' if overall_status == 'pass' else 'does not validate'} the exact "
            f"{hardware['chipClass']} / {hardware['memoryGB']}GB / {hardware['modelID']} row. "
            "No other hardware rows are validated by this evidence."
        ),
        "syntheticSpeechNote": "If a metric fails on say-generated speech, it is definitely broken. If it passes on say-generated speech, production microphone behavior is still unproven.",
        "syntheticNoSpeechNote": "Silence and blank clips were generated as zero-valued 16 kHz PCM WAVs; the noise clip was generated as low-amplitude pseudo-random 16 kHz PCM WAV noise.",
    },
}

summary_json_path.write_text(json.dumps(summary_payload, indent=2) + "\n", encoding="utf-8")

gate_rows = []
for gate_item in gates:
    gate_rows.append(
        f"| {gate_item['label']} | {gate_item['status']} | {fmt_number(gate_item['actual'])} | {gate_item['comparison']} {fmt_number(gate_item['threshold'])} | {gate_item['message']} |"
    )

dataset_rows = []
for name, values in sorted(raw["datasetBreakdown"].items()):
    dataset_rows.append(
        f"| {name} | {values['totalSamples']} | {fmt_percent(values['failureRate'])} | {fmt_number(values.get('wer'))} | {fmt_number(values.get('cer'))} | {fmt_number(values.get('meanLatencyMS'))} |"
    )

failing_sample_rows = []
for sample in failing_samples:
    failing_sample_rows.append(
        f"| {sample['id']} | {sample['dataset']} | {sample.get('audioSource') or 'n/a'} | {', '.join(sample['notes']) or 'n/a'} | {truncate_text(sample.get('pipelineRawText')) or 'n/a'} | {truncate_text(sample.get('pipelineCleanedText')) or 'n/a'} | {(sample.get('coordinatorInsertStatus') or 'n/a')} / {(sample.get('coordinatorInsertMethod') or 'n/a')} | {truncate_text(sample.get('coordinatorLastInsertedText')) or 'n/a'} | {fmt_number(sample.get('peakLatencyMS'))} | {format_timing_breakdown(sample.get('peakTimingBreakdownMS')) or 'n/a'} |"
    )

worst_sample_rows = []
for sample in worst_samples[:12]:
    worst_sample_rows.append(
        f"| {sample['id']} | {sample['dataset']} | {sample.get('audioSource') or 'n/a'} | {fmt_number(sample.get('rawWER'))} | {fmt_number(sample.get('cleanedWER'))} | {fmt_number(sample.get('peakLatencyMS'))} | {truncate_text(sample.get('pipelineCleanedText')) or 'n/a'} | {truncate_text(sample.get('coordinatorLastInsertedText')) or 'n/a'} |"
    )

latency_rows = []
for sample in latency_outliers[:10]:
    latency_rows.append(
        f"| {sample['id']} | {sample['dataset']} | {sample.get('audioSource') or 'n/a'} | {fmt_number(sample.get('peakLatencyMS'))} | {sample.get('iteration') or 'n/a'} | {sample.get('insertStatus') or 'n/a'} | {sample.get('insertMethod') or 'n/a'} | {truncate_text(sample.get('insertedText')) or 'n/a'} | {format_timing_breakdown(sample.get('timingBreakdownMS')) or 'n/a'} |"
    )

audio_rows = [f"- `{key}`: {value} samples" for key, value in sorted(audio_source_counts.items())]
cause_rows = [f"- {item}" for item in likely_causes] or ["- No interpretive root causes were generated because all release gates passed."]
fix_rows = [f"- {item}" for item in recommended_next_fixes] or ["- No product follow-up is recommended from this run because all release gates passed."]

report = f"""# Release Eval Report

## Measured Facts
- Overall status: `{overall_status}`
- Phase status: `swiftTest={phase_status['swiftTest']}`, `smokeBenchmark={phase_status['smokeBenchmark']}`, `releaseBenchmark={phase_status['releaseBenchmark']}`, `xcodeBuild={phase_status['xcodeBuild']}`, `manualMacSanity={phase_status['manualMacSanity']}`
- Benchmark: `{manifest['benchmarkName']}`
- Evidence tier: `{manifest['evidenceTier']}`
- Hardware profile: `{hardware['chipClass']}` / `{hardware['memoryGB']}GB` / `{hardware['modelID']}`
- Canonical release root: `{release_root}`
- Canonical bundle root: `{bundle_root}`
- Deprecated typo-path roots: `{', '.join(deprecated_artifact_roots) if deprecated_artifact_roots else 'none detected'}`
- Artifacts:
  - Raw: `{os.environ['RELEASE_RAW']}`
  - Pipeline: `{os.environ['RELEASE_PIPELINE']}`
  - Mac sanity: `{os.environ['RELEASE_MAC']}`
  - Benchmark report: `{os.environ['RELEASE_REPORT']}`
  - Summary JSON: `{os.environ['SUMMARY_JSON']}`

### Raw ASR
| Metric | Value |
|---|---:|
| Samples | {raw['summary']['totalSamples']} |
| Success | {raw['summary']['succeeded']} |
| Failure | {raw['summary']['failed']} |
| Failure Rate | {fmt_percent(raw['summary']['failureRate'])} |
| WER | {fmt_number(raw['summary'].get('wer'))} |
| CER | {fmt_number(raw['summary'].get('cer'))} |
| Mean Latency (ms) | {fmt_number(raw['summary'].get('meanLatencyMS'))} |
| p50 Latency (ms) | {fmt_number(raw['summary'].get('p50LatencyMS'))} |
| p90 Latency (ms) | {fmt_number(raw['summary'].get('p90LatencyMS'))} |
| p99 Latency (ms) | {fmt_number(raw['summary'].get('p99LatencyMS'))} |

### Raw ASR Dataset Breakdown
| Dataset | Samples | Failure Rate | WER | CER | Mean Latency (ms) |
|---|---:|---:|---:|---:|---:|
{chr(10).join(dataset_rows)}

### Pipeline Cleanup Quality
| Metric | Value |
|---|---:|
| Raw WER (same samples) | {fmt_number(pipeline_metrics.get('rawWER'))} |
| Cleaned WER | {fmt_number(pipeline_metrics.get('cleanedWER'))} |
| WER Delta | {fmt_number(pipeline_metrics.get('werDelta'))} |
| Raw CER (same samples) | {fmt_number(pipeline_metrics.get('rawCER'))} |
| Cleaned CER | {fmt_number(pipeline_metrics.get('cleanedCER'))} |
| CER Delta | {fmt_number(pipeline_metrics.get('cerDelta'))} |
| Term Recall Accuracy | {fmt_percent(pipeline_metrics.get('termRecallAccuracy'))} |
| Repair Marker Preservation Rate | {fmt_percent(pipeline_metrics.get('repairMarkerPreservationRate'))} |
| Repair Trigger Detection Rate | {fmt_percent(pipeline_metrics.get('repairResolutionRate'))} |
| Repair Exact Match Rate | {fmt_percent(pipeline_metrics.get('repairExactMatchRate'))} |
| Unintended Rewrite Rate | {fmt_percent(pipeline_metrics.get('unintendedRewriteRate'))} |
| Literal Repair Phrase Preservation Rate | {fmt_percent(pipeline_metrics.get('literalRepairPhrasePreservationRate'))} |
| Punctuation Artifact Rate | {fmt_percent(pipeline_metrics.get('punctuationArtifactRate'))} |

### Coordinator End-to-End Replay
| Metric | Value |
|---|---:|
| Command Passthrough Coverage Rate | {fmt_percent(coordinator_metrics.get('commandPassthroughCoverageRate'))} |
| Command Passthrough Accuracy | {fmt_percent(coordinator_metrics.get('commandPassthroughAccuracy'))} |
| No-Speech False Insert Rate | {fmt_percent(coordinator_metrics.get('noSpeechFalseInsertRate'))} |
| Coordinator p50 Latency (ms) | {fmt_number(coordinator_metrics.get('p50LatencyMS'))} |
| Coordinator p90 Latency (ms) | {fmt_number(coordinator_metrics.get('p90LatencyMS'))} |
| Coordinator p99 Latency (ms) | {fmt_number(coordinator_metrics.get('p99LatencyMS'))} |
- Latency aggregation for the gateable coordinator numbers: {coordinator_latency_aggregation}

### Gate Results
| Gate | Status | Actual | Threshold | Notes |
|---|---|---:|---:|---|
{chr(10).join(gate_rows)}

### Failing Samples
| Sample ID | Dataset | Audio Source | Failure Notes | Pipeline Raw | Pipeline Cleaned | Coordinator Result | Coordinator Inserted Text | Peak Latency (ms) | Timing Breakdown (ms) |
|---|---|---|---|---|---|---|---|---:|---|
{chr(10).join(failing_sample_rows) if failing_sample_rows else '| none | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a |'}

### Worst Samples
| Sample ID | Dataset | Audio Source | Raw WER | Cleaned WER | Peak Latency (ms) | Pipeline Cleaned | Coordinator Inserted Text |
|---|---|---|---:|---:|---:|---|---|
{chr(10).join(worst_sample_rows) if worst_sample_rows else '| none | n/a | n/a | n/a | n/a | n/a | n/a | n/a |'}

### Latency Tail Samples
| Sample ID | Dataset | Audio Source | Peak Latency (ms) | Iteration | Insert Status | Insert Method | Insert Text | Timing Breakdown (ms) |
|---|---|---|---:|---:|---|---|---|---|
{chr(10).join(latency_rows) if latency_rows else '| none | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a |'}

### Audio Evidence
{chr(10).join(audio_rows)}
- Synthetic speech note: {summary_payload['analysis']['syntheticSpeechNote']}
- Silence/noise generation: {summary_payload['analysis']['syntheticNoSpeechNote']}
- Corpus notes:
  - {notes['syntheticSpeech']}
  - {notes['syntheticSilence']}
  - {notes['syntheticNoise']}
  - {notes['librispeech']}

### Mac Sanity
- Overall status: `{mac.get('overallStatus', 'pending')}`
- Checklist path: `{os.environ['RELEASE_MAC']}`
- Manual macOS sanity remains separate from the blocking metric gate for this run.

## Interpretive Summary
### Likely Root Causes
{chr(10).join(cause_rows)}

### Recommended Next Fixes
{chr(10).join(fix_rows)}

### Validation Statement
- {summary_payload['analysis']['validationStatement']}
- Smoke fixtures are not release evidence.
- Clean audiobook clips plus synthetic targeted speech do not validate production microphone behavior.
- Manual macOS sanity is still `{phase_status['manualMacSanity']}` and remains separate from the blocking metric gate.
"""

summary_report_path.write_text(report.strip() + "\n", encoding="utf-8")
PY

echo "Release eval complete."
echo "Bundle: $BUNDLE_ROOT"
echo "Summary JSON: $SUMMARY_JSON"
echo "Summary report: $SUMMARY_REPORT"
if [[ "$RELEASE_VALIDATION_STATUS" != "pass" ]]; then
  echo "Release signoff gates failed for this machine/model row."
  exit 1
fi
