#!/bin/bash
# release.sh — build, sign, and archive MiragePlay.app as one command.
#
# Default (no flags): the whole chain, in order, each step stopping the run
#   [1/3] build    scripts/build/build-app.sh --release --out <out> --closure
#   [2/3] sign     scripts/build/package-release.sh --sign-only --app <app> --out <out>
#   [3/3] package  archive the signed bundle plus README.md into
#                  <out>/mirageplay-<VERSION>.zip, laid out as
#                    mirageplay-<VERSION>/MiragePlay.app
#                    mirageplay-<VERSION>/README.md
#   A zip written by this mode therefore carries bytes this run just built and
#   just signed. build-app.sh never runs codesign (package-release.sh is the
#   only signer in the chain, P-12.1 step 7 "signing must be the last action"),
#   so building first and signing second is enforced here rather than left to
#   the operator's memory. Any step that fails exits non-zero and no archive is
#   written.
#
# --package-only: archive a bundle that is already on disk
#   Skips [1/3] and [2/3] and archives <app> exactly as it stands. Both content
#   gates below stay active in this mode, so a stale or unsigned bundle is
#   refused instead of shipped; the gates are what make the shortcut safe.
#
# Archive layout
#   The zip carries exactly one versioned folder at its root —
#       mirageplay-<VERSION>/
#         MiragePlay.app/
#         README.md
#         docs/            (README.zh-TW, build, usage, language, configuration, images/)
#         LICENSE
#         THIRD-PARTY-NOTICES.md
#         CONTRIBUTING.md
#         Licenses/        (third-party licence texts, also inside the bundle)
#         .github/ISSUE_TEMPLATE/
#   — which is the shape of the hand-built testkits under packaging/testkit/,
#   extended with everything README.md links to. The recipient unpacks one
#   folder and drags the app out of it; the archive root is never a bare .app,
#   so two releases can be unpacked side by side.
#
#   The documentation travels with the archive rather than staying in the
#   repository because the release note is only useful if its links open. The
#   0.1.0 archive shipped a README that pointed at docs/, LICENSE,
#   THIRD-PARTY-NOTICES.md and CONTRIBUTING.md while containing none of them, so
#   every link died on extraction — an offline recipient had a README and
#   nothing it referred to. The set is declared once in
#   scripts/lib/_release-layout.sh and asserted twice: presence in the archive,
#   and resolution of every relative link in the staged copy.
#
#   The third-party licence texts travel in two places on purpose. Inside
#   MiragePlay.app/Contents/Resources/Licenses/ they are what the app carries
#   (GPL-3.0 and LGPL-2.1 require the full text to accompany the binary); at the
#   archive root they are what a recipient reads without opening the bundle and
#   what THIRD-PARTY-NOTICES.md links to. There is one full text per licence —
#   thirteen files, components under the same licence sharing a file — and the
#   set is declared by name in mp_license_file_names_expected
#   (scripts/lib/_release-layout.sh) rather than taken from whatever the tree
#   happens to hold. The checkout is compared against that manifest, and the same
#   set must then be present in both places; neither may carry a text the
#   checkout does not have, so a bundle built from an older tree fails the
#   reverse check.
#
#   The archive is written with
#       ditto -c -k --norsrc --keepParent
#   `--sequesterRsrc` used to deposit extended attributes and resource forks in
#   a __MACOSX/ sibling that every recipient sees in the extracted folder and no
#   recipient can use. Nothing in the bundle needs a resource fork (P-3:
#   physical executables, no symlinks; the closure is copied in as real files),
#   so `--norsrc` omits the sidecar instead of shipping dead weight. Nothing
#   inside the .app is rewritten and `codesign --verify --deep --strict` still
#   passes on the extracted bundle: dropping the sidecar changes the archive,
#   not the signature. The layout is asserted after writing, so a stray
#   top-level entry or a reappearing __MACOSX/ tree refuses the publish.
#
# Gates and escape hatches (both modes, fail closed)
#   The gates always run — the default mode included — so the archive is checked
#   the same way whether the bundle was built here or handed in.
#
#   Staleness gate
#     A zip must not carry bytes older than the code it was built from. This
#     script compares the mtime of the bundle's main executable
#     (Contents/MacOS/CFBundleExecutable) with the commit time of the last
#     commit that touched the build inputs:
#         git log -1 --format=%ct -- app VERSION core/vendor.lock scripts/build
#     The baseline is the last change to something the binary is actually built
#     from — the app sources, the version file, the pinned core and the build
#     scripts — not HEAD. A docs-only or test-only commit moves HEAD without
#     moving a single byte of the build, so it must not invalidate a bundle that
#     is current; comparing against HEAD made every typo fix cost a rebuild.
#     When the binary is older than that build-input commit, the archive would
#     ship bytes missing that change — the script refuses, exits non-zero, and
#     prints the rebuild command. An empty log (no commit has ever touched those
#     paths), an unreadable commit time, or a missing/unreadable executable is a
#     refusal too, never a silent pass: with no build-input baseline the
#     freshness of the bundle cannot be asserted.
#
#   Signature gate
#     The binary-vs-build-inputs gate cannot see a signature that fell behind:
#     build-app.sh rebuilds the executable and package-release.sh is the only
#     step that signs it. Rebuild without re-signing and the bundle pairs a
#     fresh binary with the previous signature — codesign --verify fails, yet the
#     binary is newer than the build-input baseline, so the gate above passes.
#     This script therefore also compares the mtime of Contents/_CodeSignature/CodeResources
#     (rewritten by every codesign run) with the main executable and refuses
#     when the signature is older. A missing signature directory (an app that
#     never went through package-release.sh) and an unreadable stat are
#     refusals too.
#
#   --allow-stale
#     The explicit, visible escape hatch: it prints a WARNING and archives
#     anyway (re-releasing an older bundle on purpose). It covers both gates —
#     one flag, one meaning: archive a bundle whose freshness cannot be
#     asserted. It cannot skip a build or a signing failure: [1/3] and [2/3]
#     stop the run before any gate is consulted.
#
# Version precedence
#   ./VERSION is required. A git tag at HEAD is only cross-checked: when the tag
#   and VERSION disagree this script warns and continues, because archiving an
#   older bundle (`--app`) legitimately runs on a re-tagged or untagged HEAD.
#
# Tag gate (fail closed, no bypass flag)
#   A release archive needs a tag at HEAD: without one the zip names a version
#   but no immutable point, which is the silent release P-8.3 forbids. This
#   script therefore refuses to archive when `git describe --tags --exact-match
#   HEAD` is empty — in both modes. [2/3] used to hard-code --allow-untagged at
#   package-release.sh, which switched off that script's own tag gate
#   (package-release.sh:163-168) and let an untagged HEAD produce a zip that
#   called itself NOT RELEASABLE; the flag is gone and no flag replaces it.
#   Tag first, then run this script.
#
# Provenance gate (fail closed)
#   build-app.sh writes MirageBuildCommit (the sha it built from) into both
#   Info.plists. This script compares that key with `git rev-parse HEAD` and
#   refuses when it is missing or different: a bundle that cannot name the
#   commit at HEAD is either older than the tree or was not built by
#   build-app.sh, and archiving it would ship bytes no commit explains. This
#   also closes the `--package-only` shortcut: an app from another tree is
#   refused instead of archived under this tag.
#
# Usage:
#   release.sh [--app PATH] [--out DIR] [--package-only] [--allow-stale]
#
#   --app PATH      the bundle to archive (default <out>/MiragePlay.app).
#                   Only meaningful with --package-only: the default mode builds
#                   into <out> and would archive an unrelated tree, so combining
#                   --app with a build is refused.
#   --out DIR       where the build lands and the zip is written
#                   (default <repo>/packaging/dist)
#   --package-only  do not build, do not sign; archive the bundle already on disk
#   --allow-stale   archive even when a content gate trips (see above)
#   -h, --help      print this help and exit
#
# Exit status: 0 on a written archive, non-zero on every refusal or failure.
# The archive lands under packaging/, which .gitignore excludes (group D): it is
# a build artifact and must never be committed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/_canonical-path.sh
. "$SCRIPT_DIR/../lib/_canonical-path.sh"
# shellcheck source=scripts/lib/_release-layout.sh
. "$SCRIPT_DIR/../lib/_release-layout.sh"

REPO_ROOT="$(mp_canonical_dir "$SCRIPT_DIR/../..")" || {
    echo "release: could not resolve the repository root ($SCRIPT_DIR/../..)" >&2
    exit 1
}

APP_NAME="MiragePlay"
DIST_DIR="$REPO_ROOT/packaging/dist"
OUT_DIR=""
APP=""
APP_GIVEN=0
PACKAGE_ONLY=0
ALLOW_STALE=0
VERSION_FILE="$REPO_ROOT/VERSION"
# Shipped inside the archive root, verbatim: no renaming, no re-wrapping.
README_FILE="$REPO_ROOT/README.md"
BUILD_APP="$REPO_ROOT/scripts/build/build-app.sh"
PACKAGE_RELEASE="$REPO_ROOT/scripts/build/package-release.sh"

usage() {
    # Header block: everything between the shebang and the first code line.
    sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

die() { printf 'release: ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'release: WARNING: %s\n' "$*" >&2; }

# Print a stage banner so a long build shows where the run is sitting.
banner() {  # <step> <total> <title>
    printf '\n=== [%s/%s] %s ===\n' "$1" "$2" "$3"
}

# Canonicalise a directory-shaped CLI argument and echo it. Same rationale as
# build-app.sh: on a case-insensitive volume the caller's spelling is not the
# spelling stored on disk, and this repo keys everything by path string.
canon_dir_arg() {   # <flag> <value>; echoes the canonical path, non-zero on error
    local flag="$1" raw="$2" out=""
    [ -n "$raw" ] || { echo "release: $flag needs a path" >&2; return 1; }
    out="$(mp_canonical_path "$raw")" || {
        echo "release: $flag: cannot resolve $raw" >&2
        return 1
    }
    printf '%s\n' "$out"
}

# Read the first line of <file> as a version string, trailing whitespace and a
# stray CR removed. Non-zero when the file is absent or the line is empty.
read_version_file() {   # <path>; echoes the version, non-zero when unavailable
    local file="$1" line=""
    [ -f "$file" ] || return 1
    line="$(head -n 1 "$file" 2>/dev/null | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
    [ -n "$line" ] || return 1
    printf '%s' "$line"
}

# Strip a trailing -rc.N, the form Apple's CFBundleShortVersionString rejects.
numeric_version() {     # <version>; echoes the numeric core
    printf '%s' "$1" | sed 's/-rc\.[0-9]*$//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --app)          APP="$(canon_dir_arg --app "${2-}")" || exit 1; APP_GIVEN=1; shift ;;
        --out)          OUT_DIR="$(canon_dir_arg --out "${2-}")" || exit 1; shift ;;
        --package-only) PACKAGE_ONLY=1 ;;
        --allow-stale)  ALLOW_STALE=1 ;;
        -h|--help)      usage 0 ;;
        *)              echo "release: unknown argument $1" >&2; usage 1 ;;
    esac
    shift
done

if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$DIST_DIR"
fi

if [ "$PACKAGE_ONLY" != "1" ] && [ "$APP_GIVEN" = "1" ]; then
    die "--app selects a bundle that is already on disk and cannot be combined with a build; use --package-only --app PATH, or --out DIR to choose where the build lands."
fi

if [ -z "$APP" ]; then
    # --app defaults to the canonical output root, spelled on disk.
    APP="$(mp_canonical_path "$OUT_DIR/$APP_NAME.app")" || {
        echo "release: cannot resolve the default app path $OUT_DIR/$APP_NAME.app" >&2
        exit 1
    }
fi

# --- version ---------------------------------------------------------------
# Read before anything expensive runs: a repo without VERSION cannot name its
# archive, and finding that out after a ten-minute build helps nobody.
VERSION_FULL="$(read_version_file "$VERSION_FILE")" || {
    echo "release: ERROR: no usable $VERSION_FILE — the archive name needs a version." >&2
    echo "         add it first (one line, e.g. 1.0.0-rc.1); nothing was written." >&2
    exit 1
}
VERSION="$(numeric_version "$VERSION_FULL")"

TAG="$(git -C "$REPO_ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [ -z "$TAG" ]; then
    die "no git tag at HEAD — refusing to archive (P-8.3). A release names an immutable point, and this HEAD has none. Tag the commit first, then rerun: git tag -a v$VERSION_FULL -m \"MiragePlay $VERSION_FULL\""
fi
if [ "v$VERSION_FULL" != "$TAG" ]; then
    warn "VERSION ($VERSION_FULL) does not match the tag at HEAD ($TAG) — continuing; the archive carries the VERSION value."
fi

# --- build + sign (skipped by --package-only) ------------------------------
TOTAL_STEPS=3
START_EPOCH="$(date +%s)"

if [ "$PACKAGE_ONLY" = "1" ]; then
    echo "=== MiragePlay release (--package-only: no build, no sign) ==="
    echo "    app     : $APP"
else
    banner 1 "$TOTAL_STEPS" "build  ($BUILD_APP --release --closure)"
    echo "    out     : $OUT_DIR"
    echo "    app     : $APP"
    [ -x "$BUILD_APP" ] || die "no executable build step at $BUILD_APP — cannot build the bundle."
    "$BUILD_APP" --release --out "$OUT_DIR" --closure \
        || die "step 1/$TOTAL_STEPS (build) failed — no archive was written. Fix the build and rerun."
    [ -d "$APP" ] || die "step 1/$TOTAL_STEPS (build) reported success but left no bundle at $APP."

    banner 2 "$TOTAL_STEPS" "sign   ($PACKAGE_RELEASE --sign-only)"
    [ -x "$PACKAGE_RELEASE" ] || die "no executable signing step at $PACKAGE_RELEASE — cannot sign the bundle."
    # --out is forwarded with --app on purpose: package-release.sh derives its
    # smoke probe log ($OUT_DIR/launch.log) and its default report path from
    # OUT_DIR, and OUT_DIR defaults there to <repo>/packaging/dist — a
    # gitignored directory a clean checkout does not have. Without --out this
    # step wrote its probe into a path that did not exist and died with
    # "packaging/dist/launch.log: No such file or directory" on any run whose
    # own --out pointed elsewhere. The bundle path still comes from --app.
    "$PACKAGE_RELEASE" --sign-only --app "$APP" --out "$OUT_DIR" \
        || die "step 2/$TOTAL_STEPS (sign) failed — no archive was written. Fix the signature and rerun."
fi

# --- the bundle ------------------------------------------------------------
[ -d "$APP" ] || die "no .app at $APP (pass --app PATH with --package-only)."
[ -f "$APP/Contents/Info.plist" ] || die "$APP/Contents/Info.plist is missing — that is not a bundle."

# --- the release note ------------------------------------------------------
# Shipped verbatim as README.md at the archive root; a missing file is a refusal,
# not a silently README-less zip.
[ -f "$README_FILE" ] || die "no README.md at $README_FILE — that file is the archive's release note."

# --- the documentation surface ---------------------------------------------
# README.md links to the documentation, the licence, the notices and the
# contribution guide; a recipient who cannot open those links has been handed a
# broken archive. Every file in the surface must be in the checkout before
# anything is staged, so a missing document stops the run here instead of
# producing a zip whose links die on extraction.
SURFACE_MISSING=""
while IFS= read -r surface; do
    [ -n "$surface" ] || continue
    [ -e "$REPO_ROOT/$surface" ] || SURFACE_MISSING="$SURFACE_MISSING $surface"
done <<EOF
$(mp_release_root_entries)
EOF
if [ -n "$SURFACE_MISSING" ]; then
    for surface in $SURFACE_MISSING; do
        printf 'release: ERROR: missing from the checkout: %s\n' "$surface" >&2
    done
    die "the archive would ship dead links — restore the files above (see scripts/lib/_release-layout.sh)."
fi

# The licence texts are the one part of the surface that is generated data
# rather than documentation, and an empty directory would otherwise satisfy
# every path check while delivering nothing.
[ -n "$(mp_license_file_names "$REPO_ROOT/$MP_LICENSES_DIRNAME")" ] \
    || die "no licence texts in $REPO_ROOT/$MP_LICENSES_DIRNAME — refusing to publish an archive that carries none."

PLIST="$APP/Contents/Info.plist"
BUNDLE_SHORT="$(plutil -extract CFBundleShortVersionString raw "$PLIST" 2>/dev/null || true)"
BUNDLE_BUILD="$(plutil -extract CFBundleVersion raw "$PLIST" 2>/dev/null || true)"
[ -n "$BUNDLE_SHORT" ] || die "$PLIST has no CFBundleShortVersionString."
[ -n "$BUNDLE_BUILD" ] || die "$PLIST has no CFBundleVersion."

# --- provenance gate (fail closed) -----------------------------------------
# build-app.sh writes MirageBuildCommit — the sha it built from — into both
# Info.plists. A bundle that does not name HEAD was built from another tree (or
# by another path), and archiving it under this tag would ship bytes no commit
# explains: that is what made the earlier 0.1.0 zip untraceable. Missing key,
# unreadable HEAD, mismatch: every case is a refusal, never a warning.
HEAD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
BUNDLE_COMMIT="$(plutil -extract MirageBuildCommit raw "$PLIST" 2>/dev/null || true)"
case "$HEAD_COMMIT" in
    [0-9a-f]*[0-9a-f]*) ;;
    *) die "cannot read HEAD in $REPO_ROOT — cannot prove which commit $APP was built from." ;;
esac
if [ -z "$BUNDLE_COMMIT" ]; then
    die "$PLIST carries no MirageBuildCommit — this bundle cannot name the commit it came from (P-8.3). Rebuild it in one go: $REPO_ROOT/scripts/build/release.sh"
fi
if [ "$BUNDLE_COMMIT" != "$HEAD_COMMIT" ]; then
    die "$APP was built from $BUNDLE_COMMIT but HEAD is $HEAD_COMMIT — refusing to archive a bundle from another tree (P-8.3). Rebuild it at this commit: $REPO_ROOT/scripts/build/release.sh"
fi

# The bundle carries the numeric core only (Apple's three-integer rule), so an
# -rc.N VERSION matches it by design. A mismatch means the .app was built from a
# different version than ./VERSION claims — say so instead of shipping silently.
if [ "$BUNDLE_SHORT" != "$VERSION" ]; then
    warn "bundle says $BUNDLE_SHORT but VERSION ($VERSION_FULL) strips to $VERSION."
    warn "the archive will be named mirageplay-$VERSION_FULL.zip while the bundle reports $BUNDLE_SHORT."
fi

# --- staleness gate (fail closed) -----------------------------------------
# A zip must not carry bytes older than the code it was built from. build-app.sh
# writes the bundle, package-release.sh signs it, and this script archives it:
# nothing in that chain notices when the build inputs change after the build, so
# the archive silently ships a binary without the newest change. Compare the main
# executable's mtime with the commit time of the last commit that touched a build
# input (`app`, `VERSION`, `core/vendor.lock`, `scripts/build`) and refuse when
# the binary is older. HEAD is deliberately not the baseline: a docs-only commit
# moves HEAD but changes nothing the binary is built from. A read that fails, or
# a log with no build-input commit at all, is a refusal too, never a pass.
EXEC_NAME="$(plutil -extract CFBundleExecutable raw "$PLIST" 2>/dev/null || true)"
[ -n "$EXEC_NAME" ] || EXEC_NAME="$APP_NAME"
MAIN_BIN="$APP/Contents/MacOS/$EXEC_NAME"
[ -f "$MAIN_BIN" ] || die "no executable at $MAIN_BIN — cannot prove this bundle is not stale."

fmt_epoch() { date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$1"; }

BIN_MTIME="$(stat -f%m "$MAIN_BIN" 2>/dev/null || true)"
case "$BIN_MTIME" in
    ''|*[!0-9]*) die "cannot read the mtime of $MAIN_BIN — refusing to archive unverifiable bytes." ;;
esac

# --- signature gate (fail closed) ------------------------------------------
# A signature covers the bytes that existed when it was written. build-app.sh
# rebuilds the executable and package-release.sh signs it afterwards; skip the
# signing step and the bundle carries a fresh binary under the previous
# signature. `codesign --verify` rejects such a bundle, but the
# binary-vs-build-inputs gate below happily passes it because the binary *is* new
# — so this gate is the only place that can catch a stale signature. Compare
# CodeResources (rewritten
# by every codesign run, so its mtime tracks the last signing) with the main
# executable. Absent signature, unreadable stat: refusal, never a pass.
SIG_RESOURCES="$APP/Contents/_CodeSignature/CodeResources"

if [ ! -f "$SIG_RESOURCES" ]; then
    if [ "$ALLOW_STALE" != "1" ]; then
        echo "release: ERROR: $APP carries no signature — refusing to archive an unsigned bundle." >&2
        echo "         missing: $SIG_RESOURCES" >&2
        echo "         package-release.sh is the only signer in this chain; a bundle that" >&2
        echo "         skipped it must never be published." >&2
        echo "         sign the bundle, verify it, then archive:" >&2
        echo "           $PACKAGE_RELEASE --sign-only --app \"$APP\" --out \"$OUT_DIR\"" >&2
        echo "           codesign --verify --deep --strict \"$APP\"" >&2
        echo "         or rerun without --package-only to build and sign in one go." >&2
        echo "         archive the unsigned bundle on purpose: release.sh --allow-stale ..." >&2
        exit 1
    fi
    warn "no signature at $SIG_RESOURCES — archiving an unsigned bundle because --allow-stale was passed."
    SIGN_NOTE="MISSING (no _CodeSignature, --allow-stale)"
else
    SIG_MTIME="$(stat -f%m "$SIG_RESOURCES" 2>/dev/null || true)"
    case "$SIG_MTIME" in
        ''|*[!0-9]*) SIG_MTIME="" ;;
    esac

    if [ -z "$SIG_MTIME" ]; then
        if [ "$ALLOW_STALE" != "1" ]; then
            echo "release: ERROR: cannot read the mtime of $SIG_RESOURCES — refusing to archive." >&2
            echo "         the signature's age is unprovable, so this script will not archive on a guess." >&2
            echo "         check   : stat -f%m \"$SIG_RESOURCES\"" >&2
            echo "         re-sign : $PACKAGE_RELEASE --sign-only --app \"$APP\" --out \"$OUT_DIR\"" >&2
            echo "         override: release.sh --allow-stale ... (archives with a WARNING)" >&2
            exit 1
        fi
        warn "cannot read the mtime of $SIG_RESOURCES — archiving unverified signature freshness (--allow-stale)."
        SIGN_NOTE="unknown (signature mtime unreadable, --allow-stale)"
    elif [ "$SIG_MTIME" -lt "$BIN_MTIME" ]; then
        if [ "$ALLOW_STALE" != "1" ]; then
            echo "release: ERROR: the signature on $APP is older than its main executable — refusing to archive." >&2
            echo "         executable: $MAIN_BIN" >&2
            echo "                     modified $(fmt_epoch "$BIN_MTIME")" >&2
            echo "         signature : $SIG_RESOURCES" >&2
            echo "                     written  $(fmt_epoch "$SIG_MTIME")" >&2
            echo "         the binary is newer than its signature: the bundle was rebuilt after the" >&2
            echo "         last signing run, so the signature covers the previous binary and" >&2
            echo "         codesign --verify rejects it. Re-sign, verify, then archive:" >&2
            echo "           $PACKAGE_RELEASE --sign-only --app \"$APP\" --out \"$OUT_DIR\"" >&2
            echo "           codesign --verify --deep --strict \"$APP\"" >&2
            echo "         or rerun without --package-only to build and sign in one go." >&2
            echo "         archive this bundle on purpose: release.sh --allow-stale ..." >&2
            exit 1
        fi
        warn "the signature on $APP is older than its executable ($(fmt_epoch "$SIG_MTIME") < $(fmt_epoch "$BIN_MTIME")) — archiving because --allow-stale was passed."
        SIGN_NOTE="NO — signature $(fmt_epoch "$SIG_MTIME") < binary $(fmt_epoch "$BIN_MTIME") (--allow-stale)"
    else
        SIGN_NOTE="yes (signature $(fmt_epoch "$SIG_MTIME") >= binary $(fmt_epoch "$BIN_MTIME"))"
    fi
fi

# Baseline for freshness: the newest commit that touched something the binary is
# actually built from. HEAD is the wrong yardstick — a docs-only commit moves HEAD
# without moving a byte of the build, so comparing against HEAD invalidated a
# perfectly current bundle and charged a full rebuild for a typo fix.
BUILD_INPUTS=(app VERSION core/vendor.lock scripts/build)
BUILD_INPUT_EPOCH="$(git -C "$REPO_ROOT" log -1 --format=%ct -- "${BUILD_INPUTS[@]}" 2>/dev/null || true)"
case "$BUILD_INPUT_EPOCH" in
    ''|*[!0-9]*) BUILD_INPUT_EPOCH="" ;;
esac
BUILD_INPUT_COMMIT="$(git -C "$REPO_ROOT" log -1 --format='%h %s' -- "${BUILD_INPUTS[@]}" 2>/dev/null || true)"

REBUILD_HINT="$BUILD_APP --release --out $OUT_DIR --closure"

if [ -z "$BUILD_INPUT_EPOCH" ]; then
    if [ "$ALLOW_STALE" != "1" ]; then
        echo "release: ERROR: no commit in $REPO_ROOT has touched the build inputs (app, VERSION, core/vendor.lock, scripts/build)." >&2
        echo "         with no build-input commit there is no baseline, the bundle's freshness" >&2
        echo "         cannot be asserted, and this script will not archive on a guess." >&2
        echo "         check   : git -C \"$REPO_ROOT\" log -1 --format=%ct -- app VERSION core/vendor.lock scripts/build" >&2
        echo "         override: release.sh --allow-stale ... (archives with a WARNING)" >&2
        exit 1
    fi
    warn "no build-input commit to compare against (app, VERSION, core/vendor.lock, scripts/build) — archiving $MAIN_BIN unverified (--allow-stale)."
    FRESH_NOTE="unknown (no build-input commit, --allow-stale)"
elif [ "$BIN_MTIME" -lt "$BUILD_INPUT_EPOCH" ]; then
    if [ "$ALLOW_STALE" != "1" ]; then
        echo "release: ERROR: $APP is older than the last change to the build inputs — refusing to archive stale bytes." >&2
        echo "         app binary   : $MAIN_BIN" >&2
        echo "                        built $(fmt_epoch "$BIN_MTIME")" >&2
        echo "         build inputs : ${BUILD_INPUT_COMMIT:-?}" >&2
        echo "                        committed $(fmt_epoch "$BUILD_INPUT_EPOCH")" >&2
        echo "                        baseline: git log -1 --format=%ct -- app VERSION core/vendor.lock scripts/build" >&2
        echo "         the zip would ship a binary that predates the newest change to app/, VERSION," >&2
        echo "         core/vendor.lock or scripts/build/." >&2
        echo "         build, sign and archive in one go (that is this script's default mode):" >&2
        echo "           $REPO_ROOT/scripts/build/release.sh" >&2
        echo "         or rebuild and sign the bundle by hand:" >&2
        echo "           $REBUILD_HINT" >&2
        echo "           $PACKAGE_RELEASE --sign-only --app \"$APP\" --out \"$OUT_DIR\"" >&2
        echo "         archive this older bundle on purpose: release.sh --allow-stale ..." >&2
        exit 1
    fi
    warn "$MAIN_BIN is older than the last build-input commit ($(fmt_epoch "$BIN_MTIME") < $(fmt_epoch "$BUILD_INPUT_EPOCH"), ${BUILD_INPUT_COMMIT:-?}) — archiving stale bytes because --allow-stale was passed."
    FRESH_NOTE="NO — binary $(fmt_epoch "$BIN_MTIME") < build inputs ${BUILD_INPUT_COMMIT:-?} $(fmt_epoch "$BUILD_INPUT_EPOCH") (--allow-stale)"
else
    FRESH_NOTE="yes (binary $(fmt_epoch "$BIN_MTIME") >= build inputs ${BUILD_INPUT_COMMIT:-?} $(fmt_epoch "$BUILD_INPUT_EPOCH"))"
fi

SIGNATURE="$(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p' || true)"
SIGNATURE="${SIGNATURE%%$'\n'*}"
[ -n "$SIGNATURE" ] || warn "codesign reports no signature on $APP — archiving an unsigned bundle."

mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/mirageplay-$VERSION_FULL.zip"
TARGET="$ZIP.incoming"
# One folder at the archive root, named after the release, exactly like the
# testkits in packaging/testkit/: mirageplay-<VERSION>/{MiragePlay.app,README.md}.
FOLDER="mirageplay-$VERSION_FULL"

banner 3 "$TOTAL_STEPS" "package (archive the signed bundle)"
echo "    version : $VERSION_FULL (bundle: $BUNDLE_SHORT / build $BUNDLE_BUILD, ${SIGNATURE:-unsigned})"
echo "    commit  : $BUNDLE_COMMIT"
echo "    tag     : ${TAG:-<none at HEAD>}"
echo "    fresh   : $FRESH_NOTE"
echo "    signed  : $SIGN_NOTE"
echo "    layout  : $FOLDER/{$(basename "$APP"),README.md,docs/,LICENSE,THIRD-PARTY-NOTICES.md,CONTRIBUTING.md,$MP_LICENSES_DIRNAME/}"
echo "    zip     : $ZIP"

# `ditto` archives exactly one source tree, so the bundle and the documentation
# cannot be passed as separate arguments. Stage both inside one versioned folder
# on the same volume (APFS clones the bundle rather than copying its bytes) and
# archive that folder with --keepParent, so the folder itself becomes the
# archive root.
STAGE="$(mktemp -d "$OUT_DIR/.release-stage.XXXXXX")" \
    || die "could not create a staging directory under $OUT_DIR."
trap 'rm -rf "$STAGE"' EXIT
STAGE_ROOT="$STAGE/$FOLDER"
STAGE_APP="$STAGE_ROOT/$(basename "$APP")"
mkdir -p "$STAGE_ROOT" || die "could not create the staging folder $STAGE_ROOT."

# Write beside the destination and move it into place: a half-written archive is
# never visible under the real name, and no existing archive is deleted first
# (mv -f replaces it atomically).
ditto "$APP" "$STAGE_APP" || die "ditto failed to stage $APP."
[ -d "$STAGE_APP/Contents" ] || die "staging lost the bundle layout of $APP."
ditto "$README_FILE" "$STAGE_ROOT/README.md" || die "ditto failed to stage $README_FILE."

# Stage the rest of the documentation surface next to the README, plus the
# licence texts. README.md's links are relative to the folder a recipient
# extracts, so a file that is not staged here is a link that dies on
# extraction — the reason the 0.1.0 archive shipped a README pointing at
# seven files it did not contain.
#
# Each path is staged into its own parent so the subdirectories (docs/images,
# .github/ISSUE_TEMPLATE) keep the names the documents use.
while IFS= read -r surface; do
    [ -n "$surface" ] || continue
    [ "$surface" = "README.md" ] && continue   # already staged verbatim above
    mkdir -p "$STAGE_ROOT/$(dirname "$surface")" \
        || die "could not create the staging directory for $surface."
    ditto "$REPO_ROOT/$surface" "$STAGE_ROOT/$surface" \
        || die "ditto failed to stage $surface."
done <<EOF
$(mp_release_root_entries)
EOF

# The licence texts are staged at the archive root as well as inside the
# bundle. The copies are not redundant: the bundle's copies are what the app
# itself carries, these are what a recipient reads without opening the bundle
# and what THIRD-PARTY-NOTICES.md links to. Copying file-by-file keeps
# .DS_Store and friends out of the archive without a second cleanup pass.
mkdir -p "$STAGE_ROOT/$MP_LICENSES_DIRNAME" \
    || die "could not create $STAGE_ROOT/$MP_LICENSES_DIRNAME."
while IFS= read -r lic; do
    [ -n "$lic" ] || continue
    ditto "$REPO_ROOT/$MP_LICENSES_DIRNAME/$lic" "$STAGE_ROOT/$MP_LICENSES_DIRNAME/$lic" \
        || die "ditto failed to stage licence text $lic."
done <<EOF
$(mp_license_file_names "$REPO_ROOT/$MP_LICENSES_DIRNAME")
EOF

# --norsrc: no resource fork / extended-attribute sidecar, hence no __MACOSX/.
# --keepParent: the staged versioned folder becomes the archive's top level.
ditto -c -k --norsrc --keepParent "$STAGE_ROOT" "$TARGET" \
    || die "ditto failed to archive $STAGE_ROOT."
[ -s "$TARGET" ] || die "ditto produced an empty archive at $TARGET."

# Layout check. The archive must carry exactly one top-level folder, that folder
# must hold the bundle, the documentation surface and the licence texts, and
# nothing may sit outside it. The listing is captured once so `grep -q` cannot
# SIGPIPE `unzip` under `set -o pipefail`.
#
# The surface assertions live in scripts/lib/_release-layout.sh because
# package-release.sh has to answer the same question about the bundle it signs;
# one answer, one place.
LIST="$(unzip -Z1 "$TARGET")"
case "$LIST" in
    *__MACOSX*) die "the archive carries a __MACOSX/ tree — refusing to publish a zip with metadata sidecars." ;;
esac
case "$LIST" in
    *.DS_Store*) die "the archive carries a .DS_Store — refusing to publish a zip with Finder metadata." ;;
esac
STRAY="$(printf '%s\n' "$LIST" | grep -v "^$FOLDER/" | head -n 5 || true)"
[ -z "$STRAY" ] || die "the archive has entries outside $FOLDER/ (e.g. $(printf '%s' "$STRAY" | head -n 1)) — refusing to publish a flat zip."
LIST_FILE="$STAGE/listing.txt"
printf '%s\n' "$LIST" > "$LIST_FILE"
mp_check_archive_entries "$LIST_FILE" "$FOLDER" "$(basename "$APP")" "$REPO_ROOT" \
    || die "the archive is missing part of its documentation or licence surface — refusing to publish a zip whose README links into nothing."

# The links themselves: every relative link in the shipped documents must
# resolve inside the staged tree, which is the tree a recipient receives. This
# is checked on the staged copy rather than the checkout because staging is
# where a path can be lost (a subdirectory not created, a file skipped), and a
# link that resolves in the checkout but not in the archive is exactly the
# defect this gate exists for.
STAGED_DOCS=()
while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    STAGED_DOCS+=("$doc")
done <<EOF
$(mp_shipped_documents)
EOF
mp_check_relative_links "$STAGE_ROOT" "${STAGED_DOCS[@]}" \
    || die "the staged documentation has broken relative links — refusing to publish a zip whose documents do not open."

mv -f "$TARGET" "$ZIP"

BYTES="$(stat -f%z "$ZIP")"
MIB="$(awk -v b="$BYTES" 'BEGIN { printf "%.1f", b / 1048576 }')"
ENTRIES="$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
TOP_LEVEL="$(printf '%s\n' "$LIST" | awk -F/ 'NF { print $1 }' | sort -u | tr '\n' ' ')"
ELAPSED=$(( $(date +%s) - START_EPOCH ))
ELAPSED_HUMAN="$(printf '%dm%02ds' $((ELAPSED / 60)) $((ELAPSED % 60)))"

echo "=== Archive written ==="
echo "    path    : $ZIP"
echo "    size    : $BYTES bytes ($MIB MiB)"
echo "    entries : $ENTRIES"
echo "    top     : $TOP_LEVEL"
echo "    sha256  : $SHA"
echo "    elapsed : $ELAPSED_HUMAN"
echo "    first 5 :"
printf '%s\n' "$LIST" | awk 'NR <= 5 { printf "              %s\n", $0 }'
