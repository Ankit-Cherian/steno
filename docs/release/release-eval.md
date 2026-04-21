# Steno Release Eval

## Why this exists

Steno now has two very different benchmark paths:

- a **smoke** path that proves the repo-level validation machinery works
- a **release-signoff** path that measures a real hardware/model row with real `whisper.cpp`, a real model file, and coordinator-owned latency timing

This document exists so contributors do not blur those two together.

## Smoke fixture vs release signoff

### Smoke fixture

Use the smoke path when you want fast confidence that the benchmark pipeline, report generation, and validation gates are still wired correctly.

Run:

```bash
cd /path/to/steno
scripts/run-smoke-benchmark.sh
```

What it proves:

- `StenoBenchmarkCLI run-all` still works
- report generation still produces the required labels
- pipeline validation still sees the expected delta metrics

What it does **not** prove:

- real model quality on your machine
- real release latency
- real hardware-row validation
- real macOS integration behavior

### Release signoff

Use the release path when you want a real measured verdict for one exact hardware/model row.

Run:

```bash
cd /path/to/steno
STENO_WHISPER_CLI=/absolute/path/to/whisper-cli \
STENO_WHISPER_MODEL=/absolute/path/to/ggml-large-v3-turbo.bin \
STENO_VAD_MODEL=/absolute/path/to/ggml-silero-v6.2.0.bin \
STENO_LIBRISPEECH_ROOT=/absolute/path/to/librispeech_test_clean \
scripts/run-release-eval.sh
```

This path runs:

1. `swift test --package-path StenoKit`
2. the smoke fixture benchmark and validations
3. a generated release-signoff corpus
4. the real release benchmark with explicit env overrides
5. report validation
6. `xcodegen generate`
7. `xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

## Required environment variables

For a full release run, these are required:

- `STENO_WHISPER_CLI`
- `STENO_WHISPER_MODEL`
- `STENO_LIBRISPEECH_ROOT`

Optional but effectively expected for realistic runs:

- `STENO_VAD_MODEL`

The script will derive `STENO_VAD_MODEL` from the selected model directory if you omit it, but that only works if the expected Silero file is present next to the selected Whisper model.

## Canonical commands

### Smoke only

```bash
cd /path/to/steno
scripts/run-release-eval.sh --smoke-only
```

### Full release signoff on the current local setup

```bash
cd /path/to/steno
STENO_WHISPER_CLI=/path/to/whisper-cli \
STENO_WHISPER_MODEL=/path/to/ggml-large-v3-turbo.bin \
STENO_VAD_MODEL=/path/to/ggml-silero-v6.2.0.bin \
STENO_LIBRISPEECH_ROOT=/path/to/librispeech_test_clean \
scripts/run-release-eval.sh
```

## Canonical artifact roots

Release-eval bundles are written under:

`research/benchmarks/generated/release-signoff-YYYY-MM-DD-HOST-CHIP-MEMORYgb-MODEL/`

The current canonical 0.2 candidate bundle in this repo is:

`research/benchmarks/generated/release-signoff-2026-04-21-macbook-pro-m5-pro-64gb-large-v3-turbo`

Inside it:

- `smoke/` contains the smoke fixture artifacts
- `release/` contains the real release-signoff artifacts

The most important files are:

- `release/release_eval_summary.json`
- `release/release_eval_report.md`
- `release/results/raw_engine.json`
- `release/results/steno_pipeline.json`
- `release/results/mac_sanity.json`
- `release/REPORT.md`

If older typo-path or double-dash bundles exist from prior runs, treat them as historical only. The newest canonical host/chip/memory/model bundle should be the truth source for public release claims.

## Compatibility-matrix policy

The compatibility matrix lives at:

`StenoKit/Sources/StenoKit/Resources/whisper-compatibility-matrix.json`

Rules:

- `validated` means one exact row has measured release-signoff evidence
- `allowed-warning` means the model is still a recommendation or supported configuration, but it does **not** yet have exact release validation for that row
- release-eval evidence is row-specific, not universal

That means:

- it is fair to say the exact `m5-pro / 64GB / large-v3-turbo` row is validated
- it is **not** fair to say “large-v3-turbo is validated on all high-end Apple silicon Macs”

## Interpreting `not_evaluable` gates

Some metrics are only valid if the corpus honestly exercised the behavior.

Current example:

- `commandPassthroughAccuracy` can be `not_evaluable` if the raw benchmark pass never preserved a leading slash and therefore never truly exercised the command-passthrough contract.

Do not present `not_evaluable` as a pass, and do not present it as a real failure either. It means the corpus did not prove the behavior one way or the other.

## Manual macOS sanity

Release signoff intentionally separates metric gates from manual macOS sanity.

The manual checklist lives in:

`release/results/mac_sanity.json`

This lets the repo distinguish:

- measured benchmark truth
- manual interaction truth

For public release notes and README copy:

- it is fair to say the exact benchmark row passed
- it is also fair to say manual macOS sanity remains a separate checklist when it is still `pending`

## Safe wording boundaries

Safe:

- “The exact `m5-pro / 64GB / large-v3-turbo` row passed the canonical release-signoff run.”
- “Smoke fixtures are preflight checks, not release evidence.”
- “Command passthrough is still `not_evaluable` on the current canonical corpus.”

Not safe:

- “All Pro/Max Macs are validated.”
- “Release eval proves microphone behavior everywhere.”
- “Command passthrough is fully benchmark-validated.”
