# Contributing to Steno

For local app setup, start with [QUICKSTART.md](QUICKSTART.md). This guide covers changes to the unreleased 1.0.0 source. Use the documentation for the branch or tag you are working on.

The [CI guide](docs/ci-cd.md) explains package and hosted tests, runtime checks, the public-audio smoke benchmark, preview builds, and how to reproduce failures locally. Maintainers must complete [GitHub activation](docs/maintainers/github-setup.md) to enforce these checks. Release requirements are tracked in [the 1.0 checklist](docs/release/1.0-checklist.md).

## Prerequisites

- an Apple silicon Mac
- a macOS version supported by your Xcode installation; the app's deployment target is macOS 13.0+
- Xcode with Swift 6.2 or later; CI uses Xcode 26.3
- XcodeGen (`brew install xcodegen`)
- CMake (`brew install cmake`)
- a local `whisper.cpp` checkout at the pinned revision, built under `vendor/whisper.cpp/build-steno`
- the `small.en` Whisper model for default source-app setup and runtime discovery
- the Silero VAD model for the canonical app and release-eval configuration

## First-Time Setup

1. Clone the repository, then select the branch or tag you intend to contribute to:

   ```bash
   git clone https://github.com/Ankit-Cherian/steno.git
   cd steno
   ```

2. Build `whisper.cpp`:

   ```bash
   git clone https://github.com/ggerganov/whisper.cpp vendor/whisper.cpp
   cd vendor/whisper.cpp
   git checkout 764482c3175d9c3bc6089c1ec84df7d1b9537d83
   cd ../..
   scripts/build-whisper-runtime-helper.sh
   ```

   This build disables host-specific CPU tuning, BLAS, RPC, CURL, and the Whisper server while retaining Accelerate and Metal. It produces arm64 `whisper-cli` and `steno-whisper-runtime` binaries under `vendor/whisper.cpp/build-steno/bin/` for macOS 13 or later.

3. Download the default model and VAD model:

   ```bash
   cd vendor/whisper.cpp
   ./models/download-ggml-model.sh small.en
   cd models
   ./download-vad-model.sh silero-v6.2.0
   cd ../../..
   ```

   Medium and Large V3 Turbo are optional downloads in Settings → Speech model. Additional evaluation models can be downloaded with `./models/download-ggml-model.sh medium.en` or `./models/download-ggml-model.sh large-v3-turbo` from `vendor/whisper.cpp`.

4. Generate the local Xcode project:

   ```bash
   xcodegen generate
   ```

5. Open `Steno.xcodeproj`, set your Apple Developer Team in Signing & Capabilities, and run the app locally.

   If runtime discovery fails, follow the explicit path setup in [QUICKSTART.md](QUICKSTART.md#3-run-in-xcode).

## Daily Development Loop

For substantial code changes, run:

```bash
cd /path/to/steno
swift test --package-path StenoKit
xcodegen generate
xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Run the relevant hosted tests for app behavior or UI changes. Check microphone capture, media interruption, editor insertion, appearance, VoiceOver, installation, and macOS 13 behavior in the app when your change affects them. Automated tests alone cannot verify those interactions.

For documentation-only changes, verify the claims against source, check links and commands, and review the diff. Always report results for the source you actually tested.

## Architecture

### Retained Whisper runtime

`steno-whisper-runtime` is a private child process that keeps the Whisper model loaded between compatible dictations. It communicates over inherited pipes and must not expose a network listener. The first request loads the model; changes to the model, VAD path, or another part of its load configuration require a reload. Cancellation, shutdown, sleep/wake recovery, memory pressure, and helper failure must release or invalidate retained resources safely. Recoverable helper failures can use `WhisperCLITranscriptionEngine` for the request. Cancellation, stale responses, and VAD integrity failures must not trigger that fallback.

### Insights privacy and persistence

The Insights ledger stores session timestamps, application identifiers, word and duration counts and their sources, cleanup counts, and insertion outcomes. It contains no transcript text or audio. Deleting History content does not delete usage totals. Preserve this separation during migrations and corruption recovery, and distinguish measured from estimated values in the UI.

### Media and cleanup safety

Media interruption must fail closed. Pause and Play are semantic, application-targeted commands, and resume ownership is valid only for the exact application/process lineage Steno verified that it paused. Do not add a global play/pause toggle fallback.

Default cleanup must preserve ambiguous dictated language. Phrases such as `like`, `you know`, `question mark`, `open paren`, and `slash command` stay literal instead of being automatically converted or removed; only the aggressive filler policy performs narrow filler removal. Keep repairs, punctuation, lexicon corrections, and command passthrough covered by preservation counterexamples.

## Release-Eval and Benchmark Workflow

### Smoke benchmark

Check that the benchmark runner and report generation work. Python 3 is required; the script generates its synthetic inputs automatically:

```bash
cd /path/to/steno
scripts/run-smoke-benchmark.sh
```

This uses fixtures and does not measure recognition quality or release latency. Changes to transcription, runtime behavior, post-processing, cleanup, ranking, or benchmark logic also need real-audio evaluation with the report and zero-regression pipeline gates in [the evaluation guide](docs/release/release-eval.md): no increase in WER or CER, and no regressed samples.

### Full release signoff

Measure a specific hardware and model combination. This requires Python 3 and the prepared LibriSpeech WAV subset described in [the evaluation guide](docs/release/release-eval.md). The script expects specific filenames and reference text; an unprepared LibriSpeech download is not sufficient.

```bash
cd /path/to/steno
STENO_WHISPER_CLI=/absolute/path/to/whisper-cli \
STENO_WHISPER_MODEL=/absolute/path/to/ggml-large-v3-turbo.bin \
STENO_VAD_MODEL=/absolute/path/to/ggml-silero-v6.2.0.bin \
STENO_LIBRISPEECH_ROOT=/absolute/path/to/librispeech_test_clean \
scripts/run-release-eval.sh
```

Results apply to the tested hardware and model. A `not_evaluable` metric is neither a pass nor a failure: the run did not establish that result. Keep generated reports out of Git. See [the evaluation guide](docs/release/release-eval.md) for details and [the distribution guide](docs/release/direct-distribution.md) for DMG packaging.

## Code Style

### Swift 6 concurrency

- Use actors for mutable shared state
- Mark UI code with `@MainActor`
- Prefer `Sendable` value types for domain models
- Avoid `@unchecked Sendable` unless bridging constraints force it

### UI and design-system rules

- Do not hardcode fonts, shadows, spacing, or colors when `StenoDesign`/theme tokens already exist
- Respect `accessibilityReduceMotion`
- Add accessibility labels to interactive elements
- Follow the single Manuscript design and its semantic typography/color roles; preserve saved accents and the transparent in-app mark
- Keep the compact Dictate action and configured shortcuts together; preserve mode-aware Stop and a separate Cancel action
- Keep overlay text display-only, bounded, revision-aware, and readable across light/dark modes and supported window sizes
- Keep Settings drafts, persistent Save changes/Discard controls, and conflict protection intact; appearance changes save immediately
- Synthetic review fixtures must stay isolated from microphone, global shortcuts, system permissions, playback, and personal storage

### General engineering rules

- No `print()` debugging in committed code
- No force unwraps unless there is a very narrow, well-justified boundary
- Prefer protocol-first design for reusable services
- Keep generated state out of git unless the repo explicitly tracks it

## Testing Notes

Steno uses Swift Testing for its package and hosted macOS regression suites.

Run the full package suite:

```bash
cd /path/to/steno
swift test --package-path StenoKit
```

Run one test by name:

```bash
cd /path/to/steno
swift test --package-path StenoKit --filter overlayHitTestingReturnsInteractiveButtonForNestedContent
```

Run the hosted macOS test target after generating the project:

```bash
xcodegen generate
xcodebuild test -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

When adding behavior:

- prefer regression tests first
- keep literal-preservation counterexamples near aggressive cleanup logic
- distinguish raw-ASR problems from cleanup problems before patching

## XcodeGen Workflow

`Steno.xcodeproj` is generated from `project.yml`.

Whenever you:

- add or remove files under `Steno/`
- change project configuration
- modify signing/resource settings in `project.yml`

rerun:

```bash
xcodegen generate
```

Do not commit the generated Xcode project unless the repository starts tracking it again.

## Code Signing and TCC

Do not commit personal signing settings.

Keep these local:

- Apple Developer Team identifiers
- personal provisioning profiles
- personal signing identities

Changing those in tracked source can invalidate user TCC permissions and force re-grants for:

- Microphone
- Accessibility
- Input Monitoring

Local Xcode runs require selecting an Apple Developer Team. Package tests and unsigned command-line builds do not. Public distribution requires Developer ID signing, hardened runtime, notarization, stapling, and verification of the resulting artifact. Follow the distribution guide when preparing a release.

## Pull Request Checklist

Before opening a PR, complete the checks that apply to the change. Documentation-only PRs need claim, link, command, and diff checks. Substantial code changes require the package suite and app build; app behavior or UI changes also require relevant hosted tests.

- [ ] `swift test --package-path StenoKit` passes
- [ ] `xcodegen generate` succeeds
- [ ] `xcodebuild test -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] transcription/runtime, cleanup, ranking, or benchmark changes passed real-audio report and zero-regression pipeline checks; fixture smoke results are identified separately
- [ ] public docs match the source and reported results
- [ ] no generated benchmark bundles are staged
- [ ] no generated Xcode project changes are staged unintentionally
- [ ] commit history keeps one concern per commit
- [ ] any required live microphone, media-player, insertion, UI, VoiceOver, installed-app, and macOS 13 checks are reported separately instead of inferred from automated tests
- [ ] distribution work, when in scope, has separate signing and notarization evidence

## Related docs

- Repo overview: [README.md](README.md)
- Fast user setup: [QUICKSTART.md](QUICKSTART.md)
- Core package overview: [StenoKit/README.md](StenoKit/README.md)
- Release-eval guide: [docs/release/release-eval.md](docs/release/release-eval.md)
