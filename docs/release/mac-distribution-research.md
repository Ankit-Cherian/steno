# Steno Mac Distribution Research

Date: 2026-04-21

## Recommendation

For Steno, the best next shipping path is:

1. **Direct distribution outside the Mac App Store**
2. **Signed with a `Developer ID Application` certificate**
3. **Notarized with Apple using `notarytool`**
4. **Delivered as a drag-to-Applications `.dmg`**
5. **Hosted on GitHub Releases and/or the project website**

That is the cleanest path to a real downloadable Mac app without requiring users to install Xcode, clone the repo, or run setup commands locally.

## Why this is the right path

### 1. Mac App Store is a poor fit for Steno

Apple’s App Sandbox guidance says sandboxing is required for App Store distribution, and it explicitly calls out **use of accessibility APIs in assistive apps** as incompatible with App Sandbox.

Steno depends on:

- Accessibility-style insertion
- Input monitoring/global hotkey behavior
- low-level dictation/insertion workflows that act on other apps

That makes **direct distribution** the right default route. It aligns with how other Mac power tools ship and avoids forcing the app into a sandbox model that fights its core behavior.

### 2. DMG is the best first-install artifact

For the first public downloadable release:

- **DMG** gives the most normal Mac installation UX
- users download one file, open it, and drag `Steno.app` into `Applications`
- it feels like a real native Mac app

Compared to alternatives:

- **ZIP** is simpler to produce, but the UX is less polished for first install
- **PKG** is overkill unless Steno starts installing privileged helpers, background services, or system-wide components

## Best practical release architecture

### Phase 1: First public downloadable release

Ship:

- `Steno.app`
- inside a notarized `.dmg`
- attached to a GitHub Release

Required ingredients:

- Developer ID Application certificate
- Hardened Runtime enabled
- notarization via `xcrun notarytool`
- stapled ticket on the final distribution artifact

### Phase 2: Auto-updates later

After the first downloadable build is working, the best upgrade path is likely:

- keep shipping the public installer as a DMG
- add **Sparkle 2** later for in-app updates
- publish Sparkle archives and appcast metadata from GitHub Releases or a small static site

This is a better sequence than trying to do “downloadable app + auto-update framework + notarization + release hosting” all at once.

## Apple-account implications

Your Apple Developer account is exactly what unlocks the right path here.

What you need from it:

### Required

- `Developer ID Application` certificate

### Optional / later

- `Developer ID Installer` certificate only if you later decide to ship a `.pkg`

### Notarization setup

- save credentials with `xcrun notarytool store-credentials ...`
- use those credentials for scripted notarization

## Current repo-specific blockers

Steno is not distribution-ready yet in a few important ways:

### 1. Current signing is still development-only

`project.yml` currently uses:

- `CODE_SIGN_STYLE: Automatic`
- `CODE_SIGN_IDENTITY: Apple Development`

That is correct for local dev, but not for a public downloadable app.

### 2. Current machine only has an Apple Development identity installed

Local signing identity check currently shows only:

- `Apple Development: ankitcherian@outlook.com (72FXF6VDRC)`

So before building a public DMG, you need to create/install a **Developer ID Application** certificate in Keychain.

### 3. Entitlements need a distribution-safe path

Current entitlements include:

- `com.apple.security.cs.allow-dyld-environment-variables`
- `com.apple.security.device.audio-input`

The microphone entitlement is expected.

The DYLD entitlement is a strong sign that the current entitlements file is still tuned for local runtime/development convenience. The release build should use a **separate distribution entitlements path** instead of blindly reusing the dev entitlements file.

## Recommended implementation shape

### Build outputs

Add a distribution workflow that produces:

1. archived app
2. exported signed `.app`
3. signed `.dmg`
4. notarized `.dmg`
5. stapled `.dmg`

### Repo changes I would recommend

1. Add a dedicated distribution entitlements file
2. Add a release/distribution build path in `project.yml` or a distribution script that overrides the dev identity/settings
3. Add a `scripts/build-dmg.sh` or `scripts/release-dmg.sh`
4. Add notarization and stapling steps
5. Add validation commands:
   - `codesign -dvvv --entitlements :-`
   - `spctl -a -vv`
   - `xcrun stapler validate`
6. Document a local “cut a DMG” release flow in `docs/release/`

## DMG vs ZIP vs PKG

### DMG

Best choice for Steno now.

Pros:

- native Mac feel
- drag-to-Applications install flow
- works well with GitHub Releases
- matches user expectation for a standalone Mac utility

Cons:

- slightly more packaging work than ZIP

### ZIP

Good fallback or Sparkle archive format later.

Pros:

- simplest packaging path
- easy to notarize
- good for updater feeds

Cons:

- weaker first-install UX
- less “real Mac app” feeling than a DMG

### PKG

Not recommended for the first Steno release.

Use only if you later need:

- privileged helpers
- launch daemons
- system-wide installation steps

## Sparkle recommendation

Sparkle is the right likely future update framework, but **not the first thing to do**.

Why it still matters:

- it is the de-facto standard for direct-distributed macOS app updates
- it supports ZIP/DMG/TAR-style update archives
- it gives Steno a good long-term update story once direct distribution is live

Why it should wait:

- first you need one good signed, notarized, manually downloadable artifact
- then you can layer in Sparkle cleanly

## Recommended decision

If the goal is “make Steno feel like a real native Mac app people can just download,” the best answer is:

**Ship a notarized Developer-ID-signed DMG outside the Mac App Store.**

Then:

- use GitHub Releases for hosting first
- add Sparkle later for updates

## Suggested next implementation order

1. Create/install `Developer ID Application` certificate
2. Add distribution-specific entitlements/signing path
3. Archive/export a release-signed `.app`
4. Package it into a `.dmg`
5. Notarize + staple the DMG
6. Validate with Gatekeeper locally
7. Publish through GitHub Releases
8. Consider Sparkle after the first downloadable release is working

## Sources

- Apple: Developer ID certificates  
  https://developer.apple.com/help/account/certificates/create-developer-id-certificates

- Apple: Signing your apps for Gatekeeper  
  https://developer.apple.com/developer-id/

- Apple: Notarizing macOS software before distribution  
  https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

- Apple: Preparing your app for distribution  
  https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution

- Apple: Protecting user data with App Sandbox  
  https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox

- Sparkle: About  
  https://sparkle-project.org/about/

- Sparkle: Publishing an update  
  https://sparkle-project.org/documentation/publishing/

- Sparkle: Security and reliability  
  https://sparkle-project.org/documentation/security-and-reliability/
