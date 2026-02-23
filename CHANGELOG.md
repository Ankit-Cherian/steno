# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
