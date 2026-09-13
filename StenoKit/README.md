# StenoKit

`StenoKit` contains Steno's audio capture, Whisper runtime, text cleanup, insertion, history, usage analytics, and media controls. It also provides the benchmark runner and release-evaluation tools.

The macOS app in `Steno/` connects these services to its windows, settings, onboarding, menu bar, and application lifecycle. The package includes the recording overlay's presentation and layout helpers.

Requires Swift 6.2 or later. The package targets macOS 13 or later; the app and native runtime build use Apple silicon. See [the source setup guide](../QUICKSTART.md) for the Xcode host requirements and local runtime setup.

## Package contents

### Runtime services

- `SessionCoordinator`: actor that manages a dictation from capture through insertion and history
- `MacAudioCaptureService`: local audio capture
- `WhisperCLITranscriptionEngine`: local `whisper.cpp` adapter
- `RetainedWhisperTranscriptionEngine`: reuses a loaded model, serializes requests, and handles CLI fallback, cancellation, configuration changes, and shutdown
- `RuleBasedCleanupEngine`: local cleanup pipeline
- `InsertionService`: target-aware insertion routing
- `HistoryStore`: transcript persistence and recovery
- `UsageAnalyticsStore`: separate aggregate per-session usage persistence and calculation
- `MacMediaInterruptionService`: pauses and resumes only the app it verifies, leaving uncertain playback state alone
- `PersonalLexiconService`: term correction and alias handling
- `StyleProfileService`: cleanup policy selection
- `SnippetService`: phrase expansion
- `WhisperCompatibilityService`: hardware/model recommendation logic

### Models and state

- transcript models with segment metadata
- recording state-machine models
- cleanup policies used by profiles and preferences
- hardware/model compatibility types
- usage events with measurement sources, calendar summaries, streaks, speed, and per-app metrics
- retained-runtime load identity and lifecycle configuration

### Benchmarks

- `StenoBenchmarkCLI`
- `StenoBenchmarkCore`
- benchmark manifest parsing and corpus generation support
- raw ASR vs pipeline cleanup scoring
- release-threshold validation
- machine-readable and human-readable release summary/report generation

## Public Interfaces

The main interfaces are:

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

- Whisper stays loaded between compatible dictations in a private helper connected through inherited pipes, with no network listener. The first request loads the model; changes to the model, VAD, or other load configuration require a reload. Cancellation, unloading, and shutdown release retained resources. Recoverable helper failures can use a per-request CLI fallback; cancellation, stale responses, and VAD integrity failures do not.
- The versioned streaming protocol supports live transcripts, cooperative cancellation, and priority for final recognition. It validates PCM frame counts and digests. Session, controller, runtime, revision, and audio-watermark checks prevent stale previews from reaching a newer recording.
- Live text can revise itself. The overlay displays a limited, line-aware portion of the current text without joining previous previews or changing the final transcript. Voice-activity detection skips preview decoding only for confirmed new silence; resumed speech, unknown evidence, and final decoding retain their normal paths.
- Nearby editor text is limited to the active target and checked again before insertion. Automatic continuation is restricted to English in supported fields in Apple Mail, Notes, and TextEdit; secure and unsupported fields are excluded. The independent `lowercase <payload>` command and `literal lowercase <text>` escape run around the existing cleanup steps.
- Insights stores session metadata separately from transcript history, without transcript text or audio. It provides calendar activity, streaks, words, known time, session counts, weighted speed, cleanup coverage, and top apps.
- Media Pause and Play commands apply only to the verified app and process. Uncertain playback state, cancellation, and rapid restarts cannot authorize an unrelated resume.
- Cleanup preserves ambiguous language, repairs, punctuation, and lexicon intent. Only explicitly selected Aggressive cleanup removes its supported filler phrases.
- Benchmark results identify their inputs and runtime. Package and hosted macOS tests cover the retained runtime and related app behavior.

The retained helper is built from the audited `whisper.cpp` revision `764482c3175d9c3bc6089c1ec84df7d1b9537d83` into `vendor/whisper.cpp/build-steno/bin/`. The canonical build targets Apple silicon and macOS 13+, disables the server, RPC, and CURL paths, and keeps the standalone CLI available.

## Test coverage

`swift test --package-path StenoKit` covers:

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

Run the smoke benchmark with Python 3 available. The script generates its synthetic inputs automatically:

```bash
cd /path/to/steno
scripts/run-smoke-benchmark.sh
```

Run the release evaluation with Python 3 and the prepared LibriSpeech WAV subset described in [the evaluation guide](../docs/release/release-eval.md). The script expects specific filenames and reference text, not an arbitrary LibriSpeech directory:

```bash
cd /path/to/steno
STENO_WHISPER_CLI=/absolute/path/to/whisper-cli \
STENO_WHISPER_MODEL=/absolute/path/to/ggml-large-v3-turbo.bin \
STENO_VAD_MODEL=/absolute/path/to/ggml-silero-v6.2.0.bin \
STENO_LIBRISPEECH_ROOT=/absolute/path/to/librispeech_test_clean \
scripts/run-release-eval.sh
```

## Prompt-verification regression checks

The retained helper has separate decision and real-inference checks. From the repository root, run `bash scripts/test-whisper-prompt-verification.sh` for the shared decision rules and `bash scripts/test-whisper-prompt-scoring.sh` for the scorer. The scorer requires the local whisper.cpp build, a model, the JFK sample, Python 3, and macOS speech synthesis; its defaults are `small.en` and the Samantha voice. Set `STENO_TEST_WHISPER_MODEL` explicitly for each additional model, and `STENO_TEST_SPEECH_VOICE` to test another installed voice. Generated speech can vary between macOS voice versions.

The opt-in coordinator suite requires public or synthetic 16 kHz mono PCM WAVs. Keep the manifest and audio together; audio paths are relative to the manifest. The normal package command does not run this suite. Supply the local files and a new output directory:

```sh
STENO_TEST_RETAINED_HELPER=/absolute/path/to/steno-whisper-runtime \
STENO_TEST_WHISPER_MODEL=/absolute/path/to/model.bin \
STENO_TEST_WHISPER_VAD=/absolute/path/to/vad-model.bin \
STENO_TEST_PROMPT_MANIFEST=/absolute/path/to/fixture-bundle/manifest.json \
STENO_TEST_PROMPT_RECEIPTS=/absolute/path/to/new-receipts \
bash scripts/test-prompt-isolation.sh
```

The manifest schema is documented in [PromptIsolationIntegrationTests.swift](Tests/StenoKitTests/PromptIsolationIntegrationTests.swift): `publicOrSyntheticAudio: true` and fixtures containing `id`, `audio`, `expectedText`, and `hotTerms`. Required cases cover ordinary speech, literal and repeated terms, vocabulary, pauses, and silence. References must be independently supplied, and exact audio hashes must accompany evaluation results. Omit the VAD variable only for a deliberately separate diagnostic run. The runner creates an isolated Swift build cache unless `STENO_TEST_SWIFT_SCRATCH_PATH` is supplied.

This suite exercises press-to-talk with preview enabled and disabled, the retained helper, cleanup, isolated insertion, and file history. It does not exercise a microphone, native editor delivery, or hands-free mode. Per-window helper diagnostics are available in rich output to external harnesses; they are not persisted by the app.

Package and hosted tests do not replace checks with a microphone, supported media players, real editors, VoiceOver, or an installed app on macOS 13. Signing and notarization also require separate verification. See the release checklist below.

## Related Docs

- 1.0 acceptance checklist: [`docs/release/1.0-checklist.md`](../docs/release/1.0-checklist.md)
- Repo overview: [`README.md`](../README.md)
- Contributor workflow: [`CONTRIBUTING.md`](../CONTRIBUTING.md)
- Release-eval guide: [`docs/release/release-eval.md`](../docs/release/release-eval.md)
- Historical 0.2 release brief: [`docs/release/v0.2.0-release-brief.md`](../docs/release/v0.2.0-release-brief.md)
