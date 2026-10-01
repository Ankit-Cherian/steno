# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- History is no longer erased when its file can't be read in full. Entries that can't be read are skipped and kept in a copy of the original file, a file that can't be read at all is moved aside instead of overwritten, and the previous version of the file is kept after each save.
- Two copies of Steno running at the same time, such as a development build next to the installed app, no longer remove each other's History entries.
- A transcript that was inserted but couldn't be saved to History is no longer reported as a failed transcription. Steno says the text was inserted, offers it for copying, and never inserts it again.
- When History can't be read in full, Steno now says so once and can show the kept file in Finder.
- Settings, word corrections, text shortcuts and app style profiles are no longer reset when the settings file contains something Steno can't read. Each setting that can't be read falls back on its own, the rest load, and Steno keeps a copy of the original file. Settings files from Steno 0.1 now load with their vocabulary and shortcuts intact.
- Settings no longer report "Settings saved" when the file couldn't be written. The changes stay unsaved in Settings, with Save changes and Discard still available.
- Choosing Disabled for the hands-free key is now saved; it no longer comes back as F18 after a relaunch.
- Insights no longer resets lifetime totals when its data contains a value written by a newer version of Steno.
- Keyboard shortcuts that use Option, such as Option+Arrow, Option+Delete, or Cmd+Option+I, and quick taps of Option no longer start a dictation. The overlay no longer flashes, media keeps playing, and nothing is inserted or added to History. Recording still starts the instant Option goes down, so opening words are not clipped.
- Turning off the hands-free key no longer shows an error at launch, after saving settings, or after changing models, and a resolved shortcut problem no longer leaves a warning on the Dictate tab. A shortcut problem reported during a recording no longer hides the overlay's Stop and Cancel controls.
- Holding the hands-free key no longer sends repeated key presses to the app in front, and its key release is no longer passed through. A quick double press of the key no longer starts and immediately stops a recording.
- F3 and F4 now work as the hands-free key in standard function-key mode. Keys chosen in earlier versions keep working.
- If macOS pauses the hands-free key's listener, Steno now always turns it back on, and saving settings also recovers it.
- If the release of Option is missed, for example around a password field or a screen lock, the recording now ends within about a second and is transcribed. Recordings stop automatically after one hour, with a countdown in the overlay during the last minute, and the audio is transcribed rather than lost.
- Pressing a dictation shortcut while the previous dictation is still finishing now shows a brief notice in the overlay instead of silently doing nothing.
- Direct typing no longer types into another app when the original app can't be brought back to the front. The transcript is copied to the clipboard instead.
- Auto-paste now sends the Command-V shortcut for the current keyboard layout. On Dvorak it previously sent Command-K, which clears the terminal.
- Auto-paste now puts your previous clipboard contents back shortly after pasting, and marks the transcript it places on the clipboard as transient so clipboard managers skip it. If another app changes the clipboard before the paste, Steno no longer pastes. When Steno only copies the transcript, it stays on the clipboard.
- After pasting into Terminal, iTerm2 or Warp, Steno now says the transcript was pasted instead of asking you to press Command-V, which pasted it twice. History shows these entries as Pasted.
- Steno now copies the transcript instead of inserting it when the cursor is in a password or other secure field, or when focus moved to a different field while it was transcribing. This works with default settings; nearby-text continuation is not required. Apps that answer Accessibility slowly keep inserting as before.
- A recording recognized as punctuation only, such as a lone period, or one that cleanup empties entirely, such as fillers under Aggressive cleanup, is now reported as no speech. Nothing is inserted or saved, and the clipboard is left alone.
- Remote-desktop and virtual-machine apps now receive dictation by clipboard paste first, like terminals, because they may not pass typed characters through correctly.
- The Insertion order setting now explains when Steno changes the order, and an app that is too slow to answer Accessibility is reported as a timeout instead of "Target changed".
- On macOS 13 and 14, the media pausing settings are now shown as unavailable with the reason, instead of appearing on while doing nothing. Media pausing requires macOS 15 or later; the saved choice is kept for after an update.
- When media pausing is on, transcription no longer waits for the paused app to resume, so text appears one to three seconds sooner. A new recording started right after Cancel no longer waits for the previous resume either.
- A media player that was slow to confirm a pause is now resumed after dictation instead of being left paused.
- The media settings caption now says that media you paused yourself a few seconds before dictating may be resumed, instead of promising it always stays paused.
- Saved vocabulary corrections now apply to every dictation, including short ones and ones the recognizer was confident about. Corrections that join words, such as "steno kit" to "StenoKit", no longer need a long sentence.
- Spoken corrections such as "scratch that" and "never mind" now apply however confident the recognizer was, and paragraph capitalization is no longer dropped from clearly recognized speech.
- "Never mind" and "scratch that" are now recognized when the recognizer writes them as "Nevermind.", after a full stop, or without a comma before the corrected name.
- Paragraph formatting no longer capitalizes deliberately lowercase spellings at the start of a dictation: "iPhone", "eBay" and "macOS" stay as spoken, and a saved spelling such as "npm" is kept.
- Settings now shows whether each correction is active, never applies (a common word Steno keeps as spoken, or an app scope with no bundle ID), or is overridden by another correction. Saving a correction for a common word such as "won" asks for confirmation, and an app scope without a bundle ID or a near-duplicate entry is rejected.
- Vocabulary corrections no longer chain into each other, an app-specific correction always takes precedence over an all-apps correction for the same word, and corrections that only change capitalization, such as "github" to "GitHub", now apply.
- A correction no longer rewrites text that already has its preferred spelling, so "Visual Studio" does not become "Visual Studio Studio". Terms such as C++, C# and .NET can now be corrected.
- Moving Steno after its first launch, for example from Downloads to Applications, no longer switches a downloaded speech model back to the included Small model. Only the path that stopped working is repaired, and a custom voice-detection model is kept.
- Model downloads are now checked against the published file before they are installed. A download that doesn't match, such as a page returned by a network filter, is deleted, the current model stays in use, and Steno says what happened.
- A failed model download now shows the reason next to the Download button, in Settings and during setup.
- Downloading a model no longer replaces a voice-detection model you chose yourself.
- Choosing or downloading a model no longer reports that Steno switched to it when the change couldn't be saved. The current model stays in use and the reason is shown with the model controls.
- Appearance changes that can't be saved are now reported on the Appearance page instead of failing silently.
- When a model download finishes while Settings has unsaved edits, the locked Save now explains that the download changed the saved speech model.
- Downloaded models can now be removed or downloaded again from Settings > Speech model. Removing the model in use switches to the included Small model first.
- Permission status now updates when you return to Steno after changing access in System Settings, and a hands-free key that failed for missing access is set up again without Check again or a relaunch.
- Review settings on the Dictate tab now opens the page that fixes the problem, such as Permissions for missing Accessibility or Input Monitoring access and Speech model for a model problem. Each Open Settings button opens the matching list in Privacy & Security.
- Launch at login is now saved as On only after macOS accepts it. If registration fails, the setting stays Off and Settings says why. If macOS needs your approval, Settings says so and offers to open Login Items. Turning Steno off in Login Items is now reflected in Settings.

## [1.0.0] - 2026-09-17

[Download Steno 1.0.0](https://github.com/Ankit-Cherian/steno/releases/tag/v1.0.0). The Developer ID signed installer is notarized and includes the local speech model.

### Added
- Added GitHub Actions checks for package and app tests, native runtime behavior, security analysis, and downloadable preview installers. The release workflow signs and notarizes an approved build, records its source and installer checksum, and updates the default download after publication.
- Added a ribbon S app icon and transparent in-app mark, centered in the sidebar and used throughout onboarding.
- Added an optional live transcript that follows recording in a nonactivating overlay while preserving the completed recording as the source of final insertion.
- Added opt-in, bounded nearby-text continuation for insertion spacing and conservative casing, with editor identity revalidation and no persistence of surrounding text.
- Added Insights with a six-month activity calendar and private, on-device summaries for words, known recording time, estimated speaking speed, completed sessions, streaks, and frequently used applications. The per-session metadata is stored separately from transcript history and contains no transcript text or audio.
- Added a retained local Whisper context that communicates with a bundled helper over inherited process pipes, without opening a network listener.

### Changed
- Updated the GitHub Actions dependencies and removed duplicate validation runs for pull-request pushes.
- Reworked the README around the 1.0 interface with current native screenshots using sample data, and aligned source setup and contributor documentation with Steno 1.0.
- Unified Dictate, History, Insights, Settings, and onboarding around the Manuscript design, with clearer typography, quieter metadata, responsive reading layouts, and consistent navigation.
- Replaced the large Dictate control with a centered compact pill that reflects microphone access, listening, elapsed time, and transcription state, with configured shortcuts grouped beneath it.
- Redesigned the floating overlay as a bounded reading panel that grows downward, follows the current live hypothesis, and keeps Stop and Cancel controls stable. Long previews show a readable portion without changing final transcription.
- Preserved existing accent choices while using citron for new preferences; improved light-mode calendar contrast and light/dark overlay styling.
- Kept unsaved Settings drafts across navigation, with persistent Save changes and Discard actions, conflict feedback, and advanced engine diagnostics separated from routine setup.
- Clarified onboarding steps and readiness checks, History copy/recovery actions, and Insights metric labels; the six-month activity calendar keeps lifetime totals independent of its display range.
- Increased local transcript history capacity from 500 to 1,000 entries while keeping the separate usage ledger independent of transcript retention.
- Removed simulated audio meters and misleading shortcut hints; recording controls reflect the actual configured shortcuts and enabled modes.
- Retained transcription falls back to the existing local `whisper-cli` path when the helper is unavailable or fails. Cancellation stops the request; model, VAD, runtime, sleep/wake, or memory-state changes invalidate the retained context for a subsequent reload.
- Media interruption now sends semantic Pause and Play commands only to the exact application and process lineage that Steno verified was producing audio. Ambiguous ownership fails closed, and Steno never uses a global play/pause toggle fallback.
- Local cleanup is conservative by default: ambiguous phrases such as `question mark`, `open paren`, and `slash command` remain literal. Repair handling, punctuation preservation, and user lexicon replacements avoid inferring dictated-symbol intent; only explicitly selected Aggressive cleanup performs narrow filler removal.
- Benchmark results now carry reproducible input and runtime identity, including manifest, model, VAD, lexicon, and executable provenance.
- Direct-distribution builds package the retained-runtime helper and validate its local `whisper.cpp` dependency set alongside the app.

### Fixed
- Disabled automatic native backend discovery so the bundled runtime does not search for additional backend libraries.
- Fixed memory-allocation failure handling and integer arithmetic in the pinned native runtime.
- Passed cancellation through native encoder and decoder work, and limited voice-activity detection workers to the CPUs available.
- Moved helper pipe reads off Swift’s cooperative executor and preserved remaining pipe output during process termination.
- Kept editor preparation tied to its dictation session when cancellation overlaps setup.
- Marked preference errors and application identities in media diagnostics as private in unified logs.
- Fixed unwanted repeated text such as "Terms, Terms, Terms" appearing without corresponding speech. The retained Whisper helper checks acoustic support and corroborates suspected repetitions with a prompt-free decode while preserving deliberately dictated words.
- Reject incomplete or malformed capture WAVs before recognition so unfinished audio cannot produce an insertion or history entry.
- Treat failed voice-activity detection as a transcription failure instead of accepting an invalid speech mask.
- Skip provisional recognition when voice activity detection confirms that newly appended audio is silent; final transcription remains unchanged.
- Route on-screen Stop through the active recording mode so both press-to-talk and hands-free captures end correctly.
- Prevent medium and long overlay text from clipping through line-aware sizing, and bound layout work for unusually long hypotheses.
- Hardened capture start, cancellation, overlap, rapid restart, and shutdown so stale asynchronous work cannot resume media or modify a newer dictation session.
- Improved session teardown and insertion ownership so recording resources close promptly and completed text is inserted or persisted at most once through the active session.
- Kept media that was already paused unchanged and resumed only media that Steno itself verified it paused.

### Tests
- Added full-source Swift, C++, and workflow security analysis. Reviewed findings are bound to their exact source and report details; changed or unreviewed high-severity findings still block the security gate.
- Added native allocation-failure checks, backend-discovery regression coverage, and an upload/download check for release artifacts. Hosted inference checks use CPU execution; native Metal and real-device acceptance remain separate.
- Added shared C++ decision tests, real-inference scoring controls, vocabulary-prompt protocol checks, and opt-in retained-helper tests across preview modes, cleanup, insertion, and history. Verification metadata is covered without making it part of saved transcripts.
- Added focused coverage for Settings drafts and conflicts, recording Stop behavior, overlay layout and revisions, and synthetic app states.
- Expanded automated package and hosted macOS coverage for retained-runtime lifecycle and fallback behavior, exact-process media ownership, cancellation and rapid-restart races, conservative cleanup, insertion ownership, helper packaging, and dependency validation.

### Removed
- Removed the temporary three-design selection from the app; Manuscript is the single interface.

### Compatibility
- Steno 1.0 targets Apple silicon Macs running macOS 13 or later. The minimum-OS installation and full manual acceptance matrix have not been completed; Intel Macs are not supported.

### Known issues
- Voice-activity detection can omit words in quiet speech after a long silent lead-in. A separate experimental correction is deferred and is not included in 1.0; the retained limitation remains documented for the release decision.
- The legacy CLI fallback does not include the retained helper's prompt-verification correction. A separate small.en control can mistake deliberately spoken "Terms" for "Churns"; that recognition limitation is deferred from this bug closeout.

## [0.2.0] - 2026-04-21

### Added
- Added a formal release-eval workflow with repo-level `scripts/run-release-eval.sh` and `scripts/run-smoke-benchmark.sh` entrypoints.
- Added a self-contained direct-distribution workflow that bundles a local `whisper.cpp` runtime and model into the app and packages Steno as a DMG-ready macOS app.
- Added bundled `small.en` as the default first-run model in the downloadable build, with in-app downloads for `medium.en` and `large-v3-turbo` surfaced through onboarding and Settings.
- Added a compatibility matrix keyed by Apple silicon chip class and unified memory so model recommendations are backed by explicit support tiers instead of generic hardware advice.
- Added richer whisper transcript ingestion, including segment timing/confidence metadata and prompt steering assembled from language hints, app context, and hot terms.
- Added appearance preferences for accent selection, atmosphere intensity, color mode, and Record hero style.
- Added compact cancel controls across the redesigned in-app recorder and floating overlay surfaces.

### Changed
- Rebuilt the macOS app shell with a custom window surface, bespoke title bar, segmented navigation, and a redesigned stage background.
- Redesigned the Record tab around `pill` and `ring` hero styles, richer listening/idle/transcribing states, inline level meters, and a rebuilt transcript dock.
- Redesigned the History tab with grouped transcript rows, stronger selection states, inline copy/paste actions, and a dedicated preview pane.
- Redesigned Settings with a broader card-based layout, improved permissions and engine surfaces, and a dedicated Appearance section.
- Refreshed onboarding to match the redesigned shell and local-first product story.
- Reworked the recording overlay into a waveform-based floating panel with animated bars, terminal-state icons, accent-aware styling, and compact cancellation.
- Refreshed the macOS app icon to the new app logo.
- Updated hardware/model setup guidance in the docs so canonical local models and recommendation tiers are explained consistently across the repo.
- Benchmark reporting now separates smoke fixtures from release-signoff evidence, records hardware provenance, and uses coordinator stop-to-insert timing for release-tier latency gates.

### Fixed
- Hardened prompt contamination handling so prompt-echo-like transcripts are treated as no-speech before cleanup, insertion, or history persistence.
- Tightened local cleanup recovery and repair-aware cleanup behavior for natural self-corrections such as `scratch that`, `never mind`, `I mean`, `actually`, and conservative utterance-initial `no`.
- Preserved literal counterexamples like `No, thanks.` and `No, maybe later.` while improving repair resolution.
- Fixed command-line parsing so repeated `--extra-arg` values that themselves start with dashes are preserved during release-eval and VAD-backed runs.
- Reduced release-eval latency tail issues enough for the exact `m5-pro / 64GB / large-v3-turbo` row to pass the canonical 0.2 release-signoff run.
- Disabled broad background dragging on the custom title-bar window so Record / History / Settings tab clicks register reliably.
- Improved title-bar and overlay accent behavior so the selected accent is applied consistently instead of falling back to a fixed blue treatment.
- Switched transcript timestamps to a 12-hour `AM/PM` presentation.
- Updated the Record surface to reflect the configured Whisper model instead of hardcoding `small.en`.
- Improved local `whisper.cpp` path repair across checkout/worktree layouts.
- Prevented disabled Launch at login from showing a warning on cold launch when no ServiceManagement change was requested.
- Preserved valid custom `whisper-cli` and Whisper model paths when the optional VAD model is missing.

### Tests
- Expanded benchmark and release-eval coverage for raw/pipeline/coordinator metrics, signoff thresholds, evidence tiers, timing breakdowns, and coverage-aware `not_evaluable` reporting.
- Added regression coverage for rich whisper JSON parsing, prompt/suppress argument forwarding, prompt-echo no-speech gating, compatibility-matrix matching, repair-aware cleanup, and confidence-aware ranking.
- Added targeted tests for repair phrases, literal-preservation counterexamples, command-line argument preservation, and compact overlay hit-testing.
- Added regression coverage for launch-at-login mutation decisions and custom runtime path repair with a missing VAD model.

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
- Remote cleanup integration and related cleanup wiring.
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
