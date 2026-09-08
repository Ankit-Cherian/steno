## Summary

<!-- Brief description of what this PR does -->

## Checklist

- [ ] Relevant validation is recorded below; substantial code changes pass `swift test --package-path StenoKit` and the normal macOS build
- [ ] App behavior changes include relevant hosted macOS checks; transcription/runtime or cleanup changes include the required benchmark gates
- [ ] Live acceptance and distribution checks are distinguished from automated tests and synthetic renders
- [ ] No force unwraps (`as!` or `try!`) in production code
- [ ] UI uses `StenoDesign` tokens (no hardcoded fonts, shadows, or spacing)
- [ ] Interactive elements have VoiceOver labels
- [ ] Animations check `accessibilityReduceMotion`
- [ ] No hardcoded credentials, keys, or private endpoints
- [ ] Security-sensitive behavior changes include tests and documentation updates

## Validation

<!-- Name the tested source, meaningful checks and results, and remaining manual gates. For documentation-only changes, list claim/link/diff checks. Keep private logs and local paths out of this description. -->
