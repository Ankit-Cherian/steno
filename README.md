# Steno

Fast macOS voice-to-text with smart app-aware insertion and optional text cleanup.

Steno is built for a premium dictation workflow without subscription lock-in: high-accuracy local transcription with `whisper.cpp`, fast hotkeys, and reliable text output across apps.

[![Swift Tests](https://github.com/Ankit-Cherian/steno/actions/workflows/swift-tests.yml/badge.svg)](https://github.com/Ankit-Cherian/steno/actions/workflows/swift-tests.yml)

## Choose Your Path

- **I want to use Steno**: follow [QUICKSTART.md](QUICKSTART.md) or the quick setup below.
- **I want to contribute**: start with [CONTRIBUTING.md](CONTRIBUTING.md) and the architecture notes below.

## What Steno Does

- High-accuracy local transcription with `whisper.cpp` (audio never leaves your Mac)
- Optional VAD-backed silence and background-noise suppression to avoid empty or hallucinated inserts
- Smart app-aware paste (target-aware insertion): terminals prefer paste, editors use direct typing or accessibility insertion
- Local transcript cleanup with context-aware filler handling (no cloud dependency)
- Global hotkeys: Option hold-to-talk and configurable hands-free toggle
- Menu bar app with status overlay
- 30-day transcript history with search
- Personal lexicon, style profiles, and snippets
- VoiceOver accessibility support

## Screenshots

<table>
  <tr>
    <td><img src="assets/record.png" alt="Record tab — hands-free recording with live transcript" width="400"></td>
    <td><img src="assets/history.png" alt="History tab — searchable transcript history" width="400"></td>
  </tr>
  <tr>
    <td><img src="assets/settings-top.png" alt="Settings — permissions, recording, and engine setup" width="400"></td>
    <td><img src="assets/settings-bottom.png" alt="Settings — cleanup style and text shortcuts" width="400"></td>
  </tr>
</table>

## Requirements

- macOS 13.0+
- Xcode 26+ (Swift 6.2+)
- XcodeGen (`brew install xcodegen`)
- whisper.cpp built locally
- CMake (`brew install cmake`)

## Quick Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/Ankit-Cherian/steno.git
   cd steno
   ```

2. Build whisper.cpp:
   ```bash
   git clone https://github.com/ggerganov/whisper.cpp vendor/whisper.cpp
   cd vendor/whisper.cpp
   git checkout v1.8.3
   cmake -B build && cmake --build build --config Release
   cd ../..
   ```

3. Download a transcription model:
   ```bash
   cd vendor/whisper.cpp
   ./models/download-ggml-model.sh small.en
   cd ../..
   ```
   Steno’s compatibility system only reasons about the canonical local models `base.en`, `small.en`, `medium.en`, and `large-v3-turbo`.

   Conservative starting points:

   | Detected Apple silicon tier | Unified memory | Recommended default |
   |---|---:|---|
   | Base M1 / M2 / M3 | 8GB-16GB | `small.en` |
   | Base M2 / M3 / M4 / M5 | 24GB-32GB | `medium.en` |
   | Pro-tier chips | 16GB-31GB | `medium.en` |
   | Pro / Max chips | 32GB+ | `large-v3-turbo` |

   If you want multiple canonical models available in Settings -> Engine, download them alongside `small.en`:
   ```bash
   cd vendor/whisper.cpp
   ./models/download-ggml-model.sh medium.en
   ./models/download-ggml-model.sh large-v3-turbo
   cd ../..
   ```
   Settings -> Engine detects your Apple silicon chip class and unified memory, recommends the best curated model for that Mac, and warns if the configured model is outside the compatibility matrix. Quantized and other custom models remain expert-mode paths and are never auto-recommended.

4. **(Strongly recommended)** Download the VAD model for silence/background-noise suppression:
   ```bash
   cd vendor/whisper.cpp/models
   ./download-vad-model.sh silero-v6.2.0
   cd ../../..
   ```
   This downloads `ggml-silero-v6.2.0.bin` into the models directory. With VAD enabled (the default), Steno uses whisper.cpp's built-in voice activity detection to avoid inserting hallucinated text when no speech is present. If the VAD model is missing, dictation still works but with weaker protection against silence and background noise.

   > **Note:** The `for-tests-silero-v6.2.0-ggml.bin` file in the models directory is a test stub, not a usable model.

5. Generate the local Xcode project (generated from `project.yml`, not tracked in git):
   ```bash
   xcodegen generate
   ```

6. Open your local `Steno.xcodeproj` in Xcode and set your Apple Developer Team in Signing & Capabilities.

7. Build and run (Cmd+R).

8. Grant required permissions when prompted:
   - Microphone: record your voice
   - Accessibility: let Steno type or paste into the active app
   - Input Monitoring: let Steno detect global hotkeys

## Usage

- **Option Hold-to-Talk**: hold Option to start recording immediately, release to transcribe and insert
- **Hands-Free Toggle**: press the configured function key (default `F18`) to start/stop recording
- **Menu Bar**: Click icon to show app window, right-click for quick actions
- **Recording Modes**: Press-to-talk (immediate recording) or hands-free (toggle on/off)
- **Text Output**: app-aware routing picks the safest insertion method for your current app

## Verify Setup

- Hold `Option` to record and release to transcribe.
- Use the hands-free toggle key (default `F18`).
- Confirm insertion works in both a text editor and a terminal.
- Open Settings -> Engine and confirm the detected hardware line, recommended model, and current model status text.

## Architecture (Contributor View)

Steno uses a two-layer design:

- **`StenoKit/`**: pure Swift package with business logic, protocols, models, and services (no UI)
- **`Steno/`**: SwiftUI app target with views, `DictationController` orchestration, and settings persistence

Key patterns: protocol-first dependency injection, actor isolation, no singletons, `Sendable` value types.

## Testing (Contributor View)

Run the core package tests from the repository root:

```bash
cd StenoKit
CLANG_MODULE_CACHE_PATH=/tmp/steno-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/steno-swift-cache \
swift test
```

Run a single test by function name:

```bash
cd StenoKit
CLANG_MODULE_CACHE_PATH=/tmp/steno-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/steno-swift-cache \
swift test --filter sessionCoordinatorLocalFallbackOnPrimaryFailure
```

## Release Eval

Run the local release-eval entrypoint with explicit dependency overrides:

```bash
STENO_WHISPER_CLI=/absolute/path/to/whisper-cli \
STENO_WHISPER_MODEL=/absolute/path/to/ggml-large-v3-turbo.bin \
STENO_VAD_MODEL=/absolute/path/to/ggml-silero-v6.2.0.bin \
STENO_LIBRISPEECH_ROOT=/absolute/path/to/librispeech_test_clean \
scripts/run-release-eval.sh
```

- `scripts/run-release-eval.sh --smoke-only` runs only the package tests plus the smoke fixture benchmark.
- Full release eval writes ignored local bundles under `research/benchmarks/generated/`.
- Passing smoke fixtures is not release evidence. Only the measured hardware/model row from a full release-eval run can be treated as validated.

## Known Limitations

- macOS only (no Windows/Linux desktop target yet)
- Setup currently expects local whisper.cpp build and model download
- Full end-to-end behavior depends on user-granted macOS permissions
- Cleanup runs locally only

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style guidelines, and PR process.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting and response expectations.

## Support

See [SUPPORT.md](SUPPORT.md) for usage help and bug report paths.

## Acknowledgments

Steno uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) by Georgi Gerganov and contributors for local speech-to-text transcription. whisper.cpp is licensed under the MIT License. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the upstream notice text included with this repository.

## License

MIT — see [LICENSE](LICENSE) file for details.
