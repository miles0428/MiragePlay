#!/bin/bash
# package-release.sh — turn a built MiragePlay.app into a shippable, ad-hoc
# signed, self-contained bundle, verify it, and write the release report.
#
# Division of labour (YC ruling 2026-10-20, option A):
#   scripts/build/build-app.sh        = THE single assembler: release build, physical
#                                 executables, resources, both plists, version
#                                 injection (contract P-1.2 / P-8.2 unchanged).
#   scripts/build/package-release.sh  = closure copy-in + install_name_tool relocation
#                                 + ad-hoc signing + verification + release
#                                 report. It consumes build-app.sh's product.
#
# Step order is the frozen P-12.1 order. Steps 1 and 2-5 happen inside
# build-app.sh (which also installs the closure for dev bundles); step 3.5
# (copy the closure in, relocate) and steps 7-8 (sign, verify) happen here.
# The closure copy+relocate itself lives in scripts/lib/_pkg-closure-cache.sh
# so the dev and release paths cannot drift, and its inputs are cached under
# <build root>/closure/. Nothing writes into the bundle once step 7 starts:
# install_name_tool, strip, plutil and cp all happen before signing (P-12.2),
# and the release report is written outside the bundle.
#
# Usage: scripts/build/package-release.sh [options]
#
#   --app <path>        .app to operate on (default: <out>/MiragePlay.app)
#   --out <dir>         output directory (default: <repo>/packaging/dist)
#   --build             build first: build-core.sh --embedded, then
#                       build-app.sh --release --out <out>
#   --bundle-only       assemble only (closure copy-in + relocate), no signing
#   --sign-only         sign + verify an existing .app (no build, no relocate)
#   --verify-only       run the acceptance checks only; produces no artifacts
#   --skip-relocate     dev only: skip install_name_tool (NEVER for release)
#   --allow-untagged    dev only: continue when HEAD carries no git tag.
#                       Refused on the release path (--release / MIRAGEPLAY_RELEASE=1).
#                       The report is marked with the "no tag, publish forbidden" notice.
#   --release           mark this run as the release path (forbids the dev
#                       escape hatches above)
#   --report <path>     release report (default: <out>/release-report.md)
#   -h | --help         this text
#
# Exit codes: 0 success; non-zero = failure. A bundle that was signed but not
# verified is never reported as success (P-12.3).
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts/build"
# shellcheck source=scripts/lib/_canonical-path.sh
. "$REPO_ROOT/scripts/lib/_canonical-path.sh"
# Canonical spelling: this root is propagated into build-app.sh/build-core.sh
# and into --out, so a caller-typed spelling must not leak downward. See
# scripts/lib/_canonical-path.sh for why pwd/pwd -P are not enough.
REPO_ROOT="$(mp_canonical_dir "$REPO_ROOT")" || {
    echo "package-release: could not resolve the repository root to its on-disk spelling" >&2
    exit 1
}
SCRIPT_DIR="$REPO_ROOT/scripts/build"

# shellcheck source=scripts/lib/_pkg-closure.sh
. "$REPO_ROOT/scripts/lib/_pkg-closure.sh"
# shellcheck source=scripts/lib/_pkg-relocate.sh
. "$REPO_ROOT/scripts/lib/_pkg-relocate.sh"
# shellcheck source=scripts/lib/_pkg-closure-cache.sh
. "$REPO_ROOT/scripts/lib/_pkg-closure-cache.sh"

APP_NAME="MiragePlay"
HELPER_NAME="MiragePlay Projection"
# The core helper path comes from the shared layout definition, never from a
# literal in this file. A second copy of "<root>/core/uxplay" is what let this
# script keep pointing at a build root nobody wrote after the assembler moved
# (the symptom was "no core helper binary", reported long after the cause).
# _pkg-closure-cache.sh already sources the fragment; naming it here keeps the
# dependency explicit and adjacent to its only use below. One line, no guard
# clause: uxplay_core_binary() only fails when the root cannot be resolved, and
# uxplay_default_build_root() falls back to the raw override in that case, so a
# failure here is a broken library, which `set -e` already turns fatal.
# shellcheck source=scripts/lib/_uxplay-path.sh
. "$REPO_ROOT/scripts/lib/_uxplay-path.sh"
# shellcheck source=scripts/lib/_release-layout.sh
. "$REPO_ROOT/scripts/lib/_release-layout.sh"
CORE_UXPLAY="$(uxplay_core_binary "$(uxplay_default_build_root)")"

OUT_DIR="$REPO_ROOT/packaging/dist"
APP_OVERRIDE=""
REPORT_PATH=""
DO_BUILD=0
MODE="full"          # full | bundle-only | sign-only | verify-only
SKIP_RELOCATE=0
ALLOW_UNTAGGED=0
RELEASE_PATH="${MIRAGEPLAY_RELEASE:-0}"
PROBE_SECONDS="${MIRAGEPLAY_SMOKE_SECONDS:-12}"

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "package-release: $*" >&2; exit 1; }

# Canonicalise a path-shaped CLI argument and echo it (D6).
#
# --out is forwarded to build-app.sh --out and derives APP; a caller-typed
# spelling would otherwise reappear in every bundle path below and defeat the
# repo-root canonicalisation. The directory/parent may not exist yet, so
# mp_canonical_path resolves the longest existing ancestor and keeps the tail.
canon_dir_arg() {   # <flag> <value>
    local flag="$1" raw="$2" out=""

    case "$raw" in
        ''|-) die "$flag needs a path (got '${raw}')" ;;
    esac
    out="$(mp_canonical_path "$raw")" || die "cannot resolve $flag path '$raw' to its on-disk spelling"
    printf '%s\n' "$out"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --app)             APP_OVERRIDE="$(canon_dir_arg --app "${2-}")" || exit 1; shift ;;
        --out)             OUT_DIR="$(canon_dir_arg --out "${2-}")" || exit 1; shift ;;
        --build)           DO_BUILD=1 ;;
        --bundle-only)     MODE="bundle-only" ;;
        --sign-only)       MODE="sign-only" ;;
        --verify-only)     MODE="verify-only" ;;
        --skip-relocate)   SKIP_RELOCATE=1 ;;
        --allow-untagged)  ALLOW_UNTAGGED=1 ;;
        --release)         RELEASE_PATH=1 ;;
        --report)          REPORT_PATH="${2:?--report needs a path}"; shift ;;
        -h|--help)         usage 0 ;;
        *) echo "package-release: unknown argument $1" >&2; usage 1 ;;
    esac
    shift
done

# --- release-path guardrails (P-8.3 + YC ruling 2026-10-20 #2) --------------
if [ "$RELEASE_PATH" = "1" ] && [ "$ALLOW_UNTAGGED" = "1" ]; then
    die "--allow-untagged is refused on the release path (--release / MIRAGEPLAY_RELEASE=1)."
fi
if [ "$RELEASE_PATH" = "1" ] && [ "$SKIP_RELOCATE" = "1" ]; then
    die "--skip-relocate is refused on the release path."
fi

APP="$OUT_DIR/$APP_NAME.app"
if [ -n "$APP_OVERRIDE" ]; then
    # --app arrives absolute and canonical (D6). Re-deriving it with
    # `cd "$(dirname …)" && pwd` echoed the caller's spelling back on a
    # case-insensitive volume, undoing the canonicalisation.
    APP="$APP_OVERRIDE"
fi
HELPER="$APP/Contents/Helpers/$HELPER_NAME.app"
CONTENTS="$HELPER/Contents"
FW="$CONTENTS/Frameworks"
PLUGDIR="$CONTENTS/plugins"
BINDIR="$CONTENTS/bin"
HELPER_EXEC="$CONTENTS/MacOS/uxplay"
APP_EXEC="$APP/Contents/MacOS/$APP_NAME"
if [ -z "$REPORT_PATH" ]; then
    REPORT_PATH="$OUT_DIR/release-report.md"
fi

TAG="$(git -C "$REPO_ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
GIT_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_COUNT="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mirageplay-pkg.XXXXXX")"
EVIDENCE="$WORK/evidence.md"
: >"$EVIDENCE"
cleanup() { if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT

WARNINGS=0
log()    { printf '%s\n' "$*" >>"$EVIDENCE"; printf '%s\n' "$*"; }
lograw() { printf '%s\n' "$*" >>"$EVIDENCE"; }
warn()   { printf 'WARNING: %s\n' "$*" >&2; printf -- '- ⚠️ %s\n' "$*" >>"$EVIDENCE"; WARNINGS=$((WARNINGS + 1)); }

echo "=== MiragePlay package-release (mode: $MODE) ==="
echo "    app    : $APP"
echo "    out    : $OUT_DIR"
echo "    report : $REPORT_PATH"
echo "    tag    : ${TAG:-<none at HEAD>}"
echo "    commit : $GIT_COMMIT"

if [ -z "$TAG" ] && [ "$ALLOW_UNTAGGED" != "1" ] && [ "$MODE" != "verify-only" ]; then
    die "no git tag at HEAD — refusing to package (P-8.3). Tag first, or pass --allow-untagged for a dev bundle."
fi
if [ -z "$TAG" ] && [ "$ALLOW_UNTAGGED" = "1" ]; then
    warn "no tag, release forbidden — HEAD carries no tag; this bundle is a dev artifact (P-8.3)."
fi

pkg_read_plist() { plutil -extract "$2" raw "$1" 2>/dev/null || echo ""; }

# =============================================================================
# verification bookkeeping
# =============================================================================
FAILED=0
CHECKED=0
CKED=0

ck() { # ck "<description>" <expected> <actual>
    CHECKED=$((CHECKED + 1))
    if [ "$2" = "$3" ]; then
        log "- ✅ $1 — \`$3\`"
    else
        log "- ❌ $1 — expected \`$2\`, got \`$3\`"
        FAILED=$((FAILED + 1))
    fi
}
ck_rc() { # ck_rc "<description>" <exit code>
    CHECKED=$((CHECKED + 1))
    if [ "$2" = "0" ]; then
        log "- ✅ $1 (exit 0)"
    else
        log "- ❌ $1 (exit $2)"
        FAILED=$((FAILED + 1))
    fi
}
skip() { # skip "<description>" "<why>"
    log "- ⏭️ $1 — $2"
}

# Count occurrences of a pattern in a command's output. `grep -c` exits 1 when
# the count is zero, so the count is read first and compared afterwards: the
# exit status of the pipeline is never itself used as the pass condition.
count_of() { # count_of "<pattern>" <command...>
    local pat="$1"; shift
    local out
    out="$("$@" 2>/dev/null | grep -c -- "$pat" || true)"
    printf '%s' "${out:-0}"
}

# Same as count_of but keeps stderr: codesign reports `Signature=adhoc`,
# entitlements and `Info.plist=not bound` on stderr, so a stderr-swallowing
# counter would silently "pass" every signing assertion.
count_all() { # count_all "<pattern>" <command...>
    local pat="$1"; shift
    local out
    out="$("$@" 2>&1 | grep -c -- "$pat" || true)"
    printf '%s' "${out:-0}"
}

macho_list() { # every regular-file Mach-O the bundle is expected to ship
    local f
    for f in "$FW"/*.dylib "$PLUGDIR"/*.dylib \
             "$BINDIR/gst-plugin-scanner" "$HELPER_EXEC" "$APP_EXEC"; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        printf '%s\n' "$f"
    done
}

reloc_counts() { # reloc_counts <log> — "R1=8 R2=49 ..." (or "none")
    if [ ! -s "$1" ]; then
        printf 'none'
        return 0
    fi
    awk -F'\t' '
        { c[$2]++ }
        END {
            n = split("R1 R2 R3 R4 R5 R6 R7 R8 R9", r, " ")
            s = ""
            for (i = 1; i <= n; i++)
                if (c[r[i]]) s = s (s == "" ? "" : " ") r[i] "=" c[r[i]]
            printf "%s", s
        }
    ' "$1"
}

# =============================================================================
# step 1-5 — build + assemble (delegated to the single assembler)
# =============================================================================
run_build() {
    local rc=0 build_log="$WORK/build-app.log"
    local args=(--release --out "$OUT_DIR")

    echo "=== [step 1] build-core.sh --embedded ==="
    if "$SCRIPT_DIR/build-core.sh" --embedded >"$WORK/build-core.log" 2>&1; then
        log "- ✅ build-core.sh --embedded (exit 0)"
    else
        log "- ❌ build-core.sh --embedded"
        rc=1
    fi
    tail -3 "$WORK/build-core.log" 2>/dev/null >>"$EVIDENCE" || true

    if [ "$ALLOW_UNTAGGED" = "1" ]; then
        args+=(--allow-untagged)
    fi
    echo "=== [step 1-5] build-app.sh ${args[*]} ==="
    if "$SCRIPT_DIR/build-app.sh" "${args[@]}" >"$build_log" 2>&1; then
        log "- ✅ build-app.sh ${args[*]} (exit 0)"
    else
        log "- ❌ build-app.sh ${args[*]}"
        rc=1
    fi
    grep '^MIRAGE_META' "$build_log" >"$WORK/meta.txt" 2>/dev/null || true
    sed -n '/=== Stripping/,/=== self/p' "$build_log" >>"$EVIDENCE" 2>/dev/null || true
    return "$rc"
}

if [ "$DO_BUILD" = "1" ]; then
    run_build || die "build failed — see output above"
    APP="$OUT_DIR/$APP_NAME.app"
    HELPER="$APP/Contents/Helpers/$HELPER_NAME.app"
    CONTENTS="$HELPER/Contents"
    FW="$CONTENTS/Frameworks"
    PLUGDIR="$CONTENTS/plugins"
    BINDIR="$CONTENTS/bin"
    HELPER_EXEC="$CONTENTS/MacOS/uxplay"
    APP_EXEC="$APP/Contents/MacOS/$APP_NAME"
fi

if [ "$MODE" != "verify-only" ] && [ ! -d "$APP" ]; then
    die "no bundle at $APP (build it first, or pass --app)"
fi

# =============================================================================
# step 3.5 — closure computation, copy-in, relocation
# =============================================================================
CLOSURE_TSV="$WORK/closure.tsv"
RELOC_LOG="$WORK/relocations.tsv"
CLOSURE_CACHE_ENTRY=""
GST_SCANNER=""
: >"$RELOC_LOG"

compute_closure() {
    local scanner
    scanner="$(pkg_gst_scanner)" || die "cannot resolve gst-plugin-scanner (is gstreamer installed?)"
    [ -x "$CORE_UXPLAY" ] || die "no core helper binary at $CORE_UXPLAY (run scripts/build/build-core.sh --embedded)"
    GST_SCANNER="$scanner"

    echo "=== [step 3.5] computing the shipping closure from the Homebrew Cellar ==="
    pkg_compute_closure "$WORK/closure" "$CORE_UXPLAY" "$scanner" || die "closure computation failed"
    cp "$WORK/closure/closure.tsv" "$CLOSURE_TSV"
    log "closure: $(pkg_closure_summary "$CLOSURE_TSV")"

    # The closure is a hard fact of this release (P-7.2 "measured closure"):
    # 51 images / 58,080,904 bytes / 35 libs + 14 plugins + scanner + helper,
    # plus 7 version-alias symlinks. A different number means the build inputs
    # moved — that gets raised, never silently packaged.
    local images bytes aliases
    images="$(awk -F'\t' 'END{print NR}' "$CLOSURE_TSV")"
    bytes="$(awk -F'\t' '{s+=$2} END{print s}' "$CLOSURE_TSV")"
    aliases="$(awk -F'\t' '$5 != "-" {n++} END{print n+0}' "$CLOSURE_TSV")"
    ck "closure image count (P-7.2: 51)"          "51"         "$images"
    ck "closure total bytes (P-7.2: 58080904)"    "58080904"   "$bytes"
    ck "closure version-alias symlinks (P-7.2: 7)" "7"         "$aliases"
}

stage_closure() {
    compute_closure

    # Re-entrancy: rebuild the three staged directories from scratch so a
    # previous run's closure can never survive into this one (and so a second
    # relocation pass never meets files it already rewrote). Only directories
    # this script itself creates are removed.
    local d
    for d in "$FW" "$PLUGDIR" "$BINDIR"; do
        if [ -d "$d" ]; then
            log "- clearing previously staged dir \`${d#$APP/}\` (produced by an earlier run)"
            rm -rf "$d"
        fi
    done

    if [ "$SKIP_RELOCATE" = "1" ]; then
        # Dev escape hatch (refused on the release path): copy the raw Homebrew
        # images and leave their load commands alone. The cache is not used —
        # its entries are already relocated by construction.
        echo "=== [step 3.5a-c] copying the closure into the helper bundle (unrelocated) ==="
        pkg_stage_closure "$CLOSURE_TSV" "$CONTENTS" || die "closure staging failed"
        warn "--skip-relocate: install_name_tool was NOT run (dev only, not shippable)"
    else
        echo "=== [step 3.5a-c] installing the closure into the helper bundle ==="
        # The copy+relocate step is shared with scripts/build/build-app.sh, so a
        # dev bundle and a release bundle carry byte-identical closure images.
        # The cache stores the already-relocated images; only the helper's own
        # load commands are rewritten per bundle.
        CLOSURE_CACHE_ENTRY="$(pkg_closure_ensure_cached "$CLOSURE_TSV" "$CORE_UXPLAY" "$GST_SCANNER" \
            "$(dirname "$(dirname "$CORE_UXPLAY")")")" \
            || die "closure cache could not be prepared"
        echo "=== [step 3.5d] install_name_tool relocation (R1-R9) ==="
        pkg_closure_install "$CONTENTS" "$CLOSURE_CACHE_ENTRY" "$CLOSURE_TSV" \
            "$HELPER_EXEC" "$RELOC_LOG" 0 || die "closure install failed"
        log "- ✅ relocation applied: $(wc -l <"$RELOC_LOG" | tr -d ' ') rewrites ($(reloc_counts "$RELOC_LOG"))"
    fi

    echo "=== [step 3.5 self-check] the bundle never points back at Homebrew ==="
    local hb unresolved
    hb="$(pkg_assert_no_homebrew "$CONTENTS" | tee -a "$EVIDENCE" | wc -l | tr -d ' ')"
    ck "no /opt/homebrew load path in any bundled Mach-O" "0" "$hb"
    unresolved="$(pkg_assert_ids_resolvable "$CONTENTS" | tee -a "$EVIDENCE" | wc -l | tr -d ' ')"
    ck "every rewritten install name resolves inside the bundle" "0" "$unresolved"
}

# =============================================================================
# step 7 — signing, inner to outer (P-12.1)
# =============================================================================
SIGNED=0
sign_macho() {
    local f="$1" err="$WORK/sign.err"
    if [ ! -f "$f" ] || [ -L "$f" ]; then
        return 0
    fi
    if codesign --force --sign - "$f" 2>"$err"; then
        SIGNED=$((SIGNED + 1))
        return 0
    fi
    echo "codesign failed for $f" >&2
    sed 's/^/  /' "$err" >&2
    return 1
}

run_signing() {
    local rc=0 f
    echo "=== [step 7a] ad-hoc signing every Mach-O in the bundle ==="
    for f in "$FW"/*.dylib; do
        [ -f "$f" ] || continue
        sign_macho "$f" || rc=1
    done
    for f in "$PLUGDIR"/*.dylib; do
        [ -f "$f" ] || continue
        sign_macho "$f" || rc=1
    done
    sign_macho "$BINDIR/gst-plugin-scanner" || rc=1
    sign_macho "$HELPER_EXEC" || rc=1
    sign_macho "$APP_EXEC" || rc=1
    log "- signed Mach-O files: $SIGNED (expect 52 = the 51 closure images + the app executable)"

    echo "=== [step 7b] signing the helper bundle ==="
    codesign --force --sign - "$HELPER" || rc=1
    echo "=== [step 7c] signing the outer app (last) ==="
    codesign --force --sign - "$APP" || rc=1
    return "$rc"
}

# =============================================================================
# bounded helper launch (macOS has no timeout(1): pty + SIGINT)
# =============================================================================
probe_helper() { # probe_helper <log>
    local log="$1" reg="$WORK/probe-registry.bin" pidf spid cpid
    rm -f "$log" "$reg"
    : >"$log"
    pidf="$(mktemp "$WORK/probe.XXXXXX")"
    (
        export GST_PLUGIN_PATH="$PLUGDIR"
        export GST_PLUGIN_PATH_1_0="$PLUGDIR"
        export GST_PLUGIN_SYSTEM_PATH=""
        export GST_PLUGIN_SYSTEM_PATH_1_0=""
        export GST_PLUGIN_SCANNER="$BINDIR/gst-plugin-scanner"
        export GST_PLUGIN_SCANNER_1_0="$BINDIR/gst-plugin-scanner"
        export GST_REGISTRY="$reg"
        export GST_REGISTRY_1_0="$reg"
        export GST_DEBUG=2,GST_PLUGIN_LOADING:4
        # DYLD_* deliberately unset: the bundle is relocated, and the app's
        # /usr/bin/stdbuf spawn path strips DYLD_* anyway (survey §5(b)).
        script -q /dev/null sh -c 'echo $$ > "$1"; shift; exec "$@"' sh "$pidf" \
            "$HELPER_EXEC" -n MP-PackageProbe -nh >"$log" 2>&1 &
        spid=$!
        sleep "$PROBE_SECONDS"
        cpid="$(cat "$pidf" 2>/dev/null)"
        if [ -n "$cpid" ]; then
            kill -INT "$cpid" 2>/dev/null || true
            sleep 2
            kill -9 "$cpid" 2>/dev/null || true
        fi
        kill -9 "$spid" 2>/dev/null || true
        wait "$spid" 2>/dev/null || true
    )
    rm -f "$pidf"
    LC_ALL=C sed -e $'s/\x04//g' -e $'s/\x08//g' -e 's/\^D//g' -e 's/\^H//g' "$log" \
        2>/dev/null | tr -d '\r' >"$log.clean" || true
    if [ -f "$log.clean" ]; then
        mv "$log.clean" "$log"
    fi
    return 0
}

# =============================================================================
# step 8 — verification
# =============================================================================
run_verification() { # run_verification <probe log|""> <is signed: 0|1>
    local probe_log="$1" is_signed="$2"
    local ver_short ver_build ver_build_helper minos_app minos_helper \
          minos_plist_app minos_plist_helper v sig

    echo "=== [step 8] verification ==="

    # --- P-1 / P-9: resources ----------------------------------------------
    ck "P-1.5 terms.json present"   "0" "$([ -f "$APP/Contents/Resources/Strings/terms.json" ] && echo 0 || echo 1)"
    ck "P-1.5 icon.svg present"     "0" "$([ -f "$APP/Contents/Resources/StatusIcon/icon.svg" ] && echo 0 || echo 1)"
    ck "P-9.3 LICENSE present"      "0" "$([ -f "$APP/Contents/Resources/LICENSE" ] && echo 0 || echo 1)"
    # P-9.3 delivered the project's own licence and nothing else, so the bundle
    # a recipient received said nothing about the FFmpeg/GStreamer/UxPlay code
    # inside it. Compare both the checkout and the bundle against the manifest in
    # scripts/lib/_release-layout.sh — one full text per licence, thirteen of
    # them. Comparing by name (not just by count) is what catches a text that was
    # renamed, dropped or swapped for the wrong licence: equal counts of
    # different files would still under-deliver.
    ck "P-9.3 THIRD-PARTY-NOTICES.md present" "0" \
        "$([ -f "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md" ] && echo 0 || echo 1)"
    ck "P-9.3 checkout Licenses/ carries the expected texts" "match" \
        "$([ "$(mp_license_file_names "$REPO_ROOT/Licenses")" = \
              "$(mp_license_file_names_expected)" ] && echo match || echo differ)"
    ck "P-9.3 bundled Licenses/ carries the expected texts" "match" \
        "$([ "$(mp_license_file_names "$APP/Contents/Resources/Licenses")" = \
              "$(mp_license_file_names_expected)" ] && echo match || echo differ)"
    ck "P-9.3 licence text count" "13" \
        "$(mp_license_file_names "$APP/Contents/Resources/Licenses" | wc -l | tr -d ' ')"
    ck "P-1.5 Info.plist lints"     "0" "$(plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1 && echo 0 || echo 1)"
    ck "P-1.5 helper Info.plist lints" "0" "$(plutil -lint "$HELPER/Contents/Info.plist" >/dev/null 2>&1 && echo 0 || echo 1)"
    ck "P-1.5 terms.json parses with non-empty terms" "0" \
        "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if len(d["terms"])>0 else 1)' \
            "$APP/Contents/Resources/Strings/terms.json" >/dev/null 2>&1 && echo 0 || echo 1)"
    ck "no .DS_Store in the bundle" "0" "$(find "$APP" -name '.DS_Store' 2>/dev/null | wc -l | tr -d ' ')"

    # --- P-2.5 / B-15: no test channel in the release binary ------------------
    # The scripted-UI harness (UITestDriver + its AppDelegate entry points) is
    # DEBUG-only. Its environment-variable names are the observable fingerprint:
    # a release binary that still contains them means the channel shipped.
    # Guarded read: a binary that cannot be scanned must be a FAILURE, never a
    # silent `grep -c` 0 (that is exactly how a leaking binary passed before).
    local uitest_hits
    if [ -s "$APP_EXEC" ] && [ -r "$APP_EXEC" ]; then
        uitest_hits="$(strings "$APP_EXEC" 2>/dev/null | grep -c 'MIRRORBOARD_UITEST' || true)"
        [ -n "$uitest_hits" ] || uitest_hits="unscannable"
    else
        uitest_hits="unscannable"
    fi
    ck "B-15 / P-2.5 release binary contains no MIRRORBOARD_UITEST* test channel" \
        "0" "$uitest_hits"

    # --- P-3: movability ----------------------------------------------------
    ck "P-3.1 app executable is a physical file (not a symlink)" "no" \
        "$([ -L "$APP_EXEC" ] && echo yes || echo no)"
    # P-3.3 as written ("find -type l | wc -l == 0") contradicts P-7.2, which
    # requires the 7 relative version-alias links. Survey gap G-9 proposes the
    # reading below instead: no link may dangle or escape the bundle.
    local links bad_links app_real link_issues
    app_real="$(realpath "$APP")"
    link_issues="$WORK/link-issues.txt"
    : >"$link_issues"
    links="$(find "$APP" -type l 2>/dev/null | wc -l | tr -d ' ')"
    while IFS= read -r l; do
        if [ ! -e "$l" ]; then
            echo "DANGLING $l" >>"$link_issues"
            continue
        fi
        case "$(realpath "$l")" in
            *"$app_real"*) ;;
            *) echo "ESCAPES $l" >>"$link_issues" ;;
        esac
    done < <(find "$APP" -type l 2>/dev/null) || true
    bad_links="$(wc -l <"$link_issues" | tr -d ' ')"
    if [ -s "$link_issues" ]; then
        sed 's/^/  /' "$link_issues" >>"$EVIDENCE"
    fi
    ck "P-7.2 the 7 version-alias symlinks are preserved" "7" "$links"
    ck "P-3.2 no symlink dangles or escapes the bundle (G-9 reading)" "0" "$bad_links"

    # --- P-7.5 (corrected per survey gaps G-2 / G-3) ------------------------
    local hb_app local_load physical_dylibs
    hb_app="$(count_of '/opt/homebrew/' otool -L "$HELPER_EXEC")"
    ck "P-7.5 helper /opt/homebrew load paths (must be 0)" "0" "$hb_app"
    local_load="$(count_of '@loader_path/../Frameworks/' otool -L "$HELPER_EXEC")"
    CKED=$((CKED + 1))
    CHECKED=$((CHECKED + 1))
    if [ "${local_load:-0}" -ge 8 ]; then
        log "- ✅ P-7.5 helper @loader_path/../Frameworks load paths ≥ 8 — \`$local_load\`"
    else
        log "- ❌ P-7.5 helper @loader_path/../Frameworks load paths ≥ 8 — got \`$local_load\`"
        FAILED=$((FAILED + 1))
    fi
    # G-2: `find` counts symlinks too; physical dylibs need -type f.
    physical_dylibs="$(find "$APP" -type f -name '*.dylib' 2>/dev/null | wc -l | tr -d ' ')"
    ck "P-7.5 physical .dylib count (35 libs + 14 plugins)" "49" "$physical_dylibs"
    # G-3: the contract's loop is non-recursive and misses plugins/ and bin/.
    if [ "$is_signed" = "1" ]; then
        local cs_fail=0 f
        while IFS= read -r f; do
            if ! codesign --verify --strict "$f" >/dev/null 2>&1; then
                echo "UNSIGNED: $f" >>"$EVIDENCE"
                cs_fail=$((cs_fail + 1))
            fi
        done < <(macho_list)
        ck "P-11.4 every bundled Mach-O verifies (recursive: libs+plugins+scanner+execs)" "0" "$cs_fail"
    else
        skip "P-11.4 per-Mach-O codesign verification" "bundle is not signed in this mode"
    fi

    # --- P-11 / P-12: signing ----------------------------------------------
    if [ "$is_signed" = "1" ]; then
        if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
            sig=0
        else
            sig=1
        fi
        ck "P-11.7 / P-12.3 codesign --verify --deep --strict on the app" "0" "$sig"
        ck "P-11.7 Signature=adhoc" "1" "$(count_all 'Signature=adhoc' codesign -dv "$APP")"
        ck "P-11.5 no get-task-allow entitlement" "0" "$(count_all 'get-task-allow' codesign -d --entitlements - "$APP")"
        ck "P-11.6 Info.plist is bound (no 'not bound')" "0" "$(count_all 'Info.plist=not bound' codesign -dv "$APP")"
        ck "P-11.4 helper bundle verifies" "0" "$(codesign --verify --strict "$HELPER" >/dev/null 2>&1 && echo 0 || echo 1)"
    else
        skip "P-11.7 codesign --verify --deep --strict" "bundle is not signed in this mode"
        skip "P-11.5 entitlement check" "bundle is not signed in this mode"
    fi

    # --- P-8: version -------------------------------------------------------
    ver_short="$(pkg_read_plist "$APP/Contents/Info.plist" CFBundleShortVersionString)"
    ver_build="$(pkg_read_plist "$APP/Contents/Info.plist" CFBundleVersion)"
    ver_build_helper="$(pkg_read_plist "$HELPER/Contents/Info.plist" CFBundleVersion)"
    ck "P-8.4 helper CFBundleVersion equals app CFBundleVersion" "$ver_build" "$ver_build_helper"
    ck "P-8.4 CFBundleVersion equals git rev-list --count HEAD" "$GIT_COUNT" "$ver_build"
    if [ -n "$TAG" ]; then
        v="$(printf '%s' "$TAG" | sed 's/^v//' | sed 's/-rc\.[0-9]*$//')"
        ck "P-8.4 CFBundleShortVersionString equals the tag without v/-rc" "$v" "$ver_short"
    elif [ "$ALLOW_UNTAGGED" = "1" ]; then
        warn "P-8.4 not satisfiable: no tag at HEAD (dev placeholder version \`$ver_short\`)"
    else
        CHECKED=$((CHECKED + 1))
        log "- ❌ P-8.3 no git tag at HEAD — a release bundle must never be built untagged"
        FAILED=$((FAILED + 1))
    fi

    # --- P-5.1 / B-12: one minimum macOS, four places ------------------------
    # B-12 is a four-way equality gate: the app binary's LC_BUILD_VERSION
    # minos, the helper binary's minos, and both source plists'
    # LSMinimumSystemVersion must all read 15.0 (P-5.3). Each place is its own
    # check so a single lagging value is reported where it lags — previously
    # these were logged as "ℹ️ recorded facts (not gated)", which let a
    # mismatched minimum ride along in a green run.
    minos_app="$(pkg_dylib_minos "$APP_EXEC")"
    minos_helper="$(pkg_dylib_minos "$HELPER_EXEC")"
    minos_plist_app="$(pkg_read_plist "$APP/Contents/Info.plist" LSMinimumSystemVersion)"
    minos_plist_helper="$(pkg_read_plist "$HELPER/Contents/Info.plist" LSMinimumSystemVersion)"
    ck "B-12 / P-5.1 app binary minos is 15.0 (1/4)"    "15.0" "${minos_app:-missing}"
    ck "B-12 / P-5.1 helper binary minos is 15.0 (2/4)" "15.0" "${minos_helper:-missing}"
    ck "B-12 / P-5.1 app Info.plist LSMinimumSystemVersion is 15.0 (3/4)" \
        "15.0" "${minos_plist_app:-missing}"
    ck "B-12 / P-5.1 helper Info.plist LSMinimumSystemVersion is 15.0 (4/4)" \
        "15.0" "${minos_plist_helper:-missing}"
    log "- ℹ️ P-5.1 minos: app=\`${minos_app:-?}\`, helper=\`${minos_helper:-?}\` (both gated above)"
    log "- ℹ️ P-6 app architecture: \`$(lipo -info "$APP_EXEC" 2>/dev/null | sed 's/.*: //')\`"

    # --- helper launch smoke ------------------------------------------------
    if [ -n "$probe_log" ]; then
        echo "=== [smoke] bounded helper launch (no GUI) ==="
        probe_helper "$probe_log"
        ck "P-7.4 smoke: no 'Library not loaded' in launch.log"        "0"  "$(count_of 'Library not loaded' cat "$probe_log")"
        ck "P-7.4 smoke: no 'Required gstreamer plugin ... not found'" "0"  "$(count_of 'Required gstreamer plugin' cat "$probe_log")"
        ck "P-7.4 smoke: no 'Symbol not found'"                        "0"  "$(count_of 'Symbol not found' cat "$probe_log")"
        ck "smoke: all 14 GStreamer plugins register from the bundle"  "14" \
            "$(grep -oE 'libgst[A-Za-z0-9_]+\.dylib" loaded' "$probe_log" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
        ck "smoke: helper reaches the listening state"                 "1"  "$(count_of 'Initialized server socket' cat "$probe_log")"
        ck "smoke: helper log mentions no /opt/homebrew image"         "0"  "$(count_of '/opt/homebrew' cat "$probe_log")"
    fi
}

# =============================================================================
# release report
# =============================================================================
write_report() { # write_report <path>
    local report="$1" ver_short ver_build
    ver_short="$(pkg_read_plist "$APP/Contents/Info.plist" CFBundleShortVersionString)"
    ver_build="$(pkg_read_plist "$APP/Contents/Info.plist" CFBundleVersion)"
    mkdir -p "$(dirname "$report")"

    {
        echo "# MiragePlay release report"
        echo
        echo "- generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "- script: \`scripts/build/package-release.sh\` — mode \`$MODE\`"
        echo "- bundle: \`$APP\`"
        echo "- git commit: \`$GIT_COMMIT\` (rev-list count $GIT_COUNT)"
        echo "- git tag at HEAD: \`${TAG:-<none>}\`"
        echo "- version source: $([ -n "$TAG" ] && echo "git tag \`$TAG\`" || echo "**UNTAGGED dev placeholder — NOT RELEASABLE**")"
        echo "- CFBundleShortVersionString \`$ver_short\`, CFBundleVersion \`$ver_build\` (app and helper share both)"
        echo "- Homebrew prefix used for the closure: \`$(pkg_brew_prefix)\`"
        echo "- GStreamer libdir: \`$(pkg_gst_libdir)\`"
        if [ -z "$TAG" ]; then
            echo
            echo "> ## ⛔ no tag, release forbidden"
            echo ">"
            echo "> HEAD carries no tag and this bundle was produced with \`--allow-untagged\`."
            echo "> Contract P-8.3 forbids shipping it. Tag \`vX.Y.Z\` first, then re-run"
            echo "> \`scripts/build/package-release.sh --build --release\`."
        fi
        echo
        if [ -s "$WORK/meta.txt" ]; then
            echo "## strip (P-4.2)"
            echo
            echo '```'
            grep -E 'STRIP|VERSION|BUILD_CONFIG|BUILD_NUMBER' "$WORK/meta.txt" | sed 's/^MIRAGE_META //'
            echo '```'
            echo
        fi
        if [ -s "$CLOSURE_TSV" ]; then
            echo "## Dependency closure (P-7.2)"
            echo
            echo "\`$(pkg_closure_summary "$CLOSURE_TSV")\`"
            echo
            echo "| role | bytes | file | source | alias | minos |"
            echo "|---|---|---|---|---|---|"
            awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, ($5=="-"?"":$5), $6}' "$CLOSURE_TSV"
            echo
        fi
        if [ -s "$RELOC_LOG" ]; then
            echo "## install_name_tool rewrites (R1-R9)"
            echo
            echo "\`$(wc -l <"$RELOC_LOG" | tr -d ' ') rewrites — $(reloc_counts "$RELOC_LOG")\`"
            echo
            echo "| file | rule | old | new |"
            echo "|---|---|---|---|"
            awk -F'\t' '{printf "| %s | %s | `%s` | `%s` |\n", $1, $2, $3, $4}' "$RELOC_LOG"
            echo
        fi
        echo "## Verification"
        echo
        cat "$EVIDENCE"
        echo
        echo "## Interface values for the app side (unit B)"
        echo
        echo "Use these strings verbatim; derive the absolute path from \`Bundle.main\`"
        echo "and never from a hard-coded project path."
        echo
        echo '| purpose | relative to MiragePlay.app | relative to "MiragePlay Projection.app" |'
        echo "|---|---|---|"
        echo '| helper bundle | `Contents/Helpers/MiragePlay Projection.app` | `.` |'
        echo '| helper executable | `Contents/Helpers/MiragePlay Projection.app/Contents/MacOS/uxplay` | `Contents/MacOS/uxplay` |'
        echo '| bundled dylibs | `Contents/Helpers/MiragePlay Projection.app/Contents/Frameworks` | `Contents/Frameworks` |'
        echo '| `GST_PLUGIN_PATH` | `Contents/Helpers/MiragePlay Projection.app/Contents/plugins` | `Contents/plugins` |'
        echo '| `GST_PLUGIN_SCANNER` | `Contents/Helpers/MiragePlay Projection.app/Contents/bin/gst-plugin-scanner` | `Contents/bin/gst-plugin-scanner` |'
        echo
        echo "## Scope note (P-4.5)"
        echo
        echo "**release = smoke only** — the full test suite (swift test plus the six"
        echo "scripts/tests/test-*.sh harnesses) runs against the debug build only. The smoke"
        echo "run recorded above covers: helper binary launch, GStreamer plugin"
        echo "registration from the bundle, and entering the listening state."
        echo "No AirPlay mirroring round is performed by this script."
    } >"$report"
    echo "=== release report written: $report ==="
}

# =============================================================================
# run
# =============================================================================
case "$MODE" in
    full)
        stage_closure
        run_signing || die "signing failed"
        run_verification "$OUT_DIR/launch.log" 1
        write_report "$REPORT_PATH"
        ;;
    bundle-only)
        stage_closure
        run_verification "" 0
        write_report "$REPORT_PATH"
        ;;
    sign-only)
        compute_closure
        run_signing || die "signing failed"
        run_verification "$OUT_DIR/launch.log" 1
        write_report "$REPORT_PATH"
        ;;
    verify-only)
        run_verification "" 1
        ;;
esac

echo
if [ "$MODE" = "bundle-only" ]; then
    echo "=== result: checks=$CHECKED failed=$FAILED warnings=$WARNINGS (bundle assembled, unsigned) ==="
    # D-2: non-zero exit = failure, in every mode. A bundle-only run that
    # failed a check must not report success just because it stopped before
    # signing — the checks it did run are exactly the ones that can be run
    # before signing (this unconditional `exit 0` hid real failures).
    if [ "$FAILED" != "0" ]; then
        exit 1
    fi
    echo "=== next: scripts/build/package-release.sh --sign-only --app \"$APP\" ==="
    exit 0
fi
echo "=== result: checks=$CHECKED failed=$FAILED warnings=$WARNINGS ==="
if [ "$FAILED" != "0" ]; then
    exit 1
fi
exit 0
