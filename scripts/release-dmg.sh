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
                                 Default: prefer large-v3-turbo, then medium.en, small.en, base.en.
  STENO_BUNDLED_VAD_MODEL_PATH   Optional. VAD model path.
                                 Default: derive ggml-silero-v6.2.0.bin next to the chosen model.

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
    "$root/models/ggml-large-v3-turbo.bin"
    "$root/models/ggml-medium.en.bin"
    "$root/models/ggml-small.en.bin"
    "$root/models/ggml-base.en.bin"
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
  install_name_tool -add_rpath "$path" "$binary" 2>/dev/null || true
}

patch_runtime_rpaths() {
  local runtime_root="$1"
  local cli="$runtime_root/build/bin/whisper-cli"
  local whisper_dylib="$runtime_root/build/src/libwhisper.1.8.3.dylib"
  local ggml="$runtime_root/build/ggml/src/libggml.0.9.6.dylib"
  local ggml_cpu="$runtime_root/build/ggml/src/libggml-cpu.0.9.6.dylib"
  local ggml_blas="$runtime_root/build/ggml/src/ggml-blas/libggml-blas.0.9.6.dylib"
  local ggml_metal="$runtime_root/build/ggml/src/ggml-metal/libggml-metal.0.9.6.dylib"

  remove_rpaths "$cli"
  add_rpath "$cli" "@executable_path/../src"
  add_rpath "$cli" "@executable_path/../ggml/src"
  add_rpath "$cli" "@executable_path/../ggml/src/ggml-blas"
  add_rpath "$cli" "@executable_path/../ggml/src/ggml-metal"

  remove_rpaths "$whisper_dylib"
  add_rpath "$whisper_dylib" "@loader_path/../ggml/src"
  add_rpath "$whisper_dylib" "@loader_path/../ggml/src/ggml-blas"
  add_rpath "$whisper_dylib" "@loader_path/../ggml/src/ggml-metal"

  remove_rpaths "$ggml"
  add_rpath "$ggml" "@loader_path"
  add_rpath "$ggml" "@loader_path/ggml-blas"
  add_rpath "$ggml" "@loader_path/ggml-metal"

  remove_rpaths "$ggml_cpu"
  add_rpath "$ggml_cpu" "@loader_path"

  remove_rpaths "$ggml_blas"
  add_rpath "$ggml_blas" "@loader_path/.."

  remove_rpaths "$ggml_metal"
  add_rpath "$ggml_metal" "@loader_path/.."
}

copy_runtime() {
  local whisper_root="$1"
  local model_path="$2"
  local vad_path="$3"
  local app_path="$4"
  local runtime_root="$app_path/Contents/Resources/Runtime/whisper.cpp"

  mkdir -p \
    "$runtime_root/build/bin" \
    "$runtime_root/build/src" \
    "$runtime_root/build/ggml/src" \
    "$runtime_root/build/ggml/src/ggml-blas" \
    "$runtime_root/build/ggml/src/ggml-metal" \
    "$runtime_root/models"

  ditto "$whisper_root/build/bin/whisper-cli" "$runtime_root/build/bin/whisper-cli"

  while IFS= read -r -d '' file; do
    ditto "$file" "$runtime_root/build/src/$(basename "$file")"
  done < <(find "$whisper_root/build/src" -maxdepth 1 -type f -name 'libwhisper*.dylib' -print0)

  while IFS= read -r -d '' file; do
    ditto "$file" "$runtime_root/build/ggml/src/$(basename "$file")"
  done < <(find "$whisper_root/build/ggml/src" -maxdepth 1 -type f -name 'libggml*.dylib' -print0)

  while IFS= read -r -d '' file; do
    ditto "$file" "$runtime_root/build/ggml/src/ggml-blas/$(basename "$file")"
  done < <(find "$whisper_root/build/ggml/src/ggml-blas" -maxdepth 1 -type f -name 'libggml-blas*.dylib' -print0)

  while IFS= read -r -d '' file; do
    ditto "$file" "$runtime_root/build/ggml/src/ggml-metal/$(basename "$file")"
  done < <(find "$whisper_root/build/ggml/src/ggml-metal" -maxdepth 1 -type f -name 'libggml-metal*.dylib' -print0)

  ditto "$model_path" "$runtime_root/models/$(basename "$model_path")"
  if [[ -f "$vad_path" ]]; then
    ditto "$vad_path" "$runtime_root/models/$(basename "$vad_path")"
  fi

  patch_runtime_rpaths "$runtime_root"
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
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> staple ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "==> Gatekeeper assessment"
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"

echo "Release DMG ready:"
echo "  App: $UNSIGNED_APP"
echo "  DMG: $DMG_PATH"
