#!/bin/bash
# _pkg-relocate.sh — stage the shipping closure into the helper bundle and
# rewrite every Mach-O load path so the bundle needs no Homebrew at runtime.
#
# Source this file from package-release.sh (do not execute it directly):
#
#     . "$REPO_ROOT/scripts/lib/_pkg-relocate.sh"
#
# This implements P-12.1 step 3.5 out of the frozen interface spec (rules
# R1-R9 of `.task_state/survey_packaging-spec-freeze_20261020.md` §5(a) A.3):
#
#   R1  helper uxplay        -> @loader_path/../Frameworks/<name>
#   R2  each lib's own id    -> @loader_path/<name>
#   R3  lib <-> lib          -> @loader_path/<name>          (same directory)
#   R4  plugin -> libs       -> @loader_path/../Frameworks/<name>
#   R5  plugin <-> plugin    -> nothing (no plugin links a plugin)
#   R6  scanner -> libs      -> @loader_path/../Frameworks/<name>
#   R7  version aliases      -> kept as *relative* symlinks (never flattened)
#   R8  alias install names  -> -change targets and -id values use the alias
#   R9  helper -> scanner    -> nothing (the scanner is not a link dependency)
#
# Every Mach-O is written exactly once, at its final path, by `mv -f` from a
# `.incoming` sibling: macOS caches a code signature per vnode, and re-signing
# an inode that was overwritten in place leaves a stale signature behind that
# makes every later exec die (see the vnode note in build-app.sh).
#
# Nothing here signs anything: signing happens after this file has finished
# touching the bundle (P-12.2).

PKG_RELOCATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/_pkg-closure.sh
. "$PKG_RELOCATE_SCRIPT_DIR/_pkg-closure.sh"

# Canonical in-bundle name of an image: the version alias when the image has
# one (R8), otherwise the physical file name.
#   $1  closure.tsv
#   $2  real path of the source image
pkg_canonical_name() {
    local tsv="$1" real="$2"
    awk -F'\t' -v r="$real" '$4 == r { print ($5 != "-" ? $5 : $3); exit }' "$tsv"
}

# Fill a scratch map directory with `key -> canonical-name` so the relocation
# loop does not have to re-scan closure.tsv for every load command.
#   $1  closure.tsv
#   $2  map directory
pkg_build_name_map() {
    local tsv="$1" mapdir="$2"
    mkdir -p "$mapdir" || return 1
    awk -F'\t' -v m="$mapdir" '
        function key(p) { gsub("/", "%", p); return p }
        {
            canon = ($5 != "-" ? $5 : $3)
            print canon > (m "/" key($4))
            close(m "/" key($4))
        }
    ' "$tsv"
}

# Stage the closure into the helper bundle.
#   $1  closure.tsv
#   $2  helper bundle Contents directory
# Copies:
#   role=lib      -> Contents/Frameworks/<physical name> (+ relative alias links)
#   role=plugin   -> Contents/plugins/<name>
#   role=scanner  -> Contents/bin/<name>
# role=bin (the uxplay helper) is placed by build-app.sh, not here.
pkg_stage_closure() {
    local tsv="$1" contents="$2"
    local fw="$contents/Frameworks" plug="$contents/plugins" bindir="$contents/bin"
    local role size base real aliases alias src dest rc=0

    mkdir -p "$fw" "$plug" "$bindir" || return 1

    while IFS=$'\t' read -r role size base real aliases _minos; do
        [ -n "$role" ] || continue
        case "$role" in
            lib)     dest="$fw/$base" ;;
            plugin)  dest="$plug/$base" ;;
            scanner) dest="$bindir/$base" ;;
            bin)     continue ;;
            *)       continue ;;
        esac
        # Copy to a sibling, then rename: the final path is always a fresh
        # vnode, never an in-place overwrite of a previously signed file.
        rm -f "$dest.incoming"
        cp "$real" "$dest.incoming" || { rc=1; continue; }
        chmod "$(stat -f%Lp "$real")" "$dest.incoming"
        mv -f "$dest.incoming" "$dest" || rc=1
    done <"$tsv"

    # Version-alias symlinks (R7). The Cellar keeps them as relative links next
    # to the physical file, so `cp -R` of the link itself preserves both the
    # link type and its relative target.
    while IFS=$'\t' read -r role size base real aliases _minos; do
        [ "$role" = "lib" ] || continue
        [ "$aliases" != "-" ] || continue
        local IFS_SAVE="$IFS"
        IFS=','
        for alias in $aliases; do
            IFS="$IFS_SAVE"
            src="$(dirname "$real")/$alias"
            if [ -L "$src" ]; then
                rm -f "$fw/$alias"
                cp -R "$src" "$fw/$alias" || rc=1
            fi
            if [ ! -L "$fw/$alias" ]; then
                # Fallback for a Cellar that lost the link: reproduce the
                # relative link explicitly (still a link, never a copy).
                rm -f "$fw/$alias"
                ln -s "$base" "$fw/$alias" || rc=1
            fi
        done
        IFS="$IFS_SAVE"
    done <"$tsv"

    return "$rc"
}

# Rewrite one Mach-O in place (at its final path) from a fresh `.incoming`
# sibling, applying R1-R9 for its role.
#   $1  file path inside the bundle
#   $2  role  (bin|lib|plugin|scanner)
#   $3  name map directory
#   $4  relocation log (TSV: file, rule, old, new)
pkg_relocate_file() {
    local file="$1" role="$2" mapdir="$3" log="$4"
    local inc="$file.relocating" dep target_key canon new prefix rule id rc=0

    case "$role" in
        bin)     prefix='@loader_path/../Frameworks/' ;;
        lib)     prefix='@loader_path/' ;;
        plugin)  prefix='@loader_path/../Frameworks/' ;;
        scanner) prefix='@loader_path/../Frameworks/' ;;
        *)       return 1 ;;
    esac

    rm -f "$inc"
    cp "$file" "$inc" || return 1
    chmod "$(stat -f%Lp "$file")" "$inc" || return 1

    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        # Already-relative load commands are left alone: relocating is not
        # idempotent by nature, and a second pass over a relocated file must
        # not try to resolve @loader_path against the build machine.
        case "$dep" in
            @loader_path/*|@rpath/*|@executable_path/*) continue ;;
        esac
        pkg_is_system_image "$dep" && continue
        [ -e "$dep" ] || { echo "relocate: dangling $dep (in $file)" >&2; rc=1; continue; }
        target_key="$(_pkg_key "$(realpath "$dep")")"
        canon=""
        [ -f "$mapdir/$target_key" ] && canon="$(cat "$mapdir/$target_key")"
        if [ -z "$canon" ]; then
            echo "relocate: $dep is not in the closure (referenced by $file)" >&2
            rc=1
            continue
        fi
        new="$prefix$canon"
        [ "$dep" = "$new" ] && continue
        case "$role" in
            bin)     rule=R1 ;;
            lib)     rule=R3 ;;
            plugin)  rule=R4 ;;
            scanner) rule=R6 ;;
        esac
        if install_name_tool -change "$dep" "$new" "$inc" 2>"$inc.err"; then
            printf '%s\t%s\t%s\t%s\n' "${file##*/}" "$rule" "$dep" "$new" >>"$log"
        else
            echo "relocate: install_name_tool -change failed for $file" >&2
            sed 's/^/  /' "$inc.err" >&2
            rc=1
        fi
        rm -f "$inc.err"
    done < <(pkg_dylib_deps "$file")

    # R2: the image's own install name. For an aliased dylib the id must be the
    # alias (R8) - other images reference it by that leaf name.
    if [ "$role" != "scanner" ]; then
        id="$(pkg_dylib_id "$file")"
        if [ -n "$id" ]; then
            canon="$(basename "$id")"
            new="@loader_path/$canon"
            if [ "$id" != "$new" ]; then
                if install_name_tool -id "$new" "$inc" 2>"$inc.err"; then
                    printf '%s\t%s\t%s\t%s\n' "${file##*/}" R2 "$id" "$new" >>"$log"
                else
                    echo "relocate: install_name_tool -id failed for $file" >&2
                    sed 's/^/  /' "$inc.err" >&2
                    rc=1
                fi
                rm -f "$inc.err"
            fi
        fi
    fi

    # The rename is the only write that happens at the final path: new vnode.
    mv -f "$inc" "$file" || rc=1
    return "$rc"
}

# Relocate every Mach-O of the helper bundle (P-12.1 step 3.5d).
#   $1  closure.tsv
#   $2  helper bundle Contents directory
#   $3  log file (TSV of applied rewrites)
pkg_relocate_bundle() {
    local tsv="$1" contents="$2" log="$3"
    local scratch rc=0 f

    scratch="$(mktemp -d "${TMPDIR:-/tmp}/pkg-relocate.XXXXXX")" || return 1
    pkg_build_name_map "$tsv" "$scratch/names" || { rm -rf "$scratch"; return 1; }
    : >"$log"

    # Order mirrors P-11.4: libraries first, then plugins, then scanner, then
    # the helper executable (the helper is the only one that references all of
    # them). Signing order is separate and lives in package-release.sh.
    for f in "$contents"/Frameworks/*.dylib; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        pkg_relocate_file "$f" lib "$scratch/names" "$log" || rc=1
    done
    for f in "$contents"/plugins/*.dylib; do
        [ -f "$f" ] || continue
        pkg_relocate_file "$f" plugin "$scratch/names" "$log" || rc=1
    done
    if [ -f "$contents/bin/gst-plugin-scanner" ]; then
        pkg_relocate_file "$contents/bin/gst-plugin-scanner" scanner "$scratch/names" "$log" || rc=1
    fi
    pkg_relocate_file "$contents/MacOS/uxplay" bin "$scratch/names" "$log" || rc=1

    rm -rf "$scratch"
    return "$rc"
}

# Assert that every rewritten install name resolves to a file that actually
# exists in the bundle: an -id whose leaf name has no directory entry would
# make dyld fail at load time on a clean machine.
#   $1  helper bundle Contents directory
pkg_assert_ids_resolvable() {
    local contents="$1" f id leaf bad=0
    for f in "$contents"/Frameworks/*.dylib "$contents"/plugins/*.dylib; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        id="$(pkg_dylib_id "$f")"
        [ -n "$id" ] || continue
        leaf="${id##*/}"
        case "$f" in
            "$contents"/Frameworks/*)
                if [ ! -e "$contents/Frameworks/$leaf" ]; then
                    printf 'UNRESOLVED_ID %s -> %s\n' "${f##*/}" "$id"
                    bad=1
                fi
                ;;
            "$contents"/plugins/*)
                if [ ! -e "$contents/plugins/$leaf" ]; then
                    printf 'UNRESOLVED_ID %s -> %s\n' "${f##*/}" "$id"
                    bad=1
                fi
                ;;
        esac
    done
    return "$bad"
}

# Assert that no Mach-O of the helper bundle still carries a Homebrew load
# path (P-7.2 point 4). Prints one line per offending file; returns 1 if any.
#   $1  helper bundle Contents directory
pkg_assert_no_homebrew() {
    local contents="$1" f deps bad=0
    for f in "$contents"/Frameworks/*.dylib "$contents"/plugins/*.dylib \
             "$contents/bin/gst-plugin-scanner" "$contents/MacOS/uxplay"; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        deps="$(pkg_dylib_deps "$f" | grep -F '/opt/homebrew/' || true)"
        if [ -n "$deps" ]; then
            printf 'HOMEBREW_LOAD_PATH %s\n%s\n' "${f##*/}" "$deps"
            bad=1
        fi
    done
    return "$bad"
}
