#!/usr/bin/env bash
# Run only on an ephemeral macOS runner after the release environment approval.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for name in APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_NOTARY_KEY_P8_BASE64 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID RUNNER_TEMP RELEASE_VERSION RELEASE_SHA; do
  [[ -n "${!name:-}" ]] || { echo "Missing required release configuration: $name" >&2; exit 1; }
done
[[ "$APPLE_SIGNING_IDENTITY" == "Developer ID Application: "* ]] || { echo 'A Developer ID Application identity is required.' >&2; exit 1; }
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid signing team identifier.' >&2; exit 1; }
[[ "$APPLE_SIGNING_IDENTITY" == *"($APPLE_TEAM_ID)" ]] || { echo 'Signing identity does not match configured team.' >&2; exit 1; }
PRIVATE_DIR="$(mktemp -d "$RUNNER_TEMP/steno-signing.XXXXXX")"
KEYCHAIN="$PRIVATE_DIR/release.keychain-db"
cleanup() {
  local status=$?
  trap - EXIT
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$PRIVATE_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export STENO_NOTARY_KEY_PATH="$PRIVATE_DIR/AuthKey.p8"
export STENO_NOTARY_KEY_ID="$APPLE_NOTARY_KEY_ID"
export STENO_NOTARY_ISSUER_ID="$APPLE_NOTARY_ISSUER_ID"
export STENO_DIST_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY"
export STENO_SIGNING_KEYCHAIN="$KEYCHAIN"
SIGNING_TEAM="$APPLE_TEAM_ID"
export PRIVATE_DIR
python3 - <<'PY'
import base64
import os
from pathlib import Path
root = Path(os.environ['PRIVATE_DIR'])
for variable, name in [('APPLE_CERTIFICATE_P12_BASE64', 'certificate.p12'),
                       ('APPLE_NOTARY_KEY_P8_BASE64', 'AuthKey.p8')]:
    # base64 -i file | tr -d '\n' produces the expected secret format.
    (root / name).write_bytes(base64.b64decode(os.environ[variable], validate=True))
PY
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$PRIVATE_DIR/certificate.p12" -k "$KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
rm "$PRIVATE_DIR/certificate.p12"
unset APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_NOTARY_KEY_P8_BASE64 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID KEYCHAIN_PASSWORD PRIVATE_DIR
# Keep the cleanup directory in a shell variable without passing it to children.
PRIVATE_DIR="$(dirname "$KEYCHAIN")"
export STENO_DIST_DIR="$RUNNER_TEMP/steno-release-distribution"
export STENO_BUNDLED_WHISPER_ROOT="$RUNNER_TEMP/steno-release-runtime"
export STENO_BUNDLED_WHISPER_BUILD_DIR="$RUNNER_TEMP/steno-release-runtime-build"
export STENO_BUNDLED_MODEL_PATH="$STENO_BUNDLED_WHISPER_ROOT/models/ggml-small.en.bin"
export STENO_BUNDLED_VAD_MODEL_PATH="$STENO_BUNDLED_WHISPER_ROOT/models/ggml-silero-v6.2.0.bin"
bash "$ROOT/scripts/release-dmg.sh"
APP="$STENO_DIST_DIR/Steno.app"
[[ "$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$SIGNING_TEAM" ]] || { echo 'Unexpected app signing team.' >&2; exit 1; }
codesign -dv "$APP" 2>&1 | grep 'flags=.*runtime' >/dev/null
codesign -d --entitlements :- "$APP" > "$RUNNER_TEMP/release-entitlements.plist" 2>/dev/null
python3 - "$RUNNER_TEMP/release-entitlements.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as stream:
    entitlements = plistlib.load(stream)
if entitlements.get('com.apple.security.get-task-allow'):
    raise SystemExit('Distribution must not permit debugger attachment')
PY
# Copy only the final stapled DMG and public provenance metadata. Notary receipts,
# signing material, build logs, and keychain files never enter uploaded artifacts.
mkdir "$RUNNER_TEMP/steno-release-assets"
cp "$STENO_DIST_DIR/Steno-$RELEASE_VERSION.dmg" "$RUNNER_TEMP/steno-release-assets/"
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
root = Path(os.environ['RUNNER_TEMP']) / 'steno-release-assets'
dmg = root / f"Steno-{os.environ['RELEASE_VERSION']}.dmg"
sha = hashlib.file_digest(dmg.open('rb'), 'sha256').hexdigest()
(root / 'SHA256SUMS').write_text(f'{sha}  {dmg.name}\n')
(root / 'release-manifest.json').write_text(json.dumps({
    'version': os.environ['RELEASE_VERSION'], 'source_sha': os.environ['RELEASE_SHA'],
    'tag': 'v' + os.environ['RELEASE_VERSION'], 'asset': dmg.name, 'sha256': sha,
    'architecture': 'arm64', 'minimum_macos': '13.0', 'notarized': True,
    'workflow_run': f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
}, indent=2) + '\n')
PY
