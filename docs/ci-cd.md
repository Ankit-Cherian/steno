# Continuous integration and delivery

Steno uses GitHub Actions to check contributions and prepare releases. **CI** runs build and test checks for pull requests and changes merged into main. **CD** means an approved version follows a repeatable path from tested source to a signed, notarized download. A passing pull request does not publish a release.

The workflow files define triggers after they are pushed to GitHub; execution also depends on Actions settings and any required fork-run approval. Required merge checks and protected release environments are separate repository settings; follow [GitHub activation](maintainers/github-setup.md) before treating the pipeline as enforced.

The runtime and distribution job has a 75-minute overall limit. It includes native tests, the public benchmark, app packaging and DMG verification. Individual inference and diagnostic deadlines remain separate.

Within that job, the native build, the short native contract checks, the retained-engine checks, the benchmark and the preview DMG run first. The preview is uploaded before the 26-case protocol matrix and prompt-scoring suites start, so it is available for manual testing sooner. It can therefore appear before those suites have passed. The preview is ad-hoc signed and is not the shipped configuration; `CI Gate` still fails unless every step of the job succeeds.

## What runs

| Stage | When | What it proves |
| --- | --- | --- |
| Workflow and release contracts | PRs, main, merge queue, manual dispatch, release | Workflow syntax/security policy; automation regression tests; generated-project hygiene |
| Package and hosted tests | Every main push, merge group, schedule, release or manual validation, and PRs that change more than documentation; macOS 15 and 26 | Swift package assertions, app compilation, hosted controller/state tests, production-view render assertions and coverage artifacts |
| Native runtime | Full-validation events, and PRs that change code the job executes (see below); Apple silicon | Pinned native build with reviewed source corrections, allocation-failure regressions, prompt verification, VAD integrity, 26-case adversarial protocol matrix, scorer controls, retained-engine one-shot and streaming requests through the real helper |
| Public audio benchmark | Same native lane | Actual inference on the pinned public JFK sample and zero WER/CER regression introduced by the cleanup pipeline |
| Distribution preview | Same native lane | Self-contained ad-hoc app/DMG, bundled libraries and models, architecture, deployment target, code signature structure, relocatable dependencies, bundled inference, Release-configuration app build |
| Security | PRs, main, merge queue, weekly, release | Actions analysis, the reviewed-findings source check and PR dependency review always run. Swift and C/C++ analysis run on PRs only for the changes listed below. Main pushes, weekly scans and releases analyze all languages. |
| Release | Maintainer dispatch from main | Exact-source validation, protected signing/notarization, final-DMG provenance, verified draft, optional separately approved publication |

`CI Gate` requires the policy job to succeed and checks the remaining jobs against the selected scope. `Security Gate` requires every applicable scan and its severity gate to succeed. Failed, cancelled or unexpectedly skipped jobs cannot satisfy those aggregate checks, and a job that ran when the classification said it should be skipped fails them too. Both workflows start for every PR, so required checks are still reported. A feature-branch push updates its PR checks without launching a duplicate branch run. Before opening a PR, use the manual CI dispatch if a hosted preview is needed. Main retains its post-merge checks. A local commit runs no remote checks until it is pushed.

### What a pull request runs

Only a pull request whose base is `main` can skip a job. Pushes to main, merge groups, release calls, manual dispatches and the weekly CI and Security schedules always run everything, including both compiled scans, and both gates fail if any of those events reports a narrower selection. A documentation-only commit on main, such as a release's changelog commit, therefore still gets the complete tests, a preview and full analysis. No release reuses results from another run or another commit.

For a pull request, `scripts/ci/select-checks.py` reads the complete Git diff from the merge base to the head, with both sides of renames, and gives each changed path the most specific matching rule. The rules and their reasons are in that script. The PR then runs the union of what its paths need:

| Change | Runs on the PR | Skipped on the PR |
| --- | --- | --- |
| Documentation only: recognized root documents, Markdown and images under `docs/` | Policy job, CodeQL Actions, reviewed-findings source check, dependency review | Package and hosted tests, runtime job, Swift and C/C++ scans |
| App and test code: `Steno/` Swift files, `StenoTests/`, package files the runtime job does not execute (for example `SessionCoordinator.swift`, history, insertion, overlay and analytics), package tests, design and image assets, `scripts/ci/reviewed-findings.json` | The above plus package and hosted tests on macOS 15 and 26 | Runtime job, Swift and C/C++ scans |
| Code the runtime job executes: the engines and runtime session, process launching, the transcript decoder and frame streamer, the cleanup and ranking pipeline, the benchmark targets and inputs, scripts outside `scripts/ci/`, the retained-engine integration test, entitlements, bundled resources | The above plus the runtime and distribution job | Swift and C/C++ scans |
| C/C++ helper sources: `runtime-helper/` and `scripts/build-whisper-runtime-helper.sh` | The above plus the C/C++ scan | Swift scan |
| CI definitions: `.github/workflows/`, `scripts/ci/` (except the reviewed-findings record), `project.yml`, Dependabot and release-note configuration | Everything | Nothing |
| Any path no rule covers, a symbolic link or submodule anywhere in the diff, two files whose names differ only by case or Unicode normalization, a base other than `main`, or a classification failure | Everything | Nothing |

The step summary of each classification job lists every changed path with its rule. Path names are escaped there and never written to the job log or step outputs. Case and Unicode variants of a costlier path keep that path's cost. The policy job fails when a tracked file has no rule, when a rule names a missing file, and when an unlisted package file declares an extension of a type defined in a listed one, because StenoKit is one Swift module and such an extension can change what the runtime job's code calls. It does not prove that the list contains every file the runtime job depends on; main's full runs catch a wrong entry after merge.

**Reviewed findings on pull requests.** Several files are bound by the [reviewed C/C++ findings](maintainers/reviewed-codeql-findings.md), including `Steno/DictationController.swift`, `Steno/AppPreferences.swift` and `SessionCoordinator.swift`. A pull request that changes one of them does not run the compiled scans because of that binding. It runs the reviewed-findings source check, which fails `Security Gate` within a few minutes unless `scripts/ci/reviewed-findings.json` records exactly the new content. The compiled C/C++ scan then confirms the updated record on main after merge, and again in the release before signing. A mistaken re-review is therefore found on main, not on the pull request.

**What skipped PR jobs cost.** Problems that only the skipped jobs detect are first seen on main after merge: a Swift or C/C++ finding, a compile failure that only the Release configuration shows, and an absolute build path embedded in the app, which only the preview's distribution hygiene scan checks. To prove a branch before merging, dispatch **Actions → CI** or **Actions → Security → Run workflow** on it; a dispatch is not a pull request, so it runs everything.

Documentation-only PRs run local Markdown link-target checks, workflow policy and automation tests, artifact upload/download compatibility, CodeQL Actions, the reviewed-findings source check and dependency review. The local link check covers inline Markdown file targets, not remote URLs, anchors, or the correctness of prose and command examples; reviewers still verify those. Use GitHub check notifications instead of continuously polling a running job. Diagnose a failure before deciding whether a rerun is appropriate.

### Runtime and accuracy boundaries

The runtime builder retains a clean upstream checkout and applies the [reviewed native corrections](../scripts/ci/patches/README.md) to isolated source beneath the selected build directory. A manifest records the upstream revision, patch hash and staged file hashes. Every reuse verifies that content; mismatches fail without repairing or deleting existing state. CMake generates its files outside the staged source. Existing CMake caches tied to different source content require a fresh build directory.

The native lane also runs four deterministic allocation-failure regressions and three successful controls against the actual patched vendor implementations. These verify error returns, owned-memory cleanup and synthetic VAD boundaries. Fault injection exists only in separate test executables.

Hosted runtime checks explicitly use CPU inference through the upstream `GGML_METAL_DEVICES=0` test setting. The shipped helper is still compiled with Metal support. The protocol receipt verifies which backend actually ran; CPU results cannot qualify as production Metal evidence. Standard hosted Apple silicon architecture alone is not proof of GPU availability.

CPU protocol tests allow up to 180 seconds for each inference response; the default and Metal limit remains 30 seconds. Model loading, protocol acknowledgements, cancellation and shutdown retain their separate shorter deadlines. The receipt records the limits used. These are test completion limits, not advertised dictation latency.

The network observer still requires two complete launch scans, each checking all open files and network descriptors. Each process-inspection query is bounded to five seconds; startup allows 25 seconds for the four queries and scheduling, and observer shutdown allows six seconds. Inspection errors, timeouts or observed network descriptors fail the gate. These separate observer budgets are recorded in the protocol receipt.

Tests that interrupt decoding request observer shutdown without waiting, kill and reap the helper, then join the observer and check for unexpected output; slow inspection must not delay the intended crash. If an in-flight inspection returns only an empty exit-one result across that explicitly marked termination boundary, the harness discards the incomplete scan and requires confirmation that the same owned helper was reaped with `SIGKILL`. Earlier failures, timeouts, diagnostic output, unexpected exit codes and network descriptors still fail.

The completed-final test first accepts the final response and checks for extra frames, then stops and joins the observer while the helper is idle, before killing it and checking EOF. This avoids making an inspection fail by destroying the process it is inspecting.

Orderly shutdown follows the same boundary: after the final operational response, the harness stops and joins observation before sending a valid shutdown request. Invalid shutdown requests remain observed. The receipt's continuous-observation field covers the operational interval, not processing of the valid shutdown request, its acknowledgement or native teardown. Shutdown acknowledgements, correlation checks and exit-status checks still run with their existing deadlines.

The helper caps VAD workers at the reported hardware concurrency, up to the library default of four, and uses one worker if that count is unavailable. This avoids the severe slowdown measured with four VAD workers on a three-CPU runner. ASR thread requests and VAD thresholds retain their existing behavior. The VAD integrity test covers the worker-count boundaries and unchanged backend selection. The staged native patch also passes request cancellation into encoder and decoder graph computation and synchronizes backend work and clears each callback when computation ends, including on exceptions. CPU checks cancellation between compute nodes; Metal retains its existing command-buffer boundaries. Protocol acknowledgement and shutdown deadlines are unchanged.

If the protocol suite fails, the runtime lane keeps that failure and checks the same public sample through three diagnostic paths: ASR alone, VAD alone, and a complete v2 stream with VAD. The ASR and stream work budgets are 180 seconds each. The VAD comparison builds the upstream example with a 120-second limit, verifies its flags within ten seconds, then compares four threads with the available-CPU count capped at four; each trial has 60 seconds. Bounded cleanup may follow. Logs record timings, CPU use and backend/network evidence where applicable, without transcripts. None of these diagnostics can turn a failed protocol gate into a pass. Cleanup stops the network observer before terminating and reaping the owned helper, so teardown does not replace the original failure.

The public benchmark is a **single-fixture smoke regression**, not a general recognition-accuracy score or a comparison against the previous release. It compares raw recognition against Steno's cleanup pipeline on that fixture. The existing broader benchmark manifest and release evaluation remain separate requirements for relevant changes. Some historical fixtures are local-only and are deliberately not uploaded by CI.

The normal package suite includes opt-in runtime integration tests. CI activates the retained-helper contract explicitly in the native lane, on generated silence and on the public speech sample, and also streams that sample through the Swift live-transcription client to one final transcript. There it sets `STENO_TEST_REQUIRE_RETAINED_HELPER=1`, so a request answered by the command-line fallback instead of the real helper fails the check. Ordinary package-test success alone is not proof that a real model or helper executed. Real microphone behavior, actual editor insertion, permissions, supported media applications, native Metal inference, and macOS 13 acceptance remain in the [release checklist](release/1.0-checklist.md).

## Contributor experience

1. Fork the repository, create a branch, and open a pull request.
2. GitHub may ask a maintainer to approve running workflows from an external contributor. This grants permission for that run, not permission to merge or publish.
3. Open the PR's **Checks** tab. Start with the first failing job and its failing step. Independent jobs continue so one run can show multiple failures.
4. Test logs, `.xcresult` bundles, coverage JSON and synthetic renders are available as artifacts. Preview artifacts are named `unsigned-preview-arm64-<SHA>` and retained for seven days; they contain a DMG named `Steno-<version>-<short-SHA>-preview.dmg`. Other test evidence is retained for fourteen days.
5. Fix the issue and push again. A newer push to the same PR cancels its obsolete CI and Security runs. Runs on main, scheduled scans, manual dispatches and release calls are never cancelled by a newer run; each completes and reports for its own commit. The Release and Publish release workflows share a non-cancelling release lock; their reusable security checks have a separate cancellation policy.

Preview DMGs use ad-hoc signatures. They have no Developer ID identity or notarization, may be blocked by Gatekeeper, and are not official releases. An artifact from a fork or pull request is untrusted contributor code; only test contributions you have reviewed. Do not treat download availability as release approval.

The project already has extensive tests around capture integrity, no-speech gating, cleanup, insertion target safety, media ownership, runtime lifecycle, settings drafts and synthetic rendering. Add tests that expose a changed behavior or a new failure case. Do not duplicate those assertions solely to raise test counts. Coverage is published for inspection without an arbitrary percentage gate.

## Local reproduction

Before pushing app or package changes, run the local check:

```bash
scripts/check.sh
```

It regenerates `Steno.xcodeproj` with the pinned XcodeGen and confirms every hosted test file is in it, so newly added tests cannot be skipped by a stale project. It then runs the package tests, builds the app and runs the hosted tests, with derived data under `/private/tmp`. Finally it fails if a test helper process started during the run is still running, such as the runtime helper, the command-line engine or a fake helper from a temporary `steno-*` directory; it reports those processes but does not stop them. Use `scripts/check.sh --clean` after a shared struct or enum changes shape, because an incremental build can then compile but crash when the tests run. The check does not run the native runtime suites, the benchmark or packaging; CI runs those.

The individual commands are:

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

`runtime-checks.sh` runs every check by default. `--stage fast` builds the runtime and runs the short checks into a new output directory; `--stage slow` then runs the protocol matrix and prompt scoring against that same directory, and refuses an output without a completed fast stage.

For the production GPU path, use a new output directory and `--backend metal`. That mode explicitly removes inherited GPU suppression and requires observed Metal evidence. `prepare-runtime.sh --verify-only --root <path>` validates existing dependencies without downloading or modifying them.

## Security design

- PR code runs on disposable GitHub-hosted machines with `contents: read` token permission and no Apple credentials. CodeQL jobs separately request `security-events: write` for scan uploads; this does not grant repository-content write access. There are no self-hosted PR runners, `pull_request_target`, privileged `workflow_run` handoffs, or automatic PR approval.
- Every remote Action is pinned to a full commit SHA. Checkout removes persisted Git credentials. Release elevation is limited to the jobs and steps that need it.
- Xcode is selected explicitly. XcodeGen and actionlint archives, Whisper source, speech model and VAD model are pinned. Downloads are checksum verified before use; native compiled artifacts are rebuilt rather than restored from a shared executable cache.
- CodeQL scans the workflow language, Swift app and package, and native C++ compilation. The Swift and C/C++ scans are separate jobs, each required only for the pull requests listed above and always on main, schedules and releases. Every scan that runs, including on pull requests, explicitly disables diff-informed queries so the gate receives full results, including findings outside changed lines. Workflow policy rejects missing or overridden full-scan configuration. The local SARIF gate blocks security severity 7.0 and above and non-security error-level findings, including existing and suppressed findings. Four [reviewed local-file findings](maintainers/reviewed-codeql-findings.md) have exact, source-bound dispositions for the current local APIs. Each disposition prints its original severity and rationale. Changed source or finding identity, missing review evidence, and all unmatched high-severity findings fail the gate. Lower-severity results remain visible in GitHub's Security tab.
- Native security builds target ARM explicitly. The Swift scan uses a generic macOS destination with `ARCHS=arm64`; the C++ helper compiler receives its architecture explicitly. This keeps the output architecture correct when CodeQL traces the build through a translated process.
- Blocking SARIF findings include their source location and scanner message in the job log. Check that output even when GitHub's PR summary says there are no new alerts: the local gate also examines results outside the changed lines, including compiled vendor code. An empty uploaded alert list does not override a failing local severity gate.
- Dependency review blocks newly introduced high/critical vulnerable dependencies. Dependabot proposes updates; it never approves or merges them. Model files and the manually pinned native runtime are outside ordinary Swift dependency advisory coverage and need deliberate review.
- `CODEOWNERS` identifies sensitive paths. Review enforcement, secret scanning and push protection require the repository settings described in the activation guide. A CODEOWNERS file by itself cannot prevent a merge.
- No system can prove the absence of vulnerabilities. Static checks, behavioral tests, contributor review, secret protection and distribution provenance address different risks.

## Release operation

For 1.0.1, follow the step-by-step [1.0.1 release procedure](release/1.0.1-checklist.md). It adds the ordering rules that no workflow enforces: an unchanged main between merge and dispatch, the rehearsal and `plan` check before tagging, and what to do when a step fails after the tag exists.

Complete the source checks, measured evaluation, and native-app acceptance in the [1.0 checklist](release/1.0-checklist.md), integrate the intended source into main, and create the approved version tag before dispatching a release. Distribution and publication receipts are completed later against the resulting signed artifact. Before approving the release tag, finalize the README candidate status and move the approved changelog entries from `[Unreleased]` to the selected version with its actual release date in that source. Keeping candidate wording and `[Unreleased]` during PR preparation is intentional; the tagged release must describe the released version. The `/releases/latest` download link needs no version-specific edit. Tag creation is deliberately not automatic. The selected source must be the dispatch's main commit, with matching `project.yml` version and existing `vX.Y.Z` tag. No metadata is bumped automatically.

Before tagging, wait until main's own CI and Security runs for the exact intended head have both succeeded. Pull requests may skip the compiled scans, so main's Security run can be the first to analyze some changes. The Release workflow runs both scans again on the tagged commit and cannot sign without them, but a failure found there comes after the tag exists.

A version tag is permanent: a repository rule prevents moving or deleting it. Before creating one, check the hand-edited release facts at the intended commit:

```bash
python3 scripts/ci/release-guard.py plan X.Y.Z
```

`plan` needs no credentials. It reads `project.yml`, `CHANGELOG.md` and the distribution entitlements from the current commit, not the working tree, and compares them with the tag of the latest published release (read from GitHub, or given with `--previous-tag`). It requires the requested `MARKETING_VERSION`, a larger `CURRENT_PROJECT_VERSION`, one dated changelog heading for the version, no leftover `[Unreleased]` entries, a version tag that is absent or already at the current commit both locally and on `origin`, unchanged bundle identifiers, and unchanged distribution entitlements unless `--accept-entitlements-change` acknowledges a reviewed change. A changed bundle identifier would reset every user's microphone and accessibility permissions, which macOS ties to the app's identity. It reports a changelog date other than today as a note. Fetch tags first if the previous release tag is not available locally.

**Steno 1.0 recovery exception:** the existing `v1.0.0` tag remains at `d25fcdf9d625eea6ee31bd0b03c5994302e8065e`, including its historical preparation wording. Final publication dates and receipts are recorded in the main-branch changelog and checklist after publication; the tag is not moved to include those documentation changes. The [reviewed signing recovery](release/signing-recovery.md) builds that exact app source using separately reviewed workflow code, reuses verified successful source checks, and retains signing, notarization, draft, and publication protections. Its authorization records the disclosed manual-coverage limits without asserting that untested cases passed.

The 1.0 draft was ultimately verified and published manually by its existing release ID after the workflow’s draft lookup returned 404. The [publication record](release/signing-recovery.md#publication-record) documents that outcome and the temporary, restored CI exception used for PR #24. Neither is a standing exception for future releases.

The steps below describe the standard **Release** workflow. For the 1.0 recovery, use its linked instructions; the original **Publish release** workflow cannot promote a recovery draft unchanged because it assumes one source SHA for both the app and workflow. Recovery also verifies its checked-in release notes before publication, so do not replace those notes during the protected approval step.

### Release rehearsal

**Actions → Release rehearsal → Run workflow** on main exercises signing before the version tag exists. It takes the version and a mode, runs the `plan` check above first in both modes, and then waits at the same protected **release** environment as a real release.

- **`signing`** (about a minute after approval): imports the Developer ID certificate into a temporary keychain, sets the keychain search list, signs and verifies a small executable and a small library, and makes one read-only notary-service request to prove the notary credentials. Its credential steps repeat those in `release-sign.sh`, and a test keeps the two identical. Nothing is built, notarized or uploaded.
- **`full`**: also prepares the pinned runtime and runs the unchanged `release-sign.sh` and `release-dmg.sh`: the app build, signing of the app and bundled runtime, the bundled-runtime smoke test, one notarization submission, stapling and Gatekeeper verification. Apple keeps a record of that submission. The signed app and disk image are deleted on the runner; only the sanitized notary receipt and a summary of file hashes are uploaded.

Its permissions make publication impossible rather than merely unintended: every scope is read-only, so it cannot push a tag or create a release or draft, and it has no `id-token` or `attestations` permission, so it cannot create an attestation (attestations for a public repository are permanent public records). It has its own concurrency group and cannot replace a pending release.

A rehearsal cannot exercise: creating the draft release and finding it again by listing and ID, verifying the new build's attestation against `release.yml`, publication and the latest-release check, handing the signed artifact between release jobs, the `release-draft` and `release-publish` approvals, or acceptance testing of the final signed download. Those first run in the real release.

From **Actions → Release → Run workflow**, select main, enter the stable version and full 40-character commit SHA, and confirm manual acceptance only after completing the source and native-app checks for that exact source. Leave `publish_release` false to stop at a draft. Enable it only when public publication is intended.

Draft creation resolves the unpublished release through authenticated, paginated release listings, requires one exact match, and verifies it again by numeric ID. A missing or ambiguous result stops without retrying creation. Later publication uses that retained ID; it does not look up an unpublished draft through the public tag endpoint.

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
- **Check failed on main after a green pull request:** main runs everything, so it can find what a pull request skipped, such as a compiled-scan finding, a reviewed-findings record that no longer matches the scan, or a Release-configuration build failure. Each main run has its own concurrency group, so a later merge cannot cancel or replace it; a later run on a newer commit still contains the same source. Whether anyone is notified depends on GitHub's Actions notification settings; see the [activation guide](maintainers/github-setup.md). Do not tag until main is green. Fix the cause in a new pull request, and dispatch **Actions → Security** or **Actions → CI → Run workflow** on that branch to prove the fix with the full suite before merging.
- **Draft or publish job stopped during its download:** the signed-artifact download in the Release workflow's `draft` and `publish` jobs has its own 10-minute limit and runs before anything is written, so **Re-run failed jobs** is safe when the failed step is the download or the attestation check. Once `release-publish.py` has started, follow the timeout entry below instead.
- **Dependency download mismatch:** inspect the upstream release and lock. Do not replace the expected hash with whatever the network returned.
- **Notarization timeout or interruption:** inspect `notary-recovery-<run-id>-<attempt>` for the submission ID and status. Query that existing submission with `notarytool info`/`log` before considering another upload. The recovery record contains only allowlisted source/digest/submission fields. Absence of an ID after a network failure means the outcome is unknown; do not assume Apple received nothing.
- **Draft creation/publication timeout:** read the release by its exact ID and compare tag, target and asset digests. Do not blindly rerun a publishing step; the first operation may already have succeeded.
- **Bad public release:** do not rewrite the tag or replace its bytes. Prepare a new patch version through the pipeline and communicate the affected version through the normal maintainer process.

For an installer produced by the standard Release workflow, verify provenance with:

```bash
gh attestation verify Steno-X.Y.Z.dmg --repo Ankit-Cherian/steno \
  --signer-workflow Ankit-Cherian/steno/.github/workflows/release.yml
```

For Steno 1.0, verify **both** the DMG and manifest against the recovery workflow commit recorded in the [release checklist](release/1.0-checklist.md):

```bash
for artifact in Steno-1.0.0.dmg release-manifest.json; do
  gh attestation verify "$artifact" --repo Ankit-Cherian/steno \
    --signer-workflow Ankit-Cherian/steno/.github/workflows/recover-release.yml \
    --signer-digest bf95cec49731c347de14bea4a5eb987569cd5b5a \
    --source-ref refs/heads/main --source-digest bf95cec49731c347de14bea4a5eb987569cd5b5a
done
```

The attestation identifies the workflow source. After verification, check that the manifest identifies app source `d25fcdf9d625eea6ee31bd0b03c5994302e8065e`, tag `v1.0.0`, and the downloaded DMG's SHA-256. Its workflow source, producing run, and reused validation receipt must match the release record. Do not substitute the app SHA for the workflow SHA in the attestation command.

## Maintenance and design references

The workflow favors ordinary GitHub Actions over a second external CI service: contributors can see checks beside their PRs, and release permissions stay in the repository. It uses a shared validation workflow to avoid separate, drifting PR and release test definitions. Fast assertions and security analysis run in parallel; releases retain explicit human approval because automated tests cannot exercise the maintainer's complete native acceptance checklist.

The [CI change record](maintainers/ci-changes.md) records corrections made during hosted activation and the checks used to verify them. Update this guide when a correction changes contributor commands, limits, artifacts or merge requirements.

Review Dependabot's monthly Action/Swift updates. Minor and patch updates arrive grouped; each major update arrives as its own pull request. Tool archive pins in `tools.sh`, Xcode image availability, and runtime/model pins in `runtime-lock.json` require manual maintenance and the same checks as other changes. A pinned Xcode removed from the hosted image should fail clearly; do not silently select a different toolchain. Tune timeouts and runner usage from actual workflow timings rather than estimated speedups.

The design follows [GitHub's secure workflow guidance](https://docs.github.com/en/actions/reference/security/secure-use), [compiled-language CodeQL guidance](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/codeql-for-compiled-languages), [artifact attestation documentation](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations), and [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). [Rectangle's build workflow](https://github.com/rxhanson/Rectangle/blob/main/.github/workflows/build.yml) and [IINA's CI workflow](https://github.com/iina/iina/blob/develop/.github/workflows/ci.yml) provide useful examples of contributor build artifacts and macOS dependency provisioning. Their implementation details are not copied wholesale.
