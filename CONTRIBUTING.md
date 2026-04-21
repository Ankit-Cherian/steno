# Contributing to Steno

Thanks for your interest in contributing to Steno.

If you want to use the app locally, start with [QUICKSTART.md](QUICKSTART.md). This guide is for contributors working on the repo itself.

## Prerequisites

Before you start:

- macOS 13.0+
- Xcode 26+
- XcodeGen (`brew install xcodegen`)
- CMake (`brew install cmake`)
- a local `whisper.cpp` checkout built under `vendor/whisper.cpp`
- at least one canonical Whisper model
- the Silero VAD model if you want realistic release-eval or no-speech behavior

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
   git checkout v1.8.3
   cmake -B build && cmake --build build --config Release
   cd ../..
   ```

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
cd /Users/ankitcherian/Desktop/LocalProjects/Steno-next
swift test --package-path StenoKit
xcodegen generate
xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Use that as the default “done” bar for substantial work.

## Release-Eval and Benchmark Workflow

Steno has two distinct benchmark paths.

### Smoke benchmark

Use this to confirm the repo-level benchmark machinery is still healthy:

```bash
cd /Users/ankitcherian/Desktop/LocalProjects/Steno-next
scripts/run-smoke-benchmark.sh
```

This is a fast fixture path. It is not release evidence.

### Full release signoff

Use this when you need a measured verdict for one exact hardware/model row:

```bash
cd /Users/ankitcherian/Desktop/LocalProjects/Steno-next
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
- generated release bundles under `research/benchmarks/generated/` are ignored local artifacts, not tracked source files

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
- Follow the existing 0.2 visual system instead of reintroducing older default-control styling

### General engineering rules

- No `print()` debugging in committed code
- No force unwraps unless there is a very narrow, well-justified boundary
- Prefer protocol-first design for reusable services
- Keep generated state out of git unless the repo explicitly tracks it

## Testing Notes

Steno uses Swift Testing, not XCTest.

Run the full package suite:

```bash
cd /Users/ankitcherian/Desktop/LocalProjects/Steno-next
swift test --package-path StenoKit
```

Run one test by name:

```bash
cd /Users/ankitcherian/Desktop/LocalProjects/Steno-next
swift test --package-path StenoKit --filter overlayHitTestingReturnsInteractiveButtonForNestedContent
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

- `DEVELOPMENT_TEAM`
- personal provisioning profiles
- personal signing identities

Changing those in tracked source can invalidate user TCC permissions and force re-grants for:

- Microphone
- Accessibility
- Input Monitoring

## Pull Request Checklist

Before opening a PR:

- [ ] `swift test --package-path StenoKit` passes
- [ ] `xcodegen generate` succeeds
- [ ] `xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds
- [ ] benchmark-facing changes were validated with the correct smoke or release path
- [ ] public docs reflect current measured truth, not stale thread context
- [ ] no generated benchmark bundles are staged
- [ ] no generated Xcode project churn is staged unintentionally
- [ ] commit history keeps one concern per commit

## Where to Look Next

- Repo overview: [README.md](README.md)
- Fast user setup: [QUICKSTART.md](QUICKSTART.md)
- Core package overview: [StenoKit/README.md](StenoKit/README.md)
- Release-eval guide: [docs/release/release-eval.md](docs/release/release-eval.md)
