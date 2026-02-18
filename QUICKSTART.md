# Steno Quickstart

Fast path to run Steno locally on macOS.

## 1) Clone and build dependencies

```bash
git clone https://github.com/Ankit-Cherian/steno.git
cd steno
git clone https://github.com/ggerganov/whisper.cpp vendor/whisper.cpp
cd vendor/whisper.cpp
git checkout <pinned-tag-or-commit>
cmake -B build && cmake --build build --config Release
./models/download-ggml-model.sh small.en
cd ../..
```

## 2) Generate project

```bash
xcodegen generate
```

## 3) Run in Xcode

1. Open `Steno.xcodeproj`.
2. Set your Apple Developer Team in Signing & Capabilities.
3. Run scheme `Steno` (`Cmd+R`).
4. Grant permissions when prompted:
   - Microphone
   - Accessibility
   - Input Monitoring

## Optional: Cloud cleanup

Set `OPENAI_API_KEY` in your scheme environment if you want cloud transcript cleanup.
Without it, transcription/cleanup stays local-first.

## Verify setup quickly

- Press and hold `Option` to record, release to transcribe.
- Toggle hands-free mode using the configured function key (default `F18`).
- Confirm insertion works in both a text editor and a terminal target.
