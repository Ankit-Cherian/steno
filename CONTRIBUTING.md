# Contributing to Steno

For local app setup, start with [QUICKSTART.md](QUICKSTART.md). This guide covers changes to the 1.1 source. Use the documentation for the branch or tag you are working on.

The [CI guide](docs/ci-cd.md) explains package and hosted tests, runtime checks, the public-audio smoke benchmark, preview builds, and how to reproduce failures locally. Maintainers must complete [GitHub activation](docs/maintainers/github-setup.md) to enforce these checks. Release requirements are tracked in [the 1.1 checklist](docs/release/1.1-checklist.md).

## Before You Start

- Pull requests target `main`.
- Bug fixes are welcome as pull requests. For a new feature, open an issue first so the design can be agreed before you write code.
- Steno has one maintainer, so replies can take a while.
- By contributing, you agree that your contribution is licensed under the repository's [MIT license](LICENSE).

## Prerequisites

- an Apple silicon Mac
- a macOS version supported by your Xcode installation; the app's deployment target is macOS 13.0+
- Xcode with Swift 6.2 or later; CI uses Xcode 26.3
- XcodeGen (`brew install xcodegen`)
- CMake (`brew install cmake`)
- Python 3, for `scripts/check.sh` and the benchmark scripts
- the local `whisper.cpp` runtime, the `small.en` Whisper model and the Silero VAD model, set up as described in QUICKSTART

## First-Time Setup

1. Clone the repository, then select the branch or tag you intend to contribute to:

   ```bash
   git clone https://github.com/Ankit-Cherian/steno.git
   cd steno
   ```

2. Build `whisper.cpp` and download the models with [step 1 of QUICKSTART](QUICKSTART.md#1-clone-and-build-local-transcription-dependencies). It pins `whisper.cpp` to a fixed revision.

3. Generate the local Xcode project:

   ```bash
   xcodegen generate
   ```

4. Open `Steno.xcodeproj`, set your Apple Developer Team in Signing & Capabilities, and run the app locally.

   If runtime discovery fails, follow the explicit path setup in [QUICKSTART.md](QUICKSTART.md#3-run-in-xcode).

## Local Checks

Run one command before you open a pull request:

```bash
scripts/check.sh
```

It requires macOS and Python 3. It runs these steps in order and stops at the first failure:

1. Regenerates `Steno.xcodeproj` with the pinned XcodeGen version. If that version is missing, it downloads it into `build/ci-tools` and checks its hash. It then fails if a hosted test file is missing from the generated project.
2. Runs the package tests with `swift test --package-path StenoKit`.
3. Builds the app in the Debug configuration without code signing.
4. Runs the hosted macOS tests with `xcodebuild test`.
5. Fails if a test helper process is still running after the tests.

Pass `--clean` to discard the package build and derived data first. Use it after a shared struct or enum changes shape, when an incremental build can compile but crash at run time. CI runs the same checks in its own jobs; the script does not replace them.

Check microphone capture, media interruption, editor insertion, appearance, VoiceOver, installation, and macOS 13 behavior in the app when your change affects them. Automated tests alone cannot verify those interactions.

For documentation-only changes, verify the claims against source, check links and commands, and review the diff. Always report results for the source you actually tested.

## Architecture

### Retained Whisper runtime

`steno-whisper-runtime` is a private child process that keeps the Whisper model loaded between compatible dictations. It communicates over inherited pipes and must not expose a network listener. The first request loads the model; changes to the model, VAD path, or another part of its load configuration require a reload. Cancellation, shutdown, sleep/wake recovery, memory pressure, and helper failure must release or invalidate retained resources safely. Recoverable helper failures can use `WhisperCLITranscriptionEngine` for the request. Cancellation, stale responses, and VAD integrity failures must not trigger that fallback.

### Insights privacy and persistence

The Insights ledger stores session timestamps, application identifiers, word and duration counts and their sources, cleanup counts, and insertion outcomes. It contains no transcript text or audio. Deleting History content does not delete usage totals. Preserve this separation during migrations and corruption recovery, and distinguish measured from estimated values in the UI.

### Media and cleanup safety

Media interruption must fail closed. Pause and Play are semantic, application-targeted commands, and resume ownership is valid only for the exact application/process lineage Steno verified that it paused. Do not add a global play/pause toggle fallback.

Default cleanup must preserve ambiguous dictated language. Phrases such as `like`, `you know`, `question mark`, `open paren`, and `slash command` stay literal instead of being automatically converted or removed. Only the Thorough filler setting (`FillerPolicy.aggressive` in code) removes filler words, and only those on the fixed list in `RuleBasedCleanupEngine`. Keep repairs, punctuation, lexicon corrections, and command passthrough covered by preservation counterexamples.

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
- Follow the [1.1 design record](docs/design/1.1-design-record.md): the 1.1 design's theme tokens, the system font in the windows, and green as the only accent. Keep saved accent and line-number preferences decodable for 1.0.x; 1.1 does not read them
- Keep the compact Dictate action and configured shortcuts together; preserve mode-aware Stop and a separate Cancel action
- Keep overlay text display-only, bounded, revision-aware, and readable across light/dark modes and supported window sizes
- Keep Settings drafts, persistent Save Changes and Discard controls, and conflict protection intact; appearance changes save immediately
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
- keep literal-preservation counterexamples near Thorough cleanup logic
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

Before opening a PR against `main`, complete the checks that apply to the change. Documentation-only PRs need claim, link, command, and diff checks. Code changes require `scripts/check.sh`.

- [ ] `scripts/check.sh` passes
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
