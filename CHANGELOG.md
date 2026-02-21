# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-02-21

### Added
- Security and OSS governance docs (`SECURITY.md`, `SUPPORT.md`)
- Security automation workflows (policy checks, secret scanning, dependency review on eligible public PRs, and Scorecard for public repos)
- Dependabot configuration for GitHub Actions and Swift dependencies

### Changed
- Contributor-first signing defaults in `project.yml`/generated project settings
- README/CONTRIBUTING/QUICKSTART for public open-source onboarding

### Security
- Enforced HTTPS-only remote cleanup endpoints
- Hardened keychain persistence attributes and migration path
