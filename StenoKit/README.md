# StenoKit Core (macOS-first)

This package implements the core architecture for a local-first dictation workflow with:

- Session orchestration (`SessionCoordinator` actor)
- macOS hotkey monitor (`MacHotkeyMonitor`) for `Option` hold and configurable function-key toggle
- macOS recording overlay presenter (`MacOverlayPresenter`)
- macOS audio capture service (`MacAudioCaptureService`)
- local `whisper.cpp` transcription adapter (`WhisperCLITranscriptionEngine`)
- direct OpenAI cleanup adapter (`OpenAICleanupEngine`) for text-only cloud cleanup
- Local-first transcript processing with cloud cleanup fallback
- Transcript history + recovery (`HistoryStore`)
- `pasteLast()` recovery flow for wrong-text-box insertion issues
- Personal lexicon correction (e.g., `stenoh` -> `Steno`)
- Style profiles and app-specific behavior
- Snippet expansion
- Budget enforcement (`BudgetGuard`) with degrade and hard-stop thresholds
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
- `BudgetGuard`

## Test Coverage

`swift test` covers:

- Budget degrade and hard-stop behavior
- Lexicon correction with global + app scope
- Transcript history append/search/recovery + paste-last clipboard flow
- Session fallback behavior when cloud cleanup fails
- Session behavior when budget cap disables cloud cleanup

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
- Optional remote cleanup endpoint wiring (`RemoteCleanupEngine`)
- Settings UI and transcript history UI

## Suggested Next Integration Step

Create a macOS app target that wires:

- `AVAudioEngine` capture -> `AudioCaptureService`
- Active app detection -> `AppContext`
- Accessibility/direct insertion -> `InsertionTransport`
- Menu bar or floating panel for transcript history and paste-last actions
