#!/bin/bash
# _pkg-closure.sh — compute the shipping closure of the uxplay/GStreamer stack.
#
# Source this file from package-release.sh (do not execute it directly):
#
#     . "$REPO_ROOT/scripts/lib/_pkg-closure.sh"
#
# The closure is what has to travel inside the helper bundle for it to run on a
# machine without Homebrew. It is NOT "the helper's direct dependencies": it is
# the transitive image set rooted at the GStreamer plugins uxplay asks for,
# plus the helper executable and the GStreamer plugin scanner.
#
# Why the plugins are the root and not the uxplay binary: uxplay itself links
# only 8 Homebrew dylibs, but a pipeline that cannot find libgstlibav.dylib /
# libgstcoreelements.dylib fails at gst_parse_launch with a far less obvious
# error ("Required gstreamer plugin 'app' not found"). Rooting at the plugin
# set makes the closure complete by construction (release contract P-7.2).
#
# Every dependency source is derived from `brew --prefix` / `pkg-config`; no
# Homebrew path is ever written literally in this file.
#
# Public API (all read-only, no bundle writes):
#   pkg_brew_prefix                 Apple-Silicon-or-Intel Homebrew prefix
#   pkg_gst_libdir                  GStreamer library directory (Cellar path)
#   pkg_gst_plugindir               GStreamer plugin directory
#   pkg_gst_scanner                 gst-plugin-scanner executable path
#   pkg_core_plugin_names           the 14 plugin basenames uxplay needs
#   pkg_is_system_image <path>      true for /usr/lib, /System, /Library/Apple
#   pkg_dylib_deps <macho>          LC_LOAD_DYLIB paths of a Mach-O
#   pkg_dylib_id <macho>            LC_ID_DYLIB path of a Mach-O (empty if none)
#   pkg_compute_closure <dir> <uxplay> <scanner>
#                                   writes <dir>/closure.tsv and echoes a
#                                   summary; returns 1 on a dangling reference
#
# closure.tsv is tab separated:
#   role  size_bytes  basename  realpath  aliases  minos
# where `aliases` is a comma separated list of additional leaf names the image
# is referenced by (the version-alias symlinks required by P-7.2/R7-R8), and
# `minos` is the LC_BUILD_VERSION minimum. Empty fields are written as "-"
# because tab is IFS whitespace: an empty field between two tabs would be
# collapsed by `read` and silently shift every column after it.

PKG_CLOSURE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_CLOSURE_REPO_ROOT="$(cd "$PKG_CLOSURE_SCRIPT_DIR/../.." && pwd)"

# --- dependency source discovery ---------------------------------------------

# Homebrew prefix of this machine (never assume /opt/homebrew).
pkg_brew_prefix() {
    local p
    p="$(brew --prefix 2>/dev/null)" || return 1
    [ -n "$p" ] || return 1
    printf '%s\n' "$p"
}

# GStreamer library directory. pkg-config reports the Cellar path directly,
# which is what the closure wants (symlink-free); brew --prefix is the fallback
# for machines without pkg-config on PATH.
pkg_gst_libdir() {
    local d
    d="$(pkg-config --variable=libdir gstreamer-1.0 2>/dev/null)" || d=""
    if [ -n "$d" ] && [ -d "$d" ]; then
        printf '%s\n' "$d"
        return 0
    fi
    d="$(brew --prefix gstreamer 2>/dev/null)" || return 1
    [ -n "$d" ] && [ -d "$d/lib" ] || return 1
    printf '%s\n' "$d/lib"
}

# GStreamer plugin directory (GST_MODULE_SUFFIX = .dylib on macOS lives here).
pkg_gst_plugindir() {
    local d
    d="$(pkg_gst_libdir)" || return 1
    printf '%s\n' "$d/gstreamer-1.0"
}

# gst-plugin-scanner shipped with the same GStreamer keg. It must travel with
# the bundle: its own LC_LOAD_DYLIB points into Homebrew and it has no rpath.
pkg_gst_scanner() {
    local p
    p="$(brew --prefix gstreamer 2>/dev/null)" || return 1
    [ -n "$p" ] || return 1
    printf '%s\n' "$p/libexec/gstreamer-1.0/gst-plugin-scanner"
}

# The 14 plugins uxplay needs. 5 are named by check_plugins(); the other 9 are
# what the audio/video pipelines actually instantiate at runtime (P-7.2 C-5).
pkg_core_plugin_names() {
    printf '%s\n' \
        app libav playback autodetect videoparsersbad \
        coreelements videoconvertscale audioconvert audioresample \
        volume level osxvideo osxaudio typefindfunctions
}

# --- Mach-O inspection --------------------------------------------------------

# System images never travel with the bundle.
pkg_is_system_image() {
    case "$1" in
        /usr/lib/*|/System/*|/Library/Apple/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Print every LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB path of a
# Mach-O, including duplicates (callers dedupe).
pkg_dylib_deps() {
    otool -l "$1" 2>/dev/null | awk '
        /^[[:space:]]*cmd[[:space:]]+LC_LOAD(_WEAK)?_DYLIB[[:space:]]*$/ { want = 1; next }
        /^[[:space:]]*cmd[[:space:]]+LC_REEXPORT_DYLIB[[:space:]]*$/     { want = 1; next }
        want && /^[[:space:]]*name[[:space:]]/ {
            sub(/^[[:space:]]*name[[:space:]]+/, "")
            sub(/ \(offset .*$/, "")
            print
            want = 0
        }
    '
}

# Print the LC_ID_DYLIB install name of a Mach-O (nothing for plain
# executables). `otool -D` prints "<file>:" then the id on the next line.
pkg_dylib_id() {
    otool -D "$1" 2>/dev/null | sed -n '2p'
}

# Print the LC_BUILD_VERSION minos of a Mach-O (empty when the load command is
# absent, e.g. some prebuilt helper binaries).
pkg_dylib_minos() {
    otool -l "$1" 2>/dev/null | awk '
        /LC_BUILD_VERSION/ { f = 1; next }
        f && /^[[:space:]]*minos[[:space:]]/ { print $2; exit }
    '
}

# --- closure computation ------------------------------------------------------

# Flatten a path into a filename-safe key (macOS filenames cannot contain "/").
_pkg_key() {
    printf '%s' "$1" | tr '/' '%'
}

# Record one referenced image: note the leaf name it was referenced by, then
# enqueue it for expansion when it is the first time we see its real path.
#   $1  referencing path (as written in a load command, or a seed path)
#   $2  closure working directory
#   $3  queue file to append newly discovered images to
# Prints the real path on stdout when the image is new (diagnostics only);
# returns 1 on a dangling non-system reference.
_pkg_touch_image() {
    local ref="$1" outdir="$2" next="$3" real key leaf
    if pkg_is_system_image "$ref"; then
        return 0
    fi
    if [ ! -e "$ref" ]; then
        echo "closure: dangling dependency $ref" >&2
        return 1
    fi
    real="$(realpath "$ref")"
    key="$(_pkg_key "$real")"
    leaf="${ref##*/}"
    # Every leaf name an image is referenced by is recorded; a leaf that
    # differs from the physical file name is a version alias that has to be
    # reproduced as a relative symlink (contract P-7.2 / rules R7-R8).
    touch "$outdir/leaves/$key"
    grep -Fxq "$leaf" "$outdir/leaves/$key" || printf '%s\n' "$leaf" >>"$outdir/leaves/$key"
    if [ -f "$outdir/images/$key" ]; then
        return 0
    fi
    printf '%s\n' "$real" >"$outdir/images/$key"
    printf '%s\n' "$real" >>"$next"
    return 0
}

# Compute the closure rooted at the core plugin set and write <dir>/closure.tsv.
#
#   $1  working directory for the manifest and scratch
#   $2  helper executable (uxplay) — travels as role `bin`
#   $3  gst-plugin-scanner       — travels as role `scanner`
#
# Returns 1 (with a message on stderr) when a referenced image is missing.
pkg_compute_closure() {
    local outdir="$1" uxplay="$2" scanner="$3"
    local plugindir libdir names plugin p real key dep leaf rc

    plugindir="$(pkg_gst_plugindir)" || {
        echo "closure: cannot resolve the GStreamer plugin directory" >&2
        return 1
    }
    libdir="$(pkg_gst_libdir)" || {
        echo "closure: cannot resolve the GStreamer library directory" >&2
        return 1
    }
    [ -d "$plugindir" ] || { echo "closure: no plugin dir at $plugindir" >&2; return 1; }
    [ -f "$uxplay" ]    || { echo "closure: no helper binary at $uxplay" >&2; return 1; }
    [ -f "$scanner" ]   || { echo "closure: no gst-plugin-scanner at $scanner" >&2; return 1; }

    local plugindir_real uxplay_real scanner_real
    plugindir_real="$(realpath "$plugindir")"
    uxplay_real="$(realpath "$uxplay")"
    scanner_real="$(realpath "$scanner")"

    mkdir -p "$outdir/images" "$outdir/leaves" "$outdir/queue" || return 1
    : >"$outdir/closure.tsv"
    rc=0

    # Seed: the 14 plugins are the expansion roots. The helper and the scanner
    # travel too; they are expanded as well so that a future relink cannot
    # silently under-ship (their deps are a subset of the plugin closure today).
    local seed="$outdir/queue/0"
    : >"$seed"
    for names in $(pkg_core_plugin_names); do
        plugin="$plugindir/libgst$names.dylib"
        if [ ! -f "$plugin" ]; then
            echo "closure: missing core plugin $plugin" >&2
            return 1
        fi
        _pkg_touch_image "$plugin" "$outdir" "$seed" || rc=1
    done
    _pkg_touch_image "$uxplay"  "$outdir" "$seed" || rc=1
    _pkg_touch_image "$scanner" "$outdir" "$seed" || rc=1

    local cur="$seed" nxt round=0 ref dep
    while [ -s "$cur" ]; do
        nxt="$outdir/queue/$((round + 1))"
        : >"$nxt"
        while IFS= read -r ref; do
            [ -n "$ref" ] || continue
            while IFS= read -r dep; do
                [ -n "$dep" ] || continue
                _pkg_touch_image "$dep" "$outdir" "$nxt" || rc=1
            done < <(pkg_dylib_deps "$ref")
        done <"$cur"
        [ -s "$nxt" ] || rm -f "$nxt"
        cur="$nxt"
        round=$((round + 1))
    done

    # Emit one row per image.
    for img in "$outdir"/images/*; do
        [ -f "$img" ] || continue
        real="$(cat "$img")"
        key="$(_pkg_key "$real")"
        base="${real##*/}"
        case "$real" in
            "$uxplay_real")       role=bin ;;
            "$scanner_real")      role=scanner ;;
            "$plugindir_real"/*)  role=plugin ;;
            *)                    role=lib ;;
        esac
        # aliases = referenced leaf names minus the physical file name, plus the
        # LC_ID_DYLIB basename (a dylib whose id is the alias must keep the
        # alias as its install name — R8).
        local aliases="" l id idleaf
        if [ -f "$outdir/leaves/$key" ]; then
            while IFS= read -r l; do
                [ -n "$l" ] || continue
                [ "$l" = "$base" ] && continue
                case ",$aliases," in
                    *",$l,"*) ;;
                    *) aliases="${aliases:+$aliases,}$l" ;;
                esac
            done <"$outdir/leaves/$key"
        fi
        id="$(pkg_dylib_id "$real")"
        if [ -n "$id" ]; then
            idleaf="${id##*/}"
            if [ "$idleaf" != "$base" ]; then
                case ",$aliases," in
                    *",$idleaf,"*) ;;
                    *) aliases="${aliases:+$aliases,}$idleaf" ;;
                esac
            fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$role" "$(stat -f%z "$real")" "$base" "$real" "${aliases:--}" \
            "$(pkg_dylib_minos "$real" | sed 's/^$/-/')" >>"$outdir/closure.tsv"
    done

    return "$rc"
}

# Print a one-line summary of a closure.tsv (counts + total bytes).
pkg_closure_summary() {
    awk -F'\t' '
        { n++; bytes += $2; c[$1]++
          if ($5 != "-") a += (split($5, t, ",")) }
        END {
            printf "images=%d bytes=%d roles(bin=%d scanner=%d plugin=%d lib=%d) aliases=%d\n",
                   n, bytes, c["bin"], c["scanner"], c["plugin"], c["lib"], a
        }
    ' "$1"
}
