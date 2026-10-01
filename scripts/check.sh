#!/usr/bin/env bash
# Local validation for contributors and coding agents. It regenerates the Xcode
# project with the pinned XcodeGen, runs the package tests, builds the app, runs
# the hosted tests, and fails if a test helper process outlived the run.
# CI runs the same checks in its own jobs; this does not replace them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEAN=0

usage() {
  cat <<'USAGE'
Usage: scripts/check.sh [--clean]

  --clean  Discard the package build and the derived data first. Use it after a
           shared struct or enum changes shape, when an incremental build can
           compile but crash at run time.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || { echo 'Error: scripts/check.sh requires macOS.' >&2; exit 1; }
cd "$ROOT"

# Test hosts can fail to launch from protected folders such as Desktop, so the
# derived data lives under /private/tmp, one directory per checkout.
CHECKOUT_ID="$(printf '%s' "$ROOT" | shasum -a 256 | cut -c1-12)"
DERIVED_DATA="/private/tmp/steno-check-$CHECKOUT_ID/DerivedData"
SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-check-processes.XXXXXX")"

process_snapshot() {
  ps -A -o pid= -o command= > "$1"
}

# Processes that started during this run and look like test helpers: the
# runtime helper, the command-line engine, or a fake helper written to a
# temporary steno-* directory. Helpers inside other app bundles, such as an
# installed or locally running Steno, are ignored.
leftover_helpers() {
  python3 - "$SNAPSHOT_DIR/before.txt" "$SNAPSHOT_DIR/after.txt" "$$" "$DERIVED_DATA" <<'PY'
import re
import sys
from pathlib import Path

def processes(path):
    rows = {}
    for line in Path(path).read_text(errors='replace').splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit():
            rows[int(fields[0])] = fields[1]
    return rows

before, after = processes(sys.argv[1]), processes(sys.argv[2])
helper = re.compile(r'steno-whisper-runtime|whisper-cli|fake-runtime|/(?:var/folders|private/tmp|tmp)/(?:\S*/)?steno-[^/\s]*/')
derived_data = sys.argv[4].rstrip('/') + '/'
for pid, command in sorted(after.items()):
    if before.get(pid) == command or pid == int(sys.argv[3]):
        continue
    # Judge the matching argument, not the interpreter: fake helpers are often
    # scripts run by an interpreter that itself lives in an app bundle.
    if not any(helper.search(token) and ('.app/Contents/' not in token or token.startswith(derived_data))
               for token in command.split()):
        continue
    print(f'{pid} {command[:500]}')
PY
}

check_leftovers() {
  # Give exiting helpers a moment to be reaped before judging them.
  sleep 2
  process_snapshot "$SNAPSHOT_DIR/after.txt"
  local leftovers
  leftovers="$(leftover_helpers)"
  if [[ -n "$leftovers" ]]; then
    echo 'Error: test helper processes were left running:' >&2
    echo "$leftovers" >&2
    echo 'Find the test that started them; this script does not stop them.' >&2
    return 1
  fi
  echo 'No test helper processes were left running.'
}

LEFTOVERS_CHECKED=0
finish() {
  local status=$?
  trap - EXIT
  # A failed step can also strand helpers; report them as well.
  if [[ "$LEFTOVERS_CHECKED" -eq 0 && -f "$SNAPSHOT_DIR/before.txt" ]]; then
    check_leftovers || status=1
  fi
  rm -rf "$SNAPSHOT_DIR"
  exit "$status"
}
trap finish EXIT
process_snapshot "$SNAPSHOT_DIR/before.txt"

echo '==> Regenerate Steno.xcodeproj with the pinned XcodeGen'
PINNED_XCODEGEN="$(sed -n 's#.*XcodeGen/releases/download/\([0-9.]*\)/xcodegen.zip#\1#p' scripts/ci/tools.sh)"
XCODEGEN="$ROOT/build/ci-tools/xcodegen/xcodegen/bin/xcodegen"
if [[ ! -x "$XCODEGEN" || "$("$XCODEGEN" --version 2>/dev/null)" != *"$PINNED_XCODEGEN"* ]]; then
  bash scripts/ci/tools.sh xcodegen
fi
"$XCODEGEN" generate --quiet
# A stale project silently skips test files added since it was generated.
python3 - <<'PY'
from pathlib import Path
project = Path('Steno.xcodeproj/project.pbxproj').read_text()
missing = [str(path) for path in sorted(Path('StenoTests').rglob('*.swift'))
           if f'/* {path.name} in Sources */' not in project]
if missing:
    raise SystemExit('Error: hosted test sources missing from the generated project: ' + ', '.join(missing))
PY

if [[ "$CLEAN" -eq 1 ]]; then
  echo '==> Discard the package build and derived data'
  swift package --package-path StenoKit clean
  rm -rf "/private/tmp/steno-check-$CHECKOUT_ID"
fi

echo '==> Package tests'
swift test --package-path StenoKit

echo '==> Build the app'
xcodebuild build -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO

echo '==> Hosted tests'
xcodebuild test -project Steno.xcodeproj -scheme Steno -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO

LEFTOVERS_CHECKED=1
check_leftovers
echo 'All local checks passed.'
