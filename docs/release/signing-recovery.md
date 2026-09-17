# Steno 1.0 signing recovery

This workflow is limited to the existing `v1.0.0` tag at `d25fcdf9d625eea6ee31bd0b03c5994302e8065e`. It does not move the tag or change app source. The original [Release run](https://github.com/Ankit-Cherian/steno/actions/runs/35041760947) passed its package, hosted app, native runtime, distribution preview, and security checks. Its first signing attempt failed while importing the certificate. Its second attempt built the app, then failed at the first signing operation. Neither reached notarization.

The recovery runs from a separately reviewed commit on `main`. It checks out that workflow and the immutable app source in separate directories. It verifies the original successful job IDs and results, both reviewed signing-log hashes and failure stages, and the absence of a previous notarization receipt or release before signing. The signing fix adds the temporary keychain to the runner's search list, restores the prior list during cleanup, and probes the signing identity before building the installer.

The first recovery [preflight run](https://github.com/Ankit-Cherian/steno/actions/runs/35162713077) stopped before signing because the runner's GitHub CLI rejected formatting characters in the historical logs. The log reader now detects the CLI's raw-output option and uses it only when capturing those two logs for checksum verification. Log contents are never printed, and the expected hashes remain unchanged.

The original source tests are reused because the app source, runtime provisioning, and publication guards are unchanged. The new recovery controls have their own focused tests. The installer is rebuilt, signed, notarized, stapled, and verified through the existing packaging script. Signing, draft creation, and publication retain their separate protected environments and approval requirements. Apple credentials remain in the signing environment only.

The final DMG and its manifest are both attested by the recovery workflow. GitHub provenance identifies the workflow commit. The verified manifest separately identifies the app commit, tag, final DMG checksum, producing workflow, and reused validation jobs. Verify both identities; a workflow commit is not a replacement app-source claim.

Dispatch **Recover 1.0 release signing** on `main` only after reviewing this recovery and the release notes below. The authorization input acknowledges the documented manual-coverage limits. Request publication at dispatch if the same run should continue through the protected publication approval after creating its draft.

Review the actual draft, installer verification, and both attestations before approving publication. The workflow rechecks the exact draft ID, notes, source, and remote checksums, publishes once, and verifies that the latest release resolves to 1.0.0. An ambiguous result must be inspected before any further action.

Automatic recovery reruns are rejected. Any previous recovery run that reached signing also blocks a new dispatch until its outcome has been investigated and a separate recovery is reviewed. If Apple has received a submission, query that existing submission; do not upload another copy blindly. If a draft exists, preserve it and its identity. The original **Publish release** workflow does not understand the recovery's separate source and workflow identities and must not be used to promote this draft unchanged.

Live capture, transcription, and teardown were observed with the bundled helper. The full manual matrix, including live media interruption, independently verified insertion with that helper, VoiceOver, and macOS 13 installation, remains incomplete. The maintainer directed publication with those limits disclosed. This recovery does not mark those cases as passed; see the [acceptance checklist](1.0-checklist.md).

## Reviewed release notes

The text between these markers is the exact draft body. Publication stops if the draft body differs.

<!-- release-notes:start -->
Steno 1.0 is a free, open-source dictation app for Apple silicon Macs running macOS 13 or later. Hold Option, speak, and release to type. Speech recognition runs locally, with a model included in the installer and no account or API key required.

This release brings the Manuscript interface, a live transcript overlay, local usage insights, a speech engine that stays ready between recordings, and more reliable capture and cancellation. Playback resumes only when Steno verified that it paused it. It also includes native runtime security repairs and automated release signing and notarization.

Download `Steno-1.0.0.dmg`, open it, and drag Steno into Applications. The installer is Developer ID signed and notarized. `SHA256SUMS` and `release-manifest.json` identify the download and its source.

Known limitations: quiet speech after a long silent lead-in can lose words, and the speech model can substitute words. The CLI fallback does not include the retained helper's repetition correction. Review dictated text before using it. The complete manual acceptance matrix, including live media interruption and installation on macOS 13, has not been completed; the release checklist records the remaining coverage.

[Changelog](https://github.com/Ankit-Cherian/steno/blob/main/CHANGELOG.md) · [Release verification](https://github.com/Ankit-Cherian/steno/blob/main/docs/release/1.0-checklist.md) · [Support](https://github.com/Ankit-Cherian/steno/blob/main/SUPPORT.md)
<!-- release-notes:end -->
