# CI activation corrections

This record explains the corrections made while activating the 1.0 pipeline in [PR #16](https://github.com/Ankit-Cherian/steno/pull/16). Recorded on September 15, 2026 UTC. Local results, hosted outcomes and remaining release gates are recorded separately.

For current commands and gate behavior, use the [CI/CD operating guide](../ci-cd.md). For repository settings and release approvals, use [GitHub activation](github-setup.md).

## Explicit ARM build targets

[`22c4ae9` — Specify ARM targets for native security builds](https://github.com/Ankit-Cherian/steno/commit/22c4ae98b2cc05fa1a13ddd82e9253b279d14720) makes the architecture explicit in both native build paths:

- The CodeQL Swift build uses `generic/platform=macOS`, `ARCHS=arm64`, and `ONLY_ACTIVE_ARCH=NO`.
- The standalone helper compilation passes `-arch "$EXPECTED_ARCHITECTURE"` to `clang++`, matching the existing CMake architecture setting.

These settings prevent the analysis build from depending on the runner's selected active destination or the compiler's implicit target. Architecture and deployment-target checks still inspect the produced binaries. Local unsigned ARM app and helper builds passed; later hosted C++ analysis completed successfully before reaching its security-findings gate.

When changing runners or Xcode versions, check the requested target and the resulting Mach-O architecture. Keep the standalone helper compiler aligned with CMake.

## Preserve failures and collect bounded runtime evidence

[`1cb181c` — Preserve runtime test failures and collect timeout diagnostics](https://github.com/Ankit-Cherian/steno/commit/1cb181c442aa8a0bb47ad01b362508885016e9cd) fixes test teardown that could obscure an inference timeout with a network-inspection error. Cleanup now stops the observer before intentionally killing the owned helper, always attempts to reap it, and reports secondary cleanup failures without replacing the primary exception.

After a failed protocol suite, the runtime lane runs one additional v1 request against the same public JFK fixture. The diagnostic retains the real helper, network observer, and backend attestation. It records timing, logical CPU count, requested threads, and CPU/process statistics without transcript text or command arguments. Its work budget is 180 seconds; bounded cleanup can follow. The shell exits with the original suite failure even if the diagnostic succeeds.

Regression tests cover cleanup order, primary-error preservation, an actual owned child's reaping, deadline interruption, backend mismatch, and original exit-status preservation. Diagnostic success is evidence for investigation; it never satisfies the failed protocol gate.

## CPU-specific inference budget

[`e324587` — Allow slower CPU inference in runtime contract tests](https://github.com/Ankit-Cherian/steno/commit/e3245877e52070200afbea7d6eb8ff96dca74398) follows a [hosted diagnostic](https://github.com/Ankit-Cherian/steno/actions/runs/34917534501/job/104218403326) that completed inference in **33.901 seconds**, exceeding the previous 30-second limit. The runner reported three logical CPUs and the request used four threads. Backend attestation reported CPU; 230 network scans observed no network file descriptors.

Only explicit CPU mode, `GGML_METAL_DEVICES=0`, now allows 180 seconds for inference responses. Default and Metal runs retain 30 seconds. Model readiness, ordinary frame reads, backend attestation, network-monitor startup, and lifecycle operations keep their separate deadlines. The protocol receipt records the selected inference budget.

The local follow-up passed all 26 protocol cases with 25 attested CPU processes. Added tests verify budget selection and unchanged non-inference deadlines. This adjustment changes the test harness, not app inference behavior, advertised latency, or Metal qualification. Recheck measured runner behavior before changing another deadline or thread count.

## Actionable security findings

[`f54c2e2` — Report source locations for blocking security findings](https://github.com/Ankit-Cherian/steno/commit/f54c2e2b26bfd6729b8c030ba0cf26dac05e14b8) adds source locations and scanner messages to the existing severity-gate output. It supports direct and indexed SARIF artifact locations and escapes control characters so each finding stays on one log line.

This was needed because the [completed C++ scan](https://github.com/Ankit-Cherian/steno/actions/runs/34917538707/job/104218321712) produced blocking local results while GitHub's exported analysis reported zero results. The gate previously printed only rule IDs and severities. An empty uploaded result set did not explain or dismiss the generated findings.

The high/critical threshold and treatment of existing or suppressed findings are unchanged. Two regressions cover location reporting and indexed artifacts. Diagnose findings from generated SARIF and source evidence; do not bypass the gate because the upload view differs or because a result may involve vendored code.

## Cancellation test scheduling

Three [coordinator tests](../../StenoKit/Tests/StenoKitTests/SessionCoordinatorLiveContextTests.swift) deliberately hold a synchronous Accessibility call while a second task stops or cancels the session. Under constrained cooperative scheduling, the held call could occupy the executor needed by the test driver. The suite then stopped making progress instead of evaluating its assertions.

The fixtures now use an independent dispatch-backed task executor on macOS 15 and later. The deferred-setup test starts capture independently, obtains its session identity from the capture callback, and uses a bounded condition wait to observe the blocked call before canceling. Its readiness wait remains one second. The final-revalidation test arms its block when final transcription starts, after setup has finished, so it cannot accidentally cancel an earlier setup phase.

The existing focus-drift, exactly-once stop, cancellation, no-context-read, no-insertion, no-history and no-usage assertions remain. Production coordinator and helper code did not change. The deployment target remains macOS 13; older systems retain the previous executor path.

Before the correction, the isolated capture test and full suite stalled with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. Afterward, all three tests passed ten consecutive strict runs, and the full strict suite passed all 720 tests. The normal coverage-enabled suite and unsigned app build also passed. The [macOS 15 PR job](https://github.com/Ankit-Cherian/steno/actions/runs/34920713779/job/104228098979) and [macOS 26 PR job](https://github.com/Ankit-Cherian/steno/actions/runs/34920713779/job/104228098602) subsequently passed on commit `501e648`.

## Corrections to the pinned native library

[`e6a6208` — Correct allocation handling and arithmetic in the pinned runtime](https://github.com/Ankit-Cherian/steno/commit/e6a6208) contains the patch, reproducible build integration and allocation regressions.

The [location-reporting scan](https://github.com/Ankit-Cherian/steno/actions/runs/34919411377/job/104223939450) identified 57 multiplication results and four allocation-error results in compiled whisper.cpp sources. The [reviewed patch inventory](../../scripts/ci/patches/README.md) maps all 61. Integer products now use their intended destination width before multiplication. Four nonthrowing allocations make existing null-return and cleanup branches reachable. Two floating-point products now use double precision, including a mel-spectrogram remainder calculation; these changes need inference regression checks.

The builder verifies the original pinned checkout, stages tracked sources separately, and applies the checked-in patch there. The source directory is identified by upstream revision and patch SHA-256. Each reuse reconstructs expected hashes and rejects modified source, manifests, unexpected files or links. An existing CMake cache tied to a different source directory fails without deletion. Generated JavaScript package metadata goes into the build directory so configuration does not change staged source. Build metadata still identifies the original upstream revision; the source manifest records the patch separately.

Four allocation-failure regressions compile the actual CPU and Whisper implementations into separate test executables. On the original pin, all four injected failures failed their null-return and cleanup assertions; all three successful controls passed. With the patch, all seven checks passed. The native lane runs these tests before its protocol checks, and an allocation-test failure stops the lane. Fault injection is absent from the shipped helper.

The patched native build and subsequent source-hash verification passed locally. The three-fixture transcription benchmark passed its report and zero cleanup-regression gates. A direct comparison against the original runtime produced identical transcripts and WER/CER for all three fixtures. This small fixture set does not certify general recognition accuracy or prove bit-identical mel features. Local protocol validation passed all 26 cases on CPU and all 26 on Metal, with 25 attested processes per backend. Prompt verification, VAD integrity, seven prompt-scoring fixtures and five repeated silence requests also passed. These results do not resolve the separate hosted VAD timeout or replace fresh hosted C++ analysis.

## Bounded network observation and failed-constructor cleanup

[`5eacc86` — Keep runtime observation bounded during test teardown](https://github.com/Ankit-Cherian/steno/commit/5eacc86) contains this correction.

Local process inspection took approximately two seconds per `lsof` query. Two launch scans require four queries, so the previous three-second startup wait failed before the helper received a model-load request. The original unpatched helper reproduced the same failure. Numeric-UID and descriptor-only options did not improve timing; the latter also removed inspection rows and was not adopted.

Each query now has a five-second deadline, with 25 seconds for startup and six seconds for observer shutdown. Two complete all-files/network-query pairs remain mandatory. A query timeout, inspection error or network descriptor still fails the gate. The observer checks for shutdown between queries and joins its thread when construction fails. Raw-process test cases place monitor construction inside their cleanup scope and always reap their owned process. Protocol, model-readiness, inference and cancellation budgets are unchanged by this correction.

Focused regressions exercise delayed scans, real subprocess timeout and reaping, constructor-thread cleanup, network-descriptor rejection and process cleanup in the three pre-readiness interruption branches. Forced-crash tests request observer shutdown without waiting, kill and reap the helper, then join the observer. Previously, waiting before the kill allowed a response to arrive while the helper was still alive; the test misclassified that buffered response as output after a crash. Real-child regressions reproduce that failure, ensure observer errors cannot prevent the kill, and retain rejection of buffered output. All 117 CI contract tests passed after these corrections. The protocol receipt records the observer budgets. App behavior and the requirement for no network descriptors are unchanged.

## Hosted VAD timeout investigation

[`f878f48` — Collect VAD and stream timing after runtime failures](https://github.com/Ankit-Cherian/steno/commit/f878f48) adds the diagnostic paths.

The [runtime job on `501e648`](https://github.com/Ankit-Cherian/steno/actions/runs/34920713779/job/104228098787) passed 22 of 26 cases. Four full-JFK requests with VAD timed out at 180 seconds: finish priority, crash after final, stream vocabulary acceptance and prompted one-shot verification. The fourth uses four ASR threads; the three stream cases use eight. All 25 eligible processes attested CPU, and 9,144 network scans found no network descriptors.

The ASR-only diagnostic completed in 34.702 seconds on a runner reporting three logical CPUs. It does not exercise VAD. Both helper VAD constructors retain the library's default of four threads. This is more than the reported CPU count, but the available logs do not establish that oversubscription caused the timeouts.

After a failed protocol suite, the lane now compares the upstream VAD-only executable with four threads and with the available CPU count capped at four. It then sends a complete v2 stream request with VAD to the real helper. Each VAD trial is bounded to 60 seconds; the stream retains the 180-second diagnostic budget. Timing, CPU and backend evidence distinguish these paths without printing transcripts. Every path preserves the original protocol failure. Production VAD configuration and protocol deadlines are unchanged while this cause remains unverified.

## Verification and remaining gates

After the native corrections, observer cleanup and diagnostic additions, local verification passed **127 CI contract tests**, **720 package tests**, **70 hosted macOS tests**, unsigned app/helper builds, both 26-case CPU/Metal protocol runs, and the benchmark gates described above. The VAD-only comparison and full v2 VAD diagnostic also completed locally. The local stream diagnostic could not read CPU utilization; its backend and network evidence were available. These local results do not establish behavior on the hosted runner.

Local verification after the ARM and teardown corrections passed **85 CI contract tests**, **720 package tests**, unsigned ARM app/helper builds, workflow policy checks, and actionlint. The CPU-budget and SARIF-output follow-up passed **89 CI contract tests**. These counts describe those revisions and must not be reused as validation of later edits.

Hosted validation remained incomplete at this checkpoint. The original 61 C++ results have been mapped to a source patch that passed local native, package and hosted-app tests; fresh hosted security analysis remains pending. The latest hosted runtime lane passed 22 of 26 cases and timed out in four full-sample VAD cases. Its ASR-only diagnostic completed, so that result does not validate the failing VAD path. The coordinator fixture correction has passed both hosted runner versions. Merge, signing, notarization, release publication, and manual app acceptance require their own evidence and approvals in the [1.0 release checklist](../release/1.0-checklist.md).
