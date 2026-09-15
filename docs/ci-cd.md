# Continuous integration and delivery

Steno uses GitHub Actions to check contributions and prepare releases. **CI** runs build and test checks for branch pushes and pull requests. **CD** means an approved version follows a repeatable path from tested source to a signed, notarized download. A passing pull request does not publish a release.

The workflow files define triggers after they are pushed to GitHub; execution also depends on Actions settings and any required fork-run approval. Required merge checks and protected release environments are separate repository settings; follow [GitHub activation](maintainers/github-setup.md) before treating the pipeline as enforced.

## What runs

| Stage | When | What it proves |
| --- | --- | --- |
| Workflow and release contracts | Branch pushes, PRs, merge queue, release | Workflow syntax/security policy; automation regression tests; generated-project hygiene |
| Package and hosted tests | Same events, macOS 15 and 26 | Swift package assertions, app compilation, hosted controller/state tests, production-view render assertions and coverage artifacts |
| Native runtime | Same events, Apple silicon | Clean pinned native build, prompt verification, VAD integrity, 26-case adversarial protocol matrix, scorer controls, retained-process silence contract |
| Public audio benchmark | Same native lane | Actual inference on the pinned public JFK sample and zero WER/CER regression introduced by the cleanup pipeline |
| Distribution preview | Same native lane | Self-contained ad-hoc app/DMG, bundled libraries and models, architecture, deployment target, code signature structure, relocatable dependencies, bundled inference |
| Security | PRs, main, merge queue, weekly, release | CodeQL Actions/Swift/C++ analysis; high/critical SARIF gate; high/critical dependency review on PRs |
| Release | Maintainer dispatch from main | Exact-source validation, protected signing/notarization, final-DMG provenance, verified draft, optional separately approved publication |

`CI Gate` requires every validation job to succeed. `Security Gate` requires every applicable scan and its severity gate to succeed. Failed, cancelled or unexpectedly skipped jobs cannot satisfy those aggregate checks. There are no path filters that can leave required checks permanently pending on a documentation PR. A local commit runs no remote checks until it is pushed.

### Runtime and accuracy boundaries

Hosted runtime checks explicitly use CPU inference through the upstream `GGML_METAL_DEVICES=0` test setting. The shipped helper is still compiled with Metal support. The protocol receipt verifies which backend actually ran; CPU results cannot qualify as production Metal evidence. Standard hosted Apple silicon architecture alone is not proof of GPU availability.

CPU protocol tests allow up to 180 seconds for each inference response; the default and Metal limit remains 30 seconds. Model loading, protocol acknowledgements, cancellation and shutdown retain their separate shorter deadlines. The receipt records the limits used. These are test completion limits, not advertised dictation latency.

If the protocol suite fails, the runtime lane keeps the failure and runs a bounded diagnostic using the same public sample. Its log records CPU progress, response timing, backend identity and network observations. A successful diagnostic cannot turn the failed suite into a pass. Cleanup stops the network observer before terminating and reaping the owned helper, so teardown does not replace the original failure.

The public benchmark is a **single-fixture smoke regression**, not a general recognition-accuracy score or a comparison against the previous release. It compares raw recognition against Steno's cleanup pipeline on that fixture. The existing broader benchmark manifest and release evaluation remain separate requirements for relevant changes. Some historical fixtures are local-only and are deliberately not uploaded by CI.

The normal package suite includes opt-in runtime integration tests. CI activates the retained-helper contract explicitly in the native lane. Ordinary package-test success alone is not proof that a real model or helper executed. Real microphone behavior, actual editor insertion, permissions, supported media applications, native Metal inference, and macOS 13 acceptance remain in the [release checklist](release/1.0-checklist.md).

## Contributor experience

1. Fork the repository, create a branch, and open a pull request.
2. GitHub may ask a maintainer to approve running workflows from an external contributor. This grants permission for that run, not permission to merge or publish.
3. Open the PR's **Checks** tab. Start with the first failing job and its failing step. Independent jobs continue so one run can show multiple failures.
4. Test logs, `.xcresult` bundles, coverage JSON and synthetic renders are available as artifacts. Preview artifacts are named `unsigned-preview-arm64-<SHA>` and retained for seven days; they contain a DMG named `Steno-<version>-<short-SHA>-preview.dmg`. Other test evidence is retained for fourteen days.
5. Fix the issue and push again. A newer CI run cancels obsolete validation for the same branch or PR. The Release and Publish release workflows share a non-cancelling release lock; their reusable security checks have a separate cancellation policy.

Preview DMGs use ad-hoc signatures. They have no Developer ID identity or notarization, may be blocked by Gatekeeper, and are not official releases. An artifact from a fork or pull request is untrusted contributor code; only test contributions you have reviewed. Do not treat download availability as release approval.

The project already has extensive tests around capture integrity, no-speech gating, cleanup, insertion target safety, media ownership, runtime lifecycle, settings drafts and synthetic rendering. Add tests that expose a changed behavior or a new failure case. Do not duplicate those assertions solely to raise test counts. Coverage is published for inspection without an arbitrary percentage gate.

## Local reproduction

The same scripts can run on an Apple silicon Mac with Xcode 26.3, Python 3.11 or later, CMake, Git and standard macOS tools. The CI image uses `DEVELOPER_DIR` to select Xcode without changing the machine's global developer directory.

```bash
# Tool archives are versioned and SHA-256 checked before extraction.
bash scripts/ci/tools.sh xcodegen
build/ci-tools/xcodegen/xcodegen/bin/xcodegen generate

python3 scripts/ci/check-policy.py
python3 -m unittest discover -s scripts/ci/tests -p 'test_*.py' -v
bash scripts/ci/tools.sh actionlint
build/ci-tools/actionlint/actionlint -shellcheck= -pyflakes=

swift test --package-path StenoKit
xcodebuild build -project Steno.xcodeproj -scheme Steno \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Steno.xcodeproj -scheme Steno \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$(mktemp -d /private/tmp/steno-hosted-tests.XXXXXX)" \
  CODE_SIGNING_ALLOWED=NO
```

The temporary test build also avoids launch-time access problems that can occur when a test host loads its libraries from a protected Desktop folder. It does not alter macOS permissions. To retain render files at a chosen path, export `TEST_RUNNER_STENO_UI_RENDER_OUTPUT` and `TEST_RUNNER_STENO_OVERLAY_ACCENT_RENDER_OUTPUT` before `xcodebuild test`; Xcode forwards these variables after stripping `TEST_RUNNER_`.

Native checks download about 489 MB of pinned model assets, plus upstream sources. Use new output paths; the scripts refuse to overwrite existing evidence or repair a mismatched runtime checkout:

```bash
bash scripts/ci/prepare-runtime.sh --root "$PWD/build/runtime-sources"
bash scripts/ci/runtime-checks.sh --backend cpu \
  --root "$PWD/build/runtime-sources" --output "$PWD/build/runtime-checks-cpu"

GGML_METAL_DEVICES=0 \
STENO_WHISPER_ROOT="$PWD/build/runtime-sources" \
STENO_WHISPER_BUILD_DIR="$PWD/build/runtime-checks-cpu/build-steno" \
STENO_CI_BENCHMARK_OUTPUT="$PWD/build/benchmark-cpu" \
  bash scripts/ci/benchmark.sh
```

For the production GPU path, use a new output directory and `--backend metal`. That mode explicitly removes inherited GPU suppression and requires observed Metal evidence. `prepare-runtime.sh --verify-only --root <path>` validates existing dependencies without downloading or modifying them.

## Security design

- PR code runs on disposable GitHub-hosted machines with `contents: read` token permission and no Apple credentials. CodeQL jobs separately request `security-events: write` for scan uploads; this does not grant repository-content write access. There are no self-hosted PR runners, `pull_request_target`, privileged `workflow_run` handoffs, or automatic PR approval.
- Every remote Action is pinned to a full commit SHA. Checkout removes persisted Git credentials. Release elevation is limited to the jobs and steps that need it.
- Xcode is selected explicitly. XcodeGen and actionlint archives, Whisper source, speech model and VAD model are pinned. Downloads are checksum verified before use; native compiled artifacts are rebuilt rather than restored from a shared executable cache.
- CodeQL scans the workflow language, Swift app and package, and native C++ compilation. The local SARIF gate blocks security severity 7.0 and above and non-security error-level findings, including existing and suppressed findings. Missing or invalid scan evidence also fails. Lower-severity results remain visible in GitHub's Security tab.
- Native security builds target ARM explicitly. The Swift scan uses a generic macOS destination with `ARCHS=arm64`; the C++ helper compiler receives its architecture explicitly. This keeps the output architecture correct when CodeQL traces the build through a translated process.
- Blocking SARIF findings include their source location and scanner message in the job log. Check that output even when GitHub's PR summary says there are no new alerts: the local gate also examines results outside the changed lines, including compiled vendor code. An empty uploaded alert list does not override a failing local severity gate.
- Dependency review blocks newly introduced high/critical vulnerable dependencies. Dependabot proposes updates; it never approves or merges them. Model files and the manually pinned native runtime are outside ordinary Swift dependency advisory coverage and need deliberate review.
- `CODEOWNERS` identifies sensitive paths. Review enforcement, secret scanning and push protection require the repository settings described in the activation guide. A CODEOWNERS file by itself cannot prevent a merge.
- No system can prove the absence of vulnerabilities. Static checks, behavioral tests, contributor review, secret protection and distribution provenance address different risks.

## Release operation

Complete the source checks, measured evaluation, and native-app acceptance in the [1.0 checklist](release/1.0-checklist.md), integrate the intended source into main, and create the approved version tag before dispatching a release. Distribution and publication receipts are completed later against the resulting signed artifact. Before approving the release tag, finalize the README candidate status and move the approved changelog entries from `[Unreleased]` to the selected version with its actual release date in that source. Keeping candidate wording and `[Unreleased]` during PR preparation is intentional; the tagged release must describe the released version. The `/releases/latest` download link needs no version-specific edit. Tag creation is deliberately not automatic. The selected source must be the dispatch's main commit, with matching `project.yml` version and existing `vX.Y.Z` tag. No metadata is bumped automatically.

From **Actions → Release → Run workflow**, select main, enter the stable version and full 40-character commit SHA, and confirm manual acceptance only after completing the source and native-app checks for that exact source. Leave `publish_release` false to stop at a draft. Enable it only when public publication is intended.

The workflow then:

1. Checks source, tag, metadata and remote main ancestry. Runs the same complete CI and security workflows against that source.
2. Waits at the protected **release** environment. Approval unlocks the Apple credentials for the signing step only.
3. Builds a fresh self-contained distribution, imports the Developer ID certificate into a temporary keychain, signs, submits once to Apple, records the submission ID, waits for `Accepted`, staples the ticket and verifies Gatekeeper. The temporary signing material is cleaned up.
4. Generates SHA-256 checksums and a manifest after stapling, then attests the final DMG. Only allowlisted public artifacts leave the signing job. Notary diagnostic logs and credentials are excluded.
5. Waits at **release-draft**, verifies provenance and remote tag/source again, and creates one draft containing the verified assets. Existing releases/drafts are never overwritten.
6. If publication was requested, waits at **release-publish**. Before approving, inspect the draft, replace its placeholder notes with approved final release notes, and complete installation/distribution acceptance on its verified DMG. The workflow does not check note completeness or perform those manual tests. After approval, it verifies the exact draft ID from this run, remote asset digests and source, rejects prerelease drafts and versions that do not advance beyond every published stable version, then publishes that ID once as the latest full release. It verifies both the published release and GitHub's latest-release pointer against the same ID, tag, source and assets.

The workflow refuses missing setup variables or credentials. GitHub environment names alone do not create approval protection; configure their reviewers and branch restrictions before enabling them. For a sole maintainer, permit the maintainer to approve their own deployment request, otherwise the workflow is impossible to finish. A second reviewer is preferable when available.

The [default download link](https://github.com/Ankit-Cherian/steno/releases/latest) follows each verified latest release without a README edit. Versioned DMG filenames remain unchanged within each release. Drafts, prereleases and older versions cannot take over this workflow's default download. An unrecognized published stable tag requires reconciliation before promotion. Historical tags and assets remain intact; this does not update already installed apps. GitHub documents the [stable latest-release URL](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases) and [latest/full-release API settings](https://docs.github.com/en/rest/releases/releases#update-a-release).

For a completed draft-only run, inspect its verified assets and finish the release notes in GitHub's trusted UI. Then use **Actions → Publish release → Run workflow** with the same version, source SHA, exact numeric draft ID, and explicit publication acceptance. This workflow reruns validation/security, waits for `release-publish`, downloads only the three expected assets by numeric ID, and verifies their digests and original Release workflow attestation before publishing that exact draft once. It neither rebuilds nor resubmits to Apple. The requested source must equal main at the new dispatch. If main has advanced since the draft was built, reconcile the release before dispatching; the workflow will reject a different requested SHA. During a running workflow, remote rechecks verify tag identity and main ancestry, not that main has stayed at the same tip. Rerunning Release intentionally refuses an existing draft.

### Failure recovery

- **Test/build/security failure:** fix the cause and rerun normal validation. Do not bypass the aggregate checks or convert missing evidence to a pass.
- **Dependency download mismatch:** inspect the upstream release and lock. Do not replace the expected hash with whatever the network returned.
- **Notarization timeout or interruption:** inspect `notary-recovery-<run-id>-<attempt>` for the submission ID and status. Query that existing submission with `notarytool info`/`log` before considering another upload. The recovery record contains only allowlisted source/digest/submission fields. Absence of an ID after a network failure means the outcome is unknown; do not assume Apple received nothing.
- **Draft creation/publication timeout:** read the release by its exact ID and compare tag, target and asset digests. Do not blindly rerun a publishing step; the first operation may already have succeeded.
- **Bad public release:** do not rewrite the tag or replace its bytes. Prepare a new patch version through the pipeline and communicate the affected version through the normal maintainer process.

Users can verify provenance with:

```bash
gh attestation verify Steno-X.Y.Z.dmg --repo Ankit-Cherian/steno \
  --signer-workflow Ankit-Cherian/steno/.github/workflows/release.yml
```

## Maintenance and design references

The workflow favors ordinary GitHub Actions over a second external CI service: contributors can see checks beside their PRs, and release permissions stay in the repository. It uses a shared validation workflow to avoid separate, drifting PR and release test definitions. Fast assertions and security analysis run in parallel; releases retain explicit human approval because automated tests cannot exercise the maintainer's complete native acceptance checklist.

The [CI change record](maintainers/ci-changes.md) records corrections made during hosted activation and the checks used to verify them. Update this guide when a correction changes contributor commands, limits, artifacts or merge requirements.

Review Dependabot's weekly Action/Swift updates. Tool archive pins in `tools.sh`, Xcode image availability, and runtime/model pins in `runtime-lock.json` require manual maintenance and the same checks as other changes. A pinned Xcode removed from the hosted image should fail clearly; do not silently select a different toolchain. Tune timeouts and runner usage from actual workflow timings rather than estimated speedups.

The design follows [GitHub's secure workflow guidance](https://docs.github.com/en/actions/reference/security/secure-use), [compiled-language CodeQL guidance](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/codeql-for-compiled-languages), [artifact attestation documentation](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations), and [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). [Rectangle's build workflow](https://github.com/rxhanson/Rectangle/blob/main/.github/workflows/build.yml) and [IINA's CI workflow](https://github.com/iina/iina/blob/develop/.github/workflows/ci.yml) provide useful examples of contributor build artifacts and macOS dependency provisioning. Their implementation details are not copied wholesale.
