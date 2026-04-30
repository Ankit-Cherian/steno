# Steno

Fast local dictation for macOS, redesigned for 0.2.

Steno is a local-first voice-to-text app for people who want fast dictation, reliable insertion, and smart cleanup without shipping their audio to a hosted transcription service. Version 0.2 is the first release that fully combines the redesigned macOS product surface with the recent engine, cleanup, and release-eval work.

[![Swift Tests](https://github.com/Ankit-Cherian/steno/actions/workflows/swift-tests.yml/badge.svg)](https://github.com/Ankit-Cherian/steno/actions/workflows/swift-tests.yml)

## Download

Download the current macOS release:

[Download Steno-0.2.0.dmg](https://github.com/Ankit-Cherian/steno/releases/download/v0.2.0/Steno-0.2.0.dmg)

Open the DMG, drag Steno to Applications, then launch Steno from Applications. Source setup is only needed if you want to build or contribute to the app.

## Why 0.2 Matters

- Full macOS redesign across the app shell, Record, History, Settings, onboarding, and the floating overlay.
- Richer local transcription pipeline with JSON-aware `whisper.cpp` ingestion, hot-term steering, and better hardware/model guidance.
- Stronger cleanup behavior for repairs, filler removal, prompt contamination, and no-speech handling without adding a cloud cleanup dependency.
- Formal smoke and release-eval workflows, plus an exact validated hardware/model row for the current canonical signoff run.

## What Steno Does

- High-accuracy local transcription with `whisper.cpp`
- Bundled `small.en` for immediate first-run use, with in-app downloads for larger canonical models based on your hardware
- App-aware insertion: direct typing where it is safe, clipboard-first behavior where terminals or LLM surfaces need it
- Global dictation controls: `Option` hold-to-talk plus a configurable hands-free toggle key
- Local cleanup with tone, structure, filler, and command-passthrough policies
- Personal lexicon corrections, app-specific overrides, and text shortcuts
- Searchable transcript history with recovery-oriented copy and paste actions
- VoiceOver-aware controls and reduced-motion-aware animation behavior
- Floating recording overlay with waveform motion, terminal-state icons, and compact cancel controls

## Release Validation

The current 0.2 candidate passed the April 23 release evaluation on an M5 Pro MacBook Pro with 64GB memory using the Large V3 Turbo model.

Key results:

- Cleaned WER: 9.21%
- Cleaned CER: 8.78%
- Coordinator latency: 1049ms p50, 1060ms p90, 1114ms p99
- Status: passed
- Manual Mac sanity checklist: pending

## Screenshots

Representative 0.2 screenshots:

<table>
  <tr>
    <td><img src="assets/record.png" alt="Record tab in Steno 0.2" width="500"></td>
    <td><img src="assets/settings.png" alt="Settings appearance tab in Steno 0.2" width="500"></td>
  </tr>
</table>

## Developer Setup

For source builds, use [QUICKSTART.md](QUICKSTART.md). Local development expects Xcode, XcodeGen, a local `whisper.cpp` runtime, and downloaded model files.

### Model guidance

Steno curates four canonical local models:

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

These are recommendation tiers, not blanket validation claims. Exact validated rows live in the compatibility matrix and release-eval artifacts.

## Daily Use

- Hold `Option` to record immediately, then release to transcribe and insert.
- Use the configured hands-free function key to start and stop dictation without holding a modifier.
- Let Steno route insertion by target: direct typing for standard editors, safer clipboard-oriented behavior where needed.
- Use Settings to control cleanup tone, structure, filler removal, command handling, appearance, and engine configuration.
- Use History to search old transcripts, recover prior text, and repaste the exact output that was inserted or copied.

## Release Eval

The repo-level release-eval entrypoint is:

```bash
STENO_WHISPER_CLI=/absolute/path/to/whisper-cli \
STENO_WHISPER_MODEL=/absolute/path/to/ggml-large-v3-turbo.bin \
STENO_VAD_MODEL=/absolute/path/to/ggml-silero-v6.2.0.bin \
STENO_LIBRISPEECH_ROOT=/absolute/path/to/librispeech_test_clean \
scripts/run-release-eval.sh
```

Useful notes:

- `scripts/run-release-eval.sh --smoke-only` runs only the package tests plus the smoke fixture benchmark.
- Full release eval writes local audit artifacts that stay out of git.
- Smoke and release evidence are intentionally separate.
- The release report also records `not_evaluable` gates when the corpus did not honestly exercise a metric.

For the benchmark and signoff workflow details, see [docs/release/release-eval.md](docs/release/release-eval.md).

## Contributor Path

- Setup and contributor workflow: [CONTRIBUTING.md](CONTRIBUTING.md)
- Fast local run instructions: [QUICKSTART.md](QUICKSTART.md)
- Detailed 0.2 release brief: [docs/release/v0.2.0-release-brief.md](docs/release/v0.2.0-release-brief.md)
- Direct-download DMG workflow: [docs/release/direct-distribution.md](docs/release/direct-distribution.md)
- Core package overview: [StenoKit/README.md](StenoKit/README.md)

## Known Limitations

- macOS only
- Local setup still expects a built `whisper.cpp` runtime and downloaded model files
- Release-eval validation is row-specific, not universal hardware proof
- Production microphone behavior is broader than the current benchmark corpus
- Cleanup is materially stronger than before, but raw repair-marker preservation is still not something to oversell as “perfect”

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting expectations.

## Support

See [SUPPORT.md](SUPPORT.md) for usage help and bug report paths.

## Acknowledgments

Steno uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) by Georgi Gerganov and contributors for local speech-to-text transcription. whisper.cpp is licensed under the MIT License. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the upstream notice text included with this repository.

## License

MIT — see [LICENSE](LICENSE) for details.
