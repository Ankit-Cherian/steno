#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release-dmg.sh [--skip-notarize | --unsigned-preview]

Build a self-contained Steno.app, bundle whisper.cpp runtime assets into it,
sign it for distribution, package it into a DMG, and optionally notarize it.

--unsigned-preview creates an ad-hoc signed local/CI test artifact. It never
uses signing credentials or submits to Apple, and is not a distributable release.

Environment:
  STENO_DIST_DIR                Optional absolute, nonexistent output directory.
                                 Default: unique build/distribution-<time>-<pid>.
                                 Existing outputs and build/Steno.app are protected.
  STENO_SIGNING_KEYCHAIN        Optional dedicated keychain for signing.
  STENO_NOTARY_KEY_PATH         API key file, used with STENO_NOTARY_KEY_ID and
                                 STENO_NOTARY_ISSUER_ID instead of a stored profile.
  STENO_DIST_SIGN_IDENTITY       Optional. Developer ID Application signing identity.
                                 Default: auto-detect a single "Developer ID Application" identity.
  STENO_NOTARY_PROFILE           Required for notarization unless API key credentials
                                 are supplied through STENO_NOTARY_KEY_PATH.
                                 Name of a keychain profile previously stored with:
                                 xcrun notarytool store-credentials ...
  STENO_BUNDLED_WHISPER_ROOT     Optional. Root of a built whisper.cpp checkout.
                                 Default: auto-detect local vendor roots.
  STENO_BUNDLED_WHISPER_BUILD_DIR
                                 Optional. Canonical Steno whisper.cpp build directory.
                                 Default: <whisper-root>/build-steno.
  STENO_BUNDLED_MODEL_PATH       Optional. Canonical model file to bundle.
                                 Default: prefer small.en, then base.en, medium.en, large-v3-turbo.
  STENO_BUNDLED_VAD_MODEL_PATH   Optional. VAD model path.
                                 Default: derive ggml-silero-v6.2.0.bin next to the chosen model.
  STENO_RELEASE_ALLOW_DIRTY      Optional. Set to 1 to bypass the clean-worktree
                                 guard while iterating on the packaging script.

Examples:
  scripts/release-dmg.sh

  STENO_NOTARY_PROFILE=StenoNotary scripts/release-dmg.sh

  scripts/release-dmg.sh --unsigned-preview
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
UNSIGNED_PREVIEW=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned-preview)
      UNSIGNED_PREVIEW=1
      SKIP_NOTARIZE=1
      shift
      ;;
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
DIST_DIR="${STENO_DIST_DIR:-$REPO_ROOT/build/distribution-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
DIST_DIR="$(python3 "$SCRIPT_DIR/ci/release-guard.py" output "$DIST_DIR" --repo "$REPO_ROOT")"
DERIVED_DATA="$DIST_DIR/DerivedData"
UNSIGNED_APP="$DIST_DIR/Steno.app"
STAGING_DIR="$DIST_DIR/dmg-stage"
APP_NAME="Steno"
APP_VOLUME_NAME="Steno"
DIST_ENTITLEMENTS="$REPO_ROOT/Steno/StenoDistribution.entitlements"
FRAMEWORKS_SUBDIR="Contents/Frameworks"
HELPERS_SUBDIR="Contents/Helpers"
MODELS_SUBDIR="Contents/Resources/WhisperModels"
LEGAL_SUBDIR="Contents/Resources/Legal"
RUNTIME_DEPLOYMENT_TARGET="13.0"
RUNTIME_ARCHITECTURE="arm64"


detect_identity() {
  if [[ "$UNSIGNED_PREVIEW" -eq 1 ]]; then
    echo "-"
    return
  fi
  if [[ -n "${STENO_DIST_SIGN_IDENTITY:-}" ]]; then
    [[ "$STENO_DIST_SIGN_IDENTITY" == "Developer ID Application: "* ]] || die "Distribution requires a Developer ID Application identity."
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
    if [[ -f "$candidate/CMakeLists.txt" && -f "$candidate/include/whisper.h" ]]; then
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
    [[ "$UNSIGNED_PREVIEW" -eq 1 ]] || die "Dirty worktree bypass is allowed only for --unsigned-preview."
    return
  fi

  local status
  status="$(git -C "$REPO_ROOT" status --porcelain)"
  [[ -z "$status" ]] || die "Working tree must be clean before packaging. Use a clean release checkout or explicitly allow a local preview."
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
  local frameworks_dir="$app_path/$FRAMEWORKS_SUBDIR"

  local helper
  for helper in \
    "$app_path/$HELPERS_SUBDIR/whisper-cli" \
    "$app_path/$HELPERS_SUBDIR/steno-whisper-runtime"
  do
    require_file "$helper" "Bundled whisper helper"
    remove_rpaths "$helper"
    add_rpath "$helper" "@executable_path/../Frameworks"
  done

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
  local whisper_build_dir="$2"
  local model_path="$3"
  local vad_path="$4"
  local app_path="$5"
  local helpers_dir="$app_path/$HELPERS_SUBDIR"
  local frameworks_dir="$app_path/$FRAMEWORKS_SUBDIR"
  local models_dir="$app_path/$MODELS_SUBDIR"
  local legal_dir="$app_path/$LEGAL_SUBDIR"

  mkdir -p "$helpers_dir" "$frameworks_dir" "$models_dir" "$legal_dir"

  rsync -a "$whisper_build_dir/bin/whisper-cli" "$helpers_dir/"
  rsync -a "$whisper_build_dir/bin/steno-whisper-runtime" "$helpers_dir/"
  copy_matching_entries "$whisper_build_dir/src" "libwhisper*.dylib" "$frameworks_dir"
  copy_matching_entries "$whisper_build_dir/ggml/src" "libggml*.dylib" "$frameworks_dir"
  copy_matching_entries "$whisper_build_dir/ggml/src/ggml-metal" "libggml-metal*.dylib" "$frameworks_dir"

  ditto "$model_path" "$models_dir/$(basename "$model_path")"
  if [[ -f "$vad_path" ]]; then
    ditto "$vad_path" "$models_dir/$(basename "$vad_path")"
  fi
  ditto "$REPO_ROOT/LICENSE" "$legal_dir/Steno-LICENSE.txt"
  ditto "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$legal_dir/THIRD_PARTY_NOTICES.md"

  require_file "$frameworks_dir/libwhisper.1.dylib" "Bundled libwhisper soname"
  require_file "$frameworks_dir/libggml.0.dylib" "Bundled libggml soname"
  require_file "$frameworks_dir/libggml-cpu.0.dylib" "Bundled libggml-cpu soname"
  require_file "$frameworks_dir/libggml-base.0.dylib" "Bundled libggml-base soname"
  require_file "$frameworks_dir/libggml-metal.0.dylib" "Bundled libggml-metal soname"
  require_file "$legal_dir/Steno-LICENSE.txt" "Bundled Steno license"
  require_file "$legal_dir/THIRD_PARTY_NOTICES.md" "Bundled third-party notices"

  patch_runtime_rpaths "$app_path"
}

version_is_at_most() {
  local actual="$1"
  local maximum="$2"
  awk -v actual="$actual" -v maximum="$maximum" 'BEGIN {
    split(actual, a, "."); split(maximum, b, ".");
    for (i = 1; i <= 3; i++) {
      av = (a[i] == "" ? 0 : a[i]) + 0;
      bv = (b[i] == "" ? 0 : b[i]) + 0;
      if (av < bv) exit 0;
      if (av > bv) exit 1;
    }
    exit 0;
  }'
}

validate_runtime_macho() {
  local binary="$1"
  is_macho "$binary" || die "Expected Mach-O runtime file: $binary"

  local architectures
  architectures="$(lipo -archs "$binary")"
  [[ "$architectures" == "$RUNTIME_ARCHITECTURE" ]] \
    || die "Expected $RUNTIME_ARCHITECTURE-only runtime, found '$architectures' in $binary."

  local found_minos=0
  local minos
  while IFS= read -r minos; do
    [[ -n "$minos" ]] || continue
    found_minos=1
    version_is_at_most "$minos" "$RUNTIME_DEPLOYMENT_TARGET" \
      || die "$binary requires macOS $minos, above $RUNTIME_DEPLOYMENT_TARGET."
  done < <(vtool -show-build "$binary" | awk '$1 == "minos" { print $2 }')
  [[ "$found_minos" -eq 1 ]] || die "Could not read a deployment target from $binary."
}

validate_main_app_architecture() {
  local executable="$1"
  is_macho "$executable" || die "Expected a Mach-O app executable: $executable"

  local architectures
  architectures="$(lipo -archs "$executable")"
  case " $architectures " in
    *" $RUNTIME_ARCHITECTURE "*) ;;
    *) die "App executable does not contain required $RUNTIME_ARCHITECTURE architecture." ;;
  esac
}

validate_runtime_bundle() {
  local app_path="$1"
  local frameworks_dir="$app_path/$FRAMEWORKS_SUBDIR"
  local retained_helper="$app_path/$HELPERS_SUBDIR/steno-whisper-runtime"
  validate_main_app_architecture "$app_path/Contents/MacOS/Steno"
  local runtime_files=(
    "$app_path/$HELPERS_SUBDIR/whisper-cli"
    "$retained_helper"
  )
  local file
  while IFS= read -r -d '' file; do
    runtime_files+=("$file")
  done < <(find "$frameworks_dir" -maxdepth 1 -type f -name '*.dylib' -print0)

  for file in "${runtime_files[@]}"; do
    validate_runtime_macho "$file"
    local dependency
    while IFS= read -r dependency; do
      case "$dependency" in
        @rpath/libwhisper*.dylib|@rpath/libggml*.dylib)
          require_file "$frameworks_dir/$(basename "$dependency")" "Runtime dependency"
          ;;
        /usr/lib/*|/System/Library/*)
          ;;
        *)
          die "Bundled runtime contains an unapproved dependency: $(basename "$dependency")"
          ;;
      esac
    done < <(otool -L "$file" | tail -n +2 | awk '{ print $1 }')
  done

  if otool -L "${runtime_files[@]}" | grep -E 'libggml-(blas|rpc)' >/dev/null; then
    die "Bundled runtime unexpectedly depends on BLAS or RPC backends."
  fi
  if nm -u "$retained_helper" | grep -E ' U _?(socket|bind|listen|accept|connect)(\$|$)' >/dev/null; then
    die "Retained runtime unexpectedly imports a network-listener symbol."
  fi
}

is_macho() {
  file "$1" | grep "Mach-O" >/dev/null
}

sign_code() {
  local target="$1"
  local identity="$2"
  shift 2
  local arguments=(--force --sign "$identity")
  # Hardened library validation requires a shared Developer ID team. Ad-hoc
  # preview helpers and libraries have no team, so preview code omits runtime.
  if [[ "$UNSIGNED_PREVIEW" -eq 0 ]]; then
    arguments+=(--options runtime)
  fi
  codesign "${arguments[@]}" "${SIGNING_ARGS[@]}" "$@" "$target"
}

sign_nested_code() {
  local app_path="$1"
  local identity="$2"

  while IFS= read -r -d '' file; do
    if is_macho "$file"; then
      sign_code "$file" "$identity"
    fi
  done < <(find "$app_path/Contents" -type f -print0)
}

create_silence_wav() {
  local output="$1"
  # One second of mono 16 kHz signed 16-bit PCM. The fixture is generated in
  # the private distribution workspace so packaging never depends on research data.
  printf 'RIFF\x24\x7d\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x80\x3e\x00\x00\x00\x7d\x00\x00\x02\x00\x10\x00data\x00\x7d\x00\x00' >"$output"
  dd if=/dev/zero bs=32000 count=1 >>"$output" 2>/dev/null
  [[ "$(wc -c <"$output" | tr -d ' ')" -eq 32044 ]] \
    || die "Unable to create the bundled-runtime silence fixture."
}

smoke_test_bundled_runtime() {
  local app_path="$1"
  local helper="$app_path/$HELPERS_SUBDIR/whisper-cli"
  local retained_helper="$app_path/$HELPERS_SUBDIR/steno-whisper-runtime"
  local smoke_log="$DIST_DIR/bundled-whisper-smoke.log"
  local models_dir="$app_path/$MODELS_SUBDIR"
  local model
  local vad_model="$models_dir/ggml-silero-v6.2.0.bin"
  local fixture
  local smoke_dir
  # Hosted CI may lack a GPU. This affects only smoke execution, never the
  # bundled model, compiled Metal support, or the installed app environment.
  local smoke_environment=("HOME=$HOME" "PATH=/usr/bin:/bin")
  if [[ "${GGML_METAL_DEVICES+x}" == "x" ]]; then
    smoke_environment+=("GGML_METAL_DEVICES=$GGML_METAL_DEVICES")
  fi

  require_file "$helper" "Bundled whisper helper"
  require_file "$retained_helper" "Bundled retained whisper helper"
  model="$(find "$models_dir" -maxdepth 1 -type f -name 'ggml-*.bin' ! -name 'ggml-silero-*.bin' -print -quit)"
  require_file "$model" "Bundled Whisper model"

  smoke_dir="$(mktemp -d "$DIST_DIR/runtime-smoke.XXXXXX")"
  fixture="$smoke_dir/silence.wav"
  create_silence_wav "$fixture"

  if ! env -i "${smoke_environment[@]}" "$helper" --help >"$smoke_log" 2>&1; then
    cat "$smoke_log" >&2 || true
    die "Bundled whisper helper failed to launch. See $smoke_log"
  fi

  set +e
  env -i "${smoke_environment[@]}" "$retained_helper" --protocol-version 0 >>"$smoke_log" 2>&1
  local retained_status=$?
  set -e
  if [[ "$retained_status" -ne 64 ]]; then
    cat "$smoke_log" >&2 || true
    die "Bundled retained whisper helper failed to launch. See $smoke_log"
  fi

  local inference_args=(
    -m "$model"
    -f "$fixture"
    -l en
    -t 1
    --suppress-nst
    -oj
    -of "$smoke_dir/result"
  )
  if [[ -f "$vad_model" ]]; then
    inference_args+=(--vad --vad-model "$vad_model")
  fi
  if ! env -i "${smoke_environment[@]}" \
    "$helper" "${inference_args[@]}" >/dev/null 2>&1; then
    rm -rf "$smoke_dir"
    die "Bundled Whisper model/VAD inference smoke test failed."
  fi
  if [[ ! -s "$smoke_dir/result.json" ]]; then
    rm -rf "$smoke_dir"
    die "Bundled Whisper model/VAD inference smoke test produced no rich output."
  fi

  local retained_smoke_environment=(
    "STENO_TEST_RETAINED_HELPER=$retained_helper"
    "STENO_TEST_WHISPER_CLI=$helper"
    "STENO_TEST_WHISPER_MODEL=$model"
    "STENO_TEST_WHISPER_AUDIO=$fixture"
    "STENO_TEST_WHISPER_EXPECT_EMPTY=1"
    "STENO_TEST_WHISPER_REPETITIONS=1"
  )
  if [[ -f "$vad_model" ]]; then
    retained_smoke_environment+=("STENO_TEST_WHISPER_VAD=$vad_model")
  fi
  if ! env "${retained_smoke_environment[@]}" \
    xcrun swift test --package-path "$REPO_ROOT/StenoKit" \
      --filter retainedProcessRuntimeMatchesCLIContract >>"$smoke_log" 2>&1; then
    rm -rf "$smoke_dir"
    die "Bundled retained-runtime framed inference smoke test failed. See $smoke_log"
  fi
  rm -rf "$smoke_dir"
}

scan_distribution_hygiene() {
  local app_path="$1"
  local patterns=()
  local pattern

  patterns+=("$HOME" "$REPO_ROOT")
  [[ -n "${STENO_BUNDLED_WHISPER_ROOT:-}" ]] && patterns+=("$STENO_BUNDLED_WHISPER_ROOT")
  [[ -n "${STENO_BUNDLED_MODEL_PATH:-}" ]] && patterns+=("$STENO_BUNDLED_MODEL_PATH")
  [[ -n "${STENO_BUNDLED_VAD_MODEL_PATH:-}" ]] && patterns+=("$STENO_BUNDLED_VAD_MODEL_PATH")
  [[ -n "${STENO_BUNDLED_WHISPER_BUILD_DIR:-}" ]] && patterns+=("$STENO_BUNDLED_WHISPER_BUILD_DIR")

  local repo_leaf
  repo_leaf="$(basename "$REPO_ROOT")"
  # Product identifiers are expected in the bundle, regardless of checkout casing.
  # Absolute checkout paths remain forbidden by the patterns above.
  if [[ "$(printf '%s' "$repo_leaf" | LC_ALL=C tr '[:upper:]' '[:lower:]')" != \
        "$(printf '%s' "$APP_NAME" | LC_ALL=C tr '[:upper:]' '[:lower:]')" ]]; then
    patterns+=("$repo_leaf")
  fi
  patterns+=("Desktop/LocalProjects")

  local leaked=0
  local file
  while IFS= read -r -d '' file; do
    for pattern in "${patterns[@]}"; do
      if [[ -n "$pattern" ]] && strings -a "$file" | grep -F -- "$pattern" >/dev/null; then
        echo "Error: local build path leaked in bundle file: ${file#$app_path/}" >&2
        leaked=1
        break
      fi
    done
  done < <(find "$app_path/Contents" -type f -print0)

  [[ "$leaked" -eq 0 ]] || die "Distribution hygiene scan failed. Rebuild bundled runtime with prefix-mapped source paths."
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

sign_dmg() {
  local dmg_path="$1"
  local identity="$2"
  local identifier="$3"

  codesign --force \
    --sign "$identity" \
    "${SIGNING_ARGS[@]}" \
    -i "$identifier" \
    "$dmg_path"
  codesign --verify --verbose=2 "$dmg_path"
  codesign -dvvv "$dmg_path" >/dev/null
}

IDENTITY="$(detect_identity)"
WHISPER_ROOT="$(detect_whisper_root)"
WHISPER_BUILD_DIR="${STENO_BUNDLED_WHISPER_BUILD_DIR:-$WHISPER_ROOT/build-steno}"
MODEL_PATH="$(detect_model_path "$WHISPER_ROOT")"
VAD_PATH="$(detect_vad_path "$MODEL_PATH")"
NOTARY_PROFILE="${STENO_NOTARY_PROFILE:-}"
SIGNING_ARGS=(--timestamp)
if [[ "$UNSIGNED_PREVIEW" -eq 1 ]]; then
  SIGNING_ARGS=(--timestamp=none)
elif [[ -n "${STENO_SIGNING_KEYCHAIN:-}" ]]; then
  require_file "$STENO_SIGNING_KEYCHAIN" "Signing keychain"
  SIGNING_ARGS+=(--keychain "$STENO_SIGNING_KEYCHAIN")
fi
NOTARY_ARGS=()
if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  if [[ -n "${STENO_NOTARY_KEY_PATH:-}" ]]; then
    require_file "$STENO_NOTARY_KEY_PATH" "Notary API key"
    [[ -n "${STENO_NOTARY_KEY_ID:-}" && -n "${STENO_NOTARY_ISSUER_ID:-}" ]] || die "Notary API key ID and issuer are required."
    NOTARY_ARGS=(--key "$STENO_NOTARY_KEY_PATH" --key-id "$STENO_NOTARY_KEY_ID" --issuer "$STENO_NOTARY_ISSUER_ID")
  elif [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  else
    die "Provide a notary API key or STENO_NOTARY_PROFILE before packaging."
  fi
fi

require_dir "$WHISPER_ROOT" "STENO_BUNDLED_WHISPER_ROOT"
require_file "$MODEL_PATH" "Bundled model"
if [[ -n "$VAD_PATH" ]]; then
  require_file "$VAD_PATH" "Bundled VAD model"
fi
require_file "$DIST_ENTITLEMENTS" "Distribution entitlements"
require_clean_worktree
[[ "$(uname -m)" == "arm64" ]] || die "Packaging requires an Apple silicon runner."
# No existing output is removed. Create only after all read-only preflight checks.
mkdir -p "$(dirname "$DIST_DIR")"
mkdir "$DIST_DIR"

echo "==> build retained whisper helper"
STENO_WHISPER_ROOT="$WHISPER_ROOT" \
STENO_WHISPER_BUILD_DIR="$WHISPER_BUILD_DIR" \
  "$REPO_ROOT/scripts/build-whisper-runtime-helper.sh" >/dev/null
require_file "$WHISPER_BUILD_DIR/bin/whisper-cli" "Bundled whisper-cli"
require_file "$WHISPER_BUILD_DIR/bin/steno-whisper-runtime" "Bundled retained whisper helper"

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
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO
)

APP_SOURCE="$DERIVED_DATA/Build/Products/Release/Steno.app"
require_dir "$APP_SOURCE" "Built Release app"

echo "==> prepare app bundle"
ditto "$APP_SOURCE" "$UNSIGNED_APP"
copy_runtime "$WHISPER_ROOT" "$WHISPER_BUILD_DIR" "$MODEL_PATH" "$VAD_PATH" "$UNSIGNED_APP"

echo "==> validate bundled runtime compatibility"
validate_runtime_bundle "$UNSIGNED_APP"

echo "==> sign bundled runtime"
sign_nested_code "$UNSIGNED_APP" "$IDENTITY"

echo "==> sign app bundle"
sign_code "$UNSIGNED_APP" "$IDENTITY" --entitlements "$DIST_ENTITLEMENTS"

echo "==> validate signed app"
codesign --verify --deep --strict --verbose=2 "$UNSIGNED_APP"
codesign -dvvv --entitlements :- "$UNSIGNED_APP" >/dev/null

echo "==> bundled runtime smoke test"
smoke_test_bundled_runtime "$UNSIGNED_APP"

echo "==> distribution hygiene scan"
scan_distribution_hygiene "$UNSIGNED_APP"

if ! APP_VERSION="$(defaults read "$UNSIGNED_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)"; then
  die "Built app is missing CFBundleShortVersionString."
fi
[[ -n "$APP_VERSION" ]] || die "Built app has an empty CFBundleShortVersionString."
APP_BUNDLE_ID="$(defaults read "$UNSIGNED_APP/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "io.stenoapp.steno")"
DMG_SIGNING_IDENTIFIER="${APP_BUNDLE_ID}.dmg"
DMG_PATH="$DIST_DIR/Steno-${APP_VERSION}.dmg"
if [[ "$UNSIGNED_PREVIEW" -eq 1 ]]; then
  DMG_PATH="$DIST_DIR/Steno-${APP_VERSION}-$(git -C "$REPO_ROOT" rev-parse --short HEAD)-preview.dmg"
fi
[[ ! -e "$DMG_PATH" ]] || die "Refusing to overwrite a DMG."

echo "==> create DMG"
create_dmg "$UNSIGNED_APP" "$DMG_PATH"

echo "==> sign DMG"
sign_dmg "$DMG_PATH" "$IDENTITY" "$DMG_SIGNING_IDENTIFIER"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
  echo "Non-notarized test DMG created (not approved for distribution):"
  echo "  App: $UNSIGNED_APP"
  echo "  DMG: $DMG_PATH"
  exit 0
fi

echo "==> notarize DMG"
NOTARY_SUBMISSION_JSON="$DIST_DIR/notary-submit.json"
NOTARY_LOG_JSON="$DIST_DIR/notary-log.json"
# One submission only. On timeout/failure retain the receipt and inspect with
# notarytool info/log; never blindly rerun this command to resolve uncertainty.
# Submit once, record the ID before waiting, then query that same submission.
NOTARY_EXIT=0
xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --output-format json > "$NOTARY_SUBMISSION_JSON" || NOTARY_EXIT=$?
NOTARY_RECEIPT="$DIST_DIR/release-notary-receipt.json"
write_notary_receipt() {
  python3 - "$1" "$NOTARY_RECEIPT" "$DMG_PATH" "$(git -C "$REPO_ROOT" rev-parse HEAD)" <<'PYRECEIPT'
import hashlib
import json
import os
import re
import sys
from pathlib import Path
try:
    raw = json.loads(Path(sys.argv[1]).read_text())
except (ValueError, OSError):
    raw = {}
identifier = str(raw.get('id', ''))
if not re.fullmatch(r'[0-9a-fA-F-]{36}', identifier):
    # Keep the already recorded submission ID if a wait timed out without JSON.
    try:
        identifier = json.loads(Path(sys.argv[2]).read_text()).get('submission_id', 'unavailable')
    except (ValueError, OSError):
        identifier = 'unavailable'
status = str(raw.get('status', 'Unknown'))
if status not in ('Accepted', 'Invalid', 'In Progress', 'Rejected', 'Uploaded'):
    status = 'Unknown'
with Path(sys.argv[3]).open('rb') as stream:
    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
receipt = {'submission_id': identifier, 'status': status, 'source_sha': sys.argv[4],
           'submitted_dmg_sha256': digest, 'workflow_run_id': os.environ.get('GITHUB_RUN_ID', '')}
Path(sys.argv[2]).write_text(json.dumps(receipt, indent=2) + '\n')
print(f'Notary submission: {identifier}; status: {status}')
PYRECEIPT
}
write_notary_receipt "$NOTARY_SUBMISSION_JSON"
if [[ "$NOTARY_EXIT" -ne 0 ]]; then
  die "Submission failed or has unknown status. Inspect $NOTARY_RECEIPT; do not resubmit without resolving its status."
fi
NOTARY_SUBMISSION_ID="$(python3 - "$NOTARY_RECEIPT" <<'PYID'
import json
import sys
from pathlib import Path
identifier = json.loads(Path(sys.argv[1]).read_text())['submission_id']
if identifier == 'unavailable':
    raise SystemExit('Notary submission ID unavailable; do not resubmit.')
print(identifier)
PYID
)"
NOTARY_WAIT_JSON="$DIST_DIR/notary-wait.json"
NOTARY_EXIT=0
xcrun notarytool wait "$NOTARY_SUBMISSION_ID" "${NOTARY_ARGS[@]}" --timeout 20m --output-format json > "$NOTARY_WAIT_JSON" || NOTARY_EXIT=$?
write_notary_receipt "$NOTARY_WAIT_JSON"
if [[ "$NOTARY_EXIT" -ne 0 ]]; then
  die "Notarization failed or remains pending. Inspect $NOTARY_RECEIPT; do not resubmit."
fi
python3 - "$NOTARY_RECEIPT" <<'PYSTATUS'
import json
import sys
from pathlib import Path
if json.loads(Path(sys.argv[1]).read_text())['status'] != 'Accepted':
    raise SystemExit('Notarization was not Accepted; inspect the saved receipt.')
PYSTATUS
xcrun notarytool log "$NOTARY_SUBMISSION_ID" "$NOTARY_LOG_JSON" "${NOTARY_ARGS[@]}"

echo "==> staple ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "==> Gatekeeper assessment"
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"

echo "Release DMG ready:"
echo "  App: $UNSIGNED_APP"
echo "  DMG: $DMG_PATH"
