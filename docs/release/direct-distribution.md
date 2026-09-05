# Steno Direct Distribution

This document covers the repo’s direct-distribution path for Steno outside the Mac App Store.

> **1.0 candidate status:** The repository contains the packaging mechanics described below, including the retained local runtime helper. This preparation does not produce a public release: no Developer ID signing, notarization, stapling, upload, download-link change, installed-app check, or manual macOS acceptance run is claimed here.

## Goal

Produce a downloadable, self-contained `Steno.app` inside a DMG so users do not need to:

- install Xcode
- clone the repo
- build `whisper.cpp`
- manually point the app at local model/runtime paths

## Current implementation

The repo now includes:

- bundled-runtime discovery in the app
- bundled `small.en` as the always-available first-run model
- in-app downloads for `medium.en` and `large-v3-turbo`
- a distribution entitlements file
- a `scripts/release-dmg.sh` script that:
  - builds the audited Apple-silicon `whisper.cpp` runtime targeting macOS 13
  - builds an unsigned Release app
  - injects a bundled `whisper.cpp` runtime and model into the app bundle
  - patches runtime rpaths for the bundled layout
  - signs the app and DMG with Developer ID Application signing
  - creates a DMG
  - optionally notarizes and staples the DMG
  - includes Steno and third-party license notices

The retained helper communicates only through inherited standard-input and standard-output pipes. It does not open an HTTP server or any other network listener. The app keeps the CLI path as a fallback when retained runtime startup or recovery fails.

## Main script

```bash
cd /path/to/steno
scripts/release-dmg.sh
```

## Build and release prerequisites

The supported distribution target is Apple silicon on macOS 13 or later. A packaging machine needs:

- Xcode and its command-line tools
- XcodeGen
- CMake
- the local `vendor/whisper.cpp` checkout at audited revision `764482c3175d9c3bc6089c1ec84df7d1b9537d83`
- a successful canonical runtime build in `vendor/whisper.cpp/build-steno`
- the selected Whisper model and Silero VAD model

The helper and CLI can be built with:

```bash
scripts/build-whisper-runtime-helper.sh
```

That script verifies the pinned `whisper.cpp` revision and produces the Apple-silicon, macOS-13-targeted runtime in `build-steno`.

For a signed, notarized public artifact, the machine additionally needs:

- a **Developer ID Application** certificate installed in Keychain
- a saved `notarytool` keychain profile

Example notary credential setup:

```bash
xcrun notarytool store-credentials StenoNotary
```

Then the release script can use:

```bash
STENO_NOTARY_PROFILE=StenoNotary scripts/release-dmg.sh
```

## Runtime bundle strategy

The downloadable build does not commit giant binaries into git.

Instead, the release script copies a local runtime into the app bundle from a detected or specified `whisper.cpp` checkout:

- `whisper-cli`
- `steno-whisper-runtime`, a private inherited-pipe helper with no listener
- required `libwhisper` / `libggml*` dylibs
- one selected canonical model
- the VAD model

They are copied into standard macOS bundle locations:

- helper CLI: `Steno.app/Contents/Helpers/whisper-cli`
- retained helper: `Steno.app/Contents/Helpers/steno-whisper-runtime`
- dylibs: `Steno.app/Contents/Frameworks/`
- model files: `Steno.app/Contents/Resources/WhisperModels/`

The app now prefers that bundled runtime automatically on first launch when it exists.

The release script uses `vendor/whisper.cpp/build-steno` by default. Override the build directory only when validating another canonical build:

```bash
STENO_BUNDLED_WHISPER_BUILD_DIR=/absolute/path/to/build-steno \
scripts/release-dmg.sh
```

Packaging fails closed if the audited source revision is not clean, a runtime binary requires newer than macOS 13, the runtime is not Apple-silicon-only, a dependency is missing, or the retained helper imports listener-related network symbols.

## Choosing the bundled model

By default, the script prefers the first locally available canonical model in this order:

1. `ggml-small.en.bin`
2. `ggml-base.en.bin`
3. `ggml-medium.en.bin`
4. `ggml-large-v3-turbo.bin`

You can override this explicitly:

```bash
STENO_BUNDLED_MODEL_PATH=/absolute/path/to/ggml-small.en.bin scripts/release-dmg.sh
```

## Dry run vs real release

### Mechanical dry run

If you only want to test the packaging pipeline:

```bash
STENO_DIST_SIGN_IDENTITY="<local development signing identity>" \
scripts/release-dmg.sh --skip-notarize
```

This is useful for:

- build-script debugging
- runtime-bundling validation
- DMG layout checks

It is **not** the final public artifact path.

### Real public release

Use:

```bash
STENO_NOTARY_PROFILE=StenoNotary scripts/release-dmg.sh
```

with a real `Developer ID Application` certificate available.

## Validation checklist

### Automated packaging checks

The script checks the runtime architecture and deployment target, required dependencies, helper listener symbols, bundle contents, rpaths, and included Steno and third-party license notices. Those checks establish packaging properties only; they do not establish signing, notarization, installation, launch, microphone, media-interruption, insertion, UI, VoiceOver, or OS-compatibility behavior.

After a real signed run, validate the exact generated artifact (substitute the version produced by the script):

- `codesign --verify --deep --strict --verbose=2 build/distribution/Steno.app`
- `codesign --verify --verbose=2 build/distribution/Steno-<version>.dmg`
- `xcrun stapler validate build/distribution/Steno-<version>.dmg`
- `spctl -a -vv -t open --context context:primary-signature build/distribution/Steno-<version>.dmg`

### Pending release and manual proof

Before calling a 1.0 artifact releasable, separately complete and record:

- Developer ID signing, notarization, stapling, and Gatekeeper validation
- installation and first-launch checks from the produced DMG on supported Apple-silicon Macs
- the release checklist’s microphone, media interruption, insertion, settings, history, Insights, UI, and accessibility checks
- a macOS 13 compatibility run
- release hosting and download-link verification

## Current blocker

For the unreleased 1.0 candidate, the packaging path exists, but a public notarized DMG is not established by this preparation. Release time still requires verified credentials and fresh receipts:

- an available `Developer ID Application` certificate must be verified
- an available `notarytool` keychain profile must be verified

Once those exist, `scripts/release-dmg.sh` is intended to be the end-to-end packaging path. This document does not claim that a 1.0 DMG has been signed, notarized, uploaded, or made available for download.
