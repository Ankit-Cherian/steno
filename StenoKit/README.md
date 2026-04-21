# StenoKit

Core package for Steno’s local-first dictation, cleanup, insertion, compatibility, and benchmark stack.

`StenoKit` is the non-UI engine that powers the macOS app in `Steno/`. The app layer owns SwiftUI views, app persistence, and window orchestration; `StenoKit` owns the reusable logic that turns audio into text, cleans it up, inserts it safely, stores history, and evaluates release quality.

## What Lives Here

### Runtime services

- `SessionCoordinator`: actor-owned orchestration for the dictation lifecycle
- `MacAudioCaptureService`: local audio capture
- `WhisperCLITranscriptionEngine`: local `whisper.cpp` adapter
- `RuleBasedCleanupEngine`: local cleanup pipeline
- `InsertionService`: target-aware insertion routing
- `HistoryStore`: transcript persistence and recovery
- `PersonalLexiconService`: term correction and alias handling
- `StyleProfileService`: cleanup policy selection
- `SnippetService`: phrase expansion
- `WhisperCompatibilityService`: hardware/model recommendation logic

### Models and state

- transcript models with richer segment metadata
- recording state-machine models
- profile and preference-facing cleanup policy types
- hardware/model compatibility types

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

## Major 0.2 Package Changes

- Rich JSON-aware whisper ingestion with segment timing and confidence metadata
- Prompt steering built from language hints, app context, and hot terms
- Prompt-echo/no-speech short-circuiting before cleanup and insertion
- Repair-aware cleanup improvements for `scratch that`, `never mind`, `I mean`, `actually`, and conservative bare-`no`
- Compatibility-matrix-backed hardware and model guidance
- Formal smoke and release-signoff infrastructure with deterministic artifact bundles
- Shared overlay hit-testing helper for compact cancel controls in the macOS overlay presenters

## Test Surface

`swift test --package-path StenoKit` now covers:

- cleanup ranking and repair-aware candidate generation
- literal-preservation counterexamples
- prompt contamination and no-speech gating
- whisper runtime argument forwarding and rich output parsing
- lexicon aliasing and hot-term recovery
- recording state-machine transitions
- insertion fallbacks and target-order behavior
- compatibility-matrix matching and recommendation logic
- raw/pipeline/coordinator benchmark validation
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

`StenoKit` intentionally keeps those concerns out of the package so the runtime and evaluation stack remain testable and reusable.

## Related Docs

- Repo overview: [`README.md`](../README.md)
- Contributor workflow: [`CONTRIBUTING.md`](../CONTRIBUTING.md)
- Release-eval guide: [`docs/release/release-eval.md`](../docs/release/release-eval.md)
- Detailed 0.2 release brief: [`docs/release/v0.2.0-release-brief.md`](../docs/release/v0.2.0-release-brief.md)
