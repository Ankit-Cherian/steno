# StenoKit Core (macOS-first)

This package implements the core architecture for a local-first dictation workflow with:

- Session orchestration (`SessionCoordinator` actor)
- macOS hotkey monitor (`MacHotkeyMonitor`) for `Option` hold and configurable function-key toggle
- macOS recording overlay presenter (`MacOverlayPresenter`)
- macOS audio capture service (`MacAudioCaptureService`)
- local `whisper.cpp` transcription adapter (`WhisperCLITranscriptionEngine`)
- rule-based local transcript cleanup (`RuleBasedCleanupEngine`)
- Transcript history + recovery (`HistoryStore`)
- `pasteLast()` recovery flow for wrong-text-box insertion issues
- Personal lexicon correction (e.g., `stenoh` -> `Steno`)
- Style profiles and app-specific behavior
- Snippet expansion
- Fallback insertion chain (`InsertionService`)

## Implemented Public Interfaces

- `AudioCaptureService`
- `TranscriptionEngine`
- `CleanupEngine`
- `HistoryStoreProtocol`
- `InsertionServiceProtocol`
- `SessionCoordinator`
- `PersonalLexiconService`
- `StyleProfileService`
- `SnippetService`

## Test Coverage

`swift test` covers:

- Lexicon correction with global + app scope
- Transcript history append/search/recovery + paste-last clipboard flow
- Session fallback behavior when the primary cleanup engine fails

## Run Tests

```bash
CLANG_MODULE_CACHE_PATH=/tmp/steno-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/steno-swift-cache \
swift test
```

## If You Integrate StenoKit Into Another App

The following are intentionally left to the host app layer:

- Global hotkey handling (`Option` hold, function-key toggle)
- On-screen recording status overlay
- Real audio capture implementation using `AVAudioEngine`
- Optionally switch `MacAudioCaptureService` to a custom capture backend if needed
- Concrete insertion transports for accessibility and key event paste simulation
- Settings UI and transcript history UI
