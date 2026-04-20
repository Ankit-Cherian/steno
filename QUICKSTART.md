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

Steno curates these canonical local models: `base.en`, `small.en`, `medium.en`, and `large-v3-turbo`.

Conservative starting points:

| Detected Apple silicon tier | Unified memory | Recommended default |
|---|---:|---|
| Base M1 / M2 / M3 | 8GB-16GB | `small.en` |
| Base M2 / M3 / M4 / M5 | 24GB-32GB | `medium.en` |
| Pro-tier chips | 16GB-31GB | `medium.en` |
| Pro / Max chips | 32GB+ | `large-v3-turbo` |

If you want additional canonical models available in Settings -> Engine, download them alongside `small.en`:

```bash
cd vendor/whisper.cpp
./models/download-ggml-model.sh medium.en
./models/download-ggml-model.sh large-v3-turbo
cd ../..
```

Settings -> Engine detects your chip class and unified memory, recommends the best curated model for that Mac, and warns if the configured model is outside the compatibility matrix. Quantized and other custom models remain manual advanced paths and are never auto-recommended.

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
- Open Settings -> Engine and verify the detected hardware line, recommended model, and current model status.

## If something fails

- `xcodegen: command not found`: run `brew install xcodegen`.
- `cmake: command not found`: run `brew install cmake`.
- Hotkeys not responding: check Accessibility + Input Monitoring permissions in macOS Settings and relaunch Steno.
