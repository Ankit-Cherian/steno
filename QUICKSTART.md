# Steno Quickstart

Build and run Steno 1.1 on an Apple silicon Mac. For an older release, use the guide at that version's tag.

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

Start with `small.en`: the source app uses it for default paths and local runtime discovery. Medium and Large V3 Turbo are optional downloads in Settings › Speech Model. You can also download them with `./models/download-ggml-model.sh medium.en` or `./models/download-ggml-model.sh large-v3-turbo` from `vendor/whisper.cpp`.

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
| M1 / M2 / M3 Ultra | 64GB and up | `large-v3-turbo` |

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

   Steno rechecks access when it becomes active, so changes made in System Settings apply when you switch back. While Hold Option to dictate is on, Steno notices every key press and mouse click in any app. To tell a shortcut such as Option+Arrow from a dictation, it uses only the fact that a key or button was pressed. The hands-free key and the Paste Last Dictation shortcut are matched by key code, and no typed text is read.

If the source runtime is not detected, open Settings › Speech Model and expand **Advanced**. Set **whisper-cli path**, **Model path** and **Voice detection model path** to the absolute paths of `vendor/whisper.cpp/build-steno/bin/whisper-cli`, `vendor/whisper.cpp/models/ggml-small.en.bin`, and `vendor/whisper.cpp/models/ggml-silero-v6.2.0.bin` inside your checkout, then choose **Save Changes**.

## 4) Use the app

The first dictation loads the selected model. Steno keeps it loaded for later recordings and reloads it when the model, the model file, the voice-activity detection (VAD) configuration or the thread count changes. Saving other settings keeps the loaded model. The helper communicates through inherited process pipes, with no HTTP server or network listener. Recoverable helper failures can fall back to the local `whisper-cli` engine. Cancellation, stale responses, and VAD integrity failures stop without that retry.

The main window's toolbar switches between Today, History and Insights (Cmd+1 to Cmd+3). Settings opens in its own window (Cmd+,). Today's Dictate area shows the recording state, and the island at the top of the screen shows it while another app is in front. Stop finishes the recording. Discard on Today, or × in the island, discards it; while Steno is transcribing, Today's Cancel and the island's × still discard it. A discarded recording that ran for more than 30 seconds can be restored with Undo for 5 seconds. Recordings stop after one hour and are transcribed, with a countdown in the island during the last minute. Keyboard shortcuts that use Option, such as Option+Arrow, don't start a recording. Most Settings changes stay in a draft: choose Save Changes to apply them or Discard to return to saved preferences. Appearance changes save immediately. If another update conflicts with a draft, choose Discard to reload it before saving.

Insights shows this month's words and the typing time they saved, your speaking pace and streak when they are known, a calendar of the last six months with the busiest day, and the apps your words went to. Its local usage records contain no transcript text or audio. Deleting a transcript from History does not remove its usage record.

Cleanup runs locally and preserves ambiguous phrases such as `like`, `you know`, `question mark`, `open paren`, and `slash command`. Only the Thorough filler setting removes its supported filler phrases. Optional media interruption (macOS 15 or later) sends Pause and Play to the specific app and process Steno confirmed was playing, and resumes only what it paused; media you paused yourself and uncertain ownership are left alone. Saved vocabulary corrections and spoken corrections such as `scratch that` apply however confident the recognizer was.

Recording settings include an optional live transcript and nearby-text continuation. The live transcript stays in the island; the completed recording determines the final text. Automatic continuation is limited to English in supported fields in Apple Mail, Notes, and TextEdit. Nearby text is read from a limited range around the selection and discarded after the dictation. It is never added to recognition prompts, History, or Insights. Steno skips continuation in secure or unsupported fields and when it cannot confirm the same editor is still the target. Separately from continuation, and with default settings, Steno copies the final text instead of inserting it when the focused field is secure or focus moved to a different field or app during transcription. After an automatic paste, Steno restores the previous clipboard contents shortly afterwards, except in remote-desktop apps, where the transcript stays on the clipboard, and except for a password or other item marked private.

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

- Hold `Option` to start dictation immediately, then release to transcribe. Confirm the island appears, and grows out of the notch on a Mac with one notched display.
- Trigger hands-free mode using the configured function key (default `F18`), and confirm that choosing Disabled in Settings › Recording turns the key off without an error.
- Type Option shortcuts such as Option+Arrow and Option+Delete in a text editor, and confirm none starts a recording.
- Confirm Today, History and Insights load correctly from the toolbar and with Cmd+1 to Cmd+3, including the Insights empty, loading, error, and populated states.
- On Today, click the Dictate area, dictate, and confirm the words are copied when you stop. Confirm Space starts a dictation only when the Dictate area has keyboard focus.
- Turn on Show live transcript in Settings › Recording and verify that live words flow in the island; turn it off and confirm the island stays compact.
- Insert text into both a standard text editor and a terminal-like target. Confirm what the island shows for each After inserting choice, and that copies show their reason.
- Discard a recording longer than 30 seconds, choose Undo within 5 seconds, and confirm it is transcribed and inserted once. Discard a short recording and confirm no Undo is offered.
- Open the menu bar panel and use its copy button and Paste Last Dictation. Choose a Paste Last Dictation shortcut in Settings › Recording and use it from another app.
- In Settings › Microphone, choose a microphone, run Test Microphone, dictate with it, then unplug it and confirm Steno uses the system input.
- Verify nearby-text continuation at sentence and mid-sentence boundaries, plus `lowercase <payload>` and `literal lowercase <text>`.
- Verify exact-application media Pause/Play behavior with supported players, including already-paused and ambiguous-owner cases.
- Open Settings › Speech Model and confirm:
  - the line describing this Mac is present
  - the model in use is marked In use
  - the Recommended for this Mac badge makes sense for your machine
- Open History and confirm dictations, timestamps, search, filters, Copy and How it was written look correct. Fix a word in a dictation with both Just this dictation and This and future dictations, use Undo, and confirm the app the text went into is unchanged.
- Move between Settings pages and leave and return with an unsaved draft; verify Save Changes, Discard, and external-update conflict handling.
- Check short and long dictations, opening words, silence, Stop, Discard, Cancel while transcribing, and a fresh recording immediately after completion.
- Check keyboard navigation and focus rings, VoiceOver labels, larger system text sizes, Reduce Motion, Reduce Transparency, Increase Contrast, sleep and wake, an installed app bundle, and a macOS 13 machine.

Record each result and the tested build in [the 1.1 checklist](docs/release/1.1-checklist.md). These checks require using the app; automated tests and a single successful dictation cannot cover them all. For distribution signing and notarization, follow [direct distribution](docs/release/direct-distribution.md).

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

  Re-run `scripts/build-whisper-runtime-helper.sh` from the Steno repository root. The script verifies the audited whisper.cpp revision and produces the Apple-silicon runtime targeting macOS 13 under `vendor/whisper.cpp/build-steno`. It applies the [reviewed native corrections](scripts/ci/patches/README.md) to an isolated source copy. If an older CMake cache points to different sources, choose a fresh directory with `STENO_WHISPER_BUILD_DIR="$PWD/build/runtime-1.0" scripts/build-whisper-runtime-helper.sh`; the builder preserves the previous output.

- Hotkeys not responding

  Re-check Accessibility and Input Monitoring permissions in macOS Settings, then switch back to Steno, which rechecks access when it becomes active. If the shortcuts still don't respond, choose Check Again in Settings › Permissions or relaunch Steno.

- The engine status looks wrong for your hardware

  Reopen Settings › Speech Model after model downloads finish. Custom or quantized models may not have a matching hardware recommendation.

- You want benchmark or release-signoff verification instead of just a local run

  Follow [the release-eval guide](docs/release/release-eval.md) and [the 1.1 checklist](docs/release/1.1-checklist.md).
