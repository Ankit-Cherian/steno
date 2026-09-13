# Steno Release Evaluation

Use the smoke benchmark to check the runner and reports. Use the release evaluation to measure recognition quality and stop-to-insert latency for a specific Mac and model with `whisper.cpp` and coordinator timing.

The current candidate needs a fresh evaluation tied to its final commit and declared corpus. Results from 0.2/0.2.1, including the May 15, 2026 corpus work and the `m5-pro / 64GB / large-v3-turbo` run, remain historical. They cannot validate the next release.

Package tests, hosted tests, builds, and synthetic renders establish separate evidence from recognition evaluation. Record the final evaluation and manual checks in [the release checklist](1.0-checklist.md).

## Smoke benchmark

With Python 3 and the Swift toolchain available, both evaluation scripts generate their fake recognizer, model marker, and silent WAV placeholders from the tracked smoke definitions in a fresh temporary directory. No ignored fixture files, downloaded model, or private audio are needed for the smoke stage. The generated inputs remain in that temporary directory so the report can refer to them; temporary-file cleanup can remove them later.

```bash
cd /path/to/steno
scripts/run-smoke-benchmark.sh
```

The standalone smoke command writes `research/benchmarks/results/` and `research/benchmarks/REPORT.md`, replacing prior results at those paths. Preserve any evidence you need before running it.

This checks that `StenoBenchmarkCLI run-all` executes, reports contain the required labels, and pipeline validation reads the expected delta metrics. The fixtures do not measure model quality, release latency, hardware compatibility, or macOS integration.

## Release evaluation

Run this for the hardware and model you intend to evaluate. Output bundles are named by date, host, hardware, and model under `research/benchmarks/generated/`. The script refuses an existing bundle, preserving its evidence; move the previous bundle to a separate archive path before a same-day rerun. Smoke-only bundles similarly use a date-and-host name.

```bash
cd /path/to/steno
STENO_WHISPER_CLI=/absolute/path/to/whisper-cli \
STENO_WHISPER_MODEL=/absolute/path/to/ggml-large-v3-turbo.bin \
STENO_VAD_MODEL=/absolute/path/to/ggml-silero-v6.2.0.bin \
STENO_LIBRISPEECH_ROOT=/absolute/path/to/librispeech_test_clean \
scripts/run-release-eval.sh
```

The script runs:

1. `swift test --package-path StenoKit`
2. The smoke fixture benchmark and its validations
3. Generation of the release-signoff corpus
4. The release benchmark using the supplied executable, model, and VAD paths
5. Report validation and pipeline gates for zero WER/CER regression, zero regressed samples, and the declared intent/no-speech metrics
6. `xcodegen generate`
7. `xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

The script then writes an evaluation summary. A failed pipeline gate is recorded, the app build and summary still run, and the script exits with failure. Earlier command failures can stop the run before a summary is available. Hosted macOS tests are not part of this script.

The final build disables code signing. Signing, notarization, stapling, installation, launch, and publication are separate steps.

Supply these environment variables for a full run:

| Variable | Required input |
| --- | --- |
| `STENO_WHISPER_CLI` | Path to the executable `whisper-cli` |
| `STENO_WHISPER_MODEL` | Path to the Whisper model file |
| `STENO_LIBRISPEECH_ROOT` | Path to the prepared LibriSpeech WAV subset described below |
| `STENO_VAD_MODEL` | Path to the Silero VAD model; may be omitted if `ggml-silero-v6.2.0.bin` exists beside the selected Whisper model |

The script requires the VAD file even when it derives the path automatically. Full runs also require Xcode, XcodeGen, Python 3, and the macOS `say` and `afconvert` tools. It generates synthetic speech locally and reads an existing human-speech subset; it does not download or convert the original LibriSpeech archive.

The supplied corpus directory must contain `librispeech-test-clean-0000.wav`, `0006`, `0007`, `0008`, `0010`, `0024`, and `0026` with the same filename prefix and `.wav` extension. These are preselected clips whose reference text is embedded in `scripts/run-release-eval.sh`; an arbitrary LibriSpeech directory or unrelated audio renamed to those filenames is not equivalent evidence. Verify the prepared clips against those references before evaluating.

The default latency measurement uses three iterations per sample. Pass `--latency-iterations N` with a positive integer to change it, and report that choice with the results.

To run package tests and the smoke fixture only:

```bash
cd /path/to/steno
scripts/run-release-eval.sh --smoke-only
```

Generated reports and evaluation bundles stay out of Git. Publish summarized metrics with their source commit, corpus, hardware, and model, rather than private local artifact paths.

## Report word and character error rates

Word error rate (WER) is the primary English dictation metric: it counts substituted, inserted, and deleted words. Character error rate (CER) adds spelling detail that a word-level score can hide or penalize differently. Lower values are better for both.

| Metric | Raw ASR | After Steno cleanup | Improvement |
| --- | ---: | ---: | ---: |
| WER | baseline error rate | cleaned error rate | absolute percentage-point drop and relative error reduction |
| CER | baseline error rate | cleaned error rate | absolute percentage-point drop and relative error reduction |

Name the baseline and corpus for each report. In the historical 0.2/0.2.1 results, the baseline was raw local `whisper.cpp` output before Steno cleanup; do not assume that definition for a new run. Put the corpus, hardware, model, and normalization policy beside the table.

Report both the absolute percentage-point drop and relative error reduction. If the raw error rate is zero, relative reduction is undefined; report the absolute change instead. For example, `22.37% -> 9.21%` is `13.16` percentage points lower and about `59%` relative WER reduction.

- `WER = (substitutions + insertions + deletions) / reference words`
- `CER = (character substitutions + insertions + deletions) / reference characters`
- `relative error reduction = (raw error rate - cleaned error rate) / raw error rate`

These scores describe the evaluated samples. Do not present them as universal product accuracy. Comparisons with other systems require the same corpus, normalization policy, and hardware scope. Include stop-to-insert latency alongside accuracy so readers can assess the dictation experience.

## Hardware and model status

The compatibility matrix is stored at `StenoKit/Sources/StenoKit/Resources/whisper-compatibility-matrix.json`:

- `validated`: the exact hardware/model row has measured release-signoff results.
- `allowed-warning`: the configuration is recommended or supported, but that row has not completed release validation.

The historical `m5-pro / 64GB / large-v3-turbo` result applies only to its named run. It does not validate other Pro/Max Macs or a later release. Identify the run and commit when reporting a pass, and obtain fresh results for the current candidate.

## Metrics marked `not_evaluable`

A metric is `not_evaluable` when the corpus did not exercise the behavior needed to score it. This is neither a pass nor a failure.

For example, historical `commandPassthroughAccuracy` was not evaluable when the raw recognition omitted the leading slash. That run could not test whether cleanup preserved a slash command. Keep this limitation visible in the report instead of claiming command passthrough was validated.

## Manual macOS checks

Each generated release bundle contains `release/results/mac_sanity.json` for the manual checklist. Keep its `pending` status until those checks are performed; benchmark results do not complete it.

Package and hosted tests, report checks, zero-regression validation, and an unsigned build do not replace testing with a microphone, supported media apps, real editors, or an installed app. Verify exact-app pause/resume, insertion, UI, VoiceOver, and macOS 13 behavior separately. Signing and notarization also require their own results.

These manual and distribution checks remain pending for the current candidate until performed and recorded against the selected release source.
