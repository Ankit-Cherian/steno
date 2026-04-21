# Steno Quickstart

Fastest path to a local 0.2-era run on macOS.

## 1) Clone and build local transcription dependencies

```bash
git clone https://github.com/Ankit-Cherian/steno.git
cd steno
git clone https://github.com/ggerganov/whisper.cpp vendor/whisper.cpp
cd vendor/whisper.cpp
git checkout v1.8.3
cmake -B build && cmake --build build --config Release
./models/download-ggml-model.sh small.en
./models/download-ggml-model.sh medium.en
./models/download-ggml-model.sh large-v3-turbo
cd models
./download-vad-model.sh silero-v6.2.0
cd ../../..
```

Expected result:

- `vendor/whisper.cpp/build/bin/whisper-cli` exists
- at least one canonical model exists under `vendor/whisper.cpp/models/`
- `ggml-silero-v6.2.0.bin` exists under `vendor/whisper.cpp/models/`

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

## 4) Verify the redesigned app quickly

- Hold `Option` to start dictation immediately, then release to transcribe.
- Trigger hands-free mode using the configured function key (default `F18`).
- Confirm the redesigned Record, History, and Settings surfaces load correctly.
- Insert text into both a standard text editor and a terminal-like target.
- Open Settings -> Engine and confirm:
  - the detected hardware line is present
  - the current model is visible
  - the recommendation/status text makes sense for your machine
- Open History and confirm transcripts, timestamps, and copy/paste actions look correct.

## Cleanup behavior

Steno remains fully local for both transcription and cleanup. There is no cloud cleanup mode in the 0.2 branch.

## If something fails

- `xcodegen: command not found`

  ```bash
  brew install xcodegen
  ```

- `cmake: command not found`

  ```bash
  brew install cmake
  ```

- `whisper-cli` missing after build

  Re-run the `cmake -B build && cmake --build build --config Release` step inside `vendor/whisper.cpp`.

- Hotkeys not responding

  Re-check Accessibility and Input Monitoring permissions in macOS Settings, then relaunch Steno.

- The engine status looks wrong for your hardware

  Re-open Settings -> Engine after model downloads finish. If you are using a non-canonical or quantized model, expect recommendation text to stay in advanced/manual territory.

- You want benchmark or release-signoff verification instead of just a local run

  Use the repo-level release-eval docs and commands in [README.md](README.md#release-eval) and [docs/release/release-eval.md](docs/release/release-eval.md).
