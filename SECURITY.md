# Security Policy

## Supported Versions

| Version | Supported |
| --- | --- |
| 1.1.x | Yes |
| 1.0.x and earlier | No |

Security fixes ship in the next 1.1.x release.

## Scope

This policy covers the Steno app, its release artifacts (the DMG, its build attestation, `SHA256SUMS` and `release-manifest.json`), and the build and release workflows in this repository. A vulnerability in the vendored `whisper.cpp` belongs upstream: report it to the [whisper.cpp project](https://github.com/ggml-org/whisper.cpp). If it affects Steno, also tell us here.

## Reporting a Vulnerability

Please do not disclose a vulnerability in a public issue or discussion.

Preferred reporting path:

1. Open a private vulnerability report at <https://github.com/Ankit-Cherian/steno/security/advisories/new> (`Security` › `Report a vulnerability`).
2. Include impact, reproduction steps, and any proof-of-concept details needed to validate the report.

If private reporting is unavailable:

1. Use the [Private Contact Request form](https://github.com/Ankit-Cherian/steno/issues/new?template=contact_request.yml) to ask for a private follow-up channel.
2. This request is public and identifies your GitHub account. Do not include exploit details, private data, or attachments. Wait for a maintainer to provide a private channel before sharing the report.

## Response Targets

- A report is acknowledged within 7 days.
- Fixes ship in the next 1.1.x release.

## Disclosure

Please keep the report private until a fix is available. After a fix ships, maintainers may publish a coordinated advisory that includes:

- Affected versions
- Impact summary
- Remediation steps

## Verify a Download

Steno is downloaded only from this repository's GitHub Releases page. To check that a DMG is the one the release published, follow [Verify the download](README.md#verify-the-download) in the README.
