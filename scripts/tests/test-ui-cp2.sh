#!/bin/bash
# test-ui-cp2.sh — CP-2 (increment ①) UI test: menu bar icon + anchored panel
# + UI-driven receiver start/stop + clean S5 quit.
#
# Re-runnable. Self-contained. Never touches a RUNNING MiragePlay/uxplay
# instance (aborts — that would be YC's own instance; the test cleans up after itself, zero residue).
#
# Verifies:
#   0. core⇄app contract statics (C segment revision: spawn argv = snapshot argv() /
#      pty line buffering (openpty) + single executableURL, stdbuf retired /
#      prepareForReceiverStart wiring; 3 frozen log match
#      strings / env), StatusItemMenu instantiated, no auto-start
#   1. build OK                    (scripts/lib/testkit.sh -> build-app.sh --out <tmp>)
#   2. launch OK
#   3. status item exists          (ui.log instrumentation + best-effort AX)
#   4. panel open + close          (ui.log PANEL shown / PANEL hidden)
#   5. start → uxplay up              (pgrep -x uxplay)
#   6. stop → uxplay down and STAYS down (no guard respawn of a user stop)
#   7. quit → app exits, zero residue (no MiragePlay, no uxplay)
#
# The scripted UI sequence is driven by the app itself: MIRRORBOARD_UITEST=1
# makes UITestDriver call the exact entry points the panel uses (icon click /
# start/stop / quit) on a fixed timeline — see UITestDriver.swift. Timeline:
# panel open 1.5s / close 2.5s / start 3.0s / stop 14.0s / quit 20.0s.
#
# Usage:  ./scripts/tests/test-ui-cp2.sh            (full run)
#         UI_CP2_AX=0 ./scripts/tests/test-ui-cp2.sh  (skip the AX probe)
#
# Harness contract (scripts/lib/testkit.sh): the suite builds its OWN bundle
# into this run's temp directory (testkit_build), launches that bundle's
# executable (testkit_launch — which also pins the app's ui.log to this run),
# and keeps every artefact inside the run's evidence directory. Nothing here
# reads a build product that lives in the checkout, and no two suites share a
# mutable log file.
# Evidence: $(testkit_evidence_dir) of this run (kept when the run fails).

set -u

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Canonical spelling (2026-10-20): this root is handed to scripts/build/build-app.sh,
# whose --package-path/--build-path reach swift/clang. clang keys its module
# cache by path STRING, so a caller-typed spelling (projects vs Projects on
# this case-insensitive volume) creates a second module identity and ASTReader
# segfaults. `pwd`/`pwd -P` keep the caller's spelling; readlink -f does not.
# See scripts/lib/_canonical-path.sh.
. "$PROJ/scripts/lib/_canonical-path.sh"
PROJ="$(mp_canonical_dir "$PROJ")" || {
    echo "test-ui-cp2: cannot resolve the repo root to its on-disk spelling" >&2
    exit 1
}

# Shared harness foundation (build into tmp + per-run ui.log + process
# hygiene). Located relative to THIS script — the repository root is never
# spelled as an absolute literal here.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
[ -f "$LIB_DIR/testkit.sh" ] || {
    echo "test-ui-cp2: the shared harness library is missing at $LIB_DIR/testkit.sh" >&2
    exit 1
}
# shellcheck source=scripts/lib/testkit.sh
. "$LIB_DIR/testkit.sh"

CB_SWIFT="$PROJ/app/Sources/core-bridge/CoreBridgeReceiverController.swift"
CR_SWIFT="$PROJ/app/Sources/AppShell/CompositionRoot.swift"
AD_SWIFT="$PROJ/app/Sources/AppShell/AppDelegate.swift"
UI_CP2_AX="${UI_CP2_AX:-1}"

PASS=0
FAIL=0
SKIP=0
APP_PID=""

# --- this run's workspace ----------------------------------------------------

testkit_init || {
    echo "test-ui-cp2: testkit_init failed (no temp workspace for this run)" >&2
    exit 1
}
RUN="$(testkit_evidence_dir)" || {
    echo "test-ui-cp2: testkit_evidence_dir failed" >&2
    exit 1
}
UI_LOG="$(testkit_ui_log)" || {
    echo "test-ui-cp2: testkit_ui_log failed" >&2
    exit 1
}

# Paths the APP owns. They are READ-ONLY inputs for this suite (the app has no
# environment override for them), derived from the app's own layout rules:
#   - ui.log         → overridden per run by testkit_launch (above)
#   - screenshots    → NSTemporaryDirectory()/com.ycchung.mirageplay
#   - launch.log     → ~/Library/Application Support/com.ycchung.mirageplay
#                      (truncated by the app on every fresh Start, so it always
#                       holds THIS run's spawn output)
SCRATCH="${TMPDIR:-/tmp}/com.ycchung.mirageplay"
APPSUP="$HOME/Library/Application Support/com.ycchung.mirageplay"
LAUNCH_LOG="$APPSUP/launch.log"

log()  { echo "$@" | tee -a "$RUN/summary.txt"; }
pass() { PASS=$((PASS + 1)); log "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); log "FAIL  $1"; }
skip() { SKIP=$((SKIP + 1)); log "SKIP  $1"; }

# --- helpers ---------------------------------------------------------------

wait_for_line() { # <fixed-pattern> <timeout_sec> < 0.25s steps
    local pattern="$1" timeout_s="${2:-10}" waited=0
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        grep -Fq "$pattern" "$UI_LOG" 2>/dev/null && return 0
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}

wait_pgrep_up() { # <procname> <timeout_sec>
    local name="$1" timeout_s="${2:-10}" waited=0
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        pgrep -x "$name" >/dev/null 2>&1 && return 0
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}

wait_pgrep_down() { # <procname> <timeout_sec>
    local name="$1" timeout_s="${2:-10}" waited=0
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        pgrep -x "$name" >/dev/null 2>&1 || return 0
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}

no_pgrep_for() { # <procname> <seconds>
    local name="$1" seconds="$2" waited=0
    while [ "$waited" -lt $((seconds * 2)) ]; do
        pgrep -x "$name" >/dev/null 2>&1 && return 1
        sleep 0.5
        waited=$((waited + 1))
    done
    return 0
}

ax_probe() {
    # Best-effort AX check: may be unavailable without Accessibility
    # permission — bounded to ~8s so a missing grant cannot hang the run.
    #
    # The bundle now lives under a fresh temp path on every run, but the AX
    # grant is keyed on the process ASKING (osascript/Terminal), not on the
    # app's path, and the app's process name is unchanged ("MiragePlay"). So
    # this probe is unchanged in intent — and every unavailable outcome is a
    # SOFT SKIP with a reason: a permission the harness cannot grant must never
    # read as a product failure, and must never be counted as a PASS either.
    [ "$UI_CP2_AX" = "1" ] || { skip "AX probe (disabled via UI_CP2_AX=0)"; return; }
    ( osascript -e 'tell application "System Events" to tell process "MiragePlay" to get name of every menu bar item of menu bar 1' \
        >"$RUN/ax.log" 2>&1 ) &
    local ax_pid=$! waited=0
    disown "$ax_pid" 2>/dev/null
    while kill -0 "$ax_pid" 2>/dev/null && [ "$waited" -lt 16 ]; do
        sleep 0.5
        waited=$((waited + 1))
    done
    if kill -0 "$ax_pid" 2>/dev/null; then
        kill "$ax_pid" 2>/dev/null
        skip "AX probe (timed out — likely needs Accessibility permission)"
        return
    fi
    # A missing Accessibility grant surfaces as an osascript error (-1743,
    # "not authorized to send Apple events" / "assistive access"). Report it as
    # a SKIP carrying the reason, never as a FAIL and never as a PASS.
    if grep -qiE 'not authori[sz]ed|-1743|assistive access' "$RUN/ax.log" 2>/dev/null; then
        skip "AX probe (no Accessibility permission; see ax.log)"
        return
    fi
    if grep -qi "mirageplay" "$RUN/ax.log" 2>/dev/null; then
        pass "status item exists (AX: menu bar item visible)"
    else
        skip "AX probe unavailable (permission or item unnamed; see ax.log)"
    fi
}

# --- 0. preflight: never touch a live instance ------------------------------

log "== CP-2 UI test — $(date '+%Y-%m-%d %H:%M:%S %Z') =="
log "   run dir: $RUN"
log "   ui.log:  $UI_LOG"

if ! testkit_preflight_clean; then
    log "ABORT: MiragePlay or uxplay is already running — refusing to touch a live instance."
    testkit_mark_failed
    exit 2
fi
pass "preflight: zero pre-existing MiragePlay/uxplay"

# --- 1. contract statics -----------------------------------------------------

if grep -Fq '"Accepted IPv4 client"' "$CB_SWIFT" \
    && grep -Fq '"Accepted IPv6 client"' "$CB_SWIFT" \
    && grep -Fq '"Connection closed"' "$CB_SWIFT"; then
    pass "contract: 3 frozen log match strings intact"
else
    fail "contract: frozen log match strings changed in CoreBridgeReceiverController"
fi

# C segment (wave1c) revision: spawn argv is now composed from snapshot argv() — the Stage1 hard-coded
# ["-n","MiragePlay"] is retired (IF-2 diff table #17: "spawn consumes the snapshot = 2c scope"),
# and prepareForReceiverStart must be called before every spawn (-rc missing file = uxplay exit(0)).
# D3 (2026-10-20): the `stdbuf` wrapper retired in D2 — assert the pty that
# replaced it, not the tool that is gone.
#   (a) `openpty(3)` is actually CALLED: a tty on the child's stdout/stderr is
#       what makes libc line-buffer, with no external helper in the path.
#   (b) `process.executableURL` is assigned EXACTLY once: the old
#       "host has stdbuf / host has not" fork collapsed into one path — that
#       fork was what made the bug machine-dependent.
#   (c) `stdbuf` is no longer EXECUTION logic. `grep -c stdbuf == 0` would be
#       the wrong test: the file keeps 6 `stdbuf` mentions on purpose, all in
#       comments recording why it left. So whole-line comments are stripped
#       first (Swift `//` and `///` — leading blanks then `//`) and the
#       remainder is asserted clean. Trailing comments are NOT stripped,
#       which errs strict (can fail, cannot falsely pass).
CB_CODE="$(grep -v -E '^[[:space:]]*//' "$CB_SWIFT")"
CB_PTY_HITS="$(printf '%s\n' "$CB_CODE" | grep -Fc 'openpty(' || true)"
CB_STDBUF_HITS="$(printf '%s\n' "$CB_CODE" | grep -Fc 'stdbuf' || true)"
CB_EXEC_HITS="$(grep -Fc 'process.executableURL' "$CB_SWIFT" || true)"

if grep -Fq 'effectiveSnapshot.argv()' "$CB_SWIFT" \
    && grep -Fq 'snapshotPreparer' "$CB_SWIFT" \
    && ! grep -Fq '"-n", "MiragePlay"' "$CB_SWIFT" \
    && [ "${CB_PTY_HITS:-0}" -ge 1 ] \
    && [ "${CB_EXEC_HITS:-0}" -eq 1 ] \
    && [ "${CB_STDBUF_HITS:-0}" -eq 0 ]; then
    pass "contract: spawn argv = snapshot argv() (hardcoded -n MiragePlay retired); single spawn path + pty line buffering (stdbuf retired)"
else
    fail "contract: spawn argv consumption / single executableURL / pty line buffering changed in CoreBridgeReceiverController"
fi

if grep -Fq 'prepareForReceiverStart' "$CR_SWIFT"; then
    pass "wiring: snapshotPreparer wired to ConfigEngine.prepareForReceiverStart (CompositionRoot)"
else
    fail "wiring: prepareForReceiverStart not wired in CompositionRoot"
fi

if grep -Fq 'StatusItemMenu(' "$CR_SWIFT"; then
    pass "wiring: StatusItemMenu instantiated in CompositionRoot"
else
    fail "wiring: StatusItemMenu has no instantiation point"
fi

if grep -Eq '^[[:space:]]*lifecycleCoordinator\.start\(\)' "$AD_SWIFT"; then
    fail "wiring: AppDelegate still auto-starts the receiver"
else
    pass "wiring: no auto-start in AppDelegate (panel-driven lifecycle)"
fi

# --- 2. build (into this run's temp directory, via the shared testkit) --------

if testkit_build >"$RUN/build.log" 2>&1; then
    pass "build ok (scripts/build/build-app.sh)"
else
    fail "build failed — see $RUN/build.log"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    testkit_mark_failed
    exit 1
fi

EXE="$(testkit_app_binary)"
if [ -z "$EXE" ] || [ ! -x "$EXE" ]; then
    fail "built executable not found ($EXE)"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    testkit_mark_failed
    exit 1
fi
log "   executable: $EXE"

# --- 3. launch (this run's ui.log — no archive step is needed any more) ------

MIRRORBOARD_UITEST=1 testkit_launch
APP_PID="${TEST_APP_PID:-}"
sleep 1
if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    pass "launch ok (pid $APP_PID)"
else
    # Keep the historical diagnostic path: testkit sends the app's stdout+stderr
    # to TEST_APP_CONSOLE, so mirror it into the run dir before reporting.
    cp "$TEST_APP_CONSOLE" "$RUN/app.stdout.log" 2>/dev/null
    fail "launch failed — see $RUN/app.stdout.log"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    testkit_mark_failed
    exit 1
fi

# --- 4. scripted UI sequence assertions --------------------------------------

wait_for_line "STATUSITEM created" 10 \
    && pass "status item created (ui.log STATUSITEM)" \
    || fail "no STATUSITEM line in ui.log (icon never created)"

wait_for_line "PANEL shown" 8 \
    && pass "panel opens (ui.log PANEL shown)" \
    || fail "panel never shown (no PANEL shown line)"

wait_for_line "PANEL snapshot " 5 \
    && pass "panel render written (visual evidence, AppKit render)" \
    || fail "panel snapshot not written"

wait_for_line "ICONSHEET " 5 \
    && pass "icon sheet written (4-state visual evidence)" \
    || fail "icon sheet not written"

wait_for_line "PANEL hidden" 8 \
    && pass "panel closes (ui.log PANEL hidden)" \
    || fail "panel never hidden (no PANEL hidden line)"

wait_for_line "ACTION start" 8 \
    && pass "Start clicked (ACTION start)" \
    || fail "Start never invoked"

wait_pgrep_up uxplay 10 \
    && pass "start → uxplay running (pgrep -x uxplay)" \
    || fail "uxplay did not start after Start"

wait_for_line "STATE waiting" 5 \
    && pass "state rendered waiting (status row waiting for connection)" \
    || fail "STATE waiting never rendered"

ax_probe

wait_for_line "ACTION stop" 24 \
    && pass "Stop clicked (ACTION stop)" \
    || fail "Stop never invoked"

wait_pgrep_down uxplay 5 \
    && pass "stop → uxplay gone (pgrep -x uxplay)" \
    || fail "uxplay still running after Stop"

if no_pgrep_for uxplay 4; then
    pass "uxplay stays down after user stop (wantsRunning=false; no guard respawn)"
else
    fail "uxplay respawned after user Stop — user intent did not land"
fi

wait_for_line "ACTION quit" 15 \
    && pass "Quit clicked (ACTION quit, S5)" \
    || fail "Quit never invoked"

# app must exit on its own (S5: quit everything, don't ask)
waited=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do
    sleep 0.25
    waited=$((waited + 1))
done
if kill -0 "$APP_PID" 2>/dev/null; then
    fail "app did not exit after Quit"
else
    pass "quit → app exited"
    APP_PID=""
fi

# --- 5. residue ---------------------------------------------------------------

sleep 1
if pgrep -x MiragePlay >/dev/null 2>&1; then
    fail "residue: MiragePlay still running"
else
    pass "residue: no MiragePlay"
fi
if pgrep -x uxplay >/dev/null 2>&1; then
    fail "residue: uxplay still running"
else
    pass "residue: no uxplay"
fi

# advisory: crash-guard respawn lines in this run's launch.log (policy is a
# separate case; recorded, never fatal). The app truncates launch.log on every
# fresh Start, so what we grep here belongs to this run only.
if [ -f "$LAUNCH_LOG" ] && grep -Fq "CRASH respawn" "$LAUNCH_LOG"; then
    log "NOTE  launch.log contains 'CRASH respawn' during this run — inspect $RUN/launch.log"
fi

# --- evidence copy + summary --------------------------------------------------

cp "$UI_LOG" "$RUN/ui.log" 2>/dev/null
cp "$LAUNCH_LOG" "$RUN/launch.log" 2>/dev/null
cp "$TEST_APP_CONSOLE" "$RUN/app-console.log" 2>/dev/null
cp "$SCRATCH/panel-snapshot.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/statusicon-sheet.png" "$RUN/" 2>/dev/null

log ""
log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
log "   ui.log:     $UI_LOG"
log "   evidence:   $RUN"
if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
testkit_mark_failed
exit 1
