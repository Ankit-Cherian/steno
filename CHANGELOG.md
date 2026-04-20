# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Rebuilt the macOS app shell with a custom window surface, bespoke title bar, segmented navigation, and a redesigned stage background.
- Redesigned the Record tab around two hero styles (`pill` and `ring`), richer listening/idle states, inline level meters, and a rebuilt transcript dock.
- Redesigned the History tab with grouped transcript rows, richer selection states, inline copy/paste actions, and a dedicated preview pane.
- Redesigned Settings with a sidebar layout, broader full-width cards, improved permissions/engine surfaces, and a new Appearance section.
- Added persistent appearance preferences for light/dark mode, accent selection, hero style, and atmosphere intensity.
- Refreshed onboarding to match the redesigned shell and visual system.
- Reworked the overlay recorder into a waveform-based floating panel with animated bars, terminal-state icons, and accent-aware styling.
- Repo setup guidance now uses a compatibility matrix keyed by Apple silicon chip class and unified memory instead of generic “higher-end Apple Silicon” wording.
- Whisper transcription now prefers rich JSON output, preserves segment timing/confidence metadata, and uses dynamic prompt steering built from language hints, app context, and hot terms.
- Local cleanup now handles repair phrases like `scratch that` through candidate generation and ranking, improves acronym/proper-noun recovery for hot terms, and keeps IDE slash-command passthrough safe.
- Benchmark reporting and validation now distinguish smoke fixtures from release-signoff runs, record hardware profile provenance, and use coordinator stop-to-insert latency for release-tier guardrails.

### Fixed
- Disabled broad background dragging on the custom title-bar window so Record / History / Settings tab clicks register reliably.
- Title bar and overlay now follow the selected accent more consistently instead of falling back to a fixed blue treatment.
- Transcript timestamps now use a 12-hour clock with `AM/PM` instead of 24-hour time.
- The Record screen model badge now reflects the configured Whisper model path instead of hardcoding `small.en`.
- Preference repair now re-detects local `whisper.cpp` runtime paths more reliably across local checkout/worktree layouts.

### Tests
- Added regression coverage for rich whisper JSON parsing, prompt/suppress argument forwarding, lexicon aliases and hot terms, repair-aware cleanup, phonetic candidate generation, and the new benchmark validation metrics.
- Added coverage for Apple silicon hardware detection, compatibility-matrix matching, smoke-vs-release benchmark evidence tiers, short repair prefixes, and confidence-aware ranking.

## [0.1.10] - 2026-03-17

### Changed
- Settings cards now stretch to full width for consistent alignment across all sections.
- Replaced the insertion priority drag list with a grouped container using compact reorder controls and internal dividers.
- Cleanup style picker rows use fixed-width label columns for consistent alignment across all four pickers.
- Engine file-path fields use monospaced type with middle truncation for readability.
- Tightened spacing between entry rows in word corrections and text shortcuts.
- Grouped helper captions closer to their associated controls in recording and media sections.
- Added a divider above Save & Apply for clearer separation from settings content.
- Recording mic button now uses a two-ring staggered ripple pulse, a softer diffuse glow shadow, and a larger button size to better fill the Record tab.
- Mic button responds to presses with a spring scale-down for tactile feedback.
- Replaced the classic status-dot overlay with a waveform capsule featuring animated frequency bars, gradient fills, layered shadows, and SF Symbol icons for terminal states.
- Overlay auto-dismiss extended from 1.5 seconds to 2.0 seconds for better readability of result states.
- Overlay entrance uses staggered bar scale-up and a staged text fade for smoother first-show animation.
- Added a brief green background flash on successful text insertion for clearer confirmation feedback.
- Removed the non-functional expand/collapse chevron from history transcript rows; tap the text directly to expand or collapse.
- Global hands-free key picker now includes F1–F12 alongside the existing F13–F20 options, so MacBook users can assign their built-in function keys without an external keyboard.
- Hands-free key picker sections labeled by keyboard type with updated setup guidance.
- Onboarding feature tour now shows a generic hands-free setup tip instead of a hardcoded key name.

## [0.1.9] - 2026-03-11

### Changed
- Added a repository acknowledgment for `whisper.cpp` and a dedicated `THIRD_PARTY_NOTICES.md` file with the upstream MIT notice.

### Fixed
- Updated the in-app `Test Setup` check to launch `whisper-cli` with the same dynamic-library environment as real dictation, so local whisper.cpp builds validate correctly from Settings.
- Surfaced stderr when the setup check fails, making local whisper.cpp configuration errors easier to diagnose.

## [0.1.8] - 2026-03-11

### Changed
- Enabled whisper.cpp voice activity detection when a VAD model is available and kept the derived VAD model path aligned with the selected Whisper model.
- Surfaced VAD setup guidance in onboarding, settings, and setup docs so silence and background-noise suppression are easier to configure correctly.
- Balanced local cleanup now preserves intentional uses of "you know" while still removing filler cases and press-to-talk starts capture before optional media interruption to avoid clipping the first words.

### Fixed
- Added a no-speech session path and overlay state so empty captures do not insert junk text.
- Stripped known whisper artifact markers before insertion and history persistence.
- Tightened macOS main-actor shutdown, overlay, and MediaRemote callback paths to keep the app stable under Swift 6/Xcode concurrency analysis.

### Tests
- Added regression coverage for artifact stripping, no-speech gating, VAD flag forwarding/model-path sync, and contextual "you know" cleanup and ranking.

## [0.1.7] - 2026-03-03

### Changed
- Hardened hotkey lifecycle and shutdown behavior to avoid late callback execution during stop/quit, including idempotent teardown and eager overlay window warm-up.
- Updated synthetic event routing so insertion and paste remain configurable through `STENO_SYNTH_EVENT_TAP`, while media keys use a dedicated tap resolver with HID as the default.
- Improved subprocess execution reliability by streaming pipe output during process lifetime, adding cancellation escalation safeguards, and caching whisper process environment setup at engine initialization.
- Optimized local cleanup and replacement paths by precompiling reusable regexes, caching lexicon/snippet regexes with cache invalidation on mutation, and preserving longest-first lexicon ordering as an explicit invariant.
- Reduced history persistence overhead by removing pretty-printed JSON output formatting.

### Fixed
- Restored reliable media pause/resume behavior during dictation by routing media key posting through a dedicated HID-default tap path.
- Prevented event-tap re-enable thrash with debounce handling after timeout/user-input tap disable events.
- Added defensive teardown behavior for overlay timers and hotkey monitor resources during object deinitialization.
- Prevented potential deadlocks and cancellation stalls in process execution paths when child processes ignore graceful termination.

### Tests
- Added media key tap routing regression coverage for default, override, and invalid environment values.
- Hardened cancellation regression coverage to verify bounded completion when subprocesses ignore `SIGTERM`.

## [0.1.6] - 2026-03-03

### Added
- Added `Steno/Steno.entitlements` and wired entitlements via `project.yml` for microphone access and DYLD environment behavior needed by local `whisper.cpp` builds.
- Added `StenoKitTestSupport` as a dedicated package target for test doubles used by `StenoKitTests`.

### Changed
- Updated insertion transport internals to use private event source state, async pacing (`Task.sleep`), and best-effort caret restoration after accessibility insertion.
- Updated permission and window behavior paths to be more predictable on macOS 13/14+, including safer main-window targeting and refreshed input-monitoring recheck flow.
- Moved persistent storage fallbacks for preferences/history to `~/Library/Application Support` (instead of temp storage) and reduced path visibility in logs.
- Updated app activation and SwiftUI `onChange` call sites to align with modern macOS APIs.

### Fixed
- Audio capture now surfaces recorder preparation/encoding failures and cleans temporary files on early failure paths.
- MediaRemote bridge teardown now drains callback queue before unloading framework handles.
- Overlay status-dot color transitions now animate through Core Animation transactions and respect live accessibility display option updates.
- Improved lock/continuation safety documentation in cancellation-sensitive concurrency paths.

### Removed
- Removed dead `TokenEstimator` utility.
- Removed production-exposed test adapter definitions from `StenoKit` main target and relocated them to `StenoKitTestSupport`.

## [0.1.5] - 2026-02-28

### Added
- Refreshed macOS app icon artwork in `Steno/Assets.xcassets/AppIcon.appiconset`.

### Changed
- Pivoted cleanup to local-only. Steno now runs transcription and cleanup fully on-device with no cloud cleanup mode.
- Removed API key onboarding/settings flow and cloud-mode status messaging to simplify setup and avoid mixed local/cloud behavior.
- Settings now use a draft-and-apply flow to avoid mutating preferences during view updates.
- Press-to-talk now attempts media interruption before starting audio capture.

### Fixed
- Media interruption detection now requires corroborating now-playing data before trusting playback-state-only signals. This prevents false `notPlaying` decisions when MediaRemote returns fallback state values with missing playback rate (including browser `Operation not permitted` probe paths).
- Weak-positive playback signals now require a short confirmation pass before sending play/pause, reducing phantom media launches when no audio is active.
- Preserved unknown-state safety behavior so playback control is skipped when media state is not trustworthy.

### Removed
- OpenAI cleanup integration (`OpenAICleanupEngine`) and remote cleanup wiring (`RemoteCleanupEngine`).
- Cloud budget and model-tier plumbing (`BudgetGuard`, cloud cleanup decision types, and cloud-only tests).

### Breaking for StenoKit Consumers
- `CleanupEngine.cleanup` removed the `tier` parameter.
- `CleanTranscript` removed `modelTier`.
- Cloud cleanup engines and budget types were removed from the package surface.

### Notes
- This release consolidates the media interruption hotfix work and local-only cleanup pivot into one tagged release (`v0.1.5`).

## [0.1.2] - 2026-02-23

### Added
- First-pass macOS app icon set in `Steno/Assets.xcassets/AppIcon.appiconset` with a stenography-inspired glyph

### Removed
- Tracked generated Xcode project files (`Steno.xcodeproj/*`) from source control

## [0.1.1] - 2026-02-21

### Added
- Benchmark tooling in `StenoKit` via `StenoBenchmarkCLI` and `StenoBenchmarkCore` (manifest parsing, run orchestration, scoring, report generation, and pipeline validation gates)
- Local cleanup candidate generation and ranking (`RuleBasedCleanupCandidateGenerator`, `LocalCleanupRanker`, and `CleanupRanking`)
- Polished README screenshots (`assets/record.png`, `assets/history.png`, `assets/settings-top.png`, and `assets/settings-bottom.png`)

### Changed
- Rule-based cleanup flow now integrates ranking-focused post-processing refinements for better transcript quality
- Onboarding and settings screens use clearer plain-language copy for first-run setup and configuration
- `README.md`, `QUICKSTART.md`, and `CONTRIBUTING.md` were reworked for clearer user and contributor onboarding

### Fixed
- Balanced filler cleanup preserves meaning-bearing uses of "like"
- Media interruption handling avoids phantom playback launches from stale/weak-positive playback signals

### Removed
- Security audit workflow and related badge from repository CI/docs

### Tests
- Expanded benchmark validation tests for scorer/report/pipeline gates
- Added cleanup accuracy and ranking behavior coverage
- Added media interruption regression coverage for stale signal handling
