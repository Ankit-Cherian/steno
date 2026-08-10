# StenoKit

Core package for Steno’s local-first dictation, retained Whisper runtime, cleanup, insertion, usage analytics, media interruption, compatibility, and benchmark stack.

`StenoKit` is the non-UI engine that powers the macOS app in `Steno/`. The app layer owns SwiftUI views, dependency and lifecycle wiring, and window orchestration; `StenoKit` owns the reusable logic that turns audio into text, cleans it up, inserts it safely, persists transcript and aggregate usage data, coordinates exact-app media interruption, and evaluates release quality.

## What Lives Here

### Runtime services

- `SessionCoordinator`: actor-owned orchestration for the dictation lifecycle
- `MacAudioCaptureService`: local audio capture
- `WhisperCLITranscriptionEngine`: local `whisper.cpp` adapter
- `RetainedWhisperTranscriptionEngine`: serial retained-context runtime with CLI fallback, cancellation, configuration invalidation, and shutdown handling
- `RuleBasedCleanupEngine`: local cleanup pipeline
- `InsertionService`: target-aware insertion routing
- `HistoryStore`: transcript persistence and recovery
- `UsageAnalyticsStore`: separate aggregate per-session usage persistence and calculation
- `MacMediaInterruptionService`: fail-closed exact-application Pause/Play ownership
- `PersonalLexiconService`: term correction and alias handling
- `StyleProfileService`: cleanup policy selection
- `SnippetService`: phrase expansion
- `WhisperCompatibilityService`: hardware/model recommendation logic

### Models and state

- transcript models with richer segment metadata
- recording state-machine models
- profile and preference-facing cleanup policy types
- hardware/model compatibility types
- aggregate usage events, quality provenance, calendar summaries, streaks, speed, and per-app metrics
- retained-runtime load identity and lifecycle configuration

### Benchmark and release-eval infrastructure

- `StenoBenchmarkCLI`
- `StenoBenchmarkCore`
- benchmark manifest parsing and corpus generation support
- raw ASR vs pipeline cleanup scoring
- release-threshold validation
- machine-readable and human-readable release summary/report generation

## Public Interfaces

Key package interfaces include:

- `AudioCaptureService`
- `TranscriptionEngine`
- `CleanupEngine`
- `HistoryStoreProtocol`
- `InsertionServiceProtocol`
- `SessionCoordinator`
- `PersonalLexiconService`
- `StyleProfileService`
- `SnippetService`

## Planned 0.3 Package Changes

- Retained local Whisper context between compatible dictations, using a private inherited-pipe helper with no HTTP server or network listener
- Per-request `whisper-cli` fallback after retained-helper failure, plus cancellation, unload, shutdown, and load-identity invalidation
- First-use loading and reload after model, VAD, or other load-identity changes
- Local usage analytics for the app's Insights tab: calendar activity, streaks, words, known time, sessions, weighted speed, cleanup coverage, and top apps
- Aggregate per-session analytics that exclude transcript text and audio and persist separately from transcript history
- Exact-application media Pause/Play ownership with fail-closed playback evidence and rapid-restart/cancellation protection
- Conservative cleanup that preserves ambiguous language, repairs, punctuation, and lexicon intent; only explicit aggressive cleanup performs narrow filler removal
- Reproducible benchmark identities plus retained-runtime and hosted macOS test coverage

The retained helper is built from the audited `whisper.cpp` revision `764482c3175d9c3bc6089c1ec84df7d1b9537d83` into `vendor/whisper.cpp/build-steno/bin/`. The canonical build targets Apple silicon and macOS 13+, disables the server, RPC, and CURL paths, and keeps the standalone CLI available.

## Test Surface

`swift test --package-path StenoKit` now covers:

- cleanup ranking and repair-aware candidate generation
- literal-preservation counterexamples
- prompt contamination and no-speech gating
- whisper runtime argument forwarding and rich output parsing
- retained-runtime queueing, fallback, cancellation, reload identity, and shutdown behavior
- lexicon aliasing and hot-term recovery
- recording state-machine transitions
- exact-app media ownership, playback evidence, cancellation, and rapid restart races
- insertion fallbacks and target-order behavior
- usage-ledger persistence, reconciliation, calendar/streak calculation, metric provenance, and corruption handling
- compatibility-matrix matching and recommendation logic
- raw/pipeline/coordinator benchmark validation
- warm-runtime benchmark identity and acceptance validation
- release-signoff timing aggregation and gate evaluation
- compact overlay hit-testing

## Core Commands

Run the package tests:

```bash
cd /path/to/steno
swift test --package-path StenoKit
```

Run the smoke benchmark:

```bash
cd /path/to/steno
scripts/run-smoke-benchmark.sh
```

Run the full release-eval path:

```bash
cd /path/to/steno
STENO_WHISPER_CLI=/absolute/path/to/whisper-cli \
STENO_WHISPER_MODEL=/absolute/path/to/ggml-large-v3-turbo.bin \
STENO_VAD_MODEL=/absolute/path/to/ggml-silero-v6.2.0.bin \
STENO_LIBRISPEECH_ROOT=/absolute/path/to/librispeech_test_clean \
scripts/run-release-eval.sh
```

## Integration Boundaries

The host app in `Steno/` still owns:

- SwiftUI views and app window structure
- settings screens and onboarding UI
- app lifecycle wiring
- menu bar integration
- final macOS presentation polish
- the Record, History, Insights, and Settings tab presentation

`StenoKit` intentionally keeps those concerns out of the package so the runtime and evaluation stack remain testable and reusable.

Package and hosted tests are automated evidence only. They do not establish live microphone capture, supported-player behavior, real-app insertion, UI or VoiceOver behavior, an installed signed app, notarization, or execution on macOS 13; those checks require separate manual or distribution evidence.

## Related Docs

- Repo overview: [`README.md`](../README.md)
- Contributor workflow: [`CONTRIBUTING.md`](../CONTRIBUTING.md)
- Release-eval guide: [`docs/release/release-eval.md`](../docs/release/release-eval.md)
- Historical 0.2 release brief: [`docs/release/v0.2.0-release-brief.md`](../docs/release/v0.2.0-release-brief.md)
