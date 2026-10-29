#!/bin/bash
# build-core.sh — Build UxPlay core (embedded or spawn mode)
#
# Usage: ./build-core.sh --embedded | --spawn [--build-dir DIR]
#
#   --embedded        native-macos-renderer in-process core (packaging path)
#   --spawn           GStreamer master / spawn renderer core
#   --build-dir DIR   build cache root, SAME name and SAME meaning as
#                     build-app.sh --build-dir. The cmake build dir for the
#                     core is <DIR>/core, i.e. exactly where build-app.sh
#                     looks for it (<DIR>/core/uxplay). Default:
#                     <repo>/_build — so the default core lands
#                     in <repo>/_build/core.
#   --print-paths     print the resolved BUILD_ROOT= / BUILD_DIR= and exit
#                     (no cmake, no vendoring; used by the path-consistency
#                     assertion in scripts/tests/test-config-engine.sh)
#
# The upstream UxPlay tree is no longer version-controlled: it is materialized
# on demand by scripts/build/vendor-uxplay.sh (pinned in core/vendor.lock) into
# _build/uxplay. This script resolves that path through the shared
# fragment scripts/lib/_uxplay-path.sh and fetches the tree when it is missing.
#
# Where the core build goes is defined ONCE, in scripts/lib/_uxplay-path.sh
# (uxplay_default_build_root / uxplay_core_build_dir). Do not restate the
# layout here: build-app.sh derives <--build-dir>/core/uxplay from the same
# functions, and a second spelling of the layout is exactly what broke the
# `build-app.sh --build-dir X` path (task D-1).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/_canonical-path.sh
. "$SCRIPT_DIR/../lib/_canonical-path.sh"
# Canonical spelling: BUILD_DIR below is handed to cmake. See
# scripts/lib/_canonical-path.sh for why pwd/pwd -P are not enough.
SCRIPT_DIR="$(mp_canonical_dir "$SCRIPT_DIR")" || {
  echo "build-core: could not resolve $SCRIPT_DIR to its on-disk spelling" >&2
  exit 1
}
# shellcheck source=scripts/lib/_uxplay-path.sh
. "$SCRIPT_DIR/../lib/_uxplay-path.sh"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Canonicalise a directory-shaped CLI argument and echo it (D6).
# The directory may not exist yet on a first build, so mp_canonical_path
# resolves the longest existing ancestor and keeps the tail; creation still
# happens later (mkdir -p). Same helper contract as build-app.sh.
canon_dir_arg() {   # <flag> <value>; echoes the canonical path, non-zero on error
  local flag="$1" raw="$2" out=""

  case "$raw" in
    ''|-) echo "build-core.sh: $flag needs a directory (got '${raw}')" >&2; return 1 ;;
  esac
  out="$(mp_canonical_path "$raw")" || {
    echo "build-core.sh: cannot resolve $flag path '$raw' to its on-disk spelling" >&2
    return 1
  }
  printf '%s\n' "$out"
}

MODE=""
PRINT_PATHS=0
BUILD_ROOT="$(uxplay_default_build_root)" || {
  echo "build-core: could not resolve the default build root" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --embedded|--spawn) MODE="$1" ;;
    --build-dir)        BUILD_ROOT="$(canon_dir_arg --build-dir "${2-}")" || exit 1; shift ;;
    --print-paths)      PRINT_PATHS=1 ;;
    -h|--help)          usage 0 ;;
    *) echo "build-core.sh: unknown argument $1" >&2; usage 1 ;;
  esac
  shift
done

# The cmake build dir is derived, never spelled (see _uxplay-path.sh).
BUILD_DIR="$(uxplay_core_build_dir "$BUILD_ROOT")" || {
  echo "build-core: could not resolve the core build dir under $BUILD_ROOT" >&2
  exit 1
}

if [ "$PRINT_PATHS" = "1" ]; then
  printf 'BUILD_ROOT=%s\nBUILD_DIR=%s\n' "$BUILD_ROOT" "$BUILD_DIR"
  exit 0
fi

if [ -z "$MODE" ]; then
  echo "build-core.sh: pick a mode (--embedded | --spawn)" >&2
  usage 1
fi

# Minimum macOS version of the built UxPlay core binary.
# Frozen at 15.0 (release contract P-5.3). Must NOT float with the build
# machine's macOS version: that would raise the deployment target to the
# builder's macOS release and lock the binary out of older supported systems.
MINOS_TARGET="15.0"

# Resolve the tree location (UXPLAY_SRC_DIR overrides the vendor default).
SRC_DIR="$(uxplay_src_dir)" || {
  echo "ERROR: could not resolve the uxplay source tree location" >&2
  exit 1
}

# Materialize the pinned tree when it is not there yet.
if [ ! -d "$SRC_DIR" ]; then
  echo "=== uxplay tree missing — materializing via scripts/build/vendor-uxplay.sh ==="
  if ! uxplay_ensure_tree; then
    echo "ERROR: scripts/build/vendor-uxplay.sh could not materialize $SRC_DIR" >&2
    exit 1
  fi
  echo "=== uxplay tree ready at $SRC_DIR ==="
fi

# Fail closed on EVERY path, not only on the materialize one (BLUEPRINT.md:63,
# YC ruling 2026-10-25, Q1 = always block). Until this gate existed, an already
# present tree was taken on trust: a core patched in place, or one checked out
# at a commit other than the pin, went straight into `cmake -S` below and was
# shipped. The check is the same one `vendor-uxplay.sh --check` runs (commit,
# tree, file count, per-file sha256) and costs ~0.08 s for the 90 pinned files,
# paid on every build on purpose. A tree that was just materialized is verified
# once more here — the fetch path verifies its staging dir, this verifies the
# path cmake is about to read.
if ! uxplay_require_pinned_tree; then
  echo "ERROR: refusing to build the core — $SRC_DIR is not the tree pinned in core/vendor.lock" >&2
  echo "       see BLUEPRINT.md:63 (fail-closed) and :157 (change the fork, change the pin)" >&2
  exit 1
fi
echo "=== pinned tree verified: $SRC_DIR ==="

# Reproducible compile-time file paths (P-9 evidence hygiene / E2's P2 finding).
# Clang bakes the translation unit's COMPILE-TIME path into `__FILE__`
# (assert/diagnostic strings) and into DWARF. The shipped core binary carried
# two such literals naming this machine's checkout
# (`<repo>/_build/uxplay/uxplay.cpp`,
# `<repo>/_build/uxplay/renderers/audio_renderer.c`), leaking the local
# path and making builds non-reproducible. `-ffile-prefix-map` is the union of
# -fmacro-prefix-map and -fdebug-prefix-map, so it covers macro expansion
# (C and C++ alike) and debug info in one flag. SRC_DIR must already be
# resolved: the map is only exact when the prefix matches what cmake passes.
FILE_PREFIX_MAP_FLAGS="-ffile-prefix-map=$SRC_DIR=."

# Pre-build cache validity gate. A CMakeCache.txt that points at paths which no
# longer exist (a Homebrew formula upgrade moves the Cellar) makes cmake link
# against headers/libraries that are gone; the failure surfaces as a link error
# long after the cause. The shared checker also re-runs the source-dir check
# that used to live here (CMAKE_HOME_DIRECTORY != the pinned tree), so there is
# one definition of "this cache is still valid" and one marker line when it is
# not: `STALE-CACHE: <dir> rebuilt (<key>=<path>)`.
uxplay_rebuild_stale_cache "$BUILD_DIR" "$SRC_DIR"

mkdir -p "$BUILD_DIR"

case "$MODE" in
  --embedded)
    echo "=== Building UxPlay core: embedded (native-macos-renderer) ==="
    cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
      -DUSE_NATIVE_MACOS_RENDERER=ON \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/openssl@3" \
      -DCMAKE_C_FLAGS="$FILE_PREFIX_MAP_FLAGS" \
      -DCMAKE_CXX_FLAGS="$FILE_PREFIX_MAP_FLAGS" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINOS_TARGET"
    cmake --build "$BUILD_DIR" -j$(sysctl -n hw.ncpu)
    echo "=== Build complete ==="
    ls "$BUILD_DIR"/lib*.a 2>/dev/null || ls "$BUILD_DIR"/*.a 2>/dev/null || find "$BUILD_DIR" -name "*.a" -o -name "*.dylib" 2>/dev/null
    ;;
  --spawn)
    echo "=== Building UxPlay core: spawn (GStreamer master) ==="
    cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
      -DUSE_NATIVE_MACOS_RENDERER=OFF \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/openssl@3" \
      -DCMAKE_C_FLAGS="$FILE_PREFIX_MAP_FLAGS" \
      -DCMAKE_CXX_FLAGS="$FILE_PREFIX_MAP_FLAGS" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINOS_TARGET"
    cmake --build "$BUILD_DIR" -j$(sysctl -n hw.ncpu)
    echo "=== Build complete ==="
    ;;
  *)
    echo "Usage: $0 --embedded | --spawn"
    exit 1
    ;;
esac
