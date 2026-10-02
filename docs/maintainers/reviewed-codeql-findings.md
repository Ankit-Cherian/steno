# Reviewed local-file findings

The full C++ [scan for PR #20](https://github.com/Ankit-Cherian/steno/actions/runs/34999812499/job/104485163486) reported four `cpp/path-injection` findings at severity 7.5. The scan ran all selected queries and no longer reported automatic backend loading after its repair. The remaining reports describe intentional local file reads. Source review found no route from a less-trusted caller into the app-owned helper that would make those reads an unauthorized file-access service.

These four reports are classified as not actionable under the inspected launch contracts:

| File input | Review |
| --- | --- |
| CLI response file | The upstream branch requires exactly one argument beginning with `@`. Steno passes several explicit arguments, so its invocation cannot enter that branch. A standalone CLI caller deliberately selects the response file. |
| Helper WAV | Steno creates a recording path from its temporary directory and session UUID, then sends it to its child through a new anonymous pipe. The Speech model setup check instead sends a silent clip it writes into a new UUID-named temporary folder. Direct helper callers may intentionally choose their own WAV files. |
| VAD model | The host selects the local VAD model and sends its path through the pipe. Custom absolute model paths are supported. The setup check uses the unsaved Settings draft. |
| Transcription model | The initial load request carries the selected local model path, from saved preferences or, for the setup check, the unsaved Settings draft. This path is not derived from recognized text or a remote request. A helper that exits while idle is relaunched with the same configuration. |

The inspected launcher performs no privilege elevation and exposes no shared request endpoint into the app-owned helper. Anonymous pipes describe that connection; they do not authenticate arbitrary programs that launch their own helper. The optional parent-process identifier is a lifecycle check, not authorization.

Same-user execution alone does not establish identical macOS file authority. TCC attributes access to responsible applications. This review does not dynamically verify every signed-app launch and permission combination or establish parser safety for malformed model and audio files. A privileged or shared file service, new request transport, changed launch attribution, or newly exposed path source requires another review. See [Apple's file-permission guidance](https://developer.apple.com/forums/thread/678819).

## How the gate uses the review

[`scripts/ci/reviewed-findings.json`](../../scripts/ci/reviewed-findings.json) records the four technical classifications. Each entry binds the exact rule, severity, full source range, message and source-to-sink trace. Full SHA-256 hashes cover the repository files in the trace and fourteen launch, permission, capture, native-build and release-packaging contracts. The three helper findings also bind the retained engine that builds helper requests, and the source of their paths: preferences for the two models, and the setup check for the WAV. Generated vendor paths retain the upstream revision and patch digest. External toolchain header URIs remain part of trace identity; their contents are not hashed.

The reviewed commit identifies the scanned source. File hashes enforce the review after unrelated commits. A new file outside those contracts can still change the trust boundary; ordinary code review and full-source security analysis remain necessary.

The gate prints each disposition with its original severity and rationale. It leaves SARIF and GitHub alerts unchanged. Scanner suppression flags do not authorize a disposition. Missing or changed findings, stale hashes, duplicate matches, malformed receipts and ambiguous source references fail. Every unmatched high-severity finding still blocks. Review receipts are never refreshed automatically.

## Early source check on every event

The C/C++ scan does not run on most pull requests; see [what a pull request runs](../ci-cd.md#what-a-pull-request-runs). The Security workflow's **Reviewed findings sources** job checks the receipt on every event instead, including every pull request. It applies the same receipt validation and source-hash comparison as the full gate, through the same code, without scan output. It fails `Security Gate` within a few minutes if any bound file differs from its recorded hash.

The generated vendor source in a trace does not exist in a fresh checkout. When it is absent, the check requires its directory name to carry the whisper.cpp revision pinned in `scripts/ci/runtime-lock.json` and the SHA-256 of the current `scripts/ci/patches/whisper-security.patch`, which must also be the patch hash recorded in the same entry. The staged file is generated deterministically from that revision and patch. When a local native build has created the file, the check hashes it like any other bound source.

This check proves only that the bound files have the reviewed content. It cannot show that the scanner still reports exactly the reviewed findings, that a fix removed one, or that a new finding appeared. A pull request that changes a bound file therefore does not run the compiled scans because of that file: it passes `Security Gate` once the receipt records the new hashes, and the compiled C/C++ scan first checks the updated receipt on main after merge. If the scan disagrees, main's `Security Gate` fails. The Release workflow repeats the scan on the tagged commit before signing, so a release cannot ship with a receipt the scanner rejects.

To run the early check locally:

```bash
python3 scripts/ci/check-sarif.py --check-reviewed-sources scripts/ci/reviewed-findings.json \
  --source-root . --runtime-lock scripts/ci/runtime-lock.json
```

## Full gate after a scan

The workflow passes this receipt only to the C++ gate. Swift and Actions scans retain the ordinary severity gate. To check the C++ evidence locally after generating the exact native sources:

```bash
python3 scripts/ci/check-sarif.py \
  --directory build/codeql-results --category /language:c-cpp \
  --reviewed-dispositions scripts/ci/reviewed-findings.json \
  --source-root .
```
