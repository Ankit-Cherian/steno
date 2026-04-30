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

## Release Output Boundary

Full release-eval runs create local audit artifacts for verification. Keep those outputs out of git, and publish summarized metrics instead of local artifact paths.

## Reporting WER and CER improvements

Release docs should make improvement claims easy to verify without turning them into marketing shorthand.

Use this shape:

| Metric | Raw ASR | After Steno cleanup | Improvement |
|---|---:|---:|---:|
| WER | baseline error rate | cleaned error rate | absolute percentage-point drop and relative error reduction |
| CER | baseline error rate | cleaned error rate | absolute percentage-point drop and relative error reduction |

Rules:

- WER and CER are error rates, so lower is better.
- WER is the primary ASR metric for English dictation because it measures substitutions, insertions, and deletions at the word level.
- CER is useful as a companion metric because it shows spelling/character-level cleanup that WER can hide or over-penalize.
- Always name the baseline. For Steno 0.2 release docs, baseline means raw local `whisper.cpp` output before Steno cleanup.
- Show absolute drop in percentage points and relative error reduction. Example: `22.37% -> 9.21%` is `13.16` percentage points lower and a `59%` relative WER reduction.
- Keep corpus, hardware, model, and normalization boundaries visible near the table.
- Do not describe WER/CER as universal product accuracy, and do not compare against other systems unless the same corpus, normalization policy, and hardware scope are used.
- Pair accuracy metrics with latency for dictation UX. A lower WER is less useful if stop-to-insert latency no longer feels interactive.

Formula reference:

- `WER = (substitutions + insertions + deletions) / reference words`
- `CER = (character substitutions + insertions + deletions) / reference characters`
- `relative error reduction = (raw error rate - cleaned error rate) / raw error rate`

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
