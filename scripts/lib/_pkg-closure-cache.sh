#!/bin/bash
# _pkg-closure-cache.sh — one implementation of "put the GStreamer closure into
# a bundle", shared by the dev assembler (build-app.sh) and the release
# packager (package-release.sh), with a content-addressed cache.
#
# Source this file (do not execute it):
#
#     . "$REPO_ROOT/scripts/lib/_pkg-closure-cache.sh"
#
# Why this file exists
#   The closure (35 libraries + 14 plugins + gst-plugin-scanner, ~58 MB) used to
#   be computed, copied and relocated inside package-release.sh only. A dev
#   bundle therefore shipped without it, and uxplay died at gst_init with
#   "Required gstreamer plugin 'app' not found" — which the app correctly
#   treats as a crash attribute, so every dev harness measured respawn storms
#   instead of the behaviour under test. Both paths must produce the same
#   closure, so the steps live here once.
#
#   The expensive part (3 s of otool graph walking + 58 MB of copying + ~52
#   install_name_tool rewrites) now happens once per (inputs) combination and
#   lands in $MIRAGE_PLAY_BUILD_ROOT/closure/<key>/, so a dev build pays a copy
#   instead of a recomputation.
#
# Cache invalidation (see pkg_closure_cache_key / pkg_closure_manifest_live)
#   1. GStreamer version, Homebrew prefix, plugin set (path/size/mtime of the
#      14 core plugins + the scanner)     -> key changes
#   2. helper (uxplay) binary content sha256 -> key changes
#   3. the closure tooling itself (this file, _pkg-closure.sh,
#      _pkg-relocate.sh)                -> key changes
#   4. any cached source realpath gone or changed size (a brew upgrade that
#      moved the Cellar)                -> liveness probe fails -> rebuild
#   5. entry missing / incomplete (.complete absent) -> rebuild
#   The cache is never pruned automatically: entries are content-addressed and
#   an old one is inert. Removing $MIRAGE_PLAY_BUILD_ROOT/closure is always safe.
#
# What a cache entry holds (already relocated, NOT signed):
#   Contents/Frameworks/*.dylib  (+ the 7 version-alias symlinks)
#   Contents/plugins/*.dylib
#   Contents/bin/gst-plugin-scanner
#   closure.tsv        the manifest the entry was built from
#   relocations.tsv    the install_name_tool rewrites applied to those files
#   META              fingerprint used for the key
#   .complete          written last; its absence means "do not use"
#   The helper executable (Contents/MacOS/uxplay, role `bin`) is NOT in the
#   cache: every bundle installs its own copy of the build product, and only
#   the per-bundle copy is relocated (R1).
#
# Signing is never part of the cache: a signature is bound to one vnode of one
# bundle, and copying a signed file into a second bundle would ship a signature
# that no longer describes the file's home. The installed tree is therefore
# signed by whoever owns the last write: package-release.sh (release) or
# pkg_closure_sign_tree (dev bundles, which have no later signing step).
#
# Public API
#   pkg_closure_cache_root                      cache root directory
#   pkg_closure_cache_key <tsv> <uxplay> <scanner>   short content key
#   pkg_closure_manifest_live <tsv>             true when every row still matches disk
#   pkg_closure_ensure_cached <tsv> <uxplay> <scanner> [build root]
#                                               echo the cache entry dir, building it
#                                               on a miss; <tsv> is filled from the
#                                               entry on a hit
#   pkg_closure_install <contents> <entry> <tsv> <uxplay> <reloc_log> [sign 0|1]
#                                               copy the entry into a bundle, relocate
#                                               the helper, self-check, optionally
#                                               ad-hoc sign innermost-first
#   pkg_closure_sign_tree <contents>            ad-hoc sign libs/plugins/scanner/helper;
#                                               echoes the number of files signed

PKG_CLOSURE_CACHE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/_pkg-relocate.sh
. "$PKG_CLOSURE_CACHE_SCRIPT_DIR/_pkg-relocate.sh"
# shellcheck source=scripts/lib/_uxplay-path.sh
. "$PKG_CLOSURE_CACHE_SCRIPT_DIR/_uxplay-path.sh"

# Cache root: <build cache root>/closure. The build root is the same value
# build-core.sh/build-app.sh name with --build-dir, so a custom --build-dir
# keeps its closure next to its core instead of silently sharing another
# build's closure. Callers that resolved a build root themselves pass it in;
# without an argument the shared default is used.
pkg_closure_cache_root() {   # [build root]
    local root="${1:-}"
    if [ -z "$root" ]; then
        root="$(uxplay_default_build_root)" || return 1
    fi
    printf '%s/closure\n' "$root"
}

# One-line description of the inputs that decide the closure content.
#
# Deliberately cheap: it must not walk the dependency graph (that is the work
# the cache exists to avoid). It describes the ROOTS of the closure — if a root
# moves, every image reachable from it may move too. Changes deeper in the
# graph are caught by pkg_closure_manifest_live on a hit.
pkg_closure_fingerprint() {   # <closure.tsv> <uxplay> <scanner>
    local tsv="$1" uxplay="$2" scanner="$3"
    local libdir plugindir names plugin tools core_cache cache_copy

    # Every GStreamer field here comes from the core build record (the one the
    # helper was linked against), never from this shell's pkg-config: a different
    # answer from the shell must not look like "the same closure".
    core_cache="$(pkg_gst_core_cache)"
    cache_copy="$(mktemp "${TMPDIR:-/tmp}/gst-core-cache.XXXXXX")" || cache_copy=""
    [ -n "$cache_copy" ] || cache_copy=/dev/null
    libdir="$(pkg_gst_libdir 2>/dev/null)" || libdir="unknown"
    plugindir="$(pkg_gst_plugindir 2>/dev/null)" || plugindir="unknown"

    printf 'schema=3\n'
    printf 'brew=%s\n' "$(pkg_brew_prefix 2>/dev/null || echo unknown)"
    printf 'core_cache=%s\n' "$core_cache"
    if [ -f "$core_cache" ]; then
        # Only the GStreamer lines: an unrelated reconfigure must not invalidate
        # the closure cache, a different GStreamer must.
        grep -E '^GST[0-9]*_' "$core_cache" >"$cache_copy" 2>/dev/null || true
        printf 'core_gst_sha256=%s\n' "$(shasum -a 256 "$cache_copy" 2>/dev/null | cut -d' ' -f1)"
    else
        printf 'core_gst_sha256=missing\n'
    fi
    [ "$cache_copy" = /dev/null ] || rm -f "$cache_copy"
    printf 'gst_version=%s\n' "$(pkg_gst_version 2>/dev/null || echo unknown)"
    printf 'gst_libdir=%s\n' "$libdir"
    printf 'gst_plugindir=%s\n' "$plugindir"
    printf 'uxplay_sha256=%s\n' "$(shasum -a 256 "$uxplay" 2>/dev/null | cut -d' ' -f1)"
    printf 'scanner=%s\n' "$(stat -f '%N %z %m' "$scanner" 2>/dev/null || echo missing)"
    printf 'tsv_sha256=%s\n' "$(shasum -a 256 "$tsv" 2>/dev/null | cut -d' ' -f1)"
    # The plugin set is the root of the graph: its identity decides which
    # images the closure contains at all.
    for names in $(pkg_core_plugin_names); do
        plugin="$plugindir/libgst$names.dylib"
        printf 'plugin=%s\n' "$(stat -f '%N %z %m' "$plugin" 2>/dev/null || echo "missing $names")"
    done
    # The relocation rules and the graph walk are part of the build identity:
    # a changed rule produces different bytes from the same sources.
    tools="$(cat "$PKG_CLOSURE_CACHE_SCRIPT_DIR/_pkg-closure.sh" \
                 "$PKG_CLOSURE_CACHE_SCRIPT_DIR/_pkg-relocate.sh" \
                 "$PKG_CLOSURE_CACHE_SCRIPT_DIR/_pkg-closure-cache.sh" 2>/dev/null)"
    printf 'tools_sha256=%s\n' "$(printf '%s' "$tools" | shasum -a 256 | cut -d' ' -f1)"
}

# Short directory-safe key derived from the fingerprint above.
pkg_closure_cache_key() {   # <closure.tsv> <uxplay> <scanner>
    local digest
    digest="$(pkg_closure_fingerprint "$@" | shasum -a 256 | cut -d' ' -f1)"
    [ -n "$digest" ] || return 1
    printf 'v2-%s\n' "$(printf '%s' "$digest" | cut -c1-16)"
}

# True when every source image of a manifest is still on disk with the size it
# had when the manifest was written. This is what turns a cache hit into a
# trustworthy hit: a brew upgrade replaces the Cellar directory, so the old
# realpaths stop resolving and the entry is rebuilt instead of shipped.
pkg_closure_manifest_live() {   # <closure.tsv>
    local tsv="$1" role size base real aliases minos missing=0
    [ -s "$tsv" ] || return 1
    while IFS=$'\t' read -r role size base real aliases minos; do
        [ -n "$role" ] || continue
        if [ ! -e "$real" ]; then
            echo "closure-cache: $base is gone ($real) — rebuilding" >&2
            missing=1
            continue
        fi
        if [ "$(stat -f%z "$real" 2>/dev/null)" != "$size" ]; then
            echo "closure-cache: $base changed size — rebuilding" >&2
            missing=1
        fi
    done <"$tsv"
    [ "$missing" = "0" ]
}

# mkdir-based mutex so two concurrent builds never publish into the same entry.
_pkg_closure_lock() {   # <lock dir> [seconds]
    local lock="$1" limit="${2:-300}" waited=0
    while ! mkdir "$lock" 2>/dev/null; do
        # A crashed run leaves the directory behind; break it once it is old.
        if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
            rmdir "$lock" 2>/dev/null || true
            continue
        fi
        [ "$waited" -lt "$limit" ] || return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

_pkg_closure_unlock() {   # <lock dir>
    rmdir "$1" 2>/dev/null || true
}

# Copy one staging directory's entries into a bundle directory: files get the
# usual fresh-vnode treatment (.incoming + mv -f), symlinks are reproduced as
# symlinks with their relative target intact.
_pkg_closure_copy_tree() {   # <src dir> <dst dir>
    local src="$1" dst="$2" e base
    mkdir -p "$dst" || return 1
    for e in "$src"/*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        base="${e##*/}"
        if [ -L "$e" ]; then
            rm -f "$dst/$base"
            ln -s "$(readlink "$e")" "$dst/$base" || return 1
            continue
        fi
        [ -f "$e" ] || continue
        rm -f "$dst/$base.incoming"
        cp "$e" "$dst/$base.incoming" || return 1
        chmod "$(stat -f%Lp "$e")" "$dst/$base.incoming" || return 1
        mv -f "$dst/$base.incoming" "$dst/$base" || return 1
    done
    return 0
}

# Build one cache entry from scratch in a private staging directory, then
# publish it with a single rename so a reader never sees a half-built entry.
#   <entry dir> <closure.tsv> <uxplay> <scanner>
_pkg_closure_cache_build() {
    local entry="$1" tsv="$2" uxplay="$3" scanner="$4"
    local root stage map f rc=0

    root="$(dirname "$entry")"
    mkdir -p "$root" || return 1
    stage="$root/.build-$$-$RANDOM"
    rm -rf "$stage"
    mkdir -p "$stage/Contents" || return 1

    # Stage the closure images (libs + plugins + scanner); role `bin` is the
    # per-bundle helper and is installed by the caller, never cached.
    pkg_stage_closure "$tsv" "$stage/Contents" || { rm -rf "$stage"; return 1; }

    map="$stage/.names"
    pkg_build_name_map "$tsv" "$map" || { rm -rf "$stage"; return 1; }
    : >"$stage/relocations.tsv"
    for f in "$stage/Contents"/Frameworks/*.dylib; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        pkg_relocate_file "$f" lib "$map" "$stage/relocations.tsv" || rc=1
    done
    for f in "$stage/Contents"/plugins/*.dylib; do
        [ -f "$f" ] || continue
        pkg_relocate_file "$f" plugin "$map" "$stage/relocations.tsv" || rc=1
    done
    if [ -f "$stage/Contents/bin/gst-plugin-scanner" ]; then
        pkg_relocate_file "$stage/Contents/bin/gst-plugin-scanner" scanner \
            "$map" "$stage/relocations.tsv" || rc=1
    fi
    rm -rf "$map"
    if [ "$rc" != "0" ]; then
        echo "closure-cache: relocation failed while building $entry" >&2
        rm -rf "$stage"
        return 1
    fi

    cp "$tsv" "$stage/closure.tsv" || { rm -rf "$stage"; return 1; }
    pkg_closure_fingerprint "$tsv" "$uxplay" "$scanner" >"$stage/META" || true
    # .complete last: a staging directory is only ever published complete.
    : >"$stage/.complete"

    rm -rf "$entry"
    if ! mv "$stage" "$entry"; then
        rm -rf "$stage"
        return 1
    fi
    return 0
}

# Return a usable cache entry directory, building it when the key misses.
# On a hit the caller's <closure.tsv> is refreshed from the entry, and the
# entry is validated against the live Homebrew tree first.
pkg_closure_ensure_cached() {   # <closure.tsv> <uxplay> <scanner> [build root]
    local tsv="$1" uxplay="$2" scanner="$3" build_root="${4:-}"
    local root key entry cached_tsv rc=0

    root="$(pkg_closure_cache_root "$build_root")" || return 1
    key="$(pkg_closure_cache_key "$tsv" "$uxplay" "$scanner")" || return 1
    entry="$root/$key"

    mkdir -p "$root" || return 1

    if [ -f "$entry/.complete" ] && [ -s "$entry/closure.tsv" ] \
        && [ -d "$entry/Contents/Frameworks" ]; then
        if pkg_closure_manifest_live "$entry/closure.tsv"; then
            echo "closure-cache: hit $key ($(pkg_closure_summary "$entry/closure.tsv"))" >&2
            cp "$entry/closure.tsv" "$tsv" || return 1
            printf '%s\n' "$entry"
            return 0
        fi
        echo "closure-cache: entry $key is stale — rebuilding" >&2
    else
        echo "closure-cache: miss $key" >&2
    fi

    _pkg_closure_lock "$entry.lock" || {
        echo "closure-cache: could not lock $entry (another build holds it)" >&2
        return 1
    }
    # Another process may have published the entry while we waited.
    if [ -f "$entry/.complete" ] && [ -s "$entry/closure.tsv" ] \
        && pkg_closure_manifest_live "$entry/closure.tsv"; then
        echo "closure-cache: hit $key (built by a concurrent run)" >&2
        cp "$entry/closure.tsv" "$tsv" || rc=1
    else
        echo "closure-cache: building $key ($(pkg_closure_summary "$tsv"))" >&2
        _pkg_closure_cache_build "$entry" "$tsv" "$uxplay" "$scanner" || rc=1
    fi
    _pkg_closure_unlock "$entry.lock"
    [ "$rc" = "0" ] || return 1
    printf '%s\n' "$entry"
}

# Ad-hoc sign every Mach-O this file installed, innermost first: libraries,
# then plugins, then the scanner, then the helper executable. Required on
# Apple Silicon — install_name_tool invalidates the signature of every image it
# rewrites, and dyld refuses to map an unsigned arm64 image — and kept as the
# LAST write so nothing invalidates it again.
#
# The outer .app is deliberately not signed here: sealing a bundle belongs to
# the release path (P-12.1 step 7c), and a dev bundle is launched from a path
# that never carries a seal to begin with.
#
# Prints the number of files signed.
pkg_closure_sign_tree() {   # <contents dir>
    local contents="$1" f n=0
    for f in "$contents"/Frameworks/*.dylib "$contents"/plugins/*.dylib \
             "$contents/bin/gst-plugin-scanner" "$contents/MacOS/uxplay"; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        codesign --force --sign - "$f" >/dev/null 2>&1 || return 1
        n=$((n + 1))
    done
    printf '%s\n' "$n"
}

# Install a cached closure into a bundle and relink it.
#
#   <contents dir>   the helper bundle's Contents directory
#   <entry dir>      pkg_closure_ensure_cached output
#   <closure.tsv>    manifest (the caller keeps its own copy for its report)
#   <uxplay>         the helper executable as installed in <contents>/MacOS/uxplay
#   <reloc log>      receives every install_name_tool rewrite applied here; on
#                    entry it holds the rewrites baked into the cache (libraries,
#                    plugins, scanner) and then the helper's own rows
#   [sign]           1 = ad-hoc sign the installed tree (dev bundles); default 0
#
# Returns non-zero on any copy/relocate/self-check failure.
pkg_closure_install() {   # <contents> <entry> <tsv> <uxplay> <reloc log> [sign]
    local contents="$1" entry="$2" tsv="$3" uxplay="$4" log="$5" sign="${6:-0}"
    local map signed

    [ -d "$entry/Contents/Frameworks" ] || {
        echo "closure-cache: $entry has no Frameworks directory" >&2
        return 1
    }

    # Re-entrancy: these three directories are wholly owned by the closure, so
    # they are rebuilt from scratch. Anything else in the bundle is untouched.
    rm -rf "$contents/Frameworks" "$contents/plugins" "$contents/bin"

    _pkg_closure_copy_tree "$entry/Contents/Frameworks" "$contents/Frameworks" || return 1
    _pkg_closure_copy_tree "$entry/Contents/plugins"    "$contents/plugins"    || return 1
    _pkg_closure_copy_tree "$entry/Contents/bin"        "$contents/bin"        || return 1

    # The helper binary is the bundle's own copy of the build product; only its
    # load commands are rewritten here (R1). Every other image was rewritten
    # when the cache entry was built.
    [ -f "$uxplay" ] || { echo "closure-cache: no helper executable at $uxplay" >&2; return 1; }
    map="$(mktemp -d "${TMPDIR:-/tmp}/pkg-closure-map.XXXXXX")" || return 1
    pkg_build_name_map "$tsv" "$map" || { rm -rf "$map"; return 1; }
    : >"$log"
    [ -s "$entry/relocations.tsv" ] && cat "$entry/relocations.tsv" >>"$log"
    pkg_relocate_file "$uxplay" bin "$map" "$log" "$(pkg_gst_libdir 2>/dev/null)" "$uxplay" \
        || { rm -rf "$map"; return 1; }
    rm -rf "$map"

    # Self-check before anyone signs or ships this: no load path back into
    # Homebrew, no dyld-relative load path that only exists on this machine, and
    # every rewritten install name resolvable inside the bundle.
    if ! pkg_assert_no_homebrew "$contents"; then
        echo "closure-cache: the installed closure still points at Homebrew" >&2
        return 1
    fi
    if ! pkg_assert_no_rpath_deps "$contents"; then
        echo "closure-cache: the installed closure still carries an @rpath/@executable_path load path" >&2
        return 1
    fi
    if ! pkg_assert_ids_resolvable "$contents"; then
        echo "closure-cache: an installed install name does not resolve in the bundle" >&2
        return 1
    fi

    if [ "$sign" = "1" ]; then
        signed="$(pkg_closure_sign_tree "$contents")" || {
            echo "closure-cache: ad-hoc signing the installed closure failed" >&2
            return 1
        }
        echo "closure-cache: ad-hoc signed $signed Mach-O files"
    fi
    return 0
}