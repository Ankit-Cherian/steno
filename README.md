# Steno

Local-first macOS dictation — whisper.cpp transcription with intelligent target-aware insertion

[![Swift Tests](https://github.com/Ankit-Cherian/steno/actions/workflows/swift-tests.yml/badge.svg)](https://github.com/Ankit-Cherian/steno/actions/workflows/swift-tests.yml)
[![Security Audit](https://github.com/Ankit-Cherian/steno/actions/workflows/security-audit.yml/badge.svg)](https://github.com/Ankit-Cherian/steno/actions/workflows/security-audit.yml)

## Features

- Local audio transcription via whisper.cpp (audio never leaves your Mac)
- Target-aware text insertion (detects terminals vs editors, adjusts strategy)
- Optional cloud-powered transcript cleanup (OpenAI, budget-guarded)
- Global hotkeys: Option hold-to-talk + configurable hands-free toggle
- Menu bar app with status overlay
- 30-day transcript history with search
- Personal lexicon, style profiles, and text snippets
- Full VoiceOver accessibility support
- Swift 6 strict concurrency throughout

## Architecture

Steno uses a two-layer design:

- **`StenoKit/`** — Pure Swift package with all business logic, protocols, models, services. No UI code.
- **`Steno/`** — SwiftUI app target with views, `DictationController` orchestrator, settings persistence

Key patterns: protocol-first dependency injection, actor isolation, no singletons, Sendable value types

## Requirements

- macOS 13.0+
- Xcode 26+ (Swift 6.2+)
- XcodeGen (`brew install xcodegen`)
- whisper.cpp (built locally)

## Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/Ankit-Cherian/steno.git
   cd steno
   ```

2. Build whisper.cpp:
   ```bash
   git clone https://github.com/ggerganov/whisper.cpp vendor/whisper.cpp
   cd vendor/whisper.cpp
   git checkout <pinned-tag-or-commit>
   cmake -B build && cmake --build build --config Release
   ```

3. Download a transcription model:
   ```bash
   cd vendor/whisper.cpp
   ./models/download-ggml-model.sh small.en
   ```

4. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```

5. Open `Steno.xcodeproj` in Xcode and set your own Apple Developer Team in Signing & Capabilities (the repo intentionally does not hardcode a team ID).

6. Build and run (Cmd+R).

7. Grant required permissions when prompted:
   - Microphone (for audio recording)
   - Accessibility (for global hotkeys and direct text insertion)
   - Input Monitoring (for hotkey interception)

## Usage

- **Option Hold-to-Talk**: Hold Option key to record, release to transcribe and insert
- **Hands-Free Toggle**: Press configured function key (default F18) to start/stop recording
- **Menu Bar**: Click icon to show app window, right-click for quick actions
- **Recording Modes**: Press-to-talk (immediate recording) or hands-free (toggle on/off)
- **Insertion Strategies**: Target-aware routing — terminals get clipboard+paste, editors get direct typing or accessibility API

## Testing

Run the core package tests from the repository root:

```bash
cd StenoKit && \
CLANG_MODULE_CACHE_PATH=/tmp/steno-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/steno-swift-cache \
swift test
```

Run a single test by function name:

```bash
cd StenoKit && \
CLANG_MODULE_CACHE_PATH=/tmp/steno-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/steno-swift-cache \
swift test --filter budgetGuardDegradedMode
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style guidelines, and PR process.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting and response expectations.

## Support

See [SUPPORT.md](SUPPORT.md) for usage help and bug report paths.

## License

MIT — see [LICENSE](LICENSE) file for details.
