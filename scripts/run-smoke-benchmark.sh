#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MANIFEST="$REPO_ROOT/research/benchmarks/manifest.json"
LEXICON="$REPO_ROOT/research/benchmarks/lexicon.json"
FAKE_CLI="$REPO_ROOT/research/benchmarks/fixtures/fake-whisper-cli.sh"
FAKE_MODEL="$REPO_ROOT/research/benchmarks/fixtures/fake-model.bin"
RAW_OUT="$REPO_ROOT/research/benchmarks/results/raw_engine.json"
PIPELINE_OUT="$REPO_ROOT/research/benchmarks/results/steno_pipeline.json"
MAC_SANITY="$REPO_ROOT/research/benchmarks/results/mac_sanity.json"
REPORT_OUT="$REPO_ROOT/research/benchmarks/REPORT.md"

mkdir -p "$REPO_ROOT/research/benchmarks/results"

[[ -f "$MANIFEST" ]] || { echo "Missing manifest: $MANIFEST" >&2; exit 1; }
[[ -f "$LEXICON" ]] || { echo "Missing lexicon: $LEXICON" >&2; exit 1; }
[[ -x "$FAKE_CLI" ]] || { echo "Missing or non-executable fake whisper CLI: $FAKE_CLI" >&2; exit 1; }
[[ -f "$FAKE_MODEL" ]] || { echo "Missing fake model: $FAKE_MODEL" >&2; exit 1; }

echo "==> smoke benchmark"
swift run --package-path StenoKit StenoBenchmarkCLI run-all \
  --manifest "$MANIFEST" \
  --raw-output "$RAW_OUT" \
  --pipeline-output "$PIPELINE_OUT" \
  --mac-sanity "$MAC_SANITY" \
  --report-output "$REPORT_OUT" \
  --whisper-cli "$FAKE_CLI" \
  --model "$FAKE_MODEL" \
  --default-language en \
  --lexicon "$LEXICON"

echo "==> validate report"
swift run --package-path StenoKit StenoBenchmarkCLI validate-report \
  --report "$REPORT_OUT"

echo "==> validate pipeline"
swift run --package-path StenoKit StenoBenchmarkCLI validate-pipeline \
  --pipeline "$PIPELINE_OUT" \
  --max-wer-delta 0 \
  --max-cer-delta 0 \
  --max-regressed-samples 0

echo "Smoke benchmark complete."
echo "Raw: $RAW_OUT"
echo "Pipeline: $PIPELINE_OUT"
echo "Mac sanity: $MAC_SANITY"
echo "Report: $REPORT_OUT"
