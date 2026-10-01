#!/usr/bin/env bash
# Rehearse the release credential steps without building, notarizing or uploading.
# The keychain and probe steps below repeat scripts/ci/release-sign.sh, which
# cannot run them alone; a test keeps the two copies identical.
set -euo pipefail
umask 077
for name in APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_NOTARY_KEY_P8_BASE64 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID RUNNER_TEMP; do
  [[ -n "${!name:-}" ]] || { echo "Missing required release configuration: $name" >&2; exit 1; }
done
[[ "$APPLE_SIGNING_IDENTITY" == "Developer ID Application: "* ]] || { echo 'A Developer ID Application identity is required.' >&2; exit 1; }
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid signing team identifier.' >&2; exit 1; }
[[ "$APPLE_SIGNING_IDENTITY" == *"($APPLE_TEAM_ID)" ]] || { echo 'Signing identity does not match configured team.' >&2; exit 1; }
PRIVATE_DIR="$(mktemp -d "$RUNNER_TEMP/steno-signing.XXXXXX")"
KEYCHAIN="$PRIVATE_DIR/release.keychain-db"
ORIGINAL_KEYCHAINS=()
RESTORE_SEARCH_LIST=0
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$RESTORE_SEARCH_LIST" -eq 1 ]]; then
    security list-keychains -d user -s ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"} >/dev/null 2>&1 || status=1
  fi
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$PRIVATE_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# codesign --keychain limits identity lookup; chain building uses this search list.
security list-keychains -d user > "$PRIVATE_DIR/original-keychains.txt"
python3 - "$PRIVATE_DIR/original-keychains.txt" > "$PRIVATE_DIR/original-keychains.nul" <<'KEYCHAINS'
import shlex
import sys
from pathlib import Path
for path in shlex.split(Path(sys.argv[1]).read_text()):
    sys.stdout.buffer.write(path.encode() + b'\0')
KEYCHAINS
ORIGINAL_KEYCHAINS=()
while IFS= read -r -d '' keychain_path; do
  ORIGINAL_KEYCHAINS+=("$keychain_path")
done < "$PRIVATE_DIR/original-keychains.nul"
RESTORE_SEARCH_LIST=1
NOTARY_KEY="$PRIVATE_DIR/AuthKey.p8"
NOTARY_KEY_ID="$APPLE_NOTARY_KEY_ID"
NOTARY_ISSUER_ID="$APPLE_NOTARY_ISSUER_ID"
export STENO_DIST_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY"
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
security import "$PRIVATE_DIR/certificate.p12" -f pkcs12 -k "$KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"}
rm "$PRIVATE_DIR/certificate.p12"
unset APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_NOTARY_KEY_P8_BASE64 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID KEYCHAIN_PASSWORD PRIVATE_DIR
# Keep the cleanup directory in a shell variable without passing it to children.
PRIVATE_DIR="$(dirname "$KEYCHAIN")"
# Fail before the app build if the imported identity cannot actually sign code.
security find-identity -v -p codesigning "$KEYCHAIN" > "$PRIVATE_DIR/valid-identities.txt"
python3 - "$PRIVATE_DIR/valid-identities.txt" <<'IDENTITY'
import os
import re
import sys
from pathlib import Path
identities = re.findall(r'^\s*\d+\) [A-Fa-f0-9]{40} "([^"\n]+)"\s*$', Path(sys.argv[1]).read_text(), re.M)
if identities.count(os.environ['STENO_DIST_SIGN_IDENTITY']) != 1:
    raise SystemExit('The configured Developer ID identity is not uniquely valid in the signing keychain')
IDENTITY
printf 'int main(void) { return 0; }\n' > "$PRIVATE_DIR/signing-probe.c"
xcrun clang "$PRIVATE_DIR/signing-probe.c" -o "$PRIVATE_DIR/signing-probe"
codesign --force --sign "$STENO_DIST_SIGN_IDENTITY" --options runtime --timestamp --keychain "$KEYCHAIN" "$PRIVATE_DIR/signing-probe"
codesign --verify --strict --verbose=2 "$PRIVATE_DIR/signing-probe"
[[ "$(codesign -dv "$PRIVATE_DIR/signing-probe" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$SIGNING_TEAM" ]] || { echo 'Unexpected preflight signing team.' >&2; exit 1; }
echo 'Signing preflight passed.'

# The bundled runtime is a set of dynamic libraries; sign one the same way.
printf 'int steno_rehearsal_probe(void) { return 0; }\n' > "$PRIVATE_DIR/library-probe.c"
xcrun clang -dynamiclib "$PRIVATE_DIR/library-probe.c" -o "$PRIVATE_DIR/library-probe.dylib"
codesign --force --sign "$STENO_DIST_SIGN_IDENTITY" --options runtime --timestamp --keychain "$KEYCHAIN" "$PRIVATE_DIR/library-probe.dylib"
codesign --verify --strict --verbose=2 "$PRIVATE_DIR/library-probe.dylib"
echo 'Library signing passed.'

# A read-only request proves the notary credentials. Submission history is
# account data, so only the count leaves this private directory.
xcrun notarytool history --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
  --output-format json > "$PRIVATE_DIR/notary-history.json" 2>"$PRIVATE_DIR/notary-history.log" \
  || { echo 'The notary service rejected the configured credentials.' >&2; exit 1; }
python3 - "$PRIVATE_DIR/notary-history.json" <<'HISTORY'
import json
import sys
from pathlib import Path
history = json.loads(Path(sys.argv[1]).read_text()).get('history')
if not isinstance(history, list):
    raise SystemExit('Unexpected notary history response')
print(f'Notary credentials accepted; {len(history)} earlier submissions are visible.')
HISTORY
echo 'Signing rehearsal passed. Nothing was built, notarized or uploaded.'
