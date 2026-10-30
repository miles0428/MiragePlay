#!/bin/bash
# test-config-engine.sh — Stage2-B (2a) ConfigEngine self-test runner.
#
# Harness: `app/Tests/ConfigEngineSelfTest` is a plain SwiftPM executable
# target (this toolchain is CommandLineTools-only — no XCTest / swift-testing
# is linkable), so the suite runs WITHOUT the SwiftPM test machinery.
# Re-runnable: every run compiles + executes the checks and writes a fresh
# log into this run's testkit evidence directory (a tmp workspace, never the
# checkout). The suite itself still dumps its per-case evidence through
# app/Tests/ConfigEngineSelfTest/TestSupport.swift, which derives its dumps
# directory from the source path — see the report's open items.
#
# Usage: scripts/tests/test-config-engine.sh
# Exit:  0 = all checks passed; 1 = failures (see log tail).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Canonical spelling (2026-10-20): this root is the cwd of `swift run` below,
# and `swift` hands its paths to clang. clang keys its module cache by path
# STRING, so a caller-typed spelling (projects vs Projects on this
# case-insensitive volume) creates a second module identity and ASTReader
# segfaults. `pwd`/`pwd -P` keep the caller's spelling; readlink -f does not.
# See scripts/lib/_canonical-path.sh.
. "$ROOT/scripts/lib/_canonical-path.sh"
ROOT="$(mp_canonical_dir "$ROOT")" || {
    echo "test-config-engine: cannot resolve the repo root to its on-disk spelling" >&2
    exit 1
}

# --- run workspace (tmp-isolated) -------------------------------------------
# Static suite: grep probes, `--print-paths` dry runs and one `swift run`. It
# needs no .app, so it takes the testkit workspace for its log and deliberately
# never calls testkit_build. testkit_init also exports MIRAGE_PLAY_BUILD_ROOT,
# which the default-value probe below has to work around (see the note there).
# shellcheck source=scripts/lib/testkit.sh
. "$ROOT/scripts/lib/testkit.sh"
testkit_init || {
    echo "test-config-engine: could not create the test workspace" >&2
    exit 1
}

# --- build-path canonicalisation guard (D4, 2026-10-20) ----------------------
# Static, pre-build: the scripts that hand a path to swift/cmake must derive
# their root with readlink -f. This asserts the resolution LINE, not the mere
# presence of a word — restoring `pwd` in one script turns it red.
CANON_FAIL=""
canon_expect() {   # <script under scripts/<group>/> <ERE its root line must match>
    # A6: the target may have moved to another group. grep reports rc=2 for a
    # missing file and rc=1 for a non-matching line; both must be failures, and
    # a missing file must SAY so — otherwise a stale path reads as "the build
    # script lost its canonical root", which is the wrong diagnosis.
    if [ ! -f "$ROOT/scripts/$1" ]; then
        CANON_FAIL="$CANON_FAIL $1(missing)"
        return 0
    fi
    grep -Eq "$2" "$ROOT/scripts/$1" || CANON_FAIL="$CANON_FAIL $1"
}
canon_expect build/build-app.sh       '^REPO_ROOT="\$\(mp_canonical_dir "\$SCRIPT_DIR/\.\./\.\."\)"'
canon_expect build/package-release.sh '^REPO_ROOT="\$\(mp_canonical_dir "\$REPO_ROOT"\)"'
canon_expect build/vendor-uxplay.sh   '^REPO_ROOT="\$\(mp_canonical_dir "\$SCRIPT_DIR/\.\./\.\."\)"'
canon_expect lib/_uxplay-path.sh      '^UXPLAY_REPO_ROOT="\$\(mp_canonical_dir "\$UXPLAY_SCRIPT_DIR/\.\./\.\."\)"'
canon_expect build/build-core.sh      '^\. "\$SCRIPT_DIR/\.\./lib/_uxplay-path\.sh"'
# Any harness that invokes build-app.sh must canonicalise the root it passes.
# A6 guard: bash leaves an unmatched glob as its own literal pattern, so the
# loop body would run once on a non-existent filename, `grep` would fail per
# file, and `|| continue` would swallow it — a green run that inspected
# nothing. Refuse to run the assertion unless the glob resolves to real files.
CANON_GLOB=("$ROOT"/scripts/tests/test-*.sh)
[ -e "${CANON_GLOB[0]}" ] || {
    echo "FAIL: glob '$ROOT/scripts/tests/test-*.sh' matched no file — refusing to pass vacuously" >&2
    exit 1
}
for CANON_F in "${CANON_GLOB[@]}"; do
    grep -Fq 'scripts/build/build-app.sh' "$CANON_F" || continue
    grep -Fq 'mp_canonical_dir' "$CANON_F" || CANON_FAIL="$CANON_FAIL $(basename "$CANON_F")"
done
# CLI path arguments must be canonicalised at the point of ASSIGNMENT (D6).
# The repo root being canonical is not enough: a caller-typed `--out` /
# `--build-dir` was forwarded verbatim to swift, and one build dir then held
# two spellings of itself (E5 measured 242 files spelled `projects` plus 279
# spelled `Projects` under a single --build-dir) — two clang module identities,
# SIGSEGV in ASTReader. The probe matches the assignment line, so restoring the
# old `VAR="${2:?...}"` form turns it red.
canon_cli_arg() {   # <script under scripts/<group>/> <flag> <VAR>
    # A6: same rule as canon_expect — a target that moved must fail loudly, not
    # be skipped.
    if [ ! -f "$ROOT/scripts/$1" ]; then
        CANON_FAIL="$CANON_FAIL $1:$2(missing)"
        return 0
    fi
    awk -v flag="$2" -v var="$3" '
        /^[[:space:]]*#/ { next }
        index($0, flag ")") > 0 && index($0, var "=\"$(canon_dir_arg") > 0 { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$ROOT/scripts/$1" || CANON_FAIL="$CANON_FAIL $1:$2"
}
canon_cli_arg build/build-app.sh       --out       OUT_DIR
canon_cli_arg build/build-app.sh       --build-dir BUILD_DIR
canon_cli_arg build/package-release.sh --out       OUT_DIR
canon_cli_arg build/package-release.sh --app       APP_OVERRIDE
# `pwd -P` is NOT a canonicaliser on a case-insensitive volume: it echoes the
# caller's spelling. The probe below looks for it in the only shape that
# matters — a root/script-dir ASSIGNMENT — so the prose in this very file (and
# in scripts/lib/_canonical-path.sh) that explains why it is unusable cannot trip
# it. Whole-line comments are skipped; trailing comments are not, which errs
# strict.
# A6 guard: `scripts/*.sh` is empty now that the scripts live in four groups, and
# an unmatched glob handed straight to awk means no input file at all — awk
# writes nothing, stderr is dropped by 2>/dev/null, `|| true` hides rc, and the
# probe below reads an empty CANON_PWD_P as "clean". Expand the glob as an array
# first and refuse to scan nothing.
PWD_P_SCAN=("$ROOT"/scripts/*/*.sh)
[ -e "${PWD_P_SCAN[0]}" ] || {
    echo "FAIL: glob '$ROOT/scripts/*/*.sh' matched no file — refusing to pass vacuously" >&2
    exit 1
}
CANON_PWD_P="$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*(SCRIPT_DIR|REPO_ROOT|UXPLAY_[A-Z_]+|PROJ|ROOT)=/ && /pwd[[:space:]]+-P/ {
        print FILENAME ":" FNR ": " $0
    }
' "${PWD_P_SCAN[@]}" 2>/dev/null || true)"

if [ -n "$CANON_FAIL" ]; then
    echo "FAIL: build scripts lost canonical root resolution:$CANON_FAIL" >&2
    echo "      a caller-typed spelling segfaults swift-frontend (see scripts/lib/_canonical-path.sh)" >&2
    exit 1
fi
if [ -n "$CANON_PWD_P" ]; then
    echo "FAIL: 'pwd -P' is used as a canonicaliser (it keeps the caller's spelling):" >&2
    printf '      %s\n' "$CANON_PWD_P" >&2
    exit 1
fi
echo "PASS: build scripts resolve the repo root with readlink -f (module-cache spelling guard)"

# --- core build-dir consistency guard (D-1, 2026-10-20) -----------------------
# build-core.sh WRITES the core into <build-dir>/core; build-app.sh READS
# <build-dir>/core/uxplay. They used to spell that layout independently
# (build-core hard-coded the default cache root, build-app derived
# <--build-dir>/core), so any non-default --build-dir left the assembler
# looking at a path nobody had written (E6: exit 1 until the core was copied
# in by hand). All three probes below are dry — no cmake, no swift:
#   1. static: each script DERIVES its location from the shared fragment,
#      instead of restating the layout in its own literal
#   2. dry-run: both scripts report the same core location for the same
#      --build-dir, and the default pair still describes <repo>/_build
#   3. drift: package-release.sh's CORE_UXPLAY (it computes the closure from
#      it) is derived, not spelled, and agrees with the shared definition
CORE_DIR_FAIL=""
core_dry() {   # <script under scripts/<group>/> <grep-key> [args...] -> value or ""
    local script="$1" key="$2" out=""
    shift 2
    out="$("$ROOT/scripts/$script" --print-paths "$@" 2>/dev/null)" || out=""
    printf '%s\n' "$out" | sed -n "s/^${key}=//p" | head -n 1
}
# 1. static derivation lines (a re-introduced literal turns these red)
grep -Eq '^BUILD_DIR="\$\(uxplay_core_build_dir "\$BUILD_ROOT"\)"' \
    "$ROOT/scripts/build/build-core.sh" || CORE_DIR_FAIL="$CORE_DIR_FAIL build-core.sh:BUILD_DIR-not-derived"
grep -Eq '^CORE_UXPLAY="\$\(uxplay_core_binary "\$BUILD_DIR"\)"' \
    "$ROOT/scripts/build/build-app.sh" || CORE_DIR_FAIL="$CORE_DIR_FAIL build-app.sh:CORE_UXPLAY-not-derived"
# build-core.sh must accept --build-dir (same flag name as build-app.sh)
grep -Eq '^[[:space:]]+--build-dir\)' \
    "$ROOT/scripts/build/build-core.sh" || CORE_DIR_FAIL="$CORE_DIR_FAIL build-core.sh:no---build-dir"
[ -f "$ROOT/scripts/lib/_uxplay-path.sh" ] && \
    grep -Eq '^uxplay_core_binary\(\)' "$ROOT/scripts/lib/_uxplay-path.sh" \
    || CORE_DIR_FAIL="$CORE_DIR_FAIL _uxplay-path.sh:no-shared-mapping"

# 2. dry-run agreement, custom --build-dir and default
PROBE_ROOT="$TEST_TMP/core-dir-probe-$$"
CORE_CUSTOM="$(core_dry build/build-core.sh BUILD_DIR --build-dir "$PROBE_ROOT")"
APP_CUSTOM="$(core_dry build/build-app.sh CORE_UXPLAY --build-dir "$PROBE_ROOT")"
if [ -z "$CORE_CUSTOM" ] || [ -z "$APP_CUSTOM" ]; then
    CORE_DIR_FAIL="$CORE_DIR_FAIL dry-run:no-output"
elif [ "$APP_CUSTOM" != "$CORE_CUSTOM/uxplay" ]; then
    CORE_DIR_FAIL="$CORE_DIR_FAIL dry-run:build-app($APP_CUSTOM)!=build-core($CORE_CUSTOM/uxplay)"
fi
# The two probes below assert the value a fresh checkout gets — the documented
# default, not this harness's own build location. testkit_init exports
# MIRAGE_PLAY_BUILD_ROOT (the shared cache) and _uxplay-path.sh honours it, so
# the variable is dropped for these two calls only; otherwise the assertion
# would compare the cache path against the default and read as a drift. The
# explicit --build-dir probe above is unaffected (a flag already overrides it).
CORE_DEFAULT="$(unset MIRAGE_PLAY_BUILD_ROOT; core_dry build/build-core.sh BUILD_DIR)"
APP_DEFAULT="$(unset MIRAGE_PLAY_BUILD_ROOT; core_dry build/build-app.sh CORE_UXPLAY)"
[ "$CORE_DEFAULT" = "$ROOT/_build/core" ] \
    || CORE_DIR_FAIL="$CORE_DIR_FAIL default:build-core($CORE_DEFAULT)"
[ "$APP_DEFAULT" = "$CORE_DEFAULT/uxplay" ] \
    || CORE_DIR_FAIL="$CORE_DIR_FAIL default:build-app($APP_DEFAULT)"

# 3. package-release.sh must DERIVE CORE_UXPLAY (no second copy of the layout)
#    and resolve to the binary the assembler expects. The probe evals the
#    script's own assignment line with the fragment already sourced — the state
#    that line runs in (package-release.sh sources _pkg-closure-cache.sh, which
#    sources _uxplay-path.sh, before it). A re-introduced literal turns the
#    first probe red; a function that resolves somewhere else turns the second
#    red.
PKG_LINE="$(grep -E '^CORE_UXPLAY=' "$ROOT/scripts/build/package-release.sh" | head -n 1)"
case "$PKG_LINE" in
    *uxplay_core_binary*) ;;
    *) CORE_DIR_FAIL="$CORE_DIR_FAIL package-release.sh:CORE_UXPLAY-not-derived" ;;
esac
PKG_CORE="$(unset MIRAGE_PLAY_BUILD_ROOT; PKG_LINE="$PKG_LINE" bash -c '
    . "$1/scripts/lib/_uxplay-path.sh" || exit 1
    eval "$PKG_LINE" || exit 1
    printf "%s" "${CORE_UXPLAY:-}"
' _ "$ROOT")"
[ "$PKG_CORE" = "$APP_DEFAULT" ] \
    || CORE_DIR_FAIL="$CORE_DIR_FAIL package-release($PKG_CORE)!=build-app($APP_DEFAULT)"

if [ -n "$CORE_DIR_FAIL" ]; then
    echo "FAIL: core build-dir is not shared between the build scripts:" >&2
    printf '      %s\n' $CORE_DIR_FAIL >&2
    echo "      build-app.sh --build-dir X looks for X/core/uxplay; build-core.sh must" >&2
    echo "      write there for the same X (see scripts/lib/_uxplay-path.sh)." >&2
    exit 1
fi
echo "PASS: core build-dir is one definition shared by build-core.sh/build-app.sh (D-1)"

# --- stale-cache gate guard (R1/N4, 2026-10-28) ------------------------------
# The shared stale-cache judgement is the pre-build gate both build scripts use:
# a CMakeCache.txt that names paths which no longer exist is dropped so cmake
# reconfigures instead of failing later with 'plist/plist.h' file not found.
# Since 2026-10-30 that judgement has two entry points — the deleting one
# (build-core.sh) and the read-only one (build-app.sh) — and the cases below
# exercise the deleting entry point, which is where the rule lives.
# Nothing asserted this gate before, so a rule that stopped matching would go
# unnoticed until a build failed far from the cause. The properties below
# are what make the gate worth its code, and each one can turn red on its own:
#   1. a HEALTHY cache produces no marker — zero false positives, which is why
#      the CMAKE_INSTALL_* exemption exists (an install destination such as
#      /usr/include does not exist on macOS and is legitimately absent)
#   2. an OpenSSL key naming a dead path produces the marker (the original case)
#   3. a libplist / gstreamer key does too. The gate used to match a list of
#      OpenSSL key names only, so `brew upgrade libplist` (which rewrites
#      LIBPLIST, PLIST_2*, pkgcfg_lib_PLIST_*, GST*) passed silently while
#      cmake went on to link against a Cellar path that was gone
#   4. a cache whose absolute paths cannot be read is treated as stale
#      (fail closed) instead of trusted
#   5. an absent path that is a macOS framework alias (GStreamer.framework's
#      include/ and lib/, which the .pc files name and the vendored tree
#      rewrites to Headers/ and Libraries/ at configure time) is spared while
#      the bundle is installed — otherwise the gate never converges on a
#      machine that has one
#   6. build-app.sh, which only consumes an already-built core, asks the
#      read-only checker and never the deleting one
# Each case runs the real function against a cache copy under TEST_TMP — the
# function removes the directory it rejects, so it must never see a real build
# dir. A case asserts the marker line AND the output variable; "there was some
# output" would not distinguish a fired gate from a gate that never ran.
STALE_FAIL=""
STALE_ROOT="$TEST_TMP/stale-cache-probe"
STALE_DEAD="/opt/homebrew/Cellar/mirageplay-probe/9.9.9-gone"
mkdir -p "$STALE_ROOT/src" "$STALE_ROOT/lib" "$STALE_ROOT/include"

# stale_write_cache <dir>: a cache shaped like the real one, every path present
# except the install destination, which is absent on purpose.
stale_write_cache() {
    mkdir -p "$1" || return 1
    cat >"$1/CMakeCache.txt" <<EOF
# synthetic CMakeCache for the stale-cache gate probe
CMAKE_CACHEFILE_DIR:INTERNAL=$1
CMAKE_COMMAND:INTERNAL=/bin/sh
CMAKE_HOME_DIRECTORY:INTERNAL=$STALE_ROOT/src
CMAKE_INSTALL_PREFIX:PATH=/usr/local
CMAKE_INSTALL_OLDINCLUDEDIR:PATH=/usr/include
CMAKE_C_FLAGS:STRING=-I$STALE_ROOT/include
CMAKE_PREFIX_PATH:PATH=$STALE_ROOT/lib;/usr/lib
OPENSSL_PREFIX:INTERNAL=$STALE_ROOT/lib
OPENSSL_INCLUDE_DIRS:INTERNAL=$STALE_ROOT/include
LIBPLIST:INTERNAL=$STALE_ROOT/lib
PLIST_23_LDFLAGS:INTERNAL=-L$STALE_ROOT/lib;-lplist-2.0
GST124_PREFIX:INTERNAL=$STALE_ROOT/include
GST124_INCLUDE_DIRS:INTERNAL=$STALE_ROOT/include
GST_STATIC_LDFLAGS:INTERNAL=-L$STALE_ROOT/lib;-framework;Cocoa
EOF
}

# stale_pollute <cache dir> <key> <value>: point one key at a path that is gone.
stale_pollute() {
    sed -i '' "s|^$2:.*|$2:INTERNAL=$3|" "$1/CMakeCache.txt" || return 1
    # -- : the polluting value may itself start with '-' (-L<dir> is a value).
    grep -Fq -- "$3" "$1/CMakeCache.txt" || return 1
}

# stale_run <dir> -> the function's own output, marker line included
stale_run() {
    bash -c '
        . "$1/scripts/lib/_uxplay-path.sh" || exit 9
        uxplay_rebuild_stale_cache "$2" ""
        printf "REMOVED=%s\n" "${UXPLAY_STALE_CACHE_REMOVED:-unset}"
    ' _ "$ROOT" "$1" 2>&1
}

# stale_expect <case> <dir> <yes|no>
stale_expect() {
    local name="$1" dir="$2" want="$3" out="" marker=0 removed=""
    out="$(stale_run "$dir")"
    printf '%s\n' "$out" | grep -Eq '^STALE-CACHE: ' && marker=1
    removed="$(printf '%s\n' "$out" | sed -n 's/^REMOVED=//p' | tail -n 1)"
    if [ "$want" = "yes" ]; then
        [ "$marker" -eq 1 ] || STALE_FAIL="$STALE_FAIL $name(no-marker)"
        [ "$removed" = "1" ] || STALE_FAIL="$STALE_FAIL $name(removed=${removed:-none})"
    else
        [ "$marker" -eq 0 ] || STALE_FAIL="$STALE_FAIL $name(marker-fired)"
        [ "$removed" = "0" ] || STALE_FAIL="$STALE_FAIL $name(removed=${removed:-none})"
    fi
    printf '      stale-cache %-22s expect-marker=%s marker=%s removed=%s\n' \
        "$name" "$want" "$marker" "${removed:-none}"
}

# 1. healthy: every path present (plus one absent install destination)
stale_write_cache "$STALE_ROOT/healthy" || STALE_FAIL="$STALE_FAIL healthy(no-cache)"
stale_expect healthy "$STALE_ROOT/healthy" no

# 2. OpenSSL key dead (the case that always worked)
for key in OPENSSL_PREFIX OPENSSL_INCLUDE_DIRS; do
    case_dir="$STALE_ROOT/polluted-$key"
    stale_write_cache "$case_dir" || STALE_FAIL="$STALE_FAIL $key(no-cache)"
    stale_pollute "$case_dir" "$key" "$STALE_DEAD" || STALE_FAIL="$STALE_FAIL $key(pollution-not-applied)"
    stale_expect "$key" "$case_dir" yes
done

# 3. non-OpenSSL keys dead — the R1 regression lock
for key in PLIST_23_LDFLAGS GST_STATIC_LDFLAGS LIBPLIST; do
    case_dir="$STALE_ROOT/polluted-$key"
    stale_write_cache "$case_dir" || STALE_FAIL="$STALE_FAIL $key(no-cache)"
    stale_pollute "$case_dir" "$key" "-L$STALE_DEAD/lib;-lplist-2.0" \
        || STALE_FAIL="$STALE_FAIL $key(pollution-not-applied)"
    stale_expect "$key" "$case_dir" yes
done

# 4. no absolute path readable at all: fail closed, not "looks fine"
mkdir -p "$STALE_ROOT/unparsable"
printf '# no key=absolute-path lines here\nFOO:STRING=bar\n' >"$STALE_ROOT/unparsable/CMakeCache.txt"
stale_expect unparsable "$STALE_ROOT/unparsable" yes

# 5. the checkout's own cache, when there is one: the real 400+ entry cache must
#    not be judged stale. It sees real Homebrew Cellar paths, which is the shape
#    case 1 approximates. A red here means the cache really is stale — rebuild
#    the core (scripts/build/build-core.sh --embedded) and re-run.
REAL_CACHE="$ROOT/_build/core/CMakeCache.txt"
if [ -f "$REAL_CACHE" ]; then
    REAL_PROBE="$STALE_ROOT/real"
    mkdir -p "$REAL_PROBE"
    cp "$REAL_CACHE" "$REAL_PROBE/CMakeCache.txt"
    stale_expect real-checkout-cache "$REAL_PROBE" no
else
    echo "      stale-cache real-checkout-cache   SKIP (no $REAL_CACHE)"
fi

# --- 6-8: the macOS framework alias (2026-10-30) -----------------------------
# A framework bundle stores Headers/ and Libraries/; the .pc files of the
# "Official" GStreamer .pkg say include/ and lib/. The vendored UxPlay tree
# rewrites the CMake variables at configure time
# (_build/uxplay/renderers/CMakeLists.txt:97-99 and :117-118) but never the
# cache, so CMakeCache.txt permanently records GST122_CFLAGS with a path that
# never existed on that machine. The gate used to call that stale and delete a
# build dir that had just built successfully — on any machine whose framework
# .pc files use that spelling, every run, forever.
#
# The exemption is NARROW on purpose: it covers only the two alias spellings
# (<bundle>/include/... and <bundle>/lib/...), and only when the directory the
# alias stands for is really there. The cases must pull in opposite directions
# or the fix is worthless:
#   6. the bundle exists and ships the module -> the alias path is spared,
#      nothing is deleted
#   6b. the bundle exists but a REAL path inside it is gone -> still stale.
#      This is the reviewer's counterexample: a framework upgraded in place
#      prunes subdirectories, that is genuine dependency drift, and a gate that
#      spares everything under a .framework is a gate with a hole in it
#   7. the bundle exists but the SAME cache also names a dead Cellar path ->
#      still stale (the exemption is per path, not a blanket "this cache is
#      fine because it mentions a framework")
#   8. the bundle is GONE -> still stale (the exemption asks the filesystem; a
#      path string containing .framework is not evidence of anything)
stale_append_key() {
    # stale_append_key <dir> <key> <value>: add a line the healthy fixture has
    # no slot for (the framework fields only exist on machines with a bundle).
    printf '%s:INTERNAL=%s\n' "$2" "$3" >>"$1/CMakeCache.txt" || return 1
    # -- : the value may itself start with '-' (-I<dir> is a value).
    grep -Fq -- "$3" "$1/CMakeCache.txt" || return 1
}

FRAMEWORK_ROOT="$STALE_ROOT/fw"
FRAMEWORK_BUNDLE="$FRAMEWORK_ROOT/GStreamer.framework"
FRAMEWORK_INCLUDE="$FRAMEWORK_BUNDLE/include/gstreamer-1.0"
FRAMEWORK_LIB="$FRAMEWORK_BUNDLE/lib"
# The layout a real bundle has: Headers/ holds the headers FLAT (gst/gst.h
# directly, which is what -I<bundle>/Headers + '#include <gst/gst.h>' needs),
# Libraries/ holds the dylibs, and Libraries/pkgconfig/ holds the bundle's own
# .pc files (renderers/CMakeLists.txt:9 and :18 point PKG_CONFIG_PATH there).
mkdir -p "$FRAMEWORK_BUNDLE/Headers/gst" "$FRAMEWORK_BUNDLE/Libraries/pkgconfig" \
    || STALE_FAIL="$STALE_FAIL framework(fixture-not-created)"
: >"$FRAMEWORK_BUNDLE/Headers/gst/gst.h" \
    || STALE_FAIL="$STALE_FAIL framework(fixture-no-header)"
: >"$FRAMEWORK_BUNDLE/Libraries/libgstreamer-1.0.0.dylib" \
    || STALE_FAIL="$STALE_FAIL framework(fixture-no-dylib)"
: >"$FRAMEWORK_BUNDLE/Libraries/pkgconfig/gstreamer-1.0.pc" \
    || STALE_FAIL="$STALE_FAIL framework(fixture-no-pc)"
# The layout the gate must NOT accept: both alias spellings are absent.
[ ! -e "$FRAMEWORK_INCLUDE" ] && [ ! -e "$FRAMEWORK_LIB" ] \
    || STALE_FAIL="$STALE_FAIL framework(alias-paths-exist-unexpectedly)"

# stale_write_framework_cache <dir>: healthy cache plus the two framework
# spellings pkg-config reports, exactly as the reported failure had them.
stale_write_framework_cache() {
    stale_write_cache "$1" || return 1
    stale_append_key "$1" GST122_CFLAGS "-I$FRAMEWORK_INCLUDE" || return 1
    stale_append_key "$1" GST122_LDFLAGS "-L$FRAMEWORK_LIB;-framework;GStreamer" || return 1
}

# 6. bundle present and shipping the module -> spared (the false positive that
#    caused the loop)
stale_write_framework_cache "$STALE_ROOT/framework-alias" \
    || STALE_FAIL="$STALE_FAIL framework-alias(no-cache)"
stale_expect framework-alias "$STALE_ROOT/framework-alias" no

# 6b. bundle present, but a REAL path inside it is gone -> still stale. The
#     alias exemption must not cover Headers/... / Libraries/... paths: those
#     are real paths, and their absence is the dependency drift the gate is
#     for. (Reviewer counterexample (a).)
stale_write_framework_cache "$STALE_ROOT/framework-drift" \
    || STALE_FAIL="$STALE_FAIL framework-drift(no-cache)"
stale_append_key "$STALE_ROOT/framework-drift" GST122_INCLUDE_DIRS \
    "$FRAMEWORK_BUNDLE/Headers/gst/gst-missing.h" \
    || STALE_FAIL="$STALE_FAIL framework-drift(pollution-not-applied)"
stale_expect framework-drift "$STALE_ROOT/framework-drift" yes

# 7. bundle present, dead Cellar path in the same cache -> still stale
stale_write_framework_cache "$STALE_ROOT/framework-plus-dead" \
    || STALE_FAIL="$STALE_FAIL framework-plus-dead(no-cache)"
# appended, not pollute(): the healthy fixture has no GST124_CFLAGS slot, and
# sed on a key that is absent would silently add nothing (a case that passes
# because it never ran).
stale_append_key "$STALE_ROOT/framework-plus-dead" GST124_CFLAGS \
    "-I$STALE_DEAD/include/gstreamer-1.0" \
    || STALE_FAIL="$STALE_FAIL framework-plus-dead(pollution-not-applied)"
stale_expect framework-plus-dead "$STALE_ROOT/framework-plus-dead" yes

# 8. bundle removed -> the same cache is stale again (negative control: the
#    exemption must not be a string test, so taking the bundle away re-arms it)
rm -rf "$FRAMEWORK_ROOT"
stale_write_framework_cache "$STALE_ROOT/framework-gone" \
    || STALE_FAIL="$STALE_FAIL framework-gone(no-cache)"
[ ! -d "$FRAMEWORK_BUNDLE" ] || STALE_FAIL="$STALE_FAIL framework-gone(fixture-still-present)"
stale_expect framework-gone "$STALE_ROOT/framework-gone" yes

# --- 9: the consumer must not be the deleter (2026-10-30) --------------------
# build-app.sh only consumes <build-dir>/core/uxplay and never configures cmake.
# When it called the deleting gate it removed the core it was about to package,
# then reported "core uxplay binary missing" on the following run.
#
# Two independent guards, because a static one alone was not enough:
#
#   9a. content assertion on build-app.sh — not a literal call match. The
#       deleting function must not be NAMED anywhere in the file (a call on its
#       own line, an inlined `if uxplay_rebuild_stale_cache ...; then`, an
#       indirect `DEL=uxplay_rebuild_stale_cache; $DEL` all contain the name),
#       and no `rm -rf` may target the core build dir. The read-only entry must
#       still be called. Comment lines are excluded from the "is called"
#       positive check only, so the explanatory comment above the call does not
#       have to be rewritten every time the prose changes.
#   9b. runtime assertion — the read-only entry point against a genuinely stale
#       cache must report stale AND leave the build dir (and its
#       CMakeCache.txt) exactly where it was, printing no removal marker. This
#       is the invariant the whole split exists for, and no static check can
#       see it: moving `rm -rf` into the SHARED _uxplay_stale_cache_reason
#       keeps build-app.sh's text identical while restoring the original defect.
APP_SH="$ROOT/scripts/build/build-app.sh"
APP_READONLY="$(grep -Ec '^[[:space:]]*[^#[:space:]]*uxplay_stale_cache_check[[:space:]]' "$APP_SH")"
# The deleting function's NAME must not appear at all, in code or comment.
APP_DELETER="$(grep -Fc 'uxplay_rebuild_stale_cache' "$APP_SH")"
# No rm -rf may name the core build dir (directly or via the resolver).
APP_RM_CORE="$(grep -E '^[[:space:]]*[^#[:space:]]*rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*f.*(uxplay_core_build_dir|CORE_UXPLAY|BUILD_DIR/core)' "$APP_SH" | wc -l | tr -d ' ')"
[ "${APP_READONLY:-0}" -ge 1 ] || STALE_FAIL="$STALE_FAIL build-app(read-only-gate-missing)"
[ "${APP_DELETER:-0}" -eq 0 ] || STALE_FAIL="$STALE_FAIL build-app(deleting-gate-named)"
[ "${APP_RM_CORE:-0}" -eq 0 ] || STALE_FAIL="$STALE_FAIL build-app(rm-rf-on-core)"
printf '      stale-cache %-22s read-only-call=%s deleting-mentions=%s rm-core=%s\n' \
    build-app-consumer "${APP_READONLY:-0}" "${APP_DELETER:-0}" "${APP_RM_CORE:-0}"

# 9b. runtime: the read-only entry point must not delete anything.
#     stale_readonly_run <dir> -> "<stale>|<reason>|<marker>|<cache present>|<dir present>"
stale_readonly_run() {
    bash -c '
        . "$1/scripts/lib/_uxplay-path.sh" || exit 9
        uxplay_stale_cache_check "$2" ""
        marker=0
        if printf "%s\n" "$UXPLAY_STALE_CACHE_REASON" | grep -Eq "^STALE-CACHE: "; then
            marker=1
        fi
        cache=no
        [ -f "$2/CMakeCache.txt" ] && cache=yes
        dir=no
        [ -d "$2" ] && dir=yes
        printf "%s|%s|%s|%s|%s\n" \
            "${UXPLAY_STALE_CACHE_STALE:-unset}" \
            "${UXPLAY_STALE_CACHE_REASON:-}" \
            "$marker" "$cache" "$dir"
    ' _ "$ROOT" "$1" 2>&1
}

READONLY_DIR="$STALE_ROOT/readonly-entry"
stale_write_cache "$READONLY_DIR" || STALE_FAIL="$STALE_FAIL readonly-entry(no-cache)"
stale_pollute "$READONLY_DIR" OPENSSL_PREFIX "$STALE_DEAD" \
    || STALE_FAIL="$STALE_FAIL readonly-entry(pollution-not-applied)"
# A sentinel that stands in for the built core the consumer is about to package.
printf 'not-a-real-binary\n' >"$READONLY_DIR/uxplay"
RO_OUT="$(stale_readonly_run "$READONLY_DIR")"
RO_STALE="${RO_OUT%%|*}"
RO_REST="${RO_OUT#*|}"
RO_REASON="${RO_REST%%|*}"
RO_REST="${RO_REST#*|}"
RO_MARKER="${RO_REST%%|*}"
RO_REST="${RO_REST#*|}"
RO_CACHE="${RO_REST%%|*}"
RO_DIR="${RO_REST#*|}"
[ "$RO_STALE" = "1" ] || STALE_FAIL="$STALE_FAIL readonly-entry(not-stale=$RO_STALE)"
[ -n "$RO_REASON" ] || STALE_FAIL="$STALE_FAIL readonly-entry(empty-reason)"
[ "$RO_CACHE" = "yes" ] || STALE_FAIL="$STALE_FAIL readonly-entry(cache-deleted)"
[ "$RO_DIR" = "yes" ] || STALE_FAIL="$STALE_FAIL readonly-entry(dir-deleted)"
[ -f "$READONLY_DIR/uxplay" ] || STALE_FAIL="$STALE_FAIL readonly-entry(core-binary-deleted)"
# No removal marker may be produced by the read-only path. The marker is
# written by the DELETING entry point only (printf 'STALE-CACHE: ...'), so its
# presence anywhere in the read-only output means deletion leaked in.
if printf '%s\n' "$RO_OUT" | grep -Eq 'STALE-CACHE: '; then
    STALE_FAIL="$STALE_FAIL readonly-entry(removal-marker-printed)"
fi
printf '      stale-cache %-22s stale=%s cache-kept=%s dir-kept=%s marker=%s\n' \
    readonly-entry "$RO_STALE" "$RO_CACHE" "$RO_DIR" "$RO_MARKER"

if [ -n "$STALE_FAIL" ]; then
    echo "FAIL: the pre-build stale-cache gate is not doing its job:" >&2
    printf '      %s\n' $STALE_FAIL >&2
    echo "      a stale cache must be dropped before cmake links against a path that" >&2
    echo "      is gone; a healthy cache must never be dropped; an absent path inside" >&2
    echo "      an installed .framework bundle is spared only for the include/ and lib/" >&2
    echo "      alias spellings whose counterpart directory exists; and the read-only" >&2
    echo "      entry point (uxplay_stale_cache_check) must never delete anything —" >&2
    echo "      see _uxplay_framework_alias_path in scripts/lib/_uxplay-path.sh." >&2
    exit 1
fi
echo "PASS: stale-cache gate fires on dead paths (OpenSSL and libplist/gstreamer), spares a healthy cache, spares framework aliases only when the aliased directory exists, reports drift inside an installed bundle, and leaves deletion to the builder while the read-only entry point removes nothing"


APP="$ROOT/app"
# Output goes to this run's testkit evidence directory: the workspace is a tmp
# tree, so a suite run writes nothing into the checkout. The testkit keeps the
# workspace when the run fails and drops it when it passes, hence the explicit
# mark_failed below.
LOG_DIR="$(testkit_evidence_dir)" || {
    echo "test-config-engine: cannot create the evidence directory" >&2
    exit 1
}
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="$LOG_DIR/testrun-self-test-$STAMP.log"

cd "$APP" || exit 2

echo "=== ConfigEngine self-test (build + run) ==="
set +e
swift run ConfigEngineSelfTest 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

echo "=== self-test exit=$STATUS; log: $LOG ==="
[ "$STATUS" -eq 0 ] || testkit_mark_failed
exit "$STATUS"
