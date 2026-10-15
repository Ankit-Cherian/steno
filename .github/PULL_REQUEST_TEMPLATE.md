## Summary

<!-- Brief description of what this PR does -->

## Checklist

<!-- Check applicable items and explain any that do not apply. See CONTRIBUTING.md for commands and validation gates. -->

- [ ] Relevant validation is recorded below; code changes pass `scripts/check.sh` as described in `CONTRIBUTING.md`
- [ ] App behavior changes include relevant hosted macOS checks; transcription/runtime or cleanup changes include the required benchmark gates
- [ ] Live acceptance and distribution checks are distinguished from automated tests and synthetic renders
- [ ] Any forced unwrap, forced cast, or `try!` has a narrow, documented justification
- [ ] UI uses the 1.1 design's theme tokens and follows the 1.1 design record (`docs/design/1.1-design-record.md`)
- [ ] Interactive elements have VoiceOver labels
- [ ] Animations check `accessibilityReduceMotion`
- [ ] No hardcoded credentials, keys, or private endpoints
- [ ] Code, documentation, images, and attached logs contain no private user data or personal file paths
- [ ] Security-sensitive behavior changes include tests and documentation updates

## Validation

<!-- Name the tested source, meaningful checks and results, and remaining manual gates. For documentation-only changes, list claim/link/diff checks. Keep private logs and local paths out of this description. -->
