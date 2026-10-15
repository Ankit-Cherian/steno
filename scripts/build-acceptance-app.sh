#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-acceptance-app.sh <output-directory>

Build "Steno Acceptance.app" for live acceptance runs: the Acceptance build
configuration (its own bundle identifier, its own Application Support folder,
no launch at login), with the whisper.cpp runtime and one speech model bundled
in, signed ad hoc. The app is written to <output-directory> and is neither
installed nor opened.

The output directory must not exist, and must be outside this repository.

Environment:
  STENO_BUNDLED_WHISPER_ROOT   Optional. A whisper.cpp checkout, read only.
                               Default: auto-detect local vendor roots.
  STENO_BUNDLED_MODEL_PATH     Optional. The model to bundle. Default: small.en.
  STENO_BUNDLED_VAD_MODEL_PATH Optional. Default: ggml-silero-v6.2.0.bin next to the model.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

[[ $# -eq 1 && "$1" != -* ]] || { usage; exit 64; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$1"
[[ "$OUT" = /* ]] || die "The output directory must be an absolute path."
[[ ! -e "$OUT" ]] || die "The output directory already exists: $OUT"
case "$OUT/" in
  "$REPO_ROOT"/*) die "The output directory must be outside the repository." ;;
esac
[[ "$(uname -m)" == "arm64" ]] || die "The runtime is built for Apple silicon only."

APP_NAME="Steno Acceptance"
BUNDLE_ID="io.stenoapp.steno.acceptance"
ENTITLEMENTS="$REPO_ROOT/Steno/StenoDistribution.entitlements"
[[ -f "$ENTITLEMENTS" ]] || die "Missing entitlements file."

detect_whisper_root() {
  if [[ -n "${STENO_BUNDLED_WHISPER_ROOT:-}" ]]; then
    echo "$STENO_BUNDLED_WHISPER_ROOT"
    return
  fi
  local candidate
  for candidate in "$REPO_ROOT/vendor/whisper.cpp" "$REPO_ROOT/../Steno/vendor/whisper.cpp" "$HOME/vendor/whisper.cpp"; do
    if [[ -f "$candidate/CMakeLists.txt" && -f "$candidate/include/whisper.h" ]]; then
      echo "$candidate"
      return
    fi
  done
  die "Could not find a whisper.cpp checkout. Set STENO_BUNDLED_WHISPER_ROOT."
}

WHISPER_ROOT="$(detect_whisper_root)"
MODEL_PATH="${STENO_BUNDLED_MODEL_PATH:-$WHISPER_ROOT/models/ggml-small.en.bin}"
VAD_PATH="${STENO_BUNDLED_VAD_MODEL_PATH:-$(dirname "$MODEL_PATH")/ggml-silero-v6.2.0.bin}"
[[ -f "$MODEL_PATH" ]] || die "Model not found at $MODEL_PATH."
[[ -f "$VAD_PATH" ]] || die "Voice-detection model not found at $VAD_PATH."

mkdir -p "$OUT"
WHISPER_BUILD_DIR="$OUT/whisper-build"
DERIVED_DATA="$OUT/DerivedData"
APP="$OUT/$APP_NAME.app"

echo "==> build the whisper runtime into the output directory"
STENO_WHISPER_ROOT="$WHISPER_ROOT" \
STENO_WHISPER_BUILD_DIR="$WHISPER_BUILD_DIR" \
  "$SCRIPT_DIR/build-whisper-runtime-helper.sh" >"$OUT/whisper-build.log" 2>&1 \
  || { tail -20 "$OUT/whisper-build.log" >&2; die "Runtime build failed. See $OUT/whisper-build.log"; }

echo "==> xcodegen generate"
(cd "$REPO_ROOT" && xcodegen generate >/dev/null)

echo "==> build the Acceptance configuration"
(
  cd "$REPO_ROOT"
  xcodebuild build \
    -project Steno.xcodeproj \
    -scheme Steno \
    -configuration Acceptance \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO
) >"$OUT/xcodebuild.log" 2>&1 || { tail -20 "$OUT/xcodebuild.log" >&2; die "Build failed. See $OUT/xcodebuild.log"; }

BUILT="$DERIVED_DATA/Build/Products/Acceptance/$APP_NAME.app"
[[ -d "$BUILT" ]] || die "Built app not found at $BUILT"
ditto "$BUILT" "$APP"

echo "==> bundle the runtime and model"
HELPERS="$APP/Contents/Helpers"
FRAMEWORKS="$APP/Contents/Frameworks"
MODELS="$APP/Contents/Resources/WhisperModels"
mkdir -p "$HELPERS" "$FRAMEWORKS" "$MODELS"
rsync -a "$WHISPER_BUILD_DIR/bin/whisper-cli" "$WHISPER_BUILD_DIR/bin/steno-whisper-runtime" "$HELPERS/"
find "$WHISPER_BUILD_DIR/src" -maxdepth 1 \( -type f -o -type l \) -name 'libwhisper*.dylib' -exec rsync -a {} "$FRAMEWORKS/" \;
find "$WHISPER_BUILD_DIR/ggml/src" -maxdepth 1 \( -type f -o -type l \) -name 'libggml*.dylib' -exec rsync -a {} "$FRAMEWORKS/" \;
find "$WHISPER_BUILD_DIR/ggml/src/ggml-metal" -maxdepth 1 \( -type f -o -type l \) -name 'libggml-metal*.dylib' -exec rsync -a {} "$FRAMEWORKS/" \;
ditto "$MODEL_PATH" "$MODELS/$(basename "$MODEL_PATH")"
ditto "$VAD_PATH" "$MODELS/$(basename "$VAD_PATH")"
for required in libwhisper.1.dylib libggml.0.dylib libggml-cpu.0.dylib libggml-base.0.dylib libggml-metal.0.dylib; do
  [[ -e "$FRAMEWORKS/$required" ]] || die "Missing bundled library $required."
done

remove_rpaths() {
  local binary="$1" path
  while IFS= read -r path; do
    install_name_tool -delete_rpath "$path" "$binary" 2>/dev/null || true
  done < <(otool -l "$binary" | awk '/LC_RPATH/{getline; getline; if ($1 == "path") print $2}')
}
for helper in "$HELPERS/whisper-cli" "$HELPERS/steno-whisper-runtime"; do
  remove_rpaths "$helper"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$helper"
done
while IFS= read -r -d '' dylib; do
  remove_rpaths "$dylib"
  install_name_tool -add_rpath "@loader_path" "$dylib"
done < <(find "$FRAMEWORKS" -maxdepth 1 -type f -name '*.dylib' -print0)

echo "==> sign ad hoc"
while IFS= read -r -d '' file; do
  if file "$file" | grep -q "Mach-O"; then
    codesign --force --sign - --timestamp=none "$file"
  fi
done < <(find "$APP/Contents" -type f -print0)
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> check the bundle"
[[ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || die "Unexpected bundle identifier."
"$HELPERS/whisper-cli" --help >/dev/null 2>&1 || die "The bundled whisper-cli does not start."

COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
DIRTY="$(git -C "$REPO_ROOT" status --porcelain | wc -l | tr -d ' ')"
cat >"$OUT/build-manifest.json" <<JSON
{
  "app": "$APP",
  "bundle_identifier": "$BUNDLE_ID",
  "configuration": "Acceptance",
  "source_head": "$COMMIT",
  "uncommitted_paths": $DIRTY,
  "signature": "ad hoc",
  "executable_sha256": "$(shasum -a 256 "$APP/Contents/MacOS/$APP_NAME" | cut -d' ' -f1)",
  "bundled_model": "$(basename "$MODEL_PATH")"
}
JSON

echo "Built (not installed, not opened): $APP"
