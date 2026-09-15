# CI activation corrections

This record explains the corrections made while activating the 1.0 pipeline in [PR #16](https://github.com/Ankit-Cherian/steno/pull/16). It covers changes through [`f54c2e2`](https://github.com/Ankit-Cherian/steno/commit/f54c2e2b26bfd6729b8c030ba0cf26dac05e14b8), recorded on September 15, 2026 UTC. It is a dated engineering record, not a claim that all hosted checks passed or that 1.0 was released.

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

## Verification and remaining gates

Local verification after the ARM and teardown corrections passed **85 CI contract tests**, **720 package tests**, unsigned ARM app/helper builds, workflow policy checks, and actionlint. The CPU-budget and SARIF-output follow-up passed **89 CI contract tests**. These counts describe those revisions and must not be reused as validation of later edits.

Hosted validation remained incomplete at this checkpoint. Security findings still required location-level review, and hosted macOS test failures remained under investigation. No pending Accessibility test correction is recorded here as complete. Merge, signing, notarization, release publication, and manual app acceptance require their own evidence and approvals in the [1.0 release checklist](../release/1.0-checklist.md).
