#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release-dmg.sh [--skip-notarize]

Build a self-contained Steno.app, bundle whisper.cpp runtime assets into it,
sign it for distribution, package it into a DMG, and optionally notarize it.

Environment:
  STENO_DIST_SIGN_IDENTITY       Optional. Signing identity to use.
                                 Default: auto-detect a single "Developer ID Application" identity.
  STENO_NOTARY_PROFILE           Required unless --skip-notarize is used.
                                 Name of a keychain profile previously stored with:
                                 xcrun notarytool store-credentials ...
  STENO_BUNDLED_WHISPER_ROOT     Optional. Root of a built whisper.cpp checkout.
                                 Default: auto-detect local vendor roots.
  STENO_BUNDLED_MODEL_PATH       Optional. Canonical model file to bundle.
                                 Default: prefer small.en, then base.en, medium.en, large-v3-turbo.
  STENO_BUNDLED_VAD_MODEL_PATH   Optional. VAD model path.
                                 Default: derive ggml-silero-v6.2.0.bin next to the chosen model.
  STENO_RELEASE_ALLOW_DIRTY      Optional. Set to 1 to bypass the clean-worktree
                                 guard while iterating on the packaging script.

Examples:
  scripts/release-dmg.sh

  STENO_NOTARY_PROFILE=StenoNotary scripts/release-dmg.sh

  STENO_DIST_SIGN_IDENTITY="Apple Development: name@example.com (TEAMID)" \
  scripts/release-dmg.sh --skip-notarize
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  local label="$2"
  [[ -n "$path" ]] || die "$label is required."
  [[ -f "$path" ]] || die "$label not found at: $path"
}

require_dir() {
  local path="$1"
  local label="$2"
  [[ -n "$path" ]] || die "$label is required."
  [[ -d "$path" ]] || die "$label directory not found at: $path"
}

SKIP_NOTARIZE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/build/distribution"
DERIVED_DATA="$DIST_DIR/DerivedData"
UNSIGNED_APP="$DIST_DIR/Steno.app"
STAGING_DIR="$DIST_DIR/dmg-stage"
APP_NAME="Steno"
APP_VOLUME_NAME="Steno"
DIST_ENTITLEMENTS="$REPO_ROOT/Steno/StenoDistribution.entitlements"
FRAMEWORKS_SUBDIR="Contents/Frameworks"
HELPERS_SUBDIR="Contents/Helpers"
MODELS_SUBDIR="Contents/Resources/WhisperModels"

mkdir -p "$DIST_DIR"
rm -rf "$DERIVED_DATA" "$UNSIGNED_APP" "$STAGING_DIR"

detect_identity() {
  if [[ -n "${STENO_DIST_SIGN_IDENTITY:-}" ]]; then
    echo "$STENO_DIST_SIGN_IDENTITY"
    return
  fi

  local identities=()
  local line
  while IFS= read -r line; do
    identities+=("$line")
  done < <(security find-identity -p codesigning -v | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')

  if [[ "${#identities[@]}" -eq 1 ]]; then
    echo "${identities[0]}"
    return
  fi

  if [[ "${#identities[@]}" -eq 0 ]]; then
    die "No Developer ID Application identity found. Install one in Keychain or set STENO_DIST_SIGN_IDENTITY."
  fi

  die "Multiple Developer ID Application identities found. Set STENO_DIST_SIGN_IDENTITY explicitly."
}

detect_whisper_root() {
  if [[ -n "${STENO_BUNDLED_WHISPER_ROOT:-}" ]]; then
    echo "$STENO_BUNDLED_WHISPER_ROOT"
    return
  fi

  local candidates=(
    "$REPO_ROOT/vendor/whisper.cpp"
    "$REPO_ROOT/../Steno/vendor/whisper.cpp"
    "$HOME/vendor/whisper.cpp"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate/build/bin/whisper-cli" ]]; then
      echo "$candidate"
      return
    fi
  done

  die "Could not detect a built whisper.cpp root. Set STENO_BUNDLED_WHISPER_ROOT."
}

detect_model_path() {
  if [[ -n "${STENO_BUNDLED_MODEL_PATH:-}" ]]; then
    echo "$STENO_BUNDLED_MODEL_PATH"
    return
  fi

  local root="$1"
  local models=(
    "$root/models/ggml-small.en.bin"
    "$root/models/ggml-base.en.bin"
    "$root/models/ggml-medium.en.bin"
    "$root/models/ggml-large-v3-turbo.bin"
  )

  local model
  for model in "${models[@]}"; do
    if [[ -f "$model" ]]; then
      echo "$model"
      return
    fi
  done

  die "Could not detect a canonical model to bundle. Set STENO_BUNDLED_MODEL_PATH."
}

detect_vad_path() {
  if [[ -n "${STENO_BUNDLED_VAD_MODEL_PATH:-}" ]]; then
    echo "$STENO_BUNDLED_VAD_MODEL_PATH"
    return
  fi

  local model_path="$1"
  local model_dir
  model_dir="$(cd "$(dirname "$model_path")" && pwd)"
  echo "$model_dir/ggml-silero-v6.2.0.bin"
}

require_clean_worktree() {
  if [[ "${STENO_RELEASE_ALLOW_DIRTY:-0}" == "1" ]]; then
    return
  fi

  local status
  status="$(git -C "$REPO_ROOT" status --porcelain)"
  [[ -z "$status" ]] || die "Working tree must be clean before packaging. Commit or stash changes first."
}

remove_rpaths() {
  local binary="$1"
  local path
  while IFS= read -r path; do
    install_name_tool -delete_rpath "$path" "$binary" 2>/dev/null || true
  done < <(otool -l "$binary" | awk '/LC_RPATH/{getline; getline; if ($1 == "path") print $2}')
}

add_rpath() {
  local binary="$1"
  local path="$2"
  install_name_tool -add_rpath "$path" "$binary" || die "Failed adding rpath $path to $binary"
}

patch_runtime_rpaths() {
  local app_path="$1"
  local helper="$app_path/$HELPERS_SUBDIR/whisper-cli"
  local frameworks_dir="$app_path/$FRAMEWORKS_SUBDIR"

  require_file "$helper" "Bundled whisper helper"
  remove_rpaths "$helper"
  add_rpath "$helper" "@executable_path/../Frameworks"

  local dylib
  local dylib_count=0
  while IFS= read -r -d '' dylib; do
    dylib_count=$((dylib_count + 1))
    remove_rpaths "$dylib"
    add_rpath "$dylib" "@loader_path"
  done < <(find "$frameworks_dir" -maxdepth 1 -type f -name '*.dylib' -print0)

  [[ "$dylib_count" -gt 0 ]] || die "No regular dylibs found in $frameworks_dir to patch."
}

copy_matching_entries() {
  local src_dir="$1"
  local pattern="$2"
  local dest_dir="$3"
  local matches=()
  local file
  while IFS= read -r -d '' file; do
    matches+=("$file")
  done < <(find "$src_dir" -maxdepth 1 \( -type f -o -type l \) -name "$pattern" -print0)

  [[ "${#matches[@]}" -gt 0 ]] || die "No matches for $pattern in $src_dir"
  rsync -a "${matches[@]}" "$dest_dir/"
}

copy_runtime() {
  local whisper_root="$1"
  local model_path="$2"
  local vad_path="$3"
  local app_path="$4"
  local helpers_dir="$app_path/$HELPERS_SUBDIR"
  local frameworks_dir="$app_path/$FRAMEWORKS_SUBDIR"
  local models_dir="$app_path/$MODELS_SUBDIR"

  mkdir -p "$helpers_dir" "$frameworks_dir" "$models_dir"

  rsync -a "$whisper_root/build/bin/whisper-cli" "$helpers_dir/"
  copy_matching_entries "$whisper_root/build/src" "libwhisper*.dylib" "$frameworks_dir"
  copy_matching_entries "$whisper_root/build/ggml/src" "libggml*.dylib" "$frameworks_dir"
  copy_matching_entries "$whisper_root/build/ggml/src/ggml-blas" "libggml-blas*.dylib" "$frameworks_dir"
  copy_matching_entries "$whisper_root/build/ggml/src/ggml-metal" "libggml-metal*.dylib" "$frameworks_dir"

  ditto "$model_path" "$models_dir/$(basename "$model_path")"
  if [[ -f "$vad_path" ]]; then
    ditto "$vad_path" "$models_dir/$(basename "$vad_path")"
  fi

  require_file "$frameworks_dir/libwhisper.1.dylib" "Bundled libwhisper soname"
  require_file "$frameworks_dir/libggml.0.dylib" "Bundled libggml soname"
  require_file "$frameworks_dir/libggml-cpu.0.dylib" "Bundled libggml-cpu soname"
  require_file "$frameworks_dir/libggml-base.0.dylib" "Bundled libggml-base soname"
  require_file "$frameworks_dir/libggml-blas.0.dylib" "Bundled libggml-blas soname"
  require_file "$frameworks_dir/libggml-metal.0.dylib" "Bundled libggml-metal soname"

  patch_runtime_rpaths "$app_path"
}

is_macho() {
  file "$1" | grep -q "Mach-O"
}

sign_nested_code() {
  local app_path="$1"
  local identity="$2"

  while IFS= read -r -d '' file; do
    if is_macho "$file"; then
      codesign --force --sign "$identity" --options runtime --timestamp "$file"
    fi
  done < <(find "$app_path/Contents" -type f -print0)
}

smoke_test_bundled_runtime() {
  local app_path="$1"
  local helper="$app_path/$HELPERS_SUBDIR/whisper-cli"
  local smoke_log="$DIST_DIR/bundled-whisper-smoke.log"

  require_file "$helper" "Bundled whisper helper"

  if ! env -i HOME="$HOME" PATH="/usr/bin:/bin" "$helper" --help >"$smoke_log" 2>&1; then
    cat "$smoke_log" >&2 || true
    die "Bundled whisper helper failed to launch. See $smoke_log"
  fi
}

create_dmg() {
  local app_path="$1"
  local output_path="$2"

  mkdir -p "$STAGING_DIR"
  ditto "$app_path" "$STAGING_DIR/$APP_NAME.app"
  ln -s /Applications "$STAGING_DIR/Applications"

  hdiutil create \
    -volname "$APP_VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$output_path"

  hdiutil verify "$output_path"
}

IDENTITY="$(detect_identity)"
WHISPER_ROOT="$(detect_whisper_root)"
MODEL_PATH="$(detect_model_path "$WHISPER_ROOT")"
VAD_PATH="$(detect_vad_path "$MODEL_PATH")"
NOTARY_PROFILE="${STENO_NOTARY_PROFILE:-}"

require_dir "$WHISPER_ROOT" "STENO_BUNDLED_WHISPER_ROOT"
require_file "$WHISPER_ROOT/build/bin/whisper-cli" "Bundled whisper-cli"
require_file "$MODEL_PATH" "Bundled model"
if [[ -n "$VAD_PATH" ]]; then
  require_file "$VAD_PATH" "Bundled VAD model"
fi
require_file "$DIST_ENTITLEMENTS" "Distribution entitlements"
require_clean_worktree

if [[ "$SKIP_NOTARIZE" -eq 0 ]] && [[ -z "$NOTARY_PROFILE" ]]; then
  die "STENO_NOTARY_PROFILE is required unless --skip-notarize is used."
fi

echo "==> xcodegen generate"
(
  cd "$REPO_ROOT"
  xcodegen generate
)

echo "==> build unsigned Release app"
(
  cd "$REPO_ROOT"
  xcodebuild build \
    -project Steno.xcodeproj \
    -scheme Steno \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO
)

APP_SOURCE="$DERIVED_DATA/Build/Products/Release/Steno.app"
require_dir "$APP_SOURCE" "Built Release app"

echo "==> prepare app bundle"
ditto "$APP_SOURCE" "$UNSIGNED_APP"
copy_runtime "$WHISPER_ROOT" "$MODEL_PATH" "$VAD_PATH" "$UNSIGNED_APP"

echo "==> sign bundled runtime"
sign_nested_code "$UNSIGNED_APP" "$IDENTITY"

echo "==> sign app bundle"
codesign --force \
  --sign "$IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements "$DIST_ENTITLEMENTS" \
  "$UNSIGNED_APP"

echo "==> validate signed app"
codesign --verify --deep --strict --verbose=2 "$UNSIGNED_APP"
codesign -dvvv --entitlements :- "$UNSIGNED_APP" >/dev/null

echo "==> bundled runtime smoke test"
smoke_test_bundled_runtime "$UNSIGNED_APP"

APP_VERSION="$(defaults read "$UNSIGNED_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "0.2.0")"
DMG_PATH="$DIST_DIR/Steno-${APP_VERSION}.dmg"
rm -f "$DMG_PATH"

echo "==> create DMG"
create_dmg "$UNSIGNED_APP" "$DMG_PATH"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
  echo "DMG created without notarization:"
  echo "  App: $UNSIGNED_APP"
  echo "  DMG: $DMG_PATH"
  exit 0
fi

echo "==> notarize DMG"
NOTARY_SUBMISSION_JSON="$DIST_DIR/notary-submit.json"
NOTARY_LOG_JSON="$DIST_DIR/notary-log.json"
NOTARY_SUBMISSION_JSON_RAW="$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
printf '%s\n' "$NOTARY_SUBMISSION_JSON_RAW" > "$NOTARY_SUBMISSION_JSON"
NOTARY_SUBMISSION_ID="$(python3 - <<'PY' "$NOTARY_SUBMISSION_JSON"
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
print(payload["id"])
PY
)"
xcrun notarytool log "$NOTARY_SUBMISSION_ID" "$NOTARY_LOG_JSON" --keychain-profile "$NOTARY_PROFILE"

echo "==> staple ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "==> Gatekeeper assessment"
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"

echo "Release DMG ready:"
echo "  App: $UNSIGNED_APP"
echo "  DMG: $DMG_PATH"
