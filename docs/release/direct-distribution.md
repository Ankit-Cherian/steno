# Steno Direct Distribution

This document covers the repo’s direct-distribution path for Steno outside the Mac App Store.

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
  - builds an unsigned Release app
  - injects a bundled `whisper.cpp` runtime and model into the app bundle
  - patches runtime rpaths for the bundled layout
  - signs the app
  - creates a DMG
  - optionally notarizes and staples the DMG

## Main script

```bash
cd /path/to/steno
scripts/release-dmg.sh
```

## Required Apple-side prerequisites

Before a real public release can be notarized, the machine needs:

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
- required `libwhisper` / `libggml*` dylibs
- one selected canonical model
- the VAD model

They are copied into standard macOS bundle locations:

- helper CLI: `Steno.app/Contents/Helpers/whisper-cli`
- dylibs: `Steno.app/Contents/Frameworks/`
- model files: `Steno.app/Contents/Resources/WhisperModels/`

The app now prefers that bundled runtime automatically on first launch when it exists.

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
STENO_DIST_SIGN_IDENTITY="Apple Development: your@email.com (TEAMID)" \
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

After a real run:

- `codesign --verify --deep --strict --verbose=2 build/distribution/Steno.app`
- `xcrun stapler validate build/distribution/Steno-0.2.0.dmg`
- `spctl -a -vv -t open --context context:primary-signature build/distribution/Steno-0.2.0.dmg`

## Current blocker

As of the current repo state, the packaging mechanics are working, but a fully public notarized DMG is still blocked by local Apple-account setup:

- the machine currently only has an `Apple Development` signing identity installed
- a `Developer ID Application` certificate still needs to be installed
- a `notarytool` keychain profile still needs to be configured

Once those exist, `scripts/release-dmg.sh` is intended to be the end-to-end path.
