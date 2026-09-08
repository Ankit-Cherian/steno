# StenoKit

## Prompt-verification regression checks

The retained helper has separate decision and real-inference checks. From the repository root, run `bash scripts/test-whisper-prompt-verification.sh` for the shared decision rules and `bash scripts/test-whisper-prompt-scoring.sh` for the scorer. The scorer requires the local whisper.cpp build, a model, the JFK sample, and macOS speech synthesis; its defaults are `small.en` and the Samantha voice. Set `STENO_TEST_WHISPER_MODEL` explicitly for each additional model, and `STENO_TEST_SPEECH_VOICE` to test another installed voice. Generated speech can vary between macOS voice versions.

The opt-in coordinator suite requires an external bundle of public or synthetic 16 kHz mono PCM WAVs. Copy its manifest and audio together; each audio path is relative to the manifest. A passing ordinary package run does not execute this suite. Use explicit local inputs and a new receipt directory:

```sh
STENO_TEST_RETAINED_HELPER=/absolute/path/to/steno-whisper-runtime \
STENO_TEST_WHISPER_MODEL=/absolute/path/to/model.bin \
STENO_TEST_WHISPER_VAD=/absolute/path/to/vad-model.bin \
STENO_TEST_PROMPT_MANIFEST=/absolute/path/to/fixture-bundle/manifest.json \
STENO_TEST_PROMPT_RECEIPTS=/absolute/path/to/new-receipts \
bash scripts/test-prompt-isolation.sh
```

The manifest schema is documented in `PromptIsolationIntegrationTests.swift`: `publicOrSyntheticAudio: true` and fixtures containing `id`, `audio`, `expectedText`, and `hotTerms`. Required cases cover ordinary speech, literal and repeated terms, vocabulary, pauses, and silence. References must be independently supplied, and exact audio hashes must accompany evaluation results. Omit the VAD variable only for a deliberately separate diagnostic run. The runner creates an isolated Swift build cache unless `STENO_TEST_SWIFT_SCRATCH_PATH` is supplied.

This suite exercises press-to-talk with preview enabled and disabled, the retained helper, cleanup, isolated insertion, and file history. It does not exercise a microphone, native editor delivery, or hands-free mode. Per-window helper diagnostics are available in rich output to external harnesses; they are not persisted by the app.

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

## Unreleased 1.0 Package Changes

- Retained local Whisper context between compatible dictations, using a private inherited-pipe helper with no HTTP server or network listener
- Versioned retained-helper streaming for bounded provisional hypotheses, cooperative cancellation, final priority, and canonical PCM count/digest validation
- Ephemeral stable/revisable transcript reduction with session, controller, runtime, revision, and audio-watermark isolation
- VAD-confirmed silence skips unnecessary provisional recognition while preserving resumed speech, unknown evidence, and authoritative final decoding
- A bounded, line-aware overlay viewport that renders the current hypothesis without stitching old previews or altering final text
- Bounded exact-editor context, target revalidation, insertion-only continuation shaping, and secure/unsupported-field exclusion
- Frozen `lowercase <payload>` directive plus `literal lowercase <text>` escape, both applied around the existing cleanup pipeline
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
- streaming-frame bounds, identity/order validation, PCM/WAV parity, final priority, and provisional/final isolation
- deterministic provisional stability, rapid restart, exact-target drift, bounded AX context, continuation, and directive behavior
- lexicon aliasing and hot-term recovery
- recording state-machine transitions
- exact-app media ownership, playback evidence, cancellation, and rapid restart races
- insertion fallbacks and target-order behavior
- usage-ledger persistence, reconciliation, calendar/streak calculation, metric provenance, and corruption handling
- compatibility-matrix matching and recommendation logic
- raw/pipeline/coordinator benchmark validation
- warm-runtime benchmark identity and acceptance validation
- release-signoff timing aggregation and gate evaluation
- compact overlay hit-testing, transcript viewport bounds, Unicode handling, and revision/reset behavior

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
- the Dictate, History, Insights, and Settings navigation

`StenoKit` intentionally keeps those concerns out of the package so the runtime and evaluation stack remain testable and reusable.

Package and hosted tests are automated evidence only. They do not establish live microphone capture, supported-player behavior, real-app insertion, UI or VoiceOver behavior, an installed signed app, notarization, or execution on macOS 13; those checks require separate manual or distribution evidence.

## Related Docs

- 1.0 acceptance checklist: [`docs/release/1.0-checklist.md`](../docs/release/1.0-checklist.md)
- Repo overview: [`README.md`](../README.md)
- Contributor workflow: [`CONTRIBUTING.md`](../CONTRIBUTING.md)
- Release-eval guide: [`docs/release/release-eval.md`](../docs/release/release-eval.md)
- Historical 0.2 release brief: [`docs/release/v0.2.0-release-brief.md`](../docs/release/v0.2.0-release-brief.md)
