# Steno Quickstart

Fastest path to run Steno locally on macOS.

## 1) Clone and build local transcription dependencies

```bash
git clone https://github.com/Ankit-Cherian/steno.git
cd steno
git clone https://github.com/ggerganov/whisper.cpp vendor/whisper.cpp
cd vendor/whisper.cpp
git checkout v1.8.3
cmake -B build && cmake --build build --config Release
./models/download-ggml-model.sh small.en
cd ../..
```

Expected result: `whisper.cpp` and the `small.en` model are ready under `vendor/whisper.cpp`.

## 2) Generate the Xcode project

```bash
xcodegen generate
```

Expected result: local `Steno.xcodeproj` is up to date (it is generated from `project.yml` and intentionally not tracked in git).

## 3) Run in Xcode

1. Open `Steno.xcodeproj`.
2. Set your Apple Developer Team in Signing & Capabilities.
3. Run scheme `Steno` (`Cmd+R`).
4. Grant permissions when prompted:
   - Microphone: record your voice
   - Accessibility: let Steno type or paste into your active app
   - Input Monitoring: let Steno detect global hotkeys

## Optional: Cloud text cleanup

Set `OPENAI_API_KEY` in your scheme environment to enable OpenAI text cleanup.
Without it, Steno stays fully local for transcription and local cleanup.

## Verify setup quickly

- Press and hold `Option` to record, release to transcribe.
- Toggle hands-free mode using the configured function key (default `F18`).
- Confirm text output works in both a text editor and a terminal.

## If something fails

- `xcodegen: command not found`: run `brew install xcodegen`.
- `cmake: command not found`: run `brew install cmake`.
- Hotkeys not responding: check Accessibility + Input Monitoring permissions in macOS Settings and relaunch Steno.
