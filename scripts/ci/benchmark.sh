#!/usr/bin/env bash
# Public inference smoke regression, not broad acoustic accuracy acceptance.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WHISPER_ROOT="${STENO_WHISPER_ROOT:-$REPO_ROOT/vendor/whisper.cpp}"
RUNTIME_BUILD="${STENO_WHISPER_BUILD_DIR:-$WHISPER_ROOT/build-steno}"
OUTPUT="${STENO_CI_BENCHMARK_OUTPUT:-$REPO_ROOT/build/ci/benchmark}"
EXPECTED_REVISION=764482c3175d9c3bc6089c1ec84df7d1b9537d83
[[ ! -e "$OUTPUT" ]] || { echo 'Benchmark output already exists; choose a new output.' >&2; exit 1; }
[[ "$(git -C "$WHISPER_ROOT" rev-parse HEAD)" == "$EXPECTED_REVISION" ]]
[[ -x "$RUNTIME_BUILD/bin/whisper-cli" ]]
[[ -f "$WHISPER_ROOT/models/ggml-small.en.bin" ]]
python3 - "$REPO_ROOT/scripts/ci/benchmark-manifest.json" "$WHISPER_ROOT/samples/jfk.wav" "$OUTPUT" <<'PY'
import hashlib, json, pathlib, sys, wave
audio = pathlib.Path(sys.argv[2]).resolve(strict=True)
output = pathlib.Path(sys.argv[3])
if hashlib.sha256(audio.read_bytes()).hexdigest() != '59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e':
    raise SystemExit('Public JFK fixture checksum mismatch')
with wave.open(str(audio)) as wav:
    if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()) != (1, 2, 16000, 176000):
        raise SystemExit('Public JFK fixture geometry mismatch')
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
if manifest['evidenceTier'] != 'smokeFixture' or len(manifest['samples']) != 1:
    raise SystemExit('Unexpected public benchmark coverage')
manifest['samples'][0]['audioPath'] = str(audio)
output.mkdir(parents=True, exist_ok=False)
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
swift run --package-path "$REPO_ROOT/StenoKit" StenoBenchmarkCLI run-all \
  --manifest "$OUTPUT/manifest.json" --raw-output "$OUTPUT/raw_engine.json" \
  --pipeline-output "$OUTPUT/steno_pipeline.json" --mac-sanity "$OUTPUT/mac_sanity.json" \
  --report-output "$OUTPUT/REPORT.md" --whisper-cli "$RUNTIME_BUILD/bin/whisper-cli" \
  --model "$WHISPER_ROOT/models/ggml-small.en.bin" --threads 4 --default-language en
swift run --package-path "$REPO_ROOT/StenoKit" StenoBenchmarkCLI validate-report --report "$OUTPUT/REPORT.md"
swift run --package-path "$REPO_ROOT/StenoKit" StenoBenchmarkCLI validate-pipeline \
  --pipeline "$OUTPUT/steno_pipeline.json" --max-wer-delta 0 --max-cer-delta 0 --max-regressed-samples 0
