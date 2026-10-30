#!/bin/bash
# build-app.sh — THE single assembler for the MiragePlay .app bundle.
#
# Contract: BLUEPRINT-RELEASE.md P-1.2 ("two resources are copied into the
# bundle by the single assembler scripts/build/build-app.sh"), P-3 (physical
# executables, no symlinks), P-4 (release build + strip), P-8.2 (version
# injection point), P-12.1 steps 1-5. Signing is NOT done here: it belongs to
# scripts/build/package-release.sh, which is the only script that runs codesign
# (P-12.1 step 7, "signing must be the last action").
#
# What this script assembles
#   MiragePlay.app/Contents/
#   ├── Info.plist                      <- app/Resources/Info.plist (+ version)
#   ├── MacOS/MiragePlay                <- physical copy of the build product
#   ├── Resources/                      <- P-11.6 #3: must exist for the seal
#   │   ├── LICENSE                     <- repo LICENSE (GPL-3 full text)
#   │   ├── THIRD-PARTY-NOTICES.md      <- repo notices (index to Licenses/)
#   │   ├── Licenses/*                  <- tracked third-party licence texts
#   │   ├── Strings/terms.json          <- P-1.1
#   │   ├── StatusIcon/icon.svg         <- P-1.1
#   │   └── AppIcon.icns                <- make-appicon.sh (outer bundle icon)
#   └── Helpers/MiragePlay Projection.app/Contents/
#       ├── Info.plist                  <- app/Resources/HelperInfo.plist (+ version)
#       ├── MacOS/uxplay                <- core binary, temp + mv -f
#       ├── Frameworks/*.dylib          <- GStreamer closure (P-7.2)
#       ├── plugins/*.dylib             <- the 14 plugins uxplay needs
#       ├── bin/gst-plugin-scanner      <- the scanner that matches them
#       └── Resources/AppIcon.icns      <- make-appicon.sh
#   The closure is installed by scripts/lib/_pkg-closure-cache.sh — the same
#   code package-release.sh uses — and is ad-hoc signed here, because a dev
#   bundle has no later signing step and dyld refuses unsigned arm64 images.
#   Dev builds get it by default; --no-closure is the fast-iteration escape
#   hatch. Release builds leave the closure to package-release.sh (P-12.1
#   step 3.5) unless --closure is passed explicitly.
#
# Directory timestamps
#   After the bundle is assembled and versioned — and before package-release.sh
#   signs it — every directory inside the bundle (.app itself included, at every
#   depth of the helper bundle) gets the main executable's mtime. A directory's
#   mtime only changes when an entry is added or removed, so a bundle that is
#   rebuilt in place otherwise keeps the date of the build that first created
#   those directories while every file inside is fresh: Finder, and every
#   directory entry in the archive, then report a build time nobody can trust.
#   Files are never touched — their mtimes are the build evidence the release
#   gates read. codesign does not seal directory timestamps.
#
# Usage:
#   build-app.sh [--release] [--out DIR] [--build-dir DIR] [--allow-untagged]
#                [--icon-variant light|transparent] [--closure|--no-closure]
#                [--print-paths]
#
#   --release          shippable build: `swift build -c release`, `strip -x`,
#                      P-8 version injection (version from ./VERSION, else from
#                      a git tag at HEAD)
#   --out DIR          where the .app goes (default <repo>/_build)
#   --build-dir DIR    build cache root (default <repo>/_build).
#                      The core executable is expected at DIR/core/uxplay —
#                      the same <root>/core layout scripts/build/build-core.sh
#                      writes when given the same --build-dir (both derive it
#                      from scripts/lib/_uxplay-path.sh; D-1 fix).
#                      The closure cache lives at DIR/closure.
#   --closure          install the GStreamer closure into the helper bundle
#   --no-closure       skip it (dev only: the bundle then cannot start uxplay
#                      on a machine without Homebrew, and the app reports the
#                      resulting exit as a crash)
#   --print-paths      print the resolved BUILD_DIR= / CORE_UXPLAY= and exit
#                      (no swift, no bundle; used by the path-consistency
#                      assertion in scripts/tests/test-config-engine.sh)
#   --allow-untagged   dev escape hatch for --release: continue without a tag.
#                      The release report then says "not taggable for release";
#                      scripts/build/package-release.sh refuses this on the release
#                      path (P-8.3 + YC ruling 2026-10-20 #2).
#   --icon-variant     light (default) | transparent
#   --appicon-work DIR scratch directory handed to make-appicon.sh. Defaults to a
#                      fresh directory under $TMPDIR that is removed at exit, so
#                      an --out anywhere (including a temp tree) leaves nothing
#                      behind in the checkout. Pass a path to keep the files.
#
# Default (no --release) is the dev build: debug configuration, no version
# injection. The six existing debug harnesses (scripts/tests/test-*.sh) consume
# _build/app.swiftpm/<triple>/debug/MiragePlay, so the no-argument
# invocation must keep producing that artifact (contract P-4.5: the full test
# suite runs against the debug build only).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/_canonical-path.sh
. "$SCRIPT_DIR/../lib/_canonical-path.sh"

# The root must carry the spelling stored on disk, not the spelling the caller
# typed: it feeds `swift build --package-path/--build-path`, and clang keys its
# module cache by path string. `pwd`/`pwd -P` both echo the caller's spelling
# on a case-insensitive volume, so the spelling is recovered with readlink -f.
REPO_ROOT="$(mp_canonical_dir "$SCRIPT_DIR/../..")" || {
    echo "build-app: could not resolve the repository root ($SCRIPT_DIR/../..)" >&2
    exit 1
}
# shellcheck source=scripts/lib/_uxplay-path.sh
. "$SCRIPT_DIR/../lib/_uxplay-path.sh"
# shellcheck source=scripts/lib/_release-layout.sh
. "$SCRIPT_DIR/../lib/_release-layout.sh"

CONFIG="debug"
OUT_DIR="$REPO_ROOT/_build"
# Default build cache root comes from the shared definition, not a local
# literal: build-core.sh resolves the same root, so "no arguments" on both
# sides describes one directory (D-1).
BUILD_DIR="$(uxplay_default_build_root)" || {
    echo "build-app: could not resolve the default build root" >&2
    exit 1
}
ALLOW_UNTAGGED=0
PRINT_PATHS=0
# auto = install the closure unless this is a release build (a release bundle
# gets it from package-release.sh at P-12.1 step 3.5, signed as part of step 7).
CLOSURE_MODE="auto"
APPICON_VARIANT="${MIRAGE_APPICON_VARIANT:-light}"
APPICON_WORK=""
APPICON_WORK_AUTO=0
APP_NAME="MiragePlay"
HELPER_NAME="MiragePlay Projection"

usage() {
    # Header block: everything between the shebang and `set -e`. A line range
    # was used before; it silently truncated the help text whenever the header
    # grew, so the end marker is the code itself.
    sed -n '2,/^set -e$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# Canonicalise a directory-shaped CLI argument and echo it.
#
# Why the argument, not just the repo root: caller-typed spellings reach clang
# verbatim. Measured on 2026-10-20 (task E5): passing
# `--build-dir <repo>/_build/build-verify` in lower case produced 242 files
# spelled `projects` and 279 spelled `Projects` inside that one build dir. The
# same directory under two strings is two clang module identities, and the
# second one re-defines every module -> ASTReader SIGSEGV.
#
# The directory may not exist yet (first build), so mp_canonical_path resolves
# the longest existing ancestor and keeps the tail; creation still happens
# later at the call sites (mkdir -p), exactly as before. No new flags, no
# changed semantics — only the spelling of the value.
canon_dir_arg() {   # <flag> <value>; echoes the canonical path, non-zero on error
    local flag="$1" raw="$2" out=""

    case "$raw" in
        ''|-) echo "build-app.sh: $flag needs a directory (got '${raw}')" >&2; return 1 ;;
    esac
    out="$(mp_canonical_path "$raw")" || {
        echo "build-app.sh: cannot resolve $flag path '$raw' to its on-disk spelling" >&2
        return 1
    }
    printf '%s\n' "$out"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --release)        CONFIG="release" ;;
        --debug)          CONFIG="debug" ;;
        --out)            OUT_DIR="$(canon_dir_arg --out "${2-}")" || exit 1; shift ;;
        --build-dir)      BUILD_DIR="$(canon_dir_arg --build-dir "${2-}")" || exit 1; shift ;;
        --allow-untagged) ALLOW_UNTAGGED=1 ;;
        --closure)        CLOSURE_MODE="on" ;;
        --no-closure)     CLOSURE_MODE="off" ;;
        --icon-variant)   APPICON_VARIANT="${2:?--icon-variant needs a value}"; shift ;;
        --appicon-work)   APPICON_WORK="$(canon_dir_arg --appicon-work "${2-}")" || exit 1; shift ;;
        --print-paths)    PRINT_PATHS=1 ;;
        -h|--help)        usage 0 ;;
        # Legacy positional mode flag from the pre-release script; ignored.
        --embedded|--spawn) ;;
        *) echo "build-app.sh: unknown argument $1" >&2; usage 1 ;;
    esac
    shift
done

APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
HELPER_BUNDLE="$APP_BUNDLE/Contents/Helpers/$HELPER_NAME.app"
SWIFTPM_DIR="$BUILD_DIR/app.swiftpm"
# Derived, never spelled: build-core.sh writes its core build to <root>/core
# using the same shared functions, so any --build-dir agrees between the two
# scripts by construction (D-1).
CORE_UXPLAY="$(uxplay_core_binary "$BUILD_DIR")" || {
    echo "build-app: could not resolve the core binary path under $BUILD_DIR" >&2
    exit 1
}
INFO_PLIST="$REPO_ROOT/app/Resources/Info.plist"
HELPER_INFO_PLIST="$REPO_ROOT/app/Resources/HelperInfo.plist"
RESOURCES_SRC="$REPO_ROOT/app/Resources"

if [ "$PRINT_PATHS" = "1" ]; then
    printf 'BUILD_DIR=%s\nCORE_UXPLAY=%s\n' "$BUILD_DIR" "$CORE_UXPLAY"
    exit 0
fi

# Fail closed before anything is built or packaged (YC ruling 2026-10-25,
# Q3 = both build entries). This script is what puts the core executable into
# the shipped bundle, so a tree that is not the pinned one must stop it even
# when a binary already sits in the build dir — the "edited the tree, only
# rebuilt the app" path that build-core.sh's own gate cannot see. Verifying the
# SOURCE TREE, not the binary's provenance: the build dir records no commit
# (CMakeCache.txt keeps CMAKE_HOME_DIRECTORY, a path, not a revision).
# Placed after the --print-paths exit so that flag stays side-effect free, and
# before the swift build so a blocked run costs ~0.1 s instead of a full build.
if ! uxplay_require_pinned_tree; then
    echo "ERROR: refusing to package the core helper — the UxPlay source tree is not" >&2
    echo "       the tree pinned in core/vendor.lock (build dir: $BUILD_DIR)" >&2
    echo "       see BLUEPRINT.md:63 (fail-closed) and :157 (change the fork, change the pin)" >&2
    exit 1
fi

# Pre-build cache validity gate — READ-ONLY, deliberately (2026-10-30). This
# script consumes <build-dir>/core/uxplay and never configures cmake itself, so
# it cannot rebuild what it rejects: calling the deleting variant here removed
# the tree it was about to package, before anything was compiled or copied, and
# then reported the removal as the error. The next run found no cache at all,
# packaged, and died at the binary check below with "core uxplay binary
# missing" — one stale verdict propagated into a loop with no exit.
#
# Detection is shared with build-core.sh (one definition of "this cache is
# still valid"); deletion belongs to build-core.sh, because it owns the
# `cmake -B` that refills the directory. Here the gate only names the stale
# key=path and hands over the exact command that repairs it, with the build dir
# spelled out. Which renderer mode (--embedded / --spawn) is the caller's
# decision, so this script does not guess one on their behalf.
uxplay_stale_cache_check "$(uxplay_core_build_dir "$BUILD_DIR")" "$(uxplay_src_dir || true)"
if [ "${UXPLAY_STALE_CACHE_STALE:-0}" = "1" ]; then
    echo "ERROR: the core build cache under $BUILD_DIR/core is stale: ${UXPLAY_STALE_CACHE_REASON}" >&2
    echo "       it names a path that no longer exists, so linking it would fail far" >&2
    echo "       from the cause. NOTHING was removed by this script — the built core is" >&2
    echo "       still there and is only rebuilt by the script that owns the cmake dir." >&2
    echo "       run: $REPO_ROOT/scripts/build/build-core.sh --embedded --build-dir $(printf '%q' "$BUILD_DIR")" >&2
    echo "       (or --spawn instead of --embedded, matching the renderer the bundle is" >&2
    echo "        meant to ship)." >&2
    exit 1
fi

# Scratch dir for make-appicon.sh (intermediate SVGs + .iconset dirs).
# Make-appicon's own default lives inside the checkout, so a build whose --out
# pointed into a temp tree still wrote icon work files into the repo (G2). The
# default here is a per-run directory under $TMPDIR, canonicalised like every
# other path that reaches a tool, and dropped on the way out; --appicon-work
# keeps it. Placement is after the --print-paths exit above so that flag's
# output and side effects stay exactly as they were.
if [ -z "$APPICON_WORK" ]; then
    APPICON_WORK="$(mp_canonical_path "${TMPDIR:-/tmp}/mirageplay-appicon-work-$$")" \
        || APPICON_WORK="${TMPDIR:-/tmp}/mirageplay-appicon-work-$$"
    APPICON_WORK_AUTO=1
    cleanup_appicon_work() {
        if [ "$APPICON_WORK_AUTO" = "1" ] && [ -n "$APPICON_WORK" ]; then
            rm -rf "$APPICON_WORK"
        fi
        return 0
    }
    trap cleanup_appicon_work EXIT
fi

echo "=== Building $APP_NAME (config: $CONFIG) ==="
echo "    repo root : $REPO_ROOT"
echo "    build dir : $BUILD_DIR"
echo "    bundle out: $APP_BUNDLE"

if [ "$CONFIG" != "release" ]; then
    echo "NOTE: dev build — debug configuration, no version injection."
    echo "      For a shippable bundle run: scripts/build/build-app.sh --release"
fi

# --- 0. release provenance (P-8.3) -------------------------------------------
# A release bundle must name the commit it came from: the zip, the plist and
# `git rev-parse HEAD` have to describe one immutable tree. This script is the
# only step that writes the bundle, so it records that commit as
# `MirageBuildCommit` (injected with the version below, app and helper alike)
# and refuses a release build from a work tree with uncommitted changes: those
# changes are in the binary but in no commit, so the recorded sha would point at
# a tree that cannot reproduce the shipped bytes.
#
# Scope: release builds only. The dev path (no --release) is exempt — it is
# never published and the test harnesses build debug against a working checkout
# by design. --allow-untagged does not lift this gate: it relaxes the version
# source, not provenance.
BUILD_COMMIT=""
if [ "$CONFIG" = "release" ]; then
    BUILD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
    case "$BUILD_COMMIT" in
        [0-9a-f]*[0-9a-f]*) ;;
        *)
            echo "ERROR: cannot read HEAD in $REPO_ROOT — a release bundle must record the" >&2
            echo "       commit it was built from (P-8.3). Build from a git clone." >&2
            exit 1
            ;;
    esac
    DIRTY_TREE="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" || {
        echo "ERROR: cannot read the work-tree status in $REPO_ROOT — refusing to build a" >&2
        echo "       release bundle whose provenance cannot be asserted (P-8.3)." >&2
        exit 1
    }
    if [ -n "$DIRTY_TREE" ]; then
        echo "ERROR: the work tree has uncommitted changes — refusing to build a release bundle (P-8.3)." >&2
        printf '%s\n' "$DIRTY_TREE" | sed 's/^/       /' >&2
        echo "       the bundle would carry code that exists in no commit, so the commit it" >&2
        echo "       records (${BUILD_COMMIT}) could not reproduce it. Commit or stash first." >&2
        echo "       dev builds (no --release) are exempt." >&2
        exit 1
    fi
    echo "=== Release provenance: $BUILD_COMMIT (work tree clean) ==="
fi

# --- 1. build the Swift app (P-4.1) ------------------------------------------
# -c release for anything that ships; the build path keeps the SwiftPM cache
# out of the repo's app/ directory so the source tree stays clean.
SWIFT_CFG_ARGS=()
if [ "$CONFIG" = "release" ]; then
    SWIFT_CFG_ARGS=(-c release)
fi
swift build --package-path "$REPO_ROOT/app" --build-path "$SWIFTPM_DIR" \
    "${SWIFT_CFG_ARGS[@]}" 2>&1

BIN_DIR="$(swift build --package-path "$REPO_ROOT/app" --build-path "$SWIFTPM_DIR" \
    "${SWIFT_CFG_ARGS[@]}" --show-bin-path)"
EXE_PATH="$BIN_DIR/$APP_NAME"
[ -x "$EXE_PATH" ] || { echo "ERROR: build product missing at $EXE_PATH" >&2; exit 1; }
echo "    swift bin : $BIN_DIR"

# --- 2. assemble the outer bundle (P-12.1 step 2, P-3.1) ---------------------
echo "=== Packaging .app bundle ==="
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"

# Physical executable, never a symlink (P-3.1). Same temp + mv -f discipline as
# the helper below: the destination is always a fresh vnode so a cached code
# signature can never belong to a previous build of this path.
rm -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME.incoming"
cp "$EXE_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME.incoming"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME.incoming"
mv -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME.incoming" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# --- 3. resources (P-1.1, P-9.3) --------------------------------------------
# Copied file-by-file so macOS metadata (.DS_Store) can never ride along.
echo "=== Copying resources ==="
mkdir -p "$APP_BUNDLE/Contents/Resources/Strings" \
         "$APP_BUNDLE/Contents/Resources/StatusIcon"
cp "$RESOURCES_SRC/Strings/terms.json"     "$APP_BUNDLE/Contents/Resources/Strings/terms.json"
cp "$RESOURCES_SRC/StatusIcon/icon.svg"    "$APP_BUNDLE/Contents/Resources/StatusIcon/icon.svg"
cp "$REPO_ROOT/LICENSE"                    "$APP_BUNDLE/Contents/Resources/LICENSE"
chmod 644 "$APP_BUNDLE/Contents/Resources/Strings/terms.json" \
          "$APP_BUNDLE/Contents/Resources/StatusIcon/icon.svg" \
          "$APP_BUNDLE/Contents/Resources/LICENSE"

# --- 3.2 third-party licence texts (P-9.3) ----------------------------------
# The app embeds FFmpeg, GStreamer, UxPlay and a dozen libraries, and several of
# those licences (GPL-3.0, LGPL-2.1, Apache-2.0) require the full text to travel
# with the binary. Until now the only licence in the bundle was the project's
# own, so a recipient of the .app had no way to read the terms of the code
# inside it. Copy the tracked texts verbatim — no conversion, no rewriting: a
# licence text that differs from its original is not the licence.
#
# The names come from the checkout, so a text added to Licenses/ ships without
# touching this script — but the set is asserted against the manifest in
# scripts/lib/_release-layout.sh first, because "copy whatever is there" ships a
# bundle that under-delivers the moment a text is dropped or renamed. One full
# text per licence, thirteen of them, by name.
LICENSES_SRC="$REPO_ROOT/Licenses"
[ -d "$LICENSES_SRC" ] || {
    echo "ERROR: no $LICENSES_SRC — the bundle must carry the third-party licence texts (P-9.3)." >&2
    exit 1
}
if [ "$(mp_license_file_names "$LICENSES_SRC")" != "$(mp_license_file_names_expected)" ]; then
    echo "ERROR: $LICENSES_SRC does not carry the expected licence texts (P-9.3)." >&2
    echo "       unexpected: $(comm -13 <(mp_license_file_names_expected) <(mp_license_file_names "$LICENSES_SRC") | tr '\n' ' ')" >&2
    echo "       missing   : $(comm -23 <(mp_license_file_names_expected) <(mp_license_file_names "$LICENSES_SRC") | tr '\n' ' ')" >&2
    echo "       the manifest is mp_license_file_names_expected in scripts/lib/_release-layout.sh" >&2
    exit 1
fi
LICENSES_DEST="$APP_BUNDLE/Contents/Resources/Licenses"
# The bundle directory survives between builds on the same machine, so a
# licence text removed from Licenses/ would otherwise stay in the shipped
# .app forever — the destination is rebuilt, not merged. Asserted by P-9.3.
rm -rf "$LICENSES_DEST"
mkdir -p "$LICENSES_DEST"
LICENSE_COUNT=0
for lic in "$LICENSES_SRC"/*; do
    [ -f "$lic" ] || continue
    case "${lic##*/}" in
        .*) continue ;;   # metadata, never a licence text
    esac
    cp "$lic" "$LICENSES_DEST/${lic##*/}"
    chmod 644 "$LICENSES_DEST/${lic##*/}"
    LICENSE_COUNT=$((LICENSE_COUNT + 1))
done
[ "$LICENSE_COUNT" -gt 0 ] || {
    echo "ERROR: $LICENSES_SRC holds no licence texts — refusing to build a bundle that under-delivers (P-9.3)." >&2
    exit 1
}

# The notices file is the index to those texts: without it the Licenses/ folder
# is an unlabelled pile of files, and without the folder the notices point at
# nothing. They ship together or not at all.
[ -f "$REPO_ROOT/THIRD-PARTY-NOTICES.md" ] || {
    echo "ERROR: no $REPO_ROOT/THIRD-PARTY-NOTICES.md — it is the index to Contents/Resources/Licenses/ (P-9.3)." >&2
    exit 1
}
cp "$REPO_ROOT/THIRD-PARTY-NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD-PARTY-NOTICES.md"
chmod 644 "$APP_BUNDLE/Contents/Resources/THIRD-PARTY-NOTICES.md"
echo "    licences : $LICENSE_COUNT text(s) + THIRD-PARTY-NOTICES.md"

# --- 3.5 outer bundle icon (Finder / Launchpad identity) ---------------------
# The user sees THIS bundle in Finder and Launchpad, so the icon has to live
# here with a matching CFBundleIconFile (app/Resources/Info.plist). Generating
# it only for the nested helper left the shipped app with a blank document
# icon (YC, 2026-10-20). Same variant as the helper: one visual identity.
echo "=== Rendering outer app icon (variant: $APPICON_VARIANT) ==="
bash "$REPO_ROOT/scripts/build/make-appicon.sh" \
    --out "$APP_BUNDLE/Contents/Resources/AppIcon.icns" --variant "$APPICON_VARIANT" \
    --work "$APPICON_WORK"
[ -s "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ] || {
    echo "ERROR: outer AppIcon.icns was not produced" >&2
    exit 1
}
chmod 644 "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# --- 4. nested projection helper bundle (P-12.1 step 3) ----------------------
# The helper binary is a copy of the built core executable (same file, packed
# into a bundle so macOS resolves the Dock identity from the bundle's
# Info.plist / AppIcon.icns).
#
# The upstream UxPlay sources are NOT in this repo's version control
# (2026-10-19 decouple): they are materialized on demand by
# scripts/build/vendor-uxplay.sh from the fork pinned in core/vendor.lock. This
# script consumes only the already-built core binary; run
# scripts/build/build-core.sh --embedded first when it is missing.
if [ ! -x "$CORE_UXPLAY" ]; then
    echo "ERROR: core uxplay binary missing at $CORE_UXPLAY" >&2
    echo "       expected layout: <build-dir>/core/uxplay (build dir: $BUILD_DIR)" >&2
    echo "       run: $REPO_ROOT/scripts/build/build-core.sh --embedded --build-dir $(printf '%q' "$BUILD_DIR")" >&2
    if [ "$BUILD_DIR" != "$(uxplay_default_build_root)" ]; then
        echo "       note: --build-dir is a cache root shared with build-core.sh;" >&2
        echo "             pass the SAME --build-dir to both scripts." >&2
    fi
    exit 1
fi
echo "=== Packaging projection helper bundle ==="
mkdir -p "$HELPER_BUNDLE/Contents/MacOS" "$HELPER_BUNDLE/Contents/Resources"
cp "$HELPER_INFO_PLIST" "$HELPER_BUNDLE/Contents/Info.plist"

# Install the helper executable via fresh temp file + rename — never a plain
# in-place cp. macOS caches the code signature per vnode; overwriting the
# binary in place while a process is executing/mapping the old one leaves
# that vnode's cached signature stale (cs_mtime != mtime), after which every
# exec/mmap of the helper is SIGKILLed ("Taskgated Invalid Signature" /
# "rejecting invalid page") until the vnode identity changes. Repro +
# evidence: task wave1r8-buildgate (build-gate report, copy kept by the caller).
# Never revert to plain cp.
HELPER_EXEC="$HELPER_BUNDLE/Contents/MacOS/uxplay"
rm -f "$HELPER_EXEC.incoming"
cp "$CORE_UXPLAY" "$HELPER_EXEC.incoming"
chmod +x "$HELPER_EXEC.incoming"
mv -f "$HELPER_EXEC.incoming" "$HELPER_EXEC"

bash "$REPO_ROOT/scripts/build/make-appicon.sh" \
    --out "$HELPER_BUNDLE/Contents/Resources/AppIcon.icns" --variant "$APPICON_VARIANT" \
    --work "$APPICON_WORK"

# --- 5. strip (P-4.2, release only) -----------------------------------------
# Recorded sizes feed the release report. Strip happens on the `.incoming`
# sibling so the write that lands on the final path is still a fresh vnode.
STATS_MAIN_BEFORE=0; STATS_MAIN_AFTER=0
STATS_HELPER_BEFORE=0; STATS_HELPER_AFTER=0
if [ "$CONFIG" = "release" ]; then
    echo "=== Stripping release products (strip -x) ==="
    for pair in "$APP_BUNDLE/Contents/MacOS/$APP_NAME:MAIN" \
                "$HELPER_EXEC:HELPER"; do
        target="${pair%:*}"
        which="${pair##*:}"
        before="$(stat -f%z "$target")"
        cp "$target" "$target.incoming"
        chmod "$(stat -f%Lp "$target")" "$target.incoming"
        strip -x "$target.incoming"
        after="$(stat -f%z "$target.incoming")"
        mv -f "$target.incoming" "$target"
        echo "    $(basename "$target"): $before -> $after bytes"
        if [ "$which" = "MAIN" ]; then
            STATS_MAIN_BEFORE="$before"; STATS_MAIN_AFTER="$after"
        else
            STATS_HELPER_BEFORE="$before"; STATS_HELPER_AFTER="$after"
        fi
    done
fi

# --- 6. version injection (P-8.2, P-8.3) ------------------------------------
# Version source, in order of precedence:
#   1. the tracked VERSION file at the repo root — the only place that can
#      carry a pre-release suffix into the build facts (`1.0.0-rc.1`);
#   2. the git tag at HEAD, for a checkout that predates the VERSION file.
# Nothing here may fall back to the hand-written "1.0" of
# app/Resources/*.plist: a bundle that quietly claims a version nobody
# released is exactly the silent release P-8.3 forbids.
#
# CFBundleShortVersionString still receives the numeric core only (`1.0.0`):
# Apple specifies three period-separated integers, so `-rc.N` is stripped for
# the bundle and preserved in full as APP_VERSION_FULL in the build facts.
VERSION=""
VERSION_FULL=""
VERSION_SOURCE=""
VERSION_FILE="$REPO_ROOT/VERSION"
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"

# Read the first line of <file> as a version string, trailing whitespace and a
# stray CR removed. Non-zero when the file is absent or the line is empty, so
# the caller can fall back instead of shipping an empty version.
read_version_file() {   # <path>; echoes the version, non-zero when unavailable
    local file="$1" line=""
    [ -f "$file" ] || return 1
    line="$(head -n 1 "$file" 2>/dev/null | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
    [ -n "$line" ] || return 1
    printf '%s' "$line"
}

# Strip a trailing -rc.N so the value is acceptable as
# CFBundleShortVersionString (three period-separated integers).
numeric_version() {     # <version>; echoes the numeric core
    printf '%s' "$1" | sed 's/-rc\.[0-9]*$//'
}

if [ "$CONFIG" = "release" ]; then
    TAG="$(git -C "$REPO_ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
    VERSION_FULL="$(read_version_file "$VERSION_FILE" || true)"
    if [ -n "$VERSION_FULL" ]; then
        VERSION="$(numeric_version "$VERSION_FULL")"
        VERSION_SOURCE="VERSION file"
        # A tag that disagrees with VERSION means one of the two is stale; the
        # VERSION file wins (it is the tracked artifact), but say so loudly.
        if [ -n "$TAG" ] && [ "v$VERSION_FULL" != "$TAG" ]; then
            echo "WARNING: VERSION ($VERSION_FULL) does not match the tag at HEAD ($TAG)." >&2
            echo "WARNING: using VERSION; fix one of them before publishing (P-8.3)." >&2
        fi
        case "$VERSION" in
            [0-9]*.[0-9]*.[0-9]*) ;;
            *)
                echo "ERROR: VERSION ($VERSION_FULL) does not yield a numeric" >&2
                echo "       X.Y.Z version (got '$VERSION'); CFBundleShortVersionString" >&2
                echo "       requires three period-separated integers." >&2
                exit 1
                ;;
        esac
    elif [ -n "$TAG" ]; then
        VERSION_FULL="$(printf '%s' "$TAG" | sed 's/^v//')"
        VERSION="$(numeric_version "$VERSION_FULL")"
        VERSION_SOURCE="git tag $TAG"
    elif [ "$ALLOW_UNTAGGED" = "1" ]; then
        VERSION="0.0.0"
        VERSION_FULL="0.0.0"
        VERSION_SOURCE="UNTAGGED-DEV (no VERSION file, no git tag at HEAD) — NOT RELEASABLE"
        echo "WARNING: no VERSION file and no git tag at HEAD — dev placeholder version 0.0.0." >&2
        echo "WARNING: this bundle must NOT be published (contract P-8.3)." >&2
    else
        echo "ERROR: no VERSION file and no git tag at HEAD; refusing to build a release bundle." >&2
        echo "       Add VERSION (or tag first: git tag -a v1.0.0-rc.1), or pass" >&2
        echo "       --allow-untagged for a local dev bundle (contract P-8.3)." >&2
        exit 1
    fi
    echo "=== Injecting version ($VERSION, build $BUILD_NUMBER) ==="
    echo "    source: $VERSION_SOURCE"
    echo "    full  : $VERSION_FULL"
    echo "    commit: $BUILD_COMMIT"
    for plist in "$APP_BUNDLE/Contents/Info.plist" \
                 "$HELPER_BUNDLE/Contents/Info.plist"; do
        plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
        plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$plist"
        # The commit these bytes came from (P-8.3). CFBundleVersion stays the
        # commit count for Apple; this key is the sha itself, so `plutil` on the
        # shipped bundle names the tree `git rev-parse HEAD` named at build time.
        plutil -replace MirageBuildCommit -string "$BUILD_COMMIT" "$plist"
    done
fi

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
plutil -lint "$HELPER_BUNDLE/Contents/Info.plist" >/dev/null

# --- 6.5 gstreamer closure (P-7.2, dev bundles by default) -------------------
# Without the closure the helper cannot start on any machine that does not have
# Homebrew's GStreamer: gst_init fails with "Required gstreamer plugin 'app'
# not found", uxplay exits 1, and the app has no way to tell that apart from a
# crash — so it respawns, and every dev harness measures a respawn storm
# instead of the behaviour under test. The dev bundle therefore ships the same
# closure the release bundle does, through the same shared code.
#
# Last write wins: this runs after strip and version injection because both
# rewrite Mach-O files, and pkg_closure_install finishes by ad-hoc signing the
# tree it just installed (install_name_tool invalidates every signature it
# touches, and dyld will not map unsigned arm64 images).
CLOSURE_STATE="skipped"
if [ "$CLOSURE_MODE" = "on" ] \
    || { [ "$CLOSURE_MODE" = "auto" ] && [ "$CONFIG" != "release" ]; }; then
    echo "=== Installing the GStreamer closure (shared with package-release.sh) ==="
    # shellcheck source=scripts/lib/_pkg-closure-cache.sh
    . "$SCRIPT_DIR/../lib/_pkg-closure-cache.sh"

    CLOSURE_WORK="$BUILD_DIR/closure-work"
    rm -rf "$CLOSURE_WORK"
    mkdir -p "$CLOSURE_WORK"

    # Which GStreamer to ship is decided by the core's own configure record, not
    # by this shell's pkg-config: the vendored CMakeLists prefers an installed
    # GStreamer.framework, and following the shell there produced a bundle whose
    # libraries came from Homebrew while the helper had been linked against the
    # framework.
    export PKG_CLOSURE_CORE_CACHE="$(dirname "$CORE_UXPLAY")/CMakeCache.txt"

    GST_SCANNER="$(pkg_gst_scanner)" || {
        echo "ERROR: cannot resolve gst-plugin-scanner — is GStreamer installed?" >&2
        echo "       (the scanner must come from the GStreamer the core was linked against;" >&2
        echo "        see the gst-source: lines above)" >&2
        exit 1
    }
    pkg_compute_closure "$CLOSURE_WORK" "$CORE_UXPLAY" "$GST_SCANNER" || {
        echo "ERROR: could not compute the GStreamer closure (see messages above)" >&2
        exit 1
    }
    CLOSURE_TSV="$CLOSURE_WORK/closure.tsv"
    CLOSURE_ENTRY="$(pkg_closure_ensure_cached "$CLOSURE_TSV" "$CORE_UXPLAY" "$GST_SCANNER" "$BUILD_DIR")" || {
        echo "ERROR: the closure cache could not be prepared" >&2
        exit 1
    }
    pkg_closure_install "$HELPER_BUNDLE/Contents" "$CLOSURE_ENTRY" "$CLOSURE_TSV" \
        "$HELPER_EXEC" "$CLOSURE_WORK/relocations.tsv" 1 || {
        echo "ERROR: installing the closure into the helper bundle failed" >&2
        exit 1
    }
    CLOSURE_STATE="installed ($(pkg_closure_summary "$CLOSURE_TSV"))"
    echo "    closure    : $CLOSURE_STATE"
    echo "    cache entry: $(basename "$CLOSURE_ENTRY")"
    echo "    bundles    : Frameworks=$(ls -1 "$HELPER_BUNDLE/Contents/Frameworks" | wc -l | tr -d ' ')" \
         "plugins=$(ls -1 "$HELPER_BUNDLE/Contents/plugins" | wc -l | tr -d ' ')" \
         "scanner=$([ -x "$HELPER_BUNDLE/Contents/bin/gst-plugin-scanner" ] && echo yes || echo no)"
elif [ "$CONFIG" = "release" ]; then
    echo "NOTE: release build — the closure is installed by scripts/build/package-release.sh"
    echo "      (P-12.1 step 3.5). Pass --closure to install it here instead."
fi

# --- 6.6 directory timestamps (honest build time on disk and in the zip) -----
# A directory's mtime only moves when an entry is added or removed from it.
# Rebuilding overwrites existing files in place, so Contents/, Contents/MacOS/,
# _CodeSignature/, Helpers/ and the .app itself kept the date of the build that
# first created them. Measured 2026-10-23 on the shipped bundle: all 69 files
# carried that run's date while eight directory entries still said 2026-10-20,
# so Finder's list view — and every directory entry in the archive — reported a
# build that never happened. That defeats the point of the build-time chain
# (HEAD -> plist -> binary -> signature -> zip): a timestamp a reader cannot
# trust is worse than no timestamp.
#
# Only directories are touched. File mtimes are the build evidence — the
# staleness and signature gates in release.sh read the main executable and
# CodeResources — so they stay exactly as the build left them. The reference is
# the main executable, not "now", so the whole tree describes one instant:
# the moment the binary that ships was written.
#
# codesign seals file contents, modes and the resource envelope; it does not
# cover directory timestamps, so this cannot invalidate the seal. It still runs
# before package-release.sh signs (P-12.1 step 7) and the release path verifies
# with `codesign --verify --deep --strict` afterwards.
echo "=== normalizing directory timestamps to the build time ==="
MAIN_BIN_TIMES="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
[ -f "$MAIN_BIN_TIMES" ] || {
    echo "ERROR: no main executable at $MAIN_BIN_TIMES to use as the build time" >&2
    exit 1
}
# -exec ... + batches the whole directory list into as few touch calls as the
# argument limit allows; -type d keeps every file out of the command.
DIR_TOTAL="$(find "$APP_BUNDLE" -type d | wc -l | tr -d ' ')"
find "$APP_BUNDLE" -type d -exec touch -r "$MAIN_BIN_TIMES" {} +
echo "    directories: $DIR_TOTAL stamped to $(date -r "$(stat -f%m "$MAIN_BIN_TIMES")" '+%Y-%m-%d %H:%M:%S')"
echo "    files      : untouched (their mtimes are the build evidence)"

# --- 7. sanity --------------------------------------------------------------
[ ! -L "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ] || {
    echo "ERROR: $APP_BUNDLE/Contents/MacOS/$APP_NAME is a symlink (P-3.1)" >&2
    exit 1
}
if find "$APP_BUNDLE" -name '.DS_Store' | grep -q .; then
    echo "ERROR: .DS_Store leaked into the bundle" >&2
    exit 1
fi

# Machine-readable build facts for scripts/build/package-release.sh (which feeds
# them into the release report). Kept out of the bundle: modifying anything
# inside it after signing is forbidden (P-12.2).
META_FILE="$BUILD_DIR/app-build-meta.env"
mkdir -p "$BUILD_DIR"
{
    echo "APP_BUILD_CONFIG=$CONFIG"
    echo "APP_BUNDLE=$APP_BUNDLE"
    echo "APP_BIN_PATH=$EXE_PATH"
    echo "APP_VERSION=$VERSION"
    echo "APP_VERSION_FULL=$VERSION_FULL"
    echo "APP_VERSION_SOURCE=$VERSION_SOURCE"
    echo "APP_BUILD_NUMBER=$BUILD_NUMBER"
    echo "APP_BUILD_COMMIT=$BUILD_COMMIT"
    echo "APP_STRIP_BEFORE_MAIN=$STATS_MAIN_BEFORE"
    echo "APP_STRIP_AFTER_MAIN=$STATS_MAIN_AFTER"
    echo "APP_STRIP_BEFORE_HELPER=$STATS_HELPER_BEFORE"
    echo "APP_STRIP_AFTER_HELPER=$STATS_HELPER_AFTER"
    echo "APP_CLOSURE=$CLOSURE_STATE"
} >"$META_FILE"
while IFS='=' read -r k v; do
    printf 'MIRAGE_META %s=%s\n' "$k" "$v"
done <"$META_FILE"

echo "=== Build complete: $APP_BUNDLE ==="
echo "    helper bundle : $HELPER_BUNDLE"
echo "    helper exec   : $HELPER_EXEC (variant icon: $APPICON_VARIANT)"
