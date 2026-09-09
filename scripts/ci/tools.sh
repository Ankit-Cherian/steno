#!/usr/bin/env bash
# Download only reviewed tool archives into an isolated build directory.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tool="${1:?Usage: tools.sh actionlint|xcodegen}"
case "$tool:$(uname -s):$(uname -m)" in
  xcodegen:Darwin:arm64)
    url=https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip
    digest=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
    format=zip ;;
  actionlint:Darwin:arm64)
    url=https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz
    digest=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
    format=tar ;;
  actionlint:Linux:x86_64)
    url=https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz
    digest=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
    format=tar ;;
  *) echo 'Unsupported tool or platform' >&2; exit 1 ;;
esac
mkdir -p "$root/build/ci-tools"
archive="$(mktemp "$root/build/ci-tools/download.XXXXXX")"
trap 'rm -f "$archive"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$url" -o "$archive"
python3 - "$archive" "$digest" <<'PY'
import hashlib, pathlib, sys
actual = hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()
if actual != sys.argv[2]:
    raise SystemExit('Tool archive checksum mismatch; refusing extraction')
PY
destination="$root/build/ci-tools/$tool"
mkdir -p "$destination"
if [[ "$format" == zip ]]; then
  unzip -q -o "$archive" -d "$destination"
else
  tar -xzf "$archive" -C "$destination" actionlint
fi
