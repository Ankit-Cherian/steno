# Steno Direct Distribution

Package Steno as a self-contained app in a DMG for distribution outside the Mac App Store. Users can install it without Xcode, a source checkout, a `whisper.cpp` build, or manual runtime/model path setup.

The packaging entry point is `scripts/release-dmg.sh`. Use the preview command below to test it without Apple credentials; its default mode signs and submits the DMG for notarization.

The current candidate is unreleased. Its development build is an ad-hoc signed Debug app. Developer ID signing, notarization, stapling, installation, manual macOS checks, hosting, and download-link verification remain pending for the release. Complete [the release checklist](1.0-checklist.md) and obtain release approval before running the signing and publication steps below.

## Prerequisites

The app targets Apple silicon and macOS 13 or later. Use a packaging Mac with:

- Xcode 26.3 and its command-line tools
- XcodeGen, CMake, Git, and Python 3.11 or later
- `vendor/whisper.cpp` at revision `764482c3175d9c3bc6089c1ec84df7d1b9537d83`
- the selected Whisper model and Silero VAD model

Packaging invokes `scripts/build-whisper-runtime-helper.sh` itself: it verifies the pinned source revision, applies the [reviewed native corrections](../../scripts/ci/patches/README.md) to isolated source, and builds the Apple silicon runtime for macOS 13. A prebuilt helper is not required. The selected build directory is writable build state; choose a separate directory when preserving an existing helper. See [local runtime provisioning](../ci-cd.md#local-reproduction) for checksum-verified source and model setup.

Run from the repository root with a clean worktree. The script regenerates `Steno.xcodeproj`, builds in its distribution directory, and runs a focused Swift package inference test, which can update the package build cache.

For the signed release flow below, verify that a **Developer ID Application** certificate is available in Keychain and that a saved `notarytool` profile works. The script also supports a notary API key, as used by CI; see its environment options when using that route.

To save a local profile:

```bash
xcrun notarytool store-credentials StenoNotary
```

Pass that profile to the release script:

```bash
STENO_NOTARY_PROFILE=StenoNotary scripts/release-dmg.sh
```

## Bundle contents

The script builds an unsigned Release app, copies in the runtime and models, patches library rpaths, signs nested code, signs the app with distribution entitlements, and signs the DMG. Its default signed mode then notarizes and staples the DMG. Steno and third-party license notices are included.

| Component | Location in the app |
| --- | --- |
| Standalone CLI | `Steno.app/Contents/Helpers/whisper-cli` |
| Retained helper | `Steno.app/Contents/Helpers/steno-whisper-runtime` |
| Required `libwhisper` and `libggml*` libraries | `Steno.app/Contents/Frameworks/` |
| Selected Whisper model and Silero VAD model | `Steno.app/Contents/Resources/WhisperModels/` |

Keep these binaries out of Git. The app detects and prefers the bundled runtime on first launch. The retained helper communicates through inherited standard-input and standard-output pipes, with no HTTP server or network listener. The CLI remains available when helper startup or recovery fails.

The default runtime build directory is `vendor/whisper.cpp/build-steno`. To build the runtime in a separate directory for a preview:

```bash
STENO_BUNDLED_WHISPER_BUILD_DIR=/absolute/path/to/new-build-steno \
scripts/release-dmg.sh --unsigned-preview
```

Packaging stops if the pinned source revision is wrong or has tracked changes, the runtime requires a newer macOS version than 13, the binaries are not Apple-silicon-only, a dependency is missing, or the retained helper imports listener-related network symbols. The script also checks bundle contents, rpaths, and license notices.

## Bundled model

The script selects the first available model in this order:

1. `ggml-small.en.bin`
2. `ggml-base.en.bin`
3. `ggml-medium.en.bin`
4. `ggml-large-v3-turbo.bin`

The release workflow explicitly bundles `small.en` for first use. Users can download `medium.en` or `large-v3-turbo` in the app. To choose the bundled model explicitly:

```bash
STENO_BUNDLED_MODEL_PATH=/absolute/path/to/ggml-small.en.bin \
scripts/release-dmg.sh --unsigned-preview
```

## Test packaging

To check the build script, bundled runtime, and DMG layout without Apple credentials:

```bash
scripts/release-dmg.sh --unsigned-preview
```

This creates an ad-hoc signed `-preview.dmg`, not a public release. Preview helpers omit hardened-runtime options so their ad-hoc libraries can load; production signatures retain hardened runtime. `--skip-notarize` still requires Developer ID signing. Use it only to inspect a signed artifact before separately approved notarization.

Each run creates a new `build/distribution-<timestamp>-<pid>` directory. The default helper build still writes to `vendor/whisper.cpp/build-steno`; use `STENO_BUNDLED_WHISPER_BUILD_DIR` as above to keep an existing helper unchanged. If you set `STENO_DIST_DIR`, use an absolute path to a new, dedicated directory under `build` or the temporary directory. The script protects existing output, protected roots, and `build/Steno.app` from replacement.

## Build and verify the release

With release approval, a Developer ID Application certificate, and the saved notary profile:

```bash
STENO_NOTARY_PROFILE=StenoNotary scripts/release-dmg.sh
```

Verify the exact output, substituting the directory and version printed by the script:

- `codesign --verify --deep --strict --verbose=2 <output-directory>/Steno.app`
- `codesign --verify --verbose=2 <output-directory>/Steno-<version>.dmg`
- `xcrun stapler validate <output-directory>/Steno-<version>.dmg`
- `spctl -a -vv -t open --context context:primary-signature <output-directory>/Steno-<version>.dmg`

Before publishing, record the following against that artifact:

- Developer ID signatures, notarization, stapling, and Gatekeeper validation.
- Installation and first launch from the DMG on supported Apple silicon Macs, including macOS 13.
- Microphone capture, media pause/resume, editor insertion, Settings, History, Insights, UI, and VoiceOver/accessibility checks from the release checklist.
- Release hosting and the actual download link after the approved upload.

A packaging check or successful build cannot substitute for these results. Keep each item pending until it has been checked on the release artifact.

For GitHub publication, use the [release workflow](../ci-cd.md#release-operation), which creates checksums, a source manifest, final-DMG attestation, and a verified draft. The local packaging script does not upload a release or create that publication provenance. If notarization times out, inspect `release-notary-receipt.json` in the output directory and query that submission before considering another upload; an unavailable submission ID means the outcome remains unknown.
