# Contributing to Steno

Thanks for your interest in contributing to Steno.

If you want to use the app locally, start with [QUICKSTART.md](QUICKSTART.md). This guide is for contributors working on the repo itself.

## Prerequisites

Before you start:

- an Apple silicon Mac
- macOS 13.0+
- Xcode 26+
- XcodeGen (`brew install xcodegen`)
- CMake (`brew install cmake`)
- a local `whisper.cpp` checkout at the pinned revision, built under `vendor/whisper.cpp/build-steno`
- at least one canonical Whisper model
- the Silero VAD model for the canonical app and release-eval configuration

## First-Time Setup

1. Clone the repository:

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

   This canonical build disables host-specific CPU tuning, BLAS, RPC, CURL, and the Whisper server while retaining Accelerate and Metal. It produces arm64 `whisper-cli` and `steno-whisper-runtime` binaries under `vendor/whisper.cpp/build-steno/bin/` for the app's macOS 13 deployment target.

3. Download local models:

   ```bash
   cd vendor/whisper.cpp
   ./models/download-ggml-model.sh small.en
   ./models/download-ggml-model.sh medium.en
   ./models/download-ggml-model.sh large-v3-turbo
   cd models
   ./download-vad-model.sh silero-v6.2.0
   cd ../../..
   ```

4. Generate the local Xcode project:

   ```bash
   xcodegen generate
   ```

5. Open `Steno.xcodeproj`, set your Apple Developer Team in Signing & Capabilities, and run the app locally.

## Daily Development Loop

For normal code changes, the expected validation path is:

```bash
cd /path/to/steno
swift test --package-path StenoKit
xcodegen generate
xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Use that as the default automated “done” bar for substantial work. It does not prove live microphone capture, supported-player media interruption, insertion into real applications, UI appearance, VoiceOver behavior, an installed app bundle, or macOS 13 compatibility; run and report those checks separately when the change requires them.

## Unreleased 1.0 Architecture Boundaries

### Retained Whisper runtime

`steno-whisper-runtime` is a private child process that keeps a compatible Whisper model context loaded between dictations. It communicates over inherited pipes and must not expose an HTTP server or other network listener. The first request loads the model; changes to model, VAD path, or another load identity invalidate that context and make the next request reload it. Cancellation, shutdown, sleep/wake recovery, memory pressure, and helper failure must release or invalidate retained resources safely. `WhisperCLITranscriptionEngine` remains the per-request fallback.

### Insights privacy and persistence

Insights is a primary sidebar destination. Its local ledger records per-session aggregate metadata—timestamps, application identifiers, word and duration counts with provenance, cleanup counts, and insertion outcomes—not transcript text or audio. It persists independently of transcript history, so deleting History content does not delete aggregate usage totals. Keep migrations, corruption recovery, and UI copy honest about exact versus estimated metrics.

### Media and cleanup safety

Media interruption must fail closed. Pause and Play are semantic, application-targeted commands, and resume ownership is valid only for the exact application/process lineage Steno verified that it paused. Do not add a global play/pause toggle fallback.

Default cleanup must preserve ambiguous dictated language. Phrases such as `like`, `you know`, `question mark`, `open paren`, and `slash command` stay literal instead of being automatically converted or removed; only the aggressive filler policy performs narrow filler removal. Keep repairs, punctuation, lexicon corrections, and command passthrough covered by preservation counterexamples.

## Release-Eval and Benchmark Workflow

Steno has two distinct benchmark paths.

### Smoke benchmark

Use this to confirm the repo-level benchmark machinery is still healthy:

```bash
cd /path/to/steno
scripts/run-smoke-benchmark.sh
```

This is a fast fixture path. It is not release evidence.

### Full release signoff

Use this when you need a measured verdict for one exact hardware/model row:

```bash
cd /path/to/steno
STENO_WHISPER_CLI=/absolute/path/to/whisper-cli \
STENO_WHISPER_MODEL=/absolute/path/to/ggml-large-v3-turbo.bin \
STENO_VAD_MODEL=/absolute/path/to/ggml-silero-v6.2.0.bin \
STENO_LIBRISPEECH_ROOT=/absolute/path/to/librispeech_test_clean \
scripts/run-release-eval.sh
```

Important boundaries:

- smoke fixtures are preflight only
- release signoff is row-specific
- `not_evaluable` metrics should not be presented as real passes or real failures
- generated release outputs are local audit artifacts, not tracked source files

For the detailed workflow, see [docs/release/release-eval.md](docs/release/release-eval.md).

For the self-contained DMG distribution path, see [docs/release/direct-distribution.md](docs/release/direct-distribution.md).

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
- Follow the existing Steno visual system instead of reintroducing older default-control styling

### General engineering rules

- No `print()` debugging in committed code
- No force unwraps unless there is a very narrow, well-justified boundary
- Prefer protocol-first design for reusable services
- Keep generated state out of git unless the repo explicitly tracks it

## Testing Notes

Steno uses Swift Testing, not XCTest.

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

Do not commit generated Xcode project churn unless the repo policy changes to explicitly track it again.

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

Local Xcode runs require selecting an Apple Developer Team. Automated package tests and unsigned command-line builds do not. Public distribution additionally requires the maintainer's Developer ID signing identity, hardened runtime configuration, notarization credentials, and stapling/verification workflow. Do not treat an unsigned build as distribution proof; signing and notarization are separate release actions.

## Pull Request Checklist

Before opening a PR:

- [ ] `swift test --package-path StenoKit` passes
- [ ] `xcodegen generate` succeeds
- [ ] `xcodebuild test -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] `xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] benchmark-facing changes were validated with the correct smoke or release path
- [ ] public docs reflect current measured truth, not stale thread context
- [ ] no generated benchmark bundles are staged
- [ ] no generated Xcode project churn is staged unintentionally
- [ ] commit history keeps one concern per commit
- [ ] any required live microphone, media-player, insertion, UI, VoiceOver, installed-app, and macOS 13 checks are reported separately instead of inferred from automated tests
- [ ] distribution work, when in scope, has separate signing and notarization evidence

## Where to Look Next

- Repo overview: [README.md](README.md)
- Fast user setup: [QUICKSTART.md](QUICKSTART.md)
- Core package overview: [StenoKit/README.md](StenoKit/README.md)
- Release-eval guide: [docs/release/release-eval.md](docs/release/release-eval.md)
