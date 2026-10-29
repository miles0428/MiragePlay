#!/bin/bash
# _canonical-path.sh — resolve a directory to the spelling stored on disk.
#
# Why this exists
# ---------------
# This repo can live on a case-insensitive, case-preserving APFS volume, where
#   /srv/work/projects/demo
#   /srv/work/Projects/demo
# are the same inode reached by two different strings. bash short-circuits
# `pwd` when $PWD still names the same inode, so BOTH `pwd` and `pwd -P` echo
# whatever spelling the caller typed. clang keys its module cache by path
# STRING, so the two spellings become two module identities, the second one
# re-defines every module, and ClangImporter/ASTReader segfaults inside
# ReadASTBlock. Paths handed to swift/clang therefore have to be canonical.
#
# `readlink -f` resolves each component against its directory entry and so
# recovers the stored spelling. It requires the path to exist.
#
# Public API (source this file; do not execute it):
#   mp_canonical_dir <dir>
#       Print the on-disk spelling of <dir>. Non-zero when unresolvable.
#   mp_canonical_path <path>
#       Same, but the leaf need not exist yet (build/output directories on a
#       first run). Every existing ancestor is resolved; the not-yet-existing
#       tail is appended verbatim. Use this for CLI arguments.
#   mp_canonical_repo_root <script_path>
#       Print the repo root of a script that lives in scripts/.
#
# All three print nothing on failure so the caller can fail loudly instead of
# silently keeping a mixed spelling.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/_canonical-path.sh"
#   REPO_ROOT="$(mp_canonical_dir "$SCRIPT_DIR/../..")" || exit 1

# Resolve one existing directory to its on-disk spelling.
mp_canonical_dir() {
    local dir="${1:-}"
    local out=""

    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        return 1
    fi

    # Preferred: readlink(1) with -f (macOS 12.3+ / coreutils).
    out="$(readlink -f "$dir" 2>/dev/null)" || out=""
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
    fi

    # Fallback for readlink builds without -f: getcwd(3) returns the kernel's
    # real path. `pwd`, `pwd -P` and python's os.path.realpath all keep the
    # caller's spelling instead, so they are NOT usable here.
    if command -v python3 >/dev/null 2>&1; then
        out="$(python3 -c 'import os, sys
os.chdir(sys.argv[1])
print(os.getcwd())' "$dir" 2>/dev/null)" || out=""
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
            return 0
        fi
    fi

    return 1
}

# Resolve a path whose leaf may not exist yet to its on-disk spelling.
#
# CLI arguments name build/output directories that a first run has not created
# (`--build-dir <repo>/_build/build-verify`). `readlink -f` fails on ANY
# missing component (measured on macOS 15/26: exit 1 for a missing leaf, not
# just a missing parent), and mp_canonical_dir refuses non-directories, so the
# argument cannot be canonicalised in one step. Instead the longest existing
# ancestor is resolved and the remaining tail is appended verbatim — the result
# is canonical from the first build on, so a later invocation that spells the
# same directory differently cannot create a second clang module identity.
#
# Semantics preserved: nothing is created, no mkdir happens here. Callers that
# need the directory still mkdir -p afterwards.
#
# Notes:
#   - a relative path is taken relative to the caller's cwd
#   - an existing non-directory leaf keeps its own name (its parent is
#     resolved); the leaf is not followed through a symlink, only spelled
#   - "." / ".." inside a not-yet-existing tail are joined lexically; the OS
#     cannot resolve such a path either until the intermediate exists
mp_canonical_path() {
    local target="${1:-}"
    local tail=""
    local leaf=""
    local parent=""
    local name=""

    case "$target" in
        ''|-) return 1 ;;
    esac

    # Make it absolute. $PWD may itself carry the caller's spelling, but the
    # ancestor walk resolves every existing component, so the spelling is
    # recovered regardless.
    case "$target" in
        /*) ;;
        *)  target="$PWD/$target" ;;
    esac

    # Trailing slashes carry no meaning for a directory argument.
    while [ "$target" != "/" ] && [ "${target%/}" != "$target" ]; do
        target="${target%/}"
    done

    while :; do
        if [ -d "$target" ]; then
            parent="$(mp_canonical_dir "$target")" || return 1
            printf '%s\n' "${parent}${tail}"
            return 0
        fi
        if [ -e "$target" ]; then
            name="$(basename "$target")"
            parent="$(mp_canonical_dir "$(dirname "$target")")" || return 1
            printf '%s\n' "${parent}/${name}${tail}"
            return 0
        fi
        [ "$target" != "/" ] || return 1
        leaf="$(basename "$target")"
        parent="$(dirname "$target")"
        [ "$parent" != "$target" ] || return 1
        tail="/${leaf}${tail}"
        target="$parent"
    done
}

# Repo root for a script located in <root>/scripts/.
mp_canonical_repo_root() {
    local src="${1:-}"
    local dir=""

    [ -n "$src" ] || return 1
    dir="$(cd "$(dirname "$src")/.." 2>/dev/null && pwd)" || return 1
    mp_canonical_dir "$dir"
}
