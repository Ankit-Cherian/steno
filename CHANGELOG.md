# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
