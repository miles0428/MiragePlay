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
#                                  paths that no longer exist (pre-build gate;
#                                  the deleting variant, for the script that
#                                  reconfigures right after)
#   uxplay_stale_cache_check       the same judgement WITHOUT deleting anything
#                                  (for a caller that only consumes the build)
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
# Exemption 1, and it is a category rather than a key: CMAKE_INSTALL_* records
# *install destinations*, written by `cmake --install`, not by configure. A
# healthy cache legitimately names paths that do not exist yet — measured on
# this project's healthy cache, CMAKE_INSTALL_OLDINCLUDEDIR is /usr/include,
# which does not exist on macOS. Coverage measured on the same cache: 178
# absolute path values across 122 keys, 177 exist, and the single exception is
# that install destination.
#
# Exemption 2 is per PATH, not per key, and it is the macOS framework alias
# (2026-10-30). A framework bundle keeps its headers and imported libraries in
# Headers/ and Libraries/; the .pc files of the "Official" GStreamer .pkg still
# say include/ and lib/. The vendored UxPlay tree rewrites those two variables
# at configure time (renderers/CMakeLists.txt:97-99 -> Headers, :117-118 ->
# Libraries) but the rewrite never reaches CMakeCache.txt, so the cache keeps a
# path that never existed on that machine, forever — GST122_CFLAGS is written by
# the pkg_check_modules call inside that same `if`. Judging that path missing
# dropped a build dir that had just been built successfully: on a machine whose
# framework `.pc` files use the include/ and lib/ spelling (the "Official"
# GStreamer .pkg does; a Homebrew-only machine never records the key at all)
# the gate fired on every run and never converged.
#
# The exemption asks the FILESYSTEM, not the string, and it asks a NARROW
# question: is this absent path the pkg-config spelling of a directory that
# really exists inside an installed framework bundle? An absent path is spared
# only when it is spelled <bundle>/include/... or <bundle>/lib/... (the two
# alias spellings), the bundle itself exists, AND the directory the alias
# stands for exists on disk. Everything else still reports missing: a dead
# Homebrew Cellar path, a removed bundle, a `.framework`-looking name with
# nothing behind it, and — importantly — a path that is really gone INSIDE an
# installed bundle (a framework upgraded in place prunes subdirectories, and
# that is genuine dependency drift, not a spelling). See
# _uxplay_framework_alias_path.
#
# Fail-closed on a cache that cannot be understood: when the file exists but no
# absolute path can be read out of it (unreadable, or a format this checker no
# longer parses), the cache is treated as invalid instead of silently trusted.
# A cache we cannot interpret is exactly the state that produces an
# unexplainable link error, and a reconfigure costs seconds.
#
# One missing path invalidates the whole build dir. Deleting it belongs to the
# caller that immediately reconfigures (build-core.sh, via
# uxplay_rebuild_stale_cache). A caller that only CONSUMES an already-built
# tree must ask uxplay_stale_cache_check instead: it reports the same judgement
# and removes nothing, because a consumer has no cmake invocation to recreate
# what it would have deleted.
#
# One marker line is printed per removal so a test can assert the trigger
# instead of inferring it from a slow build:
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

# True when an absent path is a macOS framework alias, not a moved dependency.
#
# A framework bundle is laid out as <Name>.framework/{Headers,Libraries}; the
# .pc files shipped by the "Official" GStreamer .pkg still spell those as
# include/ and lib/. The vendored UxPlay configure step rewrites the CMake
# variables (renderers/CMakeLists.txt:97-99 -> Headers, :117-118 ->
# Libraries) and therefore the compile lines, but CMakeCache.txt keeps the
# pkg-config spelling verbatim, so the cache keeps a path that never existed
# on that machine, forever. Judging that path missing dropped a build dir that
# had just been built successfully: on a machine whose framework `.pc` files
# use the include/ and lib/ spelling (the "Official" GStreamer .pkg does; a
# Homebrew-only machine never records the key at all) the gate fired on every
# run and never converged.
#
# The check asks the filesystem, which is the whole point: the string
# `.framework` alone proves nothing (a Cellar path may contain it, and a bundle
# can be uninstalled). But "the bundle exists" is NOT enough either: a path
# that is really gone INSIDE an installed bundle (a framework upgraded in
# place prunes subdirectories) is genuine dependency drift, and the gate exists
# to catch exactly that. The exemption is therefore granted ONLY for the two
# alias spellings, and ONLY when the directory the alias stands for is really
# there:
#
#   <bundle>/include[/<rest>]  <->  <bundle>/Headers[/<rest>]
#   <bundle>/lib[/<rest>]      <->  <bundle>/Libraries[/<rest>]
#
# "include" and "lib" must be the component IMMEDIATELY below the bundle: that
# is the spelling pkg-config produces (evidence: the upstream rewrite matches
# on the two prefixes /Library/FrameWorks/GStreamer.framework/include and
# /Library/FrameWorks/GStreamer.framework/lib, renderers/CMakeLists.txt:97 and
# :117, and the failing machine's configure log prints both of them). A real
# bundle has no include/ or lib/ directory at all, so nothing below those two
# names can ever be a real path — every such path is a spelling, and the
# question is only whether the thing it spells exists. A path that points
# anywhere else inside the bundle (Headers/..., Libraries/..., Versions/...) is
# a REAL path and is reported missing when it is gone.
#
# Two spellings of the same alias root exist, and both are honoured:
#
#   1. the literal counterpart  <bundle>/Headers/<rest>  (or Libraries/<rest>)
#   2. the counterpart with the pkg-config MODULE directory dropped:
#      <bundle>/Headers/<rest without "<module>-<version>">
#
# Candidate 2 exists because pkg-config spells an include root as
# `includedir=${prefix}/include/gstreamer-1.0` with `Cflags: -I${includedir}`
# — the module directory is part of the ALIAS SPELLING, while the framework
# stores the headers FLAT under Headers/ (upstream compiles with
# -I<bundle>/Headers and `#include <gst/gst.h>`, and its renderers.c did
# compile on the failing machine, so <bundle>/Headers/gst/gst.h is the file
# that really exists — there is no Headers/gstreamer-1.0/).
#
# To keep candidate 2 from becoming a blanket amnesty, the module directory
# is only dropped when the bundle ITSELF ships that module: the bundle's own
# pkg-config directory must contain <module>.pc. That directory is where the
# upstream build looks for the framework's .pc files
# (renderers/CMakeLists.txt:9 and :18 set PKG_CONFIG_PATH to
# <bundle>/Libraries/pkgconfig), and it is also how the failing machine found
# the framework's gstreamer-1.0.pc in the first place. A module the bundle
# does not ship (glib-2.0, say) is NOT dropped, so its alias path is judged
# against the literal counterpart and reported missing when that is gone.
#
# The two forms with no tail at all — <bundle>/include and <bundle>/lib —
# stand for the whole Headers/ (resp. Libraries/) tree. The judgement is the
# same one the tail cases use: the counterpart root must exist. That is the
# explicit, consistent decision for those two forms.
#
# Args:
#     path (string): absolute path that already failed `[ -e ]`.
#
# Returns:
#     int: 0 when the path is a framework alias whose counterpart exists
#          (spare it); 1 otherwise (report it as missing).
_uxplay_framework_alias_path() {
    local path="$1"
    # Cheap pre-filter: a framework component must end at a '/' boundary (or be
    # the last component), so a name like `foo.frameworkish` never qualifies.
    case "$path" in
        *.framework|*.framework/*) ;;
        *) return 1 ;;
    esac
    local _parts=()
    local part="" prefix="" bundle=""
    IFS='/' read -r -a _parts <<<"$path"
    for part in ${_parts[@]+"${_parts[@]}"}; do
        [ -n "$part" ] || continue
        prefix="$prefix/$part"
        case "$part" in
            *.framework) bundle="$prefix" ;;
        esac
    done
    [ -n "$bundle" ] || return 1
    # The bundle itself must exist; a dangling alias into a removed framework
    # is exactly the dependency drift this gate is for.
    [ -d "$bundle" ] || return 1

    # The alias component must sit IMMEDIATELY below the bundle.
    local remainder="" alias="" rest=""
    remainder="${path#"$bundle"/}"
    case "$remainder" in
        include)   alias="include"; rest="" ;;
        include/*) alias="include"; rest="${remainder#include/}" ;;
        lib)       alias="lib";     rest="" ;;
        lib/*)     alias="lib";     rest="${remainder#lib/}" ;;
        *) return 1 ;;
    esac

    local root=""
    case "$alias" in
        include) root="$bundle/Headers" ;;
        lib)     root="$bundle/Libraries" ;;
    esac
    # The counterpart root must exist: a bundle without Headers/ (or without
    # Libraries/) is not a working dependency.
    [ -d "$root" ] || return 1

    # No tail: the alias stands for the whole tree. The counterpart root exists
    # (checked above), so the alias is spared.
    [ -n "$rest" ] || return 0

    # Candidate 1: the literal counterpart.
    [ -e "$root/$rest" ] && return 0

    # Candidate 2 applies to the INCLUDE spelling only. pkg-config writes
    # `includedir=${prefix}/include/gstreamer-1.0` (the module directory is
    # part of the include root) but `libdir=${prefix}/lib` (it is not), so a
    # module directory under lib/ is a real directory — the plugin directory —
    # and its absence is drift, not a spelling.
    [ "$alias" = "include" ] || return 1

    # Candidate 2: the counterpart with the pkg-config module directory
    # ("<name>-<version>", e.g. gstreamer-1.0) dropped — but only for a module
    # the bundle itself ships.
    local first="" tail=""
    first="${rest%%/*}"
    if [ "$first" != "$rest" ]; then
        tail="${rest#*/}"
    fi
    if _uxplay_framework_ships_module "$bundle" "$first"; then
        if [ -n "$tail" ]; then
            [ -e "$root/$tail" ] && return 0
        else
            # The alias names the include root itself; its counterpart is the
            # whole tree, which exists.
            return 0
        fi
    fi

    # Neither counterpart exists: the dependency is really gone.
    return 1
}

# True when the framework bundle ships the pkg-config module <module>.
#
# A framework bundle carries its own pkg-config directory (the upstream build
# points PKG_CONFIG_PATH at <bundle>/Libraries/pkgconfig,
# renderers/CMakeLists.txt:9 and :18). The <module>.pc file inside it is the
# bundle's own statement that it provides that module — which is what makes
# the module directory in a pkg-config include path an ALIAS SPELLING rather
# than a real directory. A module the bundle does not ship is not covered.
#
# Args:
#     bundle (string): the framework bundle directory.
#     module (string): the pkg-config module name, e.g. "gstreamer-1.0".
#
# Returns:
#     int: 0 when the bundle ships that module, 1 otherwise.
_uxplay_framework_ships_module() {
    local bundle="$1" module="$2" dir=""
    [ -n "$bundle" ] && [ -n "$module" ] || return 1
    for dir in "$bundle/Libraries/pkgconfig" "$bundle/lib/pkgconfig" \
               "$bundle/pkgconfig" "$bundle"/Versions/*/lib/pkgconfig; do
        [ -d "$dir" ] || continue
        [ -f "$dir/$module.pc" ] && return 0
    done
    return 1
}

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
                # Exemption 2 (header): absent, but inside a framework bundle
                # that is still installed — the cache holds the pkg-config
                # spelling, not a path that ever existed.
                if ! _uxplay_framework_alias_path "$path"; then
                    _UXPLAY_SCAN_MISSING="$key=$path"
                    return 0
                fi
            fi
        done
    done
    return 0
}

# Stale judgement only, no side effects: prints "<key>=<path>" (or the
# fail-closed note) when the build dir must be rebuilt, nothing when it is
# valid. Shared by the deleting and the read-only entry points so there is one
# definition of "this cache is still valid".
#
# Args:
#     build_dir (string): cmake build dir holding CMakeCache.txt.
#     expected_src (string): pinned source dir, or "" to skip that check.
#
# Returns:
#     int: always 0; the verdict is the printed line.
_uxplay_stale_cache_reason() {
    local build_dir="${1:-}"
    local expected_src="${2:-}"
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
            # Exemptions, see the header: an install destination is created by
            # `cmake --install`, so configure may leave it absent.
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
    printf '%s\n' "$reason"
    return 0
}

# Drop a build dir whose cache points at paths that no longer exist.
#
# For the caller that immediately reconfigures: the directory is removed and
# left to its own `cmake -B` to recreate. Only build-core.sh belongs here —
# it owns the cmake invocation that refills what this deletes.
#
# Args:
#     build_dir (string): cmake build dir to validate (and drop when stale).
#     expected_src (string): pinned source dir, or "" to skip that check.
#
# Returns:
#     int: always 0. Sets UXPLAY_STALE_CACHE_REMOVED to 1 when it deleted.
uxplay_rebuild_stale_cache() {
    local build_dir="${1:-}"
    local reason=""
    UXPLAY_STALE_CACHE_REMOVED=0
    [ -n "$build_dir" ] || return 0
    reason="$(_uxplay_stale_cache_reason "$build_dir" "${2:-}")"
    [ -n "$reason" ] || return 0
    rm -rf "$build_dir"
    UXPLAY_STALE_CACHE_REMOVED=1
    printf 'STALE-CACHE: %s rebuilt (%s)\n' "$build_dir" "$reason"
    return 0
}

# Same judgement, nothing removed. For a caller that only consumes an
# already-built tree (build-app.sh: it never configures cmake).
#
# Why the split exists: a consumer that deletes on the way in destroys the
# artifact it is about to package, and cannot put it back — it has no cmake
# step. That produced a loop where the run after the deletion reported "core
# uxplay binary missing" instead of the real cause. Detection stays shared;
# deletion stays with the builder.
#
# Args:
#     build_dir (string): cmake build dir to validate.
#     expected_src (string): pinned source dir, or "" to skip that check.
#
# Returns:
#     int: always 0. Sets UXPLAY_STALE_CACHE_STALE (0/1) and
#          UXPLAY_STALE_CACHE_REASON ("<key>=<path>", empty when valid).
uxplay_stale_cache_check() {
    UXPLAY_STALE_CACHE_STALE=0
    UXPLAY_STALE_CACHE_REASON=""
    local reason=""
    reason="$(_uxplay_stale_cache_reason "${1:-}" "${2:-}")"
    [ -n "$reason" ] || return 0
    UXPLAY_STALE_CACHE_STALE=1
    UXPLAY_STALE_CACHE_REASON="$reason"
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
