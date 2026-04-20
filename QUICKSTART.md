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
cd models
./download-vad-model.sh silero-v6.2.0
cd ..
cd ../..
```

Expected result: `whisper.cpp`, the `small.en` model, and the `ggml-silero-v6.2.0.bin` VAD model are ready under `vendor/whisper.cpp`.

If you are on a higher-end Apple Silicon Mac and want a stronger local Whisper-family model, you can download `large-v3-turbo` instead of or alongside `small.en`:

```bash
cd vendor/whisper.cpp
./models/download-ggml-model.sh large-v3-turbo
cd ../..
```

If both models are present, choose the one you want from Settings -> Engine.

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

## Cleanup behavior

Steno runs transcription and cleanup fully locally with no cloud text cleanup step.

## Verify setup quickly

- Press and hold `Option` to start recording immediately, then release to transcribe.
- Toggle hands-free mode using the configured function key (default `F18`).
- Confirm text output works in both a text editor and a terminal.

## If something fails

- `xcodegen: command not found`: run `brew install xcodegen`.
- `cmake: command not found`: run `brew install cmake`.
- Hotkeys not responding: check Accessibility + Input Monitoring permissions in macOS Settings and relaunch Steno.
