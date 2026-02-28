# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.5] - 2026-02-27

### Changed
- Pivoted cleanup to local-only. Steno now runs transcription and cleanup fully on-device with no cloud cleanup mode.
- Removed API key onboarding/settings flow and cloud-mode status messaging to simplify setup and avoid mixed local/cloud behavior.

### Removed
- OpenAI cleanup integration (`OpenAICleanupEngine`) and remote cleanup wiring (`RemoteCleanupEngine`).
- Cloud budget and model-tier plumbing (`BudgetGuard`, cloud cleanup decision types, and cloud-only tests).

### Fixed
- Preserved the media interruption fixes from the prior hotfix work while removing cloud cleanup paths, so active media still pauses/resumes correctly for press-to-talk and hands-free flows.

## [0.1.4] - 2026-02-27

### Added
- Refreshed macOS app icon artwork in `Steno/Assets.xcassets/AppIcon.appiconset`.
- Cleanup health status in Settings so cloud success/fallback outcomes are visible after each transcription.

### Fixed
- Media interruption detection now requires corroborating now-playing data before trusting playback-state-only signals. This prevents false `notPlaying` decisions when MediaRemote returns fallback state values with missing playback rate (including browser `Operation not permitted` probe paths).
- Weak-positive playback signals now require a short confirmation pass before sending play/pause, which reduces phantom media launches when no audio is active.
- Press-to-talk now attempts media interruption before starting audio capture, reducing early background-audio bleed into transcripts.
- OpenAI cleanup now uses a dedicated bounded URL session with transient retry handling, which prevents long hangs and improves resilience to intermittent network drops.
- Cloud cleanup fallback now reports explicit warnings and outcomes instead of silently appearing as local cleanup, including clearer 429 quota/billing guidance.
- Settings now edit a local draft before save, preventing SwiftUI “Publishing changes from within view updates” warnings when switching cleanup mode and other preferences.
- Save & Apply now persists both preferences and API key together, so cleanup mode/key changes are applied in one step.

### Notes
- The `v0.1.1`/`v0.1.2` phantom-start guard fixed one class of stale-signal issues, but it could still miss real playback pause events when MediaRemote exposed uncorroborated state values without now-playing metadata (for example browser media). This patch closes that gap while keeping unknown-state safety no-op behavior.

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
