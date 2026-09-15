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

The ASR-only diagnostic completed in 34.702 seconds on a runner reporting three logical CPUs. It does not exercise VAD. At that revision, both helper VAD constructors retained the library's default of four threads. The initial logs did not establish whether requesting more workers than the runner's CPU count caused the timeouts.

After a failed protocol suite, the lane now compares the upstream VAD-only executable with four threads and with the available CPU count capped at four. It then sends a complete v2 stream request with VAD to the real helper. Each VAD trial is bounded to 60 seconds; the stream retains the 180-second diagnostic budget. Timing, CPU and backend evidence distinguish these paths without printing transcripts. Every path preserves the original protocol failure. That diagnostic commit changed neither production VAD configuration nor protocol deadlines.

## Bound VAD workers to the reported hardware count

The [comparison on `043314a`](https://github.com/Ankit-Cherian/steno/actions/runs/34923180560/job/104235534694) isolated the speech detector on the same three-CPU runner and 11-second public JFK fixture. Four VAD threads took **58.838 seconds**; three took **0.029 seconds**. Both produced the same four speech segments with identical boundaries. The separate ASR-only request completed in 31.656 seconds. This establishes a severe VAD slowdown from requesting more workers than the runner reports CPUs; it does not measure end-to-end app latency.

The [separate PR run](https://github.com/Ankit-Cherian/steno/actions/runs/34923182954/job/104235541406) reproduced the difference: its four-thread VAD trial exceeded 60 seconds, while three threads completed speech detection in 0.040 seconds. Its original full-stream diagnostic still timed out at 180 seconds.

Both helper VAD constructors now use one parameter factory. It caps the library's four-worker default at `std::thread::hardware_concurrency()`, with one worker when that hint is unavailable. Hosts reporting four or more CPUs retain four VAD workers. Backend selection, ASR thread requests, VAD thresholds, context ownership and protocol deadlines are unchanged.

The integrity test covers unavailable, one-, two-, three-, four- and eight-CPU hints, plus the maximum unsigned value, and checks that the GPU fields retain their defaults. Running those assertions against the original unbounded policy fails. The hardware hint does not guarantee the process's effective CPU allocation; the hosted protocol suite still has to validate the integrated correction.

Local validation of the correction passed all 26 CPU protocol cases, all 26 Metal cases, the VAD integrity and prompt-verification checks, 720 package tests, 70 hosted macOS tests, the app build, 127 CI contract tests and the three-fixture benchmark gates. Each protocol run attested all 25 eligible helper processes. The first Metal attempt failed during GPU initialization inside the local sandbox; the same binary passed a direct Metal probe and the full suite outside that restriction. Hosted runner validation remains required.

## Completed-final crash observation

On `e48c48d`, the [push runtime job](https://github.com/Ankit-Cherian/steno/actions/runs/34925595114/job/104242856558) passed 25 of 26 protocol cases. The completed-final crash case failed its network inspection. It had already spent approximately 126 seconds in the case; the artifact recorded 7,133 scans and no observed network descriptors, but only 27 of 28 owned processes qualified. Incomplete observation correctly kept the gate failed.

An in-progress inspection could overlap the intentional kill because the shared crash helper requests observer shutdown, kills the process, then joins the observer. The completed-final case now accepts the final result, checks for extra frames, and stops and joins the observer while the helper remains alive. It then performs the same forced crash and EOF assertions. Tests that interrupt active decoding retain immediate kill before observer join.

Two deterministic regressions failed against the old ordering and passed with the correction. They exercise the actual crash and cleanup methods, verify observation finishes before process destruction, and preserve an injected observation failure while still reaping the owned process. All 31 focused cleanup tests passed, including the existing immediate-kill and extra-output checks. The hosted artifact did not record the exact failed inspection phase, so a fresh hosted run remains necessary.

## Cancellation while encoding

The [PR runtime run on `e48c48d`](https://github.com/Ankit-Cherian/steno/actions/runs/34925599511/job/104242870245) failed the cancellation/restart case after 6.118 seconds with an unlabelled response timeout. The same case passed in 1.363 seconds in the push run. The test now identifies the response stage in failures; its assertions and five-second acknowledgement and shutdown limits are unchanged.

A local public-fixture probe separated the four waits. Cancellation, replacement start and replacement cancellation replied immediately. Delaying cancellation by 10–100 milliseconds after finish made shutdown wait another 0.413–0.510 seconds on an 18-CPU Mac. A stack trace during that wait showed the main thread joining the worker while the worker was still computing encoder graphs. All local trials met the existing five-second limit. This establishes the local cancellation gap without proving the exact unlabelled stage that failed on the hosted runner.

The pinned library accepts a request abort callback but does not pass it into its scheduler-based encoder and decoder graph computation. It checks cancellation only after completing that work. The correction passes the callback into participating backends for each graph and uses scoped cleanup to synchronize and clear it after success, cancellation or an exception. CPU already exposes the setter through its backend registry; the Metal registry now exports its existing setter. The changes are applied in the staged native patch, with the original vendor checkout preserved. CPU can stop between compute nodes. Metal retains its existing command-buffer granularity, so the change does not promise immediate interruption of an in-flight GPU graph.

Nine CPU regressions exercise the actual scheduler and backend: cancellation before and during a graph, callback removal checked through direct backend reuse, healthy numerical output, and cleanup when graph computation throws. The original implementation fails three of the checks. An intermediate correction without scoped exception cleanup fails the exception regression. The final correction passes all nine. Ten Metal controls also pass with explicit GPU assignment and a checked numerical result. They cover the registered setter, cancellation at the helper boundary, exception recovery and healthy reuse; they do not establish interruption inside a Metal graph or directly observe callback clearing. The native lane runs the selected backend's checks before protocol validation, and a regression failure stops that lane. The allocation checks still pass all seven cases, and reconstructing the previous patch confirms that its 61 security corrections remain unchanged; only the scheduler cancellation paths and Metal registry differ.

The final build repeated the same delayed-cancel probe three times: shutdown returned in 0.091–0.119 milliseconds, compared with 0.510 seconds in the original 10-millisecond-delay trial. This is a controlled local cancellation measurement, not advertised end-to-end dictation latency.

## Synchronize the delayed-append test

The [macOS 26 push job on `637325c`](https://github.com/Ankit-Cherian/steno/actions/runs/34963736637/job/104363180475) failed the delayed-append test while the independent PR job passed. The test starts completion, sleeps for 30 milliseconds, checks two actor properties, then releases an append. Scheduling delays can push those steps beyond the coordinator's 150-millisecond grace period. Completion then takes the intended fallback for a permanently blocked append, invalidating this test's expectation that every provisional frame drains first. An isolated reproduction with a 250-millisecond driver delay reproduced the failure without changing production behavior.

Debug builds now expose an internal, optional observer when completion reaches a busy append, before the grace-period clock starts. The test waits for that event, checks that finish has not run, releases the append, and then allows completion to proceed. Completion revalidates session ownership after the observer returns. The observer is absent from Release builds and does not suspend Debug builds when unset. The 150-millisecond deadline and the separate permanently blocked-append test remain unchanged.

The revised test retains its final sample counts, contiguous ranges, single-append concurrency, and no-fallback assertions. A mutation that bypasses the wait fails the new entry check and the ordering assertions. Ten repetitions of the corrected test and its permanently blocked sibling passed all 20 checks. A separate trial delayed the driver by 250 milliseconds after wait entry and passed. The full coverage-enabled package suite passed 720 tests; the app build and all 70 hosted tests passed. A Release package build also passed, and symbol inspection confirmed that it contains no observer symbols. Removing the added Debug blocks exactly reproduces the previous production source. Hosted validation on the new commit remains required.

## Keep editor setup owned during cancellation

A normal-scheduler stress run on `8c99926` reproduced an editor-context read after session cancellation. Ten full runs with a constrained cooperative pool had passed; the third normal run failed the existing no-read assertion. The Accessibility handle already checked cancellation after metadata revalidation and before reading text. The detached setup task had not received cancellation: start kept it in a local array across an actor suspension before registering it with the session.

Editor setup is now registered before that suspension. Capture close retains setup-task ownership while awaiting the recorder, so cancellation can reach those tasks until ownership transfers to the captured session. A failed close cancels its setup tasks; successful ordinary capture close preserves them. Global cleanup cancels every session's setup tasks before awaiting individual resource cleanup.

The regression tests hold metadata revalidation before any bounded text read, cancel at controlled lifecycle boundaries, and await the setup task before asserting that no text was read. They also cover ordinary completion so cancellation repair cannot silently remove valid editor context. These tests use simulated editors and do not inspect personal documents.

With the regression controls retained, the original ownership paths fail 16 assertions. The corrected focused suite passes five test declarations covering ten cases. The full coverage-enabled package suite passes 722 tests, the unsigned app build and all 70 hosted macOS tests pass, and the three-fixture benchmark passes both report and zero-regression gates. Thirty further full runs under the normal executor pass all 21,660 test executions. These local results do not identify the cause of the separate hosted package stall or establish behavior against a real editor.

## Observe intentional crashes without delaying the kill

The [push runtime job on `8c99926`](https://github.com/Ankit-Cherian/steno/actions/runs/34965776335/job/104369895615) passed 25 of 26 cases. The remaining case, a crash during finish, reported that the network observer could not inspect its owned helper. The separate PR run passed all 26 cases. The failed receipt does not contain the raw inspection response, so it cannot identify that response precisely.

A deterministic regression reproduces a race consistent with the failure: an inspection already in progress loses its target when the test intentionally kills the helper, before process reaping has made the exit visible to the observer. The harness marks that intentional termination boundary and accepts an empty `lsof` exit-one result only after confirming that the same owned process was reaped with `SIGKILL`. An incomplete final query does not count as a completed observation. The two complete startup scans remain required.

The kill still happens before the observer joins, preserving the test's interruption timing and rejection of buffered output. Earlier observation failures, query timeouts, diagnostic output, unexpected query exit codes, network descriptors and an unconfirmed kill remain failures. The exception applies only to the explicitly marked termination boundary; it does not establish observation after that boundary or replace a fresh hosted run.

The observer correction passes all 141 CI contract tests, including the reproduced race, failed-kill and observation-error controls, minimum scan requirements, and buffered-output rejection. The revised harness also passes all 26 native protocol cases on CPU and all 26 on Metal. Both receipts verify 25 backend-attested processes and report zero network descriptors across all 28 owned processes.

Prompt-scoring logs also identify fixture synthesis, compilation and inference separately, and the existing fixture output is line-buffered so progress reaches the CI log promptly. This makes a delay visible without changing fixture text, scoring parameters or assertions. The local CPU scorer passes with all stage labels and seven fixture results present. The earlier PR run also completed its native checks and public benchmark; its long quiet interval was not a confirmed hang.

## Match product checkout names consistently

The [PR runtime job on `8c99926`](https://github.com/Ankit-Cherian/steno/actions/runs/34965780817/job/104369888614) passed native checks, the public benchmark, the app build and bundled-runtime smoke tests, then failed the distribution hygiene scan. Its diagnostic named four bundle files but did not identify the matched pattern.

The scan compared the checkout basename with `Steno` case-sensitively. GitHub's lowercase `steno` checkout therefore added the bare product name to the forbidden strings, matching legitimate bundle identifiers and helper names. Public metadata fixtures reproduce all four reported file failures under the original scan. This establishes a false-positive mechanism; the original message was not proof that an absolute private path had leaked.

The comparison now treats capitalization consistently. Full home, checkout, runtime, model and build paths remain forbidden, as do distinctive private checkout names. Regression tests verify both the legitimate product metadata and rejection of those private paths. The original scan fails three assertions; the corrected release-guard suite passes all 27 tests, and the full CI contract suite passes 146. Workflow policy and shell syntax checks also pass. A complete scan of the final packaged app remains required.

## Verification and remaining gates

The cancellation and completed-final observation follow-up passed **130 CI contract tests**, **720 package tests**, **70 hosted macOS tests**, the unsigned app build, and all **26 protocol cases on CPU and Metal**. Each protocol suite verified 25 backend-attested processes and observed no network descriptors across all 28 owned processes. The final staged library also passed nine CPU cancellation regressions, ten Metal controls, seven allocation checks, prompt scoring and decision checks, VAD integrity, and five retained-helper silence repetitions. The three-fixture benchmark passed its report and zero cleanup-regression gates. These results cover local fixtures; fresh hosted CI and Security results remain required before merge.

For the VAD-worker correction, local verification passed **127 CI contract tests**, **720 package tests**, **70 hosted macOS tests**, unsigned app/helper builds, both 26-case CPU/Metal protocol runs, and the benchmark gates described above. The VAD-only comparison and full v2 VAD diagnostic also completed locally. The local stream diagnostic could not read CPU utilization; its backend and network evidence were available. These local results do not establish behavior on the hosted runner.

Local verification after the ARM and teardown corrections passed **85 CI contract tests**, **720 package tests**, unsigned ARM app/helper builds, workflow policy checks, and actionlint. The CPU-budget and SARIF-output follow-up passed **89 CI contract tests**. These counts describe those revisions and must not be reused as validation of later edits.

On `043314a`, the [full Security workflow](https://github.com/Ankit-Cherian/steno/actions/runs/34923182707) passed, including the C++ high/critical severity gate after repair of the 61 prior blocking results. Package and hosted-app jobs passed on both macOS 15 and 26. The runtime suite still had three VAD-related timeouts; the diagnostic comparison above identified a VAD worker-count correction. On `e48c48d`, the [Security workflow](https://github.com/Ankit-Cherian/steno/actions/runs/34925598286) and both macOS test matrices passed. Both runtime runs passed the previously failing long transcription cases and 25 of 26 cases overall. The push run failed completed-final network observation; the [PR run](https://github.com/Ankit-Cherian/steno/actions/runs/34925599511/job/104242870245) timed out in cancellation/restart. These results validate the VAD timing improvement but leave CI blocked pending the follow-up corrections. Merge, signing, notarization, release publication, and manual app acceptance require their own evidence and approvals in the [1.0 release checklist](../release/1.0-checklist.md).
