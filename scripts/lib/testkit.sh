#!/bin/bash
# testkit.sh — shared foundation for the MiragePlay test harness.
#
# One job: every harness run BUILDS ITS OWN BUNDLE INTO ITS OWN TEMP
# DIRECTORY, with one reusable build cache OUTSIDE the checkout. Nothing in a
# suite may point at a build product that lives in the repository, and no two
# suites may share a mutable log file.
#
# Source it, do not execute it:
#
#     PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
#     . "$PROJ/scripts/lib/testkit.sh"
#     testkit_init
#     testkit_build || { testkit_mark_failed; exit 1; }
#     testkit_launch MIRRORBOARD_UITEST=1        # extra env by the caller
#     ... assertions against "$(testkit_ui_log)" ...
#     testkit_quit
#
# ---------------------------------------------------------------------------
# FROZEN INTERFACE (sub-tasks implement against these signatures; do not
# change names, arguments or printed values)
# ---------------------------------------------------------------------------
#   testkit_init             create TEST_TMP, TEST_APP_DIR, TEST_UI_LOG,
#                            TEST_EVIDENCE; export MIRAGE_PLAY_BUILD_ROOT;
#                            install the EXIT trap -> testkit_teardown
#   testkit_build            ensure the core exists in the cache (build it
#                            there when missing), then assemble the bundle into
#                            TEST_APP_DIR; non-zero on any failure
#   testkit_app_binary       print $TEST_APP_DIR/MiragePlay.app/Contents/MacOS/MiragePlay
#   testkit_launch [args...] launch that binary in the background with
#                            MIRAGE_PLAY_UI_LOG=$TEST_UI_LOG, set TEST_APP_PID,
#                            pass every argument through verbatim
#   testkit_quit             ask the app to quit, wait up to 10s, escalate
#   testkit_teardown         kill leftovers; keep TEST_TMP when the run failed
#   testkit_evidence_dir     print (and create) $TEST_EVIDENCE
#   testkit_ui_log           print $TEST_UI_LOG
#   testkit_preflight_clean  non-zero (+ reason) when MiragePlay/uxplay already
#                            runs; never kills another session's process
#   testkit_mark_failed      set TESTKIT_FAILED=1 so teardown keeps evidence
#
# Environment:
#   MIRAGE_PLAY_TEST_CACHE   cache root override (default
#                            ~/Library/Caches/mirageplay-build)
#   MIRAGE_PLAY_BUILD_ROOT   exported by testkit_init; consumed by
#                            scripts/lib/_uxplay-path.sh
#   TEST_TMP                 per-run temp root; removed on success only
#
# Conventions this file deliberately does NOT encode: the bundle's internal
# layout beyond the documented main executable, and any repository-local
# artifact directory. Suites that need a path ask the testkit for it.

TESTKIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTKIT_REPO_ROOT="$(cd "$TESTKIT_LIB_DIR/../.." && pwd)"

# shellcheck source=scripts/lib/_canonical-path.sh
. "$TESTKIT_LIB_DIR/_canonical-path.sh"
# shellcheck source=scripts/lib/_uxplay-path.sh
. "$TESTKIT_LIB_DIR/_uxplay-path.sh"

TESTKIT_REPO_ROOT="$(mp_canonical_dir "$TESTKIT_REPO_ROOT")" || {
    echo "testkit: could not resolve the repository root ($TESTKIT_LIB_DIR/../..)" >&2
    exit 1
}

# Bundle-relative path of the main executable. The one layout fact the testkit
# owns, because every suite needs to launch it.
_testkit_app_relative_binary() {
    printf '%s\n' "MiragePlay.app/Contents/MacOS/MiragePlay"
}

# Names of the processes this harness must see zero of before starting and
# zero of after finishing.
_testkit_process_names() {
    printf '%s\n' "MiragePlay uxplay"
}

# List the PIDs currently carrying one process name (empty when none).
_testkit_pids() {
    pgrep -x "$1" 2>/dev/null | tr '\n' ' '
}

# Print only the PIDs of the given name that were not already running when
# testkit_init recorded its baseline — i.e. the ones this run is responsible
# for. A concurrent session's processes are never touched.
_testkit_new_pids() {   # <name>
    local name="$1" pid baseline="${TESTKIT_PID_BASELINE:-}"
    for pid in $(_testkit_pids "$name"); do
        case " $baseline " in
            *" $pid "*) ;;             # already there before this run - not ours
            *) printf '%s\n' "$pid" ;;
        esac
    done
}

# Wait up to <seconds> for a PID to disappear. Returns 0 when it is gone.
_testkit_wait_gone() {   # <pid> <seconds>
    local pid="$1" limit="$2" waited=0
    while kill -0 "$pid" 2>/dev/null; do
        [ "$waited" -lt "$limit" ] || return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

# Terminate a PID: polite signal first, then hard kill after <seconds>.
# Returns 0 when the process is gone.
_testkit_stop_pid() {   # <pid> <seconds>
    local pid="$1" limit="$2"
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || true
    _testkit_wait_gone "$pid" "$limit" && return 0
    kill -KILL "$pid" 2>/dev/null || true
    _testkit_wait_gone "$pid" 2
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

# Create this run's private workspace and install the teardown trap.
# Re-entrant: calling it again tears the previous workspace down first.
testkit_init() {
    if [ -n "${TEST_TMP:-}" ] && [ -d "${TEST_TMP:-}" ]; then
        testkit_teardown
    fi

    # Cache root lives OUTSIDE the checkout, survives reboots, and is reused
    # across runs so the core and the SwiftPM cache are compiled once.
    local cache="${MIRAGE_PLAY_TEST_CACHE:-${HOME}/Library/Caches/mirageplay-build}"
    local cache_resolved=""
    cache_resolved="$(mp_canonical_path "$cache")" || cache_resolved="$cache"
    MIRAGE_PLAY_BUILD_ROOT="$cache_resolved"
    export MIRAGE_PLAY_BUILD_ROOT

    TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mirageplay-test.XXXXXX")" || {
        echo "testkit: could not create a temp directory under ${TMPDIR:-/tmp}" >&2
        return 1
    }
    TEST_TMP="$(mp_canonical_dir "$TEST_TMP")" || true
    TEST_APP_DIR="$TEST_TMP/app"
    TEST_UI_LOG="$TEST_TMP/ui.log"
    TEST_EVIDENCE="$TEST_TMP/evidence"
    TEST_APP_PID=""
    TESTKIT_FAILED=0
    TESTKIT_TORN_DOWN=0
    # Console of the launched app (stdout+stderr); suites may tail it.
    TEST_APP_CONSOLE="$TEST_TMP/app-console.log"
    # Processes already running before this suite touched anything.
    TESTKIT_PID_BASELINE="$(_testkit_pids MiragePlay)$(_testkit_pids uxplay)"

    export TEST_TMP TEST_APP_DIR TEST_UI_LOG TEST_EVIDENCE TEST_APP_CONSOLE

    mkdir -p "$TEST_APP_DIR" "$TEST_EVIDENCE" || return 1
    trap testkit_teardown EXIT
    return 0
}

# Mark this run as failed so the teardown keeps the temp directory.
testkit_mark_failed() {
    TESTKIT_FAILED=1
    export TESTKIT_FAILED
}

# Kill whatever this run left behind and drop the temp workspace on success.
# Safe to call twice (explicit call + EXIT trap).
testkit_teardown() {
    [ "${TESTKIT_TORN_DOWN:-0}" = "1" ] && return 0
    TESTKIT_TORN_DOWN=1

    # 1. the app this run launched
    if [ -n "${TEST_APP_PID:-}" ]; then
        _testkit_stop_pid "$TEST_APP_PID" 5 || true
    fi
    # 2. anything matching our process names that was NOT running before
    local name pid
    for name in $(_testkit_process_names); do
        for pid in $(_testkit_new_pids "$name"); do
            _testkit_stop_pid "$pid" 5 || true
        done
    done

    # 3. evidence: dropped on success, kept on failure so the run stays
    #    diagnosable
    if [ -z "${TEST_TMP:-}" ] || [ ! -d "${TEST_TMP:-}" ]; then
        return 0
    fi
    if [ "${TESTKIT_FAILED:-0}" = "1" ]; then
        echo "evidence kept at $TEST_TMP"
        return 0
    fi
    rm -rf "$TEST_TMP"
    return 0
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# Make sure the bundle this suite will launch exists in its own temp dir.
#
# The cache is shared and reused: the core is built there only when it is
# missing (that is the expensive cmake step), and the SwiftPM build cache lives
# there too, so repeated runs only pay for a relink.
testkit_build() {
    if [ -z "${TEST_APP_DIR:-}" ] || [ -z "${MIRAGE_PLAY_BUILD_ROOT:-}" ]; then
        echo "testkit: call testkit_init before testkit_build" >&2
        return 1
    fi

    mkdir -p "$MIRAGE_PLAY_BUILD_ROOT" || {
        echo "testkit: could not create the build cache $MIRAGE_PLAY_BUILD_ROOT" >&2
        return 1
    }

    local core
    core="$(uxplay_core_binary "$MIRAGE_PLAY_BUILD_ROOT")" || {
        echo "testkit: could not resolve the core path under $MIRAGE_PLAY_BUILD_ROOT" >&2
        return 1
    }

    if [ ! -x "$core" ]; then
        echo "=== testkit: core missing in the cache - building it now (one-off) ==="
        echo "    core : $core"
        if ! "$TESTKIT_REPO_ROOT/scripts/build/build-core.sh" \
                --embedded --build-dir "$MIRAGE_PLAY_BUILD_ROOT"; then
            echo "testkit: build-core.sh failed; the cache at $MIRAGE_PLAY_BUILD_ROOT is unusable" >&2
            return 1
        fi
    fi
    [ -x "$core" ] || {
        echo "testkit: core still missing at $core after build-core.sh" >&2
        return 1
    }

    if ! "$TESTKIT_REPO_ROOT/scripts/build/build-app.sh" \
            --out "$TEST_APP_DIR" --build-dir "$MIRAGE_PLAY_BUILD_ROOT"; then
        echo "testkit: build-app.sh failed; no bundle in $TEST_APP_DIR" >&2
        return 1
    fi

    local binary
    binary="$(testkit_app_binary)"
    [ -x "$binary" ] || {
        echo "testkit: the assembled bundle has no executable at $binary" >&2
        return 1
    }
    return 0
}

# Absolute path of the assembled main executable.
testkit_app_binary() {
    if [ -z "${TEST_APP_DIR:-}" ]; then
        echo "testkit: call testkit_init before testkit_app_binary" >&2
        return 1
    fi
    printf '%s\n' "$TEST_APP_DIR/$(_testkit_app_relative_binary)"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# Launch the assembled bundle's executable in the background.
#
# Every argument is forwarded verbatim, so a caller keeps spelling its own
# environment (`MIRRORBOARD_UITEST=1 testkit_launch`) exactly as it did when it
# launched the binary itself. Only MIRAGE_PLAY_UI_LOG is imposed here: that is
# what makes the log per-run and therefore assertion-safe.
testkit_launch() {
    if [ -z "${TEST_UI_LOG:-}" ]; then
        echo "testkit: call testkit_init before testkit_launch" >&2
        return 1
    fi
    local binary
    binary="$(testkit_app_binary)" || return 1
    [ -x "$binary" ] || {
        echo "testkit: no executable at $binary (run testkit_build first)" >&2
        return 1
    }
    mkdir -p "$(dirname "$TEST_UI_LOG")" || return 1

    MIRAGE_PLAY_UI_LOG="$TEST_UI_LOG" "$binary" "$@" >>"$TEST_APP_CONSOLE" 2>&1 &
    TEST_APP_PID=$!
    export TEST_APP_PID
    return 0
}

# Ask the running app to quit.
#
# The app traps SIGINT/SIGTERM and shuts its projection child down on the way
# out, so SIGINT is the polite request; a hung app is escalated to SIGTERM and
# finally SIGKILL so a suite can never leave a process behind. Returns 0 when
# the app is gone, non-zero when it had to be killed outright.
testkit_quit() {
    local pid="${TEST_APP_PID:-}"
    if [ -z "$pid" ]; then
        return 0
    fi
    kill -0 "$pid" 2>/dev/null || {
        TEST_APP_PID=""
        return 0
    }

    kill -INT "$pid" 2>/dev/null || true
    if _testkit_wait_gone "$pid" 10; then
        TEST_APP_PID=""
        return 0
    fi

    echo "testkit: app $pid ignored the quit request for 10s - sending SIGTERM" >&2
    kill -TERM "$pid" 2>/dev/null || true
    if _testkit_wait_gone "$pid" 5; then
        TEST_APP_PID=""
        return 0
    fi

    echo "testkit: app $pid survived SIGTERM - sending SIGKILL" >&2
    kill -KILL "$pid" 2>/dev/null || true
    _testkit_wait_gone "$pid" 5 || true
    TEST_APP_PID=""
    return 1
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Evidence directory for this run (created on demand).
testkit_evidence_dir() {
    if [ -z "${TEST_EVIDENCE:-}" ]; then
        echo "testkit: call testkit_init before testkit_evidence_dir" >&2
        return 1
    fi
    mkdir -p "$TEST_EVIDENCE" || return 1
    printf '%s\n' "$TEST_EVIDENCE"
}

# Per-run UI log file this run's app writes and this run's assertions read.
testkit_ui_log() {
    if [ -z "${TEST_UI_LOG:-}" ]; then
        echo "testkit: call testkit_init before testkit_ui_log" >&2
        return 1
    fi
    printf '%s\n' "$TEST_UI_LOG"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# Non-zero when another MiragePlay/uxplay already runs, with the reason printed.
# Never kills: a live instance may belong to somebody else's session.
testkit_preflight_clean() {
    local name pids found=0
    for name in $(_testkit_process_names); do
        pids="$(_testkit_pids "$name")"
        [ -n "$pids" ] || continue
        found=1
        echo "testkit: refusing to run - $name already running (pids: $pids)" >&2
    done
    [ "$found" = "0" ] && return 0
    echo "testkit: quit the running instance(s) first; this harness never kills another session's processes" >&2
    return 1
}
