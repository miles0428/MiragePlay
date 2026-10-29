#!/bin/bash
# _uxplay-path.sh — shared resolution of the vendored UxPlay source tree.
#
# The upstream UxPlay tree is NOT part of version control any more (2026-10-19,
# task mirageplay-uxplay-decouple-20261019). It is a build artifact produced on
# demand by scripts/build/vendor-uxplay.sh from the fork pinned in core/vendor.lock.
#
# Source this file from any script that needs the tree (do not execute it):
#
#     . "$PROJ/scripts/lib/_uxplay-path.sh"
#
# Public API:
#   uxplay_src_dir [log]           absolute path of the UxPlay source tree
#   uxplay_ensure_tree [log]       materialize the tree when it is missing
#   uxplay_tree_matches_pin [log]  true only when tree == pinned commit
#   uxplay_redline_check [log]     ensure + strict pin check (red-line gate)
#   uxplay_require_pinned_tree     strict pin check without the ensure step;
#                                  the fail-closed gate for build entry points
#   uxplay_pinned_file_count       file count pinned in core/vendor.lock
#   uxplay_default_build_root      default build CACHE root (what --build-dir names)
#   uxplay_rebuild_stale_cache     drop a cmake build dir whose cache points at
#                                  paths that no longer exist (pre-build gate)
#   uxplay_core_build_dir [root]   cmake build dir for the core: <root>/core
#   uxplay_core_binary [root]      built core executable:        <root>/core/uxplay
#
# Environment:
#   UXPLAY_SRC_DIR            override the tree location (tests point it at a copy)
#   UXPLAY_LOG                default log file for vendor output (default: /dev/null)
#   MIRAGE_PLAY_BUILD_ROOT    override the default build CACHE root (see
#                             uxplay_default_build_root). Empty/unset keeps the
#                             default <repo>/_build.
#
# The tree location is derived from scripts/build/vendor-uxplay.sh's own
# DEFAULT_DEST assignment, so the path literal lives in exactly one place.

UXPLAY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/_canonical-path.sh
. "$UXPLAY_SCRIPT_DIR/_canonical-path.sh"
# Canonical spelling: UXPLAY_REPO_ROOT feeds build-core.sh's cmake BUILD_DIR
# and the vendored tree's -ffile-prefix-map. `pwd`/`pwd -P` keep the caller's
# spelling, which is what corrupts clang's module cache. See
# scripts/lib/_canonical-path.sh.
UXPLAY_SCRIPT_DIR="$(mp_canonical_dir "$UXPLAY_SCRIPT_DIR")" || {
    echo "uxplay-path: could not resolve $UXPLAY_SCRIPT_DIR to its on-disk spelling" >&2
    exit 1
}
UXPLAY_REPO_ROOT="$(mp_canonical_dir "$UXPLAY_SCRIPT_DIR/../..")" || {
    echo "uxplay-path: could not resolve the repository root ($UXPLAY_SCRIPT_DIR/../..)" >&2
    exit 1
}
UXPLAY_VENDOR_SCRIPT="$UXPLAY_SCRIPT_DIR/../build/vendor-uxplay.sh"
UXPLAY_LOCK_FILE="${VENDOR_LOCK:-$UXPLAY_REPO_ROOT/core/vendor.lock}"

# Read DEFAULT_DEST out of the vendor script and evaluate it with the same
# REPO_ROOT the vendor script itself computes. Fails closed when the vendor
# script no longer declares a usable DEFAULT_DEST.
_uxplay_default_dest() {
    local vendor="$1"
    local line
    line="$(grep -E '^[[:space:]]*DEFAULT_DEST=' "$vendor" 2>/dev/null | head -n 1 || true)"
    if [ -z "$line" ]; then
        echo "uxplay-path: no DEFAULT_DEST declared in $vendor" >&2
        return 1
    fi
    (
        SCRIPT_DIR="$(cd "$(dirname "$vendor")" && pwd)"
        REPO_ROOT="$(mp_canonical_dir "$SCRIPT_DIR/../..")" || exit 1
        eval "$line"
        [ -n "${DEFAULT_DEST:-}" ] || exit 1
        printf '%s\n' "$DEFAULT_DEST"
    ) || {
        echo "uxplay-path: could not evaluate DEFAULT_DEST from $vendor" >&2
        return 1
    }
}

# Read one key out of core/vendor.lock (plain key=value file).
_uxplay_lock_get() {
    local key="$1" line
    line="$(grep -E "^${key}=" "$UXPLAY_LOCK_FILE" 2>/dev/null | tail -n 1 || true)"
    [ -n "$line" ] || return 1
    printf '%s' "${line#*=}"
}

# File count pinned in core/vendor.lock (the manifest line count).
uxplay_pinned_file_count() {
    _uxplay_lock_get VENDOR_FILE_COUNT || printf '?'
}

# ---------------------------------------------------------------------------
# Build layout: one definition, shared by every script that touches the core
# ---------------------------------------------------------------------------
# build-core.sh WRITES the core build into <cache root>/core; build-app.sh
# READS <cache root>/core/uxplay. Those two used to spell the layout
# independently — build-core.sh hard-coded the default root while
# build-app.sh derived `<--build-dir>/core` — so any `--build-dir` other than
# the default made the assembler look for a core nobody had written there
# (task D-1 / E6: `build-app.sh --build-dir .../build-e6` exited 1 until the
# core was copied in by hand). The mapping now lives here once; callers must
# not restate it.
#
# Naming: a "build root" is the CACHE root, i.e. exactly what
# `build-app.sh --build-dir` names. The cmake build dir sits at <root>/core.
#
# MIRAGE_PLAY_BUILD_ROOT overrides the location so a harness can keep one
# reusable cache outside the checkout (e.g. ~/Library/Caches/...). The test
# harness does exactly that (scripts/lib/testkit.sh exports it), so "unset"
# and "set by a harness" are both live states: unset or empty must keep the
# default below byte for byte, because every consumer of the layout resolves
# it through these functions — build-core.sh, build-app.sh, the closure cache
# and scripts/build/package-release.sh alike. No caller restates the path.
# An override spelling is canonicalised (same reason as every other path that
# reaches cmake/swift); when it cannot be resolved the value is passed through
# untouched rather than dropped.
uxplay_default_build_root() {
    local override="${MIRAGE_PLAY_BUILD_ROOT:-}"
    if [ -n "$override" ]; then
        local resolved=""
        resolved="$(mp_canonical_path "$override")" || resolved="$override"
        printf '%s\n' "$resolved"
        return 0
    fi
    printf '%s\n' "$UXPLAY_REPO_ROOT/_build"
}

# ---------------------------------------------------------------------------
# Pre-build cache validity check (stale CMakeCache guard)
# ---------------------------------------------------------------------------
# CMakeCache.txt records ABSOLUTE paths: the prefixes it was configured
# against, the pkg-config libraries it resolved, the compiler, the SDK. Those
# paths do not survive a Homebrew formula upgrade or a moved Cellar, and cmake
# does not re-resolve them: it compiles against headers and links against
# libraries that are gone, and the failure surfaces as
# `'plist/plist.h' file not found` or `ld: library not found` — far from the
# cause. The only check that existed before this function compared
# CMAKE_HOME_DIRECTORY (the source dir), which catches a moved source tree but
# not a moved dependency.
#
# The rule is "every absolute path the cache records must exist" — not a list of
# key names. A key list cannot stay honest: an earlier version of this function
# enumerated the OpenSSL family only, so `brew upgrade libplist` (which rewrites
# LIBPLIST, PLIST_2*, pkgcfg_lib_PLIST_*, GST* — 95 of the 107 homebrew-rooted
# keys in this project's cache) left the gate silent and the user back at a link
# error. Nothing in the cache format says which families a dependency added
# tomorrow will use, so the values are read instead of the key names.
#
# One exemption, and it is a category rather than a key: CMAKE_INSTALL_* records
# *install destinations*, written by `cmake --install`, not by configure. A
# healthy cache legitimately names paths that do not exist yet — measured on
# this project's healthy cache, CMAKE_INSTALL_OLDINCLUDEDIR is /usr/include,
# which does not exist on macOS. Coverage measured on the same cache: 178
# absolute path values across 122 keys, 177 exist, and the single exception is
# that install destination.
#
# Fail-closed on a cache that cannot be understood: when the file exists but no
# absolute path can be read out of it (unreadable, or a format this checker no
# longer parses), the cache is treated as invalid instead of silently trusted.
# A cache we cannot interpret is exactly the state that produces an
# unexplainable link error, and a reconfigure costs seconds.
#
# One missing path invalidates the whole build dir: it is removed here and left
# to the caller's `cmake -B` to recreate (a clean reconfigure). One marker line
# is printed per removal so a test can assert the trigger instead of inferring
# it from a slow build:
#
#     STALE-CACHE: <build dir> rebuilt (<key>=<missing path>)
#
# Output variable: UXPLAY_STALE_CACHE_REMOVED (0/1) — 1 when the directory was
# dropped in this call. Always returns 0: an invalid cache is not a build
# error, it is a cache to rebuild.
#
# Internal outputs of _uxplay_cache_scan_value, read by the loop below:
#   _UXPLAY_SCAN_ABS_COUNT  absolute paths examined so far
#   _UXPLAY_SCAN_MISSING    first "<key>=<path>" whose path is absent, else ""
_UXPLAY_SCAN_ABS_COUNT=0
_UXPLAY_SCAN_MISSING=""

# Scan the absolute paths of one CMakeCache value.
#
# A value is a ';'-separated CMake list whose elements may also carry
# space-separated words (`-I<dir> -L<dir> ...`), and a path may itself contain
# spaces, so an element that exists verbatim is taken as ONE path and is never
# split — splitting it would report a healthy cache as stale.
#
# Args:
#     key (string): cache key, used only in the reported "key=path" pair.
#     value (string): raw value after '=' (may be quoted, may be a list).
#
# Returns:
#     int: always 0; results go to _UXPLAY_SCAN_ABS_COUNT/_UXPLAY_SCAN_MISSING.
_uxplay_cache_scan_value() {
    local key="$1" value="$2"
    local element="" word="" path=""
    local _elements=()
    local _words=()
    IFS=';' read -r -a _elements <<<"$value"
    for element in ${_elements[@]+"${_elements[@]}"}; do
        element="${element%\"}"
        element="${element#\"}"
        [ -n "$element" ] || continue
        if [ -e "$element" ]; then
            case "$element" in
                /*) _UXPLAY_SCAN_ABS_COUNT=$((_UXPLAY_SCAN_ABS_COUNT + 1)) ;;
            esac
            continue
        fi
        _words=()
        IFS=$' \t' read -r -a _words <<<"$element"
        for word in ${_words[@]+"${_words[@]}"}; do
            case "$word" in
                /*) path="$word" ;;
                # -I<dir> / -L<dir>: the flag spellings the same configure step
                # writes into the compile and link lines.
                -I/*|-L/*) path="${word#-?}" ;;
                *) continue ;;
            esac
            _UXPLAY_SCAN_ABS_COUNT=$((_UXPLAY_SCAN_ABS_COUNT + 1))
            if [ ! -e "$path" ]; then
                _UXPLAY_SCAN_MISSING="$key=$path"
                return 0
            fi
        done
    done
    return 0
}

uxplay_rebuild_stale_cache() {
    local build_dir="${1:-}"
    local expected_src="${2:-}"
    UXPLAY_STALE_CACHE_REMOVED=0
    [ -n "$build_dir" ] || return 0
    local cache="$build_dir/CMakeCache.txt"
    [ -f "$cache" ] || return 0

    local reason="" cached_src="" line="" key="" value="" missing=""
    if [ -n "$expected_src" ]; then
        cached_src="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache" | head -n 1)"
        if [ -n "$cached_src" ] && [ "$cached_src" != "$expected_src" ]; then
            reason="CMAKE_HOME_DIRECTORY=$cached_src"
        fi
    fi

    if [ -z "$reason" ]; then
        _UXPLAY_SCAN_ABS_COUNT=0
        while IFS= read -r line; do
            case "$line" in
                ''|\#*|//*) continue ;;
            esac
            case "$line" in
                *=*) ;;
                *) continue ;;
            esac
            key="${line%%:*}"
            value="${line#*=}"
            # The one exemption (see the header): an install destination is
            # created by `cmake --install`, so configure may leave it absent.
            case "$key" in
                CMAKE_INSTALL_*) continue ;;
            esac
            [ -n "$value" ] || continue
            _UXPLAY_SCAN_MISSING=""
            _uxplay_cache_scan_value "$key" "$value"
            if [ -n "$_UXPLAY_SCAN_MISSING" ]; then
                missing="$_UXPLAY_SCAN_MISSING"
                break
            fi
        done <"$cache"
        if [ -z "$missing" ] && [ "$_UXPLAY_SCAN_ABS_COUNT" -eq 0 ]; then
            # The cache exists but names no absolute path at all: unreadable, or
            # a format this checker no longer parses. Fail closed (header).
            missing="CMakeCache.txt=no absolute path readable (unreadable or unknown format)"
        fi
        reason="$missing"
    fi

    [ -n "$reason" ] || return 0
    rm -rf "$build_dir"
    UXPLAY_STALE_CACHE_REMOVED=1
    printf 'STALE-CACHE: %s rebuilt (%s)\n' "$build_dir" "$reason"
    return 0
}

# cmake build dir of the core for a cache root (default root when omitted).
uxplay_core_build_dir() {
    local root="${1:-}"
    if [ -z "$root" ]; then
        root="$(uxplay_default_build_root)" || return 1
    fi
    printf '%s\n' "$root/core"
}

# Built core executable for a cache root (default root when omitted).
uxplay_core_binary() {
    local dir
    dir="$(uxplay_core_build_dir "${1:-}")" || return 1
    printf '%s\n' "$dir/uxplay"
}

# Absolute path of the UxPlay source tree. UXPLAY_SRC_DIR overrides the
# vendor script's default destination; the override is spelled canonically
# because this value is what `cmake -S` and -ffile-prefix-map receive (D6).
uxplay_src_dir() {
    local dir=""
    if [ -n "${UXPLAY_SRC_DIR:-}" ]; then
        dir="$(mp_canonical_path "$UXPLAY_SRC_DIR")" || return 1
        printf '%s\n' "$dir"
        return 0
    fi
    _uxplay_default_dest "$UXPLAY_VENDOR_SCRIPT"
}

# Materialize the tree when it is missing. An existing tree is never touched,
# so local modifications survive and stay visible to the red-line check.
uxplay_ensure_tree() {
    local log="${1:-${UXPLAY_LOG:-/dev/null}}"
    local dest
    dest="$(uxplay_src_dir)" || return 1
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    : >"$log"
    if [ -d "$dest" ]; then
        return 0
    fi
    "$UXPLAY_VENDOR_SCRIPT" "$dest" >>"$log" 2>&1 || return 1
    [ -d "$dest" ]
}

# Strict red-line check: the tree must match the commit pinned in
# core/vendor.lock byte for byte (commit, tree hash, file count, per-file
# sha256 over the manifest). Any unapproved local edit fails here.
uxplay_tree_matches_pin() {
    local log="${1:-${UXPLAY_LOG:-/dev/null}}"
    local dest
    dest="$(uxplay_src_dir)" || return 1
    "$UXPLAY_VENDOR_SCRIPT" --check "$dest" >>"$log" 2>&1
}

# Fail-closed gate for every path that CONSUMES the tree (task fix-verify-pin,
# contract BLUEPRINT.md:63). uxplay_ensure_tree() only materializes; by design
# it accepts a tree that already exists, which is exactly the hole this closes:
# a locally patched tree, or one checked out at another commit, used to walk
# straight into `cmake -S` and from there into the shipped bundle.
#
# Callers that compile (build-core.sh) or package (build-app.sh) the core call
# this instead. The tree must exist and match core/vendor.lock byte for byte —
# commit, tree hash, file count, per-file sha256 (vendor-uxplay.sh --check, no
# writes). Measured cost of the 90-file verification on this machine: ~0.08 s.
# On failure the verifier output and the way back (BLUEPRINT.md:157) go to
# stderr; nothing is printed on success.
uxplay_require_pinned_tree() {
    local dest log rc=0
    dest="$(uxplay_src_dir)" || return 1
    if [ ! -d "$dest" ]; then
        echo "uxplay-path: pinned source tree is missing at $dest" >&2
        echo "uxplay-path: run scripts/build/build-core.sh — it materializes the pinned tree" >&2
        return 1
    fi
    log="$(mktemp "${TMPDIR:-/tmp}/uxplay-pin-check.XXXXXX")" || {
        echo "uxplay-path: could not create a log file for the pin check" >&2
        return 1
    }
    if ! uxplay_tree_matches_pin "$log"; then
        rc=1
        echo "uxplay-path: FAIL — the source tree at $dest does not match core/vendor.lock" >&2
        sed 's/^/    /' "$log" >&2 || true
        echo "uxplay-path: a build may consume the pinned tree only (BLUEPRINT.md:63)." >&2
        echo "uxplay-path: to go back, drop the local changes: git -C \"$dest\" checkout -- ." >&2
        echo "uxplay-path: to keep a change, land it on the fork and bump the pin in" >&2
        echo "uxplay-path: core/vendor.lock — change the fork, change the pin (BLUEPRINT.md:157)." >&2
    fi
    rm -f "$log"
    return "$rc"
}

# Red-line gate for the test suites: the tree must exist and must match the
# pinned commit exactly. Returns 0 only when both hold.
uxplay_redline_check() {
    local log="${1:-${UXPLAY_LOG:-/dev/null}}"
    local dest
    dest="$(uxplay_src_dir)" || return 1
    uxplay_ensure_tree "$log" || return 1
    uxplay_tree_matches_pin "$log"
}
