#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RECEIPT_PATH="${STENO_LIVE_CONTEXT_HOSTED_RECEIPT:-}"
TRIAL_COUNT="${STENO_LIVE_CONTEXT_TRIAL_COUNT:-10}"
LANGUAGE="${STENO_LIVE_CONTEXT_LANGUAGE:-en}"
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)" ]]; then
  TREE_IS_DIRTY=true
else
  TREE_IS_DIRTY=false
fi

if [[ -z "$RECEIPT_PATH" ]]; then
  echo "STENO_LIVE_CONTEXT_HOSTED_RECEIPT is required" >&2
  exit 2
fi
case "$RECEIPT_PATH" in
  /tmp/*|/private/tmp/*) ;;
  *)
    echo "Hosted receipt destination must be below /tmp" >&2
    exit 2
    ;;
esac

DERIVED_DATA="$(mktemp -d /tmp/steno-live-context-hosted.XXXXXX)"
SOURCE_SNAPSHOT="$DERIVED_DATA/source-snapshot"
CONTROL_DIRECTORY="$DERIVED_DATA/observation-control"
NETWORK_MONITOR_SUMMARY="$DERIVED_DATA/network-monitor-summary.json"
RESULT_BUNDLE="$DERIVED_DATA/HostedEvidence.xcresult"
ATTESTATION_EXPORT="$DERIVED_DATA/attestation-export"
cleanup() {
  case "$DERIVED_DATA" in
    /tmp/steno-live-context-hosted.*) rm -rf -- "$DERIVED_DATA" ;;
  esac
}
trap cleanup EXIT

SOURCE_PATHS=(
  "Steno/DictationController.swift"
  "StenoKit/Sources/StenoKit/Services/SessionCoordinator.swift"
  "StenoKit/Sources/StenoKit/Services/CanonicalWAVFrameStreamer.swift"
  "StenoKit/Sources/StenoKit/Services/RuleBasedCleanupEngine.swift"
  "StenoKit/Sources/StenoKit/Services/WaveformOverlayPresenter.swift"
  "StenoKit/Sources/StenoKit/Services/ProvisionalTranscriptReducer.swift"
  "StenoKit/Sources/StenoKit/Services/MacEditorTargetHandle.swift"
  "StenoKit/Sources/StenoKit/Services/InsertionService.swift"
  "StenoKit/Sources/StenoKit/Services/InsertionTransports.swift"
  "StenoKit/Sources/StenoKit/Services/MacInsertionTransports.swift"
  "StenoKit/Sources/StenoKit/Services/WhisperCLITranscriptionEngine.swift"
  "StenoKit/Sources/StenoKit/Services/ProcessWhisperRuntimeSession.swift"
  "StenoKit/Sources/StenoKit/Services/RetainedWhisperTranscriptionEngine.swift"
  "StenoKit/Sources/StenoKit/Services/MacAudioCaptureService.swift"
  "StenoKit/Sources/StenoKit/Services/HistoryStore.swift"
  "StenoKit/Sources/StenoKit/Services/UsageAnalyticsStore.swift"
  "StenoKit/Sources/StenoKit/Services/SnippetService.swift"
  "StenoKit/Sources/StenoKit/Services/DictationContinuationPolicy.swift"
  "StenoKit/Sources/StenoKit/Models/EditorTarget.swift"
  "StenoKit/Sources/StenoKit/Models/History.swift"
  "StenoKit/Sources/StenoKit/Models/LiveTranscription.swift"
  "StenoKit/Sources/StenoKit/Models/LivePCM.swift"
  "StenoKit/Sources/StenoKit/Models/Transcripts.swift"
  "StenoKit/Sources/StenoKit/Models/UsageAnalytics.swift"
  "StenoKit/Sources/StenoKit/Protocols/Engines.swift"
  "StenoKit/Sources/StenoKit/Protocols/Stores.swift"
  "StenoKit/Sources/StenoKit/Protocols/UX.swift"
  "StenoKit/Sources/StenoBenchmarkCore/LiveContextBenchmark.swift"
  "StenoKit/Sources/StenoBenchmarkCore/LiveContextBenchmarkRunner.swift"
  "StenoKit/Sources/StenoBenchmarkCore/LiveContextProductionCoordinatorBenchmark.swift"
  "StenoTests/LiveContextHostedEvidenceTests.swift"
  "StenoTests/DictationControllerLiveContextTests.swift"
  "StenoKit/Tests/StenoKitTests/SessionCoordinatorLiveContextTests.swift"
  "StenoKit/Tests/StenoKitTests/OverlayPresenterPolicyTests.swift"
  "StenoKit/Tests/StenoBenchmarkCoreTests/LiveContextProductionCoordinatorBenchmarkTests.swift"
  "scripts/run-live-context-hosted-evidence.sh"
  "scripts/live-context-hosted-network-monitor.rb"
  "scripts/finalize-live-context-hosted-receipt.rb"
)

mkdir -p "$SOURCE_SNAPSHOT/.git"
for relative_path in "${SOURCE_PATHS[@]}"; do
  source_path="$REPO_ROOT/$relative_path"
  snapshot_path="$SOURCE_SNAPSHOT/$relative_path"
  if [[ ! -f "$source_path" ]]; then
    echo "Hosted source manifest file is missing: $relative_path" >&2
    exit 3
  fi
  mkdir -p "$(dirname "$snapshot_path")"
  cp "$source_path" "$snapshot_path"
done

cd "$REPO_ROOT"
xcodebuild build-for-testing \
  -project Steno.xcodeproj \
  -scheme Steno \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

for relative_path in "${SOURCE_PATHS[@]}"; do
  if ! cmp -s "$REPO_ROOT/$relative_path" "$SOURCE_SNAPSHOT/$relative_path"; then
    echo "Hosted source changed while the test bundle was built: $relative_path" >&2
    exit 3
  fi
done

shopt -s nullglob
XCTEST_RUN_FILES=("$DERIVED_DATA"/Build/Products/*.xctestrun)
if (( ${#XCTEST_RUN_FILES[@]} != 1 )); then
  echo "Expected exactly one generated xctestrun file" >&2
  exit 3
fi
XCTEST_RUN_FILE="${XCTEST_RUN_FILES[0]}"

plutil -insert StenoTests.EnvironmentVariables.STENO_LIVE_CONTEXT_SOURCE_ROOT \
  -string "$SOURCE_SNAPSHOT" "$XCTEST_RUN_FILE"
plutil -insert StenoTests.EnvironmentVariables.STENO_LIVE_CONTEXT_HOSTED_RECEIPT \
  -string "$RECEIPT_PATH" "$XCTEST_RUN_FILE"
plutil -insert StenoTests.EnvironmentVariables.STENO_LIVE_CONTEXT_TRIAL_COUNT \
  -string "$TRIAL_COUNT" "$XCTEST_RUN_FILE"
plutil -insert StenoTests.EnvironmentVariables.STENO_LIVE_CONTEXT_LANGUAGE \
  -string "$LANGUAGE" "$XCTEST_RUN_FILE"
plutil -insert StenoTests.EnvironmentVariables.STENO_LIVE_CONTEXT_GIT_SHA \
  -string "$GIT_SHA" "$XCTEST_RUN_FILE"
plutil -insert StenoTests.EnvironmentVariables.STENO_LIVE_CONTEXT_TREE_DIRTY \
  -string "$TREE_IS_DIRTY" "$XCTEST_RUN_FILE"
plutil -insert StenoTests.EnvironmentVariables.STENO_LIVE_CONTEXT_NETWORK_CONTROL_DIR \
  -string "$CONTROL_DIRECTORY" "$XCTEST_RUN_FILE"

mkdir -p "$CONTROL_DIRECTORY"
ruby "$SCRIPT_DIR/live-context-hosted-network-monitor.rb" \
  "$CONTROL_DIRECTORY" "$NETWORK_MONITOR_SUMMARY" &
NETWORK_MONITOR_PID=$!

set +e
xcodebuild test-without-building \
  -xctestrun "$XCTEST_RUN_FILE" \
  -destination 'platform=macOS' \
  -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:StenoTests/LiveContextHostedEvidenceTests
TEST_STATUS=$?
set -e

ruby -e 'File.binwrite(ARGV.fetch(0), "aborted\n")' "$CONTROL_DIRECTORY/abort"
set +e
wait "$NETWORK_MONITOR_PID"
NETWORK_MONITOR_STATUS=$?
set -e

if (( TEST_STATUS != 0 )); then
  echo "Hosted test failed before receipt finalization" >&2
  exit "$TEST_STATUS"
fi
if (( NETWORK_MONITOR_STATUS != 0 )); then
  echo "Hosted process network observation failed" >&2
  exit 5
fi

if [[ ! -s "$RECEIPT_PATH" ]]; then
  echo "Hosted test completed without writing a receipt" >&2
  exit 4
fi

ruby "$SCRIPT_DIR/finalize-live-context-hosted-receipt.rb" \
  "$RESULT_BUNDLE" "$RECEIPT_PATH" "$NETWORK_MONITOR_SUMMARY" \
  "$GIT_SHA" "$ATTESTATION_EXPORT"

echo "Hosted evidence receipt: $RECEIPT_PATH"
