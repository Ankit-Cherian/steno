# Steno Quickstart

Source setup for Steno on an Apple silicon Mac running macOS 13 or later. The instructions below describe the unreleased 1.0 candidate tree.

The complete candidate is still local development work. A clone of the public default branch does not include all of it. When continuing an existing candidate checkout, preserve that checkout and its changes and skip the clone step. Release acceptance is tracked in [the 1.0 checklist](docs/release/1.0-checklist.md).

## Prerequisites

- Xcode and its command-line tools
- XcodeGen
- CMake
- an Apple silicon Mac running macOS 13+
- at least one local Whisper model and the Silero VAD model
- a local Apple Developer Team for an Xcode-run build

Developer ID signing and notarization are separate distribution steps. Local development or ad-hoc signatures do not establish a distributable 1.0 release.

## 1) Clone and build local transcription dependencies

```bash
git clone https://github.com/Ankit-Cherian/steno.git
cd steno
git clone https://github.com/ggerganov/whisper.cpp vendor/whisper.cpp
cd vendor/whisper.cpp
git checkout 764482c3175d9c3bc6089c1ec84df7d1b9537d83
cd ../..
scripts/build-whisper-runtime-helper.sh
cd vendor/whisper.cpp
./models/download-ggml-model.sh small.en
./models/download-ggml-model.sh medium.en
./models/download-ggml-model.sh large-v3-turbo
cd models
./download-vad-model.sh silero-v6.2.0
cd ../../..
```

Expected result:

- `vendor/whisper.cpp/build-steno/bin/whisper-cli` exists
- `vendor/whisper.cpp/build-steno/bin/steno-whisper-runtime` exists
- at least one canonical model exists under `vendor/whisper.cpp/models/`
- `ggml-silero-v6.2.0.bin` exists under `vendor/whisper.cpp/models/`

The helper build verifies the pinned `whisper.cpp` revision, creates arm64 binaries under `vendor/whisper.cpp/build-steno/`, and targets macOS 13. It does not build the Whisper server, RPC backend, or a network-enabled runtime.

Steno curates these canonical local models:

- `base.en`
- `small.en`
- `medium.en`
- `large-v3-turbo`

Conservative starting points:

| Detected Apple silicon tier | Unified memory | Recommended default |
|---|---:|---|
| Base M1 / M2 / M3 | 8GB-16GB | `small.en` |
| Base M2 / M3 / M4 / M5 | 24GB-32GB | `medium.en` |
| Pro-tier chips | 16GB-31GB | `medium.en` |
| Pro / Max chips | 32GB+ | `large-v3-turbo` |

Those are recommendation tiers, not universal validation claims. Exact validated rows live in the compatibility matrix and release-eval artifacts.

## 2) Generate the Xcode project

```bash
xcodegen generate
```

Expected result:

- local `Steno.xcodeproj` is up to date
- the generated project matches `project.yml`

## 3) Run in Xcode

1. Open `Steno.xcodeproj`.
2. Set your Apple Developer Team in Signing & Capabilities.
3. Run scheme `Steno` (`Cmd+R`).
4. Grant permissions when prompted:
   - Microphone
   - Accessibility
   - Input Monitoring

## 4) Understand the 1.0 runtime

Steno starts with the selected model on first use and keeps that Whisper context loaded between compatible dictations. The private helper communicates only through inherited process pipes; it does not run an HTTP server or network listener. Changing the model or VAD configuration invalidates the loaded context, so the next dictation pays the reload cost. The legacy `whisper-cli` path remains available as a fallback if the retained helper cannot complete a request.

The app uses one Manuscript interface with four sidebar destinations: Dictate, History, Insights, and Settings. The compact Dictate pill reflects the current capture state; Stop ends the active recording mode, while Cancel discards the active capture. Settings changes remain a draft until Save changes; Discard reloads saved preferences. A conflict warning requires reloading before saving.

Insights shows a local activity calendar, streaks, words, known dictated time, sessions, average speed, cleanup coverage, and top apps. Its separate ledger stores per-session usage metadata, not transcript text or audio. Deleting History text does not remove the aggregate usage record.

Cleanup is conservative by default: ambiguous language, including `like`, `you know`, `question mark`, `open paren`, and `slash command`, stays literal rather than being automatically converted or removed. Only the explicit aggressive filler policy performs narrow filler removal. Optional media interruption is also fail-closed: Steno sends semantic Pause and Play commands only when it can bind ownership to the exact application and process lineage it observed.

Recording settings include an optional live transcript and nearby-text continuation. Live hypotheses are local, bounded overlay content only; the completed WAV still supplies the authoritative transcript. Nearby text is read only from a bounded range around the captured selection, retained only for the active dictation, and never added to transcription prompts or History. Context-derived casing is disabled when the exact editor cannot be revalidated and for code, terminal, remote-desktop, or unknown-language boundaries.

The directive works with or without nearby context. It is recognized only when, after optional leading Unicode whitespace, the exact case-insensitive first lexical token is `lowercase`, followed by Unicode whitespace and a nonempty payload containing a cased grapheme. It lowercases only the first cased grapheme after normal cleanup. Used alone, non-leading, punctuated (`lowercase,`), quoted, introduced, or code-like, `lowercase` remains literal. To escape the directive, after optional leading Unicode whitespace, start with the exact case-insensitive tokens `literal lowercase`, followed by Unicode whitespace and nonempty text; the output begins `lowercase` without invoking the directive.

## 5) Automated checks

These checks do not require a signed app, microphone session, or media player:

```bash
swift test --package-path StenoKit
xcodegen generate
xcodebuild test -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## 6) Pending manual checks

The original unwanted repeated-Terms bug is closed after maintainer testing. The following broader checks remain part of selecting and validating the final 1.0 release build; they do not reopen that bug:

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

Record actual results against the exact tested build in [the 1.0 checklist](docs/release/1.0-checklist.md). A transient success or a single dictation does not complete the whole checklist.

Passing the automated commands does not establish any of these manual results. Distribution signing and notarization are also still pending.

## Cleanup behavior

Steno remains local for transcription, provisional display, cleanup, and Insights aggregation. The retained helper has no HTTP or network-listener mode, the Insights ledger excludes transcript text and audio, and bounded nearby editor text remains ephemeral rather than entering prompts, History, or analytics.

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

  Re-open Settings -> Speech model after model downloads finish. If you are using a non-canonical or quantized model, expect recommendation text to stay in advanced/manual territory.

- You want benchmark or release-signoff verification instead of just a local run

  Use the repo-level release-eval docs and commands in [README.md](README.md#release-eval) and [docs/release/release-eval.md](docs/release/release-eval.md).
