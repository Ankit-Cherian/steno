#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_ROOT="${STENO_WHISPER_ROOT:-$ROOT_DIR/vendor/whisper.cpp}"
BUILD_DIR="${STENO_WHISPER_BUILD_DIR:-$WHISPER_ROOT/build-steno}"
OUTPUT="${STENO_WHISPER_RUNTIME_OUTPUT:-$BUILD_DIR/bin/steno-whisper-runtime}"
SOURCE="$ROOT_DIR/runtime-helper/steno_whisper_runtime.cpp"
MACOS_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
EXPECTED_REVISION="764482c3175d9c3bc6089c1ec84df7d1b9537d83"
EXPECTED_ARCHITECTURE="arm64"
BUILD_JOBS="${STENO_WHISPER_BUILD_JOBS:-8}"

die() {
  echo "Error: $*" >&2
  exit 1
}

[[ -f "$SOURCE" ]] || die "Missing runtime helper source."
[[ -f "$WHISPER_ROOT/include/whisper.h" ]] || die "Missing whisper.cpp headers."
git -C "$WHISPER_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "whisper.cpp must be an audited Git checkout."

actual_revision="$(git -C "$WHISPER_ROOT" rev-parse HEAD)"
[[ "$actual_revision" == "$EXPECTED_REVISION" ]] \
  || die "Expected whisper.cpp $EXPECTED_REVISION, found $actual_revision."
[[ -z "$(git -C "$WHISPER_ROOT" status --porcelain --untracked-files=no)" ]] \
  || die "whisper.cpp tracked sources must be clean before building."

cmake \
  -S "$WHISPER_ROOT" \
  -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
  -DCMAKE_OSX_ARCHITECTURES="$EXPECTED_ARCHITECTURE" \
  -DCMAKE_C_FLAGS="-ffile-prefix-map=$WHISPER_ROOT=whisper.cpp -fdebug-prefix-map=$WHISPER_ROOT=whisper.cpp" \
  -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$WHISPER_ROOT=whisper.cpp -fdebug-prefix-map=$WHISPER_ROOT=whisper.cpp" \
  -DBUILD_SHARED_LIBS=ON \
  -DGGML_ACCELERATE=ON \
  -DGGML_BLAS=OFF \
  -DGGML_METAL=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_RPC=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_CURL=OFF

cmake --build "$BUILD_DIR" --config Release --target whisper-cli -j "$BUILD_JOBS"

[[ -f "$BUILD_DIR/src/libwhisper.dylib" || -f "$BUILD_DIR/src/libwhisper.1.dylib" ]] \
  || die "Canonical whisper.cpp build did not produce libwhisper."

mkdir -p "$(dirname "$OUTPUT")"

xcrun clang++ \
  -std=c++17 \
  -O3 \
  -DNDEBUG \
  -mmacosx-version-min="$MACOS_DEPLOYMENT_TARGET" \
  -ffile-prefix-map="$ROOT_DIR"=. \
  -fdebug-prefix-map="$ROOT_DIR"=. \
  -I "$WHISPER_ROOT/include" \
  -I "$WHISPER_ROOT/ggml/include" \
  "$SOURCE" \
  -L "$BUILD_DIR/src" \
  -lwhisper \
  -Wl,-rpath,@executable_path/../Frameworks \
  -Wl,-rpath,@executable_path/../src \
  -Wl,-rpath,@executable_path/../ggml/src \
  -Wl,-rpath,@executable_path/../ggml/src/ggml-metal \
  -o "$OUTPUT"

cache_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 ~ ("^" key ":") { print $2; exit }' "$BUILD_DIR/CMakeCache.txt"
}

require_cache_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(cache_value "$key")"
  [[ "$actual" == "$expected" ]] \
    || die "Unsafe CMake cache: expected $key=$expected, found ${actual:-missing}."
}

require_cache_value CMAKE_OSX_DEPLOYMENT_TARGET "$MACOS_DEPLOYMENT_TARGET"
require_cache_value CMAKE_OSX_ARCHITECTURES "$EXPECTED_ARCHITECTURE"
require_cache_value BUILD_SHARED_LIBS ON
require_cache_value GGML_ACCELERATE ON
require_cache_value GGML_BLAS OFF
require_cache_value GGML_METAL ON
require_cache_value GGML_NATIVE OFF
require_cache_value GGML_RPC OFF
require_cache_value WHISPER_BUILD_SERVER OFF
require_cache_value WHISPER_CURL OFF

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

validate_macho() {
  local binary="$1"
  file "$binary" | grep -q "Mach-O" || die "Expected a Mach-O file: $binary"

  local architectures
  architectures="$(lipo -archs "$binary")"
  [[ "$architectures" == "$EXPECTED_ARCHITECTURE" ]] \
    || die "Expected $EXPECTED_ARCHITECTURE-only runtime, found '$architectures' in $binary."

  local found_minos=0
  local minos
  while IFS= read -r minos; do
    [[ -n "$minos" ]] || continue
    found_minos=1
    version_is_at_most "$minos" "$MACOS_DEPLOYMENT_TARGET" \
      || die "$binary requires macOS $minos, above the $MACOS_DEPLOYMENT_TARGET deployment target."
  done < <(vtool -show-build "$binary" | awk '$1 == "minos" { print $2 }')
  [[ "$found_minos" -eq 1 ]] || die "Could not read a macOS deployment target from $binary."
}

runtime_machos=(
  "$BUILD_DIR/bin/whisper-cli"
  "$OUTPUT"
)
while IFS= read -r -d '' binary; do
  runtime_machos+=("$binary")
done < <(find "$BUILD_DIR/src" "$BUILD_DIR/ggml/src" "$BUILD_DIR/ggml/src/ggml-metal" \
  -maxdepth 1 -type f -name '*.dylib' -print0)

for binary in "${runtime_machos[@]}"; do
  validate_macho "$binary"
done

if otool -L "$BUILD_DIR/src/libwhisper.1.dylib" "$OUTPUT" \
  | grep -Eq 'libggml-(blas|rpc)'; then
  die "The retained runtime must not depend on BLAS or RPC backends."
fi

if nm -u "$OUTPUT" | grep -Eq ' U _?(socket|bind|listen|accept|connect)(\$|$)'; then
  die "The retained runtime unexpectedly imports a network-listener symbol."
fi

echo "$OUTPUT"
