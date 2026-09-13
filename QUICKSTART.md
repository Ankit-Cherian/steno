# Steno Quickstart

Build and run the unreleased Steno 1.0.0 candidate on an Apple silicon Mac. For an older release, use the guide at that version's tag.

## Prerequisites

- Xcode with Swift 6.2 or later and its command-line tools; CI uses Xcode 26.3
- XcodeGen
- CMake
- an Apple silicon Mac running a macOS version supported by your Xcode installation
- the `small.en` Whisper model and Silero VAD model downloaded in step 1
- a local Apple Developer Team for an Xcode-run build

The app's deployment target is macOS 13 or later. Building requires the newer host OS supported by the selected Xcode version.

Public distribution requires Developer ID signing and notarization, which are not part of this setup.

## 1) Clone and build local transcription dependencies

Clone the repository, then select the source branch or tag you intend to build. If you already have that checkout, start with the dependency setup below.

```bash
git clone https://github.com/Ankit-Cherian/steno.git
cd steno
```

From the selected source checkout:

```bash
git clone https://github.com/ggerganov/whisper.cpp vendor/whisper.cpp
cd vendor/whisper.cpp
git checkout 764482c3175d9c3bc6089c1ec84df7d1b9537d83
cd ../..
scripts/build-whisper-runtime-helper.sh
cd vendor/whisper.cpp
./models/download-ggml-model.sh small.en
cd models
./download-vad-model.sh silero-v6.2.0
cd ../../..
```

Expected result:

- `vendor/whisper.cpp/build-steno/bin/whisper-cli` exists
- `vendor/whisper.cpp/build-steno/bin/steno-whisper-runtime` exists
- `ggml-small.en.bin` exists under `vendor/whisper.cpp/models/`
- `ggml-silero-v6.2.0.bin` exists under `vendor/whisper.cpp/models/`

The helper build verifies the pinned `whisper.cpp` revision, creates arm64 binaries under `vendor/whisper.cpp/build-steno/`, and targets macOS 13. It does not build the Whisper server, RPC backend, or a network-enabled runtime.

Start with `small.en`: the source app uses it for default paths and local runtime discovery. Medium and Large V3 Turbo are optional downloads in Settings → Speech model. You can also download them with `./models/download-ggml-model.sh medium.en` or `./models/download-ggml-model.sh large-v3-turbo` from `vendor/whisper.cpp`.

Steno recognizes these model names. Use the advanced path settings for `base.en`:

- `base.en`
- `small.en`
- `medium.en`
- `large-v3-turbo`

Model recommendations:

| Detected Apple silicon tier | Unified memory | Recommended default |
|---|---:|---|
| Base M1 / M2 / M3 | 8GB-16GB | `small.en` |
| Base M4 / M5 | 16GB | `small.en` |
| Base M2 / M3 | 24GB | `medium.en` |
| Base M4 / M5 | 24GB-32GB | `medium.en` |
| M1 / M2 / M3 Pro | 16GB-31GB | `medium.en` |
| M4 / M5 Pro | 24GB-31GB | `medium.en` |
| Pro / Max chips | 32GB-128GB | `large-v3-turbo` |

These are starting recommendations. Performance must be measured on the particular Mac and model; the compatibility matrix and release-eval results record which combinations have been tested.

## 2) Generate the Xcode project

```bash
xcodegen generate
```

This generates `Steno.xcodeproj` from `project.yml`.

## 3) Run in Xcode

1. Open `Steno.xcodeproj`.
2. Set your Apple Developer Team in Signing & Capabilities.
3. Run scheme `Steno` (`Cmd+R`).
4. Grant permissions when prompted:
   - Microphone
   - Accessibility
   - Input Monitoring

If the source runtime is not detected, open Settings → Speech model → Advanced setup and diagnostics. Set absolute paths to `vendor/whisper.cpp/build-steno/bin/whisper-cli`, `vendor/whisper.cpp/models/ggml-small.en.bin`, and `vendor/whisper.cpp/models/ggml-silero-v6.2.0.bin` inside your checkout, then choose Save changes.

## 4) Use the app

The first dictation loads the selected model. Steno keeps it loaded for later recordings and reloads it when the model or voice-activity detection (VAD) configuration changes. The helper communicates through inherited process pipes, with no HTTP server or network listener. Recoverable helper failures can fall back to the local `whisper-cli` engine. Cancellation, stale responses, and VAD integrity failures stop without that retry.

The sidebar contains Dictate, History, Insights, and Settings. The Dictate button shows the recording state. Stop finishes the recording; Cancel discards it. Most Settings changes stay in a draft: choose Save changes to apply them or Discard to return to saved preferences. Appearance changes save immediately. If another update conflicts with a draft, choose Discard to reload it before saving.

Insights shows an activity calendar, streaks, words, known dictated time, sessions, average speed, cleanup coverage, and top apps. Its local usage records contain no transcript text or audio. Deleting a transcript from History does not remove its usage record.

Cleanup runs locally and preserves ambiguous phrases such as `like`, `you know`, `question mark`, `open paren`, and `slash command`. Only Aggressive cleanup removes its supported filler phrases. Optional media interruption sends Pause and Play to the specific app and process Steno verified; uncertain ownership leaves playback alone.

Recording settings include an optional live transcript and nearby-text continuation. The live transcript stays in the local overlay; the completed recording determines the final text. Automatic continuation is limited to English in supported fields in Apple Mail, Notes, and TextEdit. Nearby text is read from a limited range around the selection and discarded after the dictation. It is never added to recognition prompts, History, or Insights. Steno skips continuation in secure or unsupported fields and when it cannot confirm the same editor is still the target.

To lowercase the first letter of the result, begin with `lowercase` followed by whitespace and your text. The command works with or without nearby context. It ignores case and leading Unicode whitespace, requires text containing a cased grapheme, and changes only the first cased grapheme after cleanup. It stays literal when the prefix does not match: for example, `lowercase` alone, `please lowercase Hello`, `lowercase, hello`, `"lowercase hello"`, or `lowercase(Hello)`. A matching command still applies when its payload contains quotes or code, such as `lowercase "Hello"`.

To keep the word itself, begin with `literal lowercase` followed by whitespace and nonempty text. These tokens also ignore case and allow leading Unicode whitespace. The output starts with `lowercase` without applying the command.

## 5) Automated checks

These checks do not require a signed app, microphone session, or media player:

```bash
swift test --package-path StenoKit
xcodegen generate
xcodebuild test -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## 6) Check a release build

Validate these behaviors against the exact app build being considered for release:

- Hold `Option` to start dictation immediately, then release to transcribe.
- Trigger hands-free mode using the configured function key (default `F18`).
- Confirm Dictate, History, Insights, and Settings load correctly, including the Insights empty, loading, error, and populated states.
- Verify that local preview words flow, recent sentences roll forward without an error message, and the overlay stays compact when the live-transcript setting is off.
- Insert text into both a standard text editor and a terminal-like target.
- Verify nearby-text continuation at sentence and mid-sentence boundaries, plus `lowercase <payload>` and `literal lowercase <text>`.
- Verify exact-application media Pause/Play behavior with supported players, including already-paused and ambiguous-owner cases.
- Open Settings -> Speech model and confirm:
  - the detected hardware line is present
  - the current model is visible
  - the recommendation/status text makes sense for your machine
- Open History and confirm transcripts, timestamps, and copy actions look correct.
- Change Settings sections and leave/return with an unsaved draft; verify Save changes, Discard, and external-update conflict handling.
- Check short and long dictations, opening words, silence, Stop, Cancel, and a fresh recording immediately after completion.
- Check keyboard navigation, VoiceOver labels, reduced motion, sleep/wake, an installed app bundle, and a macOS 13 machine.

Record each result and the tested build in [the 1.0 checklist](docs/release/1.0-checklist.md). These checks require using the app; automated tests and a single successful dictation cannot cover them all. Distribution signing and notarization remain pending.

## If something fails

- `xcodegen: command not found`

  ```bash
  brew install xcodegen
  ```

- `cmake: command not found`

  ```bash
  brew install cmake
  ```

- `whisper-cli` or `steno-whisper-runtime` missing after build

  Re-run `scripts/build-whisper-runtime-helper.sh` from the Steno repository root. The script verifies the audited whisper.cpp revision and produces the Apple-silicon runtime targeting macOS 13 under `vendor/whisper.cpp/build-steno`.

- Hotkeys not responding

  Re-check Accessibility and Input Monitoring permissions in macOS Settings, then relaunch Steno.

- The engine status looks wrong for your hardware

  Re-open Settings → Speech model after model downloads finish. Custom or quantized models may not have a matching hardware recommendation.

- You want benchmark or release-signoff verification instead of just a local run

  Follow [the release-eval guide](docs/release/release-eval.md) and [the 1.0 checklist](docs/release/1.0-checklist.md).
