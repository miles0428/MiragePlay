#!/bin/bash
# test-wiring-e1.sh — wave1r3 (B2 slider batch) staged-apply wiring test.
#
# Covers (per the wave1r3 task card ⑤):
#   ① staged model (uniform across the window) — change the four fields one by one (resolution→frame rate→mute→name) = only
#      local UI state changes: zero engine writes, zero E1, zero receiver action (settings-changed count 0,
#      no new spawn, uxplay PID unchanged) + the evidence lines `PREFS staged …` /
#      `PREFS apply enabled=1`. wave1r3: both numeric rows are sliders (slider settled
#      commit; release = commit), and the driving path lines up.
#   ② apply takes effect in one shot — all four fields committed at once: exactly one
#      `ACTION settings-changed (restart)` (exactly one restart) + spawn#2 argv carries
#      all four fields (-n "YC's Mac", -s 1280x720, -fps 60, -a; same via host-side ps);
#      after applying, dirty is cleared (apply enabled=0).
#   ③ closing the window without applying = staged discarded (PM micro-decision 1) — stage frame rate 120, close without applying:
#      `PREFS staged discarded (unapplied)`; reopening shows the persisted value (fps=60).
#   ④ not started = write-back only — after stopping, stage mute off + apply =
#      `ACTION settings-changed (write-back only)`, zero spawn.
#   ⑤ spawn consumes the snapshot (C segment invariant) — spawn argv == EffectiveSnapshot.argv();
#      the rc file proves it field by field.
#
# Re-runnable. Self-contained. Never touches a RUNNING MiragePlay/uxplay
# instance (aborts — that would be YC's own instance; the test cleans up after itself, zero residue).
# User state restore: before the test, `~/Library/Application Support/com.ycchung.
# mirageplay/settings.json` (if present) is moved into this run's directory for safekeeping and put back unchanged at the end;
# if it did not exist, the one produced by the test is moved into the run directory (zero residue, zero deletion).
#
# The scripted sequence is driven by the app itself:
# MIRRORBOARD_UITEST_WIRING=1 → UITestDriver.runWiringE1 drives the exact
# staged paths the preferences-window controls take. Timeline: panel 1.0s /
# start 1.5s / prefs 3.6s / staged 720p 4.4s / staged 60 5.2s / staged mute on
# 6.0s / staged "YC's Mac" 6.8s / apply 7.6s / close 9.0s / reopen 9.8s /
# staged 120 11.0s / close 11.8s / reopen 12.6s / close 13.4s / stop 14.2s /
# staged mute off 15.8s / apply 16.6s / quit 20.0s — see UITestDriver.swift.
#
# Usage:  ./scripts/tests/test-wiring-e1.sh
#
# Harness contract (scripts/lib/testkit.sh): the suite builds its OWN bundle
# into this run's temp directory (testkit_build), launches that bundle's
# executable (testkit_launch — which pins the app's ui.log to this run), and
# derives the projection-helper path from the assembled bundle instead of
# spelling the bundle layout here. The app's own artefacts (launch.log,
# snapshot.rc, settings.json) live in Application Support and are only read.
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
    echo "test-wiring-e1: cannot resolve the repo root to its on-disk spelling" >&2
    exit 1
}

# Shared harness foundation (build into tmp + per-run ui.log + process
# hygiene). Located relative to THIS script — the repository root is never
# spelled as an absolute literal here.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
[ -f "$LIB_DIR/testkit.sh" ] || {
    echo "test-wiring-e1: the shared harness library is missing at $LIB_DIR/testkit.sh" >&2
    exit 1
}
# shellcheck source=scripts/lib/testkit.sh
. "$LIB_DIR/testkit.sh"

CB_SWIFT="$PROJ/app/Sources/core-bridge/CoreBridgeReceiverController.swift"
CR_SWIFT="$PROJ/app/Sources/AppShell/CompositionRoot.swift"
PW_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesWindowController.swift"
PF_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesFormViews.swift"
SI_SWIFT="$PROJ/app/Sources/AppShell/StatusItemMenu.swift"
IH_SWIFT="$PROJ/app/Sources/AppShell/PreferencesIntentHandler.swift"

# Paths the APP owns (read-only inputs here; the app has no env override for
# them). ~/Library/Application Support/<bundle-id> holds the artefacts that
# must survive a relaunch: settings.json, snapshot.rc and launch.log. The app
# truncates launch.log on every fresh Start, so it only ever carries THIS run's
# spawn output.
APPSUP="$HOME/Library/Application Support/com.ycchung.mirageplay"
SETTINGS="$APPSUP/settings.json"
RC_FILE="$APPSUP/snapshot.rc"
LAUNCH_LOG="$APPSUP/launch.log"

PASS=0
FAIL=0
SKIP=0
APP_PID=""
UXPLAY_BIN=""
SETTINGS_PREEXISTED=0
APPSUP_PREEXISTED=0
RESTORED=0

# --- this run's workspace ----------------------------------------------------

testkit_init || {
    echo "test-wiring-e1: testkit_init failed (no temp workspace for this run)" >&2
    exit 1
}
RUN="$(testkit_evidence_dir)" || {
    echo "test-wiring-e1: testkit_evidence_dir failed" >&2
    exit 1
}
UI_LOG="$(testkit_ui_log)" || {
    echo "test-wiring-e1: testkit_ui_log failed" >&2
    exit 1
}

log()  { echo "$@" | tee -a "$RUN/summary.txt"; }
pass() { PASS=$((PASS + 1)); log "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); log "FAIL  $1"; }
skip() { SKIP=$((SKIP + 1)); log "SKIP  $1"; }

# --- user-state restore (exact; runs from cleanup and from the normal tail) --

restore_settings() {
    [ "$RESTORED" = "1" ] && return
    RESTORED=1
    if [ "$SETTINGS_PREEXISTED" = "1" ] && [ -f "$RUN/settings.json.prev" ]; then
        # keep the test-run file as evidence, then put the original back
        [ -f "$SETTINGS" ] && cp "$SETTINGS" "$RUN/settings.json.test-run" 2>/dev/null
        mv -f "$RUN/settings.json.prev" "$SETTINGS"
        log "[restore] original settings.json restored"
    elif [ "$SETTINGS_PREEXISTED" = "0" ] && [ -f "$SETTINGS" ]; then
        mv "$SETTINGS" "$RUN/settings.json.self-created"
        log "[restore] test-created settings.json archived (none existed before)"
    fi
    if [ "$APPSUP_PREEXISTED" = "0" ] && [ -d "$APPSUP" ]; then
        rmdir "$APPSUP" 2>/dev/null && log "[restore] empty AppSupport dir removed (created by this run)"
    fi
}

# testkit_init installed its own EXIT trap (testkit_teardown). This suite needs
# the user's settings.json put back on EVERY exit path — including the failure
# paths that keep the temp directory — so the trap is reinstalled here and it
# runs both jobs in that order.
cleanup() {
    restore_settings
    testkit_teardown
}
trap cleanup EXIT

# --- helpers ---------------------------------------------------------------

count_in() { # <fixed-pattern> <file> → a number (0 when absent)
    local n
    n="$(grep -Fc -- "$1" "$2" 2>/dev/null)" || n=0
    [ -n "$n" ] || n=0
    printf '%s' "$n"
}

wait_for_count() { # <file> <fixed-pattern> <min-count> <timeout_sec>
    local file="$1" pattern="$2" want="$3" timeout_s="${4:-12}" waited=0
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        [ "$(count_in "$pattern" "$file")" -ge "$want" ] && return 0
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

wait_pid_change() { # <old_pid> <timeout_sec> → echoes the new pid
    local old="$1" timeout_s="${2:-10}" waited=0 new=""
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        new="$(pgrep -x uxplay 2>/dev/null | head -1)"
        if [ -n "$new" ] && [ "$new" != "$old" ]; then
            echo "$new"
            return 0
        fi
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}

spawn_count() { count_in 'MIRRORBOARD SPAWN pid=' "$LAUNCH_LOG"; }

spawn_line() { # <lineno> — the Nth MIRRORBOARD SPAWN line
    grep -F -- 'MIRRORBOARD SPAWN pid=' "$LAUNCH_LOG" 2>/dev/null | sed -n "${1}p"
}

line_has() { # <text> <fixed substring>
    printf '%s\n' "$1" | grep -Fq -- "$2"
}

ps_args_of() { # <pid>
    ps -ww -o args= -p "$1" 2>/dev/null
}

ps_args_stable() { # <pid> <timeout_sec> — bounded retry around ps (proc-table hiccups)
    local pid="$1" timeout_s="${2:-3}" waited=0 args=""
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        args="$(ps_args_of "$pid")"
        [ -n "$args" ] && break
        sleep 0.25
        waited=$((waited + 1))
    done
    printf '%s' "$args"
}

# --- 0. preflight: never touch a live instance ------------------------------

log "== wave1r1 wiring/staged-apply test — $(date '+%Y-%m-%d %H:%M:%S %Z') =="
log "   run dir: $RUN"
log "   ui.log:  $UI_LOG"

if ! testkit_preflight_clean; then
    log "ABORT: MiragePlay or uxplay is already running — refusing to touch a live instance."
    testkit_mark_failed
    exit 2
fi
pass "preflight: zero pre-existing MiragePlay/uxplay"

# --- 1. contract statics -----------------------------------------------------

if grep -Fq 'effectiveSnapshot.argv()' "$CB_SWIFT" \
    && grep -Fq 'snapshotPreparer' "$CB_SWIFT" \
    && ! grep -Fq '"-n", "MiragePlay"' "$CB_SWIFT"; then
    pass "contract: spawn argv = snapshot argv() (hardcoded -n MiragePlay retired)"
else
    fail "contract: spawn argv consumption / hardcode retirement changed in CoreBridgeReceiverController"
fi

if grep -Fq 'prepareForReceiverStart' "$CR_SWIFT"; then
    pass "wiring: snapshotPreparer wired to ConfigEngine.prepareForReceiverStart (CompositionRoot)"
else
    fail "wiring: prepareForReceiverStart not wired in CompositionRoot"
fi

if grep -Fq 'settingsChanged()' "$CR_SWIFT" || grep -Fq 'settingsChanged' "$PROJ/app/Sources/AppShell/LifecycleCoordinator.swift"; then
    pass "wiring: E1 settingsChanged entry present (coordinator)"
else
    fail "wiring: E1 settingsChanged missing"
fi

# wave1r1 staged model (source static): window fields only enter staged (no per-field intent),
# apply is the only commit entry point; the adapter writes field by field + receiver-related decisions.
if grep -Fq 'applyClicked' "$PW_SWIFT" \
    && grep -Fq 'preferencesApplyRequested' "$PW_SWIFT" \
    && grep -Fq 'PREFS staged' "$PW_SWIFT" \
    && grep -Fq 'PREFS apply enabled=' "$PW_SWIFT" \
    && grep -Fq 'PREFS staged discarded' "$PW_SWIFT" \
    && ! grep -Fq 'preferencesResolutionSelected' "$PW_SWIFT" \
    && ! grep -Fq 'preferencesMuteToggled' "$PW_SWIFT" \
    && ! grep -Fq 'preferencesDeviceNameCommitted' "$PW_SWIFT"; then
    pass "staged: zero per-field intents in the window (edits only reach staged) + Apply + evidence lines (staged/enabled/discard)"
else
    fail "staged: staged-apply wiring incomplete in PreferencesWindowController"
fi

# wave1r3 — the slider-driven path lines up (B2 ruling ①): the two numeric rows are
# [slider 128] + [readout 48] (zero stepper / zero value field); the settled
# commit (release = commit; isContinuous = false) feeds the SAME staged seam the
# harness drives (select*ForTesting → SliderControl.commit → stage).
if grep -Fq 'NSSlider' "$PF_SWIFT" \
    && grep -Fq 'allowsTickMarkValuesOnly = true' "$PF_SWIFT" \
    && grep -Fq 'isContinuous = false' "$PF_SWIFT" \
    && grep -Fq 'sliderWidth: CGFloat = 128' "$PF_SWIFT" \
    && grep -Fq 'readoutWidth: CGFloat = 48' "$PF_SWIFT" \
    && ! grep -rq 'NSStepper' "$PROJ/app/Sources" 2>/dev/null \
    && ! grep -Fq 'NumericStepperControl' "$PF_SWIFT" \
    && grep -Fq 'page.resolution.onValueChanged' "$PW_SWIFT" \
    && grep -Fq 'page.frameRate.onValueChanged' "$PW_SWIFT" \
    && grep -Fq 'form?.resolution.commit(step: step)' "$PW_SWIFT" \
    && grep -Fq 'form?.frameRate.commit(step: step)' "$PW_SWIFT" \
    && ! grep -Fq 'typeResolutionForTesting' "$PW_SWIFT" \
    && ! grep -Fq 'typeResolutionForTesting' "$SI_SWIFT"; then
    pass "slider drive path: slider settled commit → onValueChanged → stage (no stepper / no value field; typed seam retired)"
else
    fail "slider drive path misaligned（PF slider config / PW commit seams）"
fi

if grep -Fq 'func preferencesApplyRequested' "$IH_SWIFT" \
    && grep -Fq 'receiverRelated' "$IH_SWIFT" \
    && grep -Fq 'settingsChanged()' "$IH_SWIFT" \
    && grep -Fq 'ACTION apply-staged' "$IH_SWIFT"; then
    pass "adapter: batched apply writes + receiver-related decision (restart orchestration stays in the coordinator)"
else
    fail "adapter: staged apply missing from PreferencesIntentHandler"
fi

# --- 2. user-state handling (never destroy evidence) -------------------------

[ -d "$APPSUP" ] && APPSUP_PREEXISTED=1
if [ -f "$SETTINGS" ]; then
    SETTINGS_PREEXISTED=1
    mv "$SETTINGS" "$RUN/settings.json.prev"
    log "   settings.json pre-existed — moved to run dir (will be restored)"
else
    log "   settings.json absent — fresh-state run (test-created file will be archived out)"
fi
# snapshot.rc is NOT moved: the app needs it in place, and the assertions below
# compare the argv's -rc tail against that exact path. A copy is kept as
# evidence only.
[ -f "$RC_FILE" ] && cp "$RC_FILE" "$RUN/snapshot.rc.prev" 2>/dev/null

# --- 3. build (into this run's temp directory, via the shared testkit) --------

if testkit_build >"$RUN/build.log" 2>&1; then
    pass "build ok (scripts/build/build-app.sh, 0 warnings/0 errors enforced by caller)"
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

# The projection helper is DISCOVERED inside the assembled bundle — this suite
# does not restate the bundle's internal layout. The app resolves the same path
# from Bundle.main at runtime (CoreBridgeReceiverController.uxplayPath), so the
# spawn-argv assertions below compare like with like.
UXPLAY_BIN="$(/usr/bin/find "$TEST_APP_DIR/MiragePlay.app" -type f -name uxplay 2>/dev/null | head -1)"
if [ -z "$UXPLAY_BIN" ] || [ ! -x "$UXPLAY_BIN" ]; then
    log "ABORT: the assembled bundle carries no executable uxplay (searched $TEST_APP_DIR/MiragePlay.app)"
    testkit_mark_failed
    exit 1
fi
log "   uxplay: $UXPLAY_BIN"

# --- the expected spawn argument vectors (ONE definition, two consumers) -----
#
# Two independent views of the same process are compared below and they do NOT
# share a shape:
#   * the app's marker  — `MIRRORBOARD SPAWN pid=N argv="-n" "MiragePlay" …`
#     carries process.arguments ONLY (no argv[0]; the executable is
#     process.executableURL), each element `"`-quoted;
#   * `ps -o args=`     — argv[0] + the same vector, space-joined, no quoting.
# So the expectation is written ONCE as a word array and consumed twice: the
# marker side renders it `"`-quoted (`quoted_vector`), the ps side matches it as
# the command line's SUFFIX (`args_end_with_vector`) — everything before it is
# argv[0], which is asserted separately. A by-hand quoted string on one side and
# a bare one on the other is what made these three assertions compare different
# things.
ARGV1_EXPECT=(-n MiragePlay -s 1920x1080 -fps 30 -vsync no -rc "$RC_FILE")
ARGV2_EXPECT=(-n "YC 的 Mac" -s 1280x720 -fps 60 -vsync no -a -rc "$RC_FILE")

# <word>... → the app marker's rendering: "a" "b" (the marker escapes `\` and
# `"` only, and no expected value carries either).
quoted_vector() {
    local out="" word
    for word in "$@"; do
        out="${out:+$out }\"$word\""
    done
    printf '%s' "$out"
}

# The bundle this run assembled, in BOTH spellings the OS hands out: TMPDIR on
# macOS is `/var/folders/…` (ps prints the path the app passed, verbatim) while
# the testkit root is symlink-resolved to `/private/var/folders/…`. A plain
# prefix test would fail on that difference alone — which is a path spelling
# detail, not a spawn defect.
BUNDLE_ROOT="$TEST_APP_DIR/MiragePlay.app"
case "$BUNDLE_ROOT" in
    /private/*) BUNDLE_ROOT_SIBLING="${BUNDLE_ROOT#/private}" ;;
    *)          BUNDLE_ROOT_SIBLING="/private$BUNDLE_ROOT" ;;
esac

# <ps args> — true when argv[0] lies inside this run's assembled bundle.
args_start_inside_bundle() {
    case "$1" in
        "$BUNDLE_ROOT"/*|"$BUNDLE_ROOT_SIBLING"/*) return 0 ;;
        *)                                         return 1 ;;
    esac
}

# <ps args> <word>... — true when the command line ENDS with exactly this
# argument vector.
#
# `ps -o args=` re-joins argv with single spaces and prints no quoting, and the
# helper's own path CONTAINS a space
# (`…/Contents/Helpers/MiragePlay Projection.app/Contents/MacOS/uxplay`), so
# "everything up to the first space is argv[0]" is false here — it cuts the path
# in half. Matching the vector as a SUFFIX needs no split: everything before it
# is argv[0] (asserted separately), and one altered or extra word breaks the
# match.
args_end_with_vector() { # <ps args> <word>...
    local line="$1"
    shift
    case "$line" in
        *" $*") return 0 ;;
        *)      return 1 ;;
    esac
}

# --- 4. launch ---------------------------------------------------------------

MIRRORBOARD_UITEST_WIRING=1 testkit_launch
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

# --- 5. ⑤ spawn consumes the snapshot (defaults) ------------------------------

wait_for_count "$UI_LOG" "ACTION start" 1 10 \
    && pass "Start (ACTION start)" \
    || fail "Start never invoked"

waited=0
while [ "$waited" -lt 40 ] && [ -z "$(pgrep -x uxplay 2>/dev/null)" ]; do
    sleep 0.25
    waited=$((waited + 1))
done
PID1="$(pgrep -x uxplay 2>/dev/null | head -1)"
if [ -n "$PID1" ]; then
    pass "start → uxplay running (pid $PID1)"
else
    fail "uxplay did not start after Start"
fi

wait_for_count "$LAUNCH_LOG" 'MIRRORBOARD SPAWN pid=' 1 8 \
    && pass "spawn #1 marker written (launch.log MIRRORBOARD SPAWN)" \
    || fail "no SPAWN marker in launch.log"

EXP1="$(quoted_vector "${ARGV1_EXPECT[@]}")"
if line_has "$(spawn_line 1)" "$EXP1"; then
    pass "spawn #1 argv == snapshot argv() (defaults; quoted vector + §2.1 order + -rc tail)"
else
    fail "spawn #1 argv mismatch — got: $(spawn_line 1) (expected vector: $EXP1)"
fi
if line_has "$(spawn_line 1)" "MIRRORBOARD SPAWN pid=$PID1 "; then
    pass "spawn #1 marker pid == live uxplay pid ($PID1)"
else
    fail "spawn #1 marker pid != live uxplay pid ($PID1)"
fi

if [ -n "$PID1" ]; then
    ARGS1="$(ps_args_stable "$PID1")"
    printf '%s\n' "$ARGS1" > "$RUN/ps-args-1.txt"
    if args_start_inside_bundle "$ARGS1"; then
        pass "host-side executable is this run's bundle (argv[0] inside $BUNDLE_ROOT)"
    else
        fail "host-side executable is outside this run's bundle ($BUNDLE_ROOT) — got: $ARGS1"
    fi
    if args_end_with_vector "$ARGS1" "${ARGV1_EXPECT[@]}"; then
        pass "host-side argv (ps, argv[0] excluded) == snapshot argv() (defaults)"
    else
        fail "host-side argv mismatch — got: $ARGS1 (expected vector: ${ARGV1_EXPECT[*]})"
    fi
fi

if [ -s "$RC_FILE" ] && grep -Fq 'n MiragePlay' "$RC_FILE" && grep -Fq 's 1920x1080' "$RC_FILE"; then
    pass "rc file rewritten before spawn (snapshot.rc: n MiragePlay / s 1920x1080)"
else
    fail "rc file missing or stale before spawn #1"
fi

# --- 6. preferences window opens; truth line + apply disabled ----------------

wait_for_count "$UI_LOG" "PREFS shown (created)" 1 12 \
    && pass "prefs opens (PREFS shown (created))" \
    || fail "preferences window never shown"

wait_for_count "$UI_LOG" "PREFS values res=1080p fps=30 mute=off name=MiragePlay pin=- sleep=on notify=on profile=預設" 1 12 \
    && pass "prefs refresh reads real values (defaults; syncFromTruth reads the engine real values)" \
    || fail "initial PREFS values line missing/mismatched"

wait_for_count "$UI_LOG" "PREFS apply enabled=0" 1 8 \
    && pass "Apply initial state = disabled (no changes; PM micro-decision 3)" \
    || fail "apply-button initial disabled state line missing"

# --- 7. ① staged model: four fields changed one by one = zero engine action -------

wait_for_count "$UI_LOG" "PREFS staged name=MiragePlay res=720p fps=30 mute=off sleep=on notify=on lang=en profile=預設 dirty=1" 1 10 \
    && pass "staged #1 (resolution→720p; dirty=1)" \
    || fail "staged resolution line missing"
wait_for_count "$UI_LOG" "PREFS staged name=MiragePlay res=720p fps=60 mute=off sleep=on notify=on lang=en profile=預設 dirty=1" 1 10 \
    && pass "staged #2 (frame rate→60)" \
    || fail "staged frame-rate line missing"
wait_for_count "$UI_LOG" "PREFS staged name=MiragePlay res=720p fps=60 mute=on sleep=on notify=on lang=en profile=預設 dirty=1" 1 10 \
    && pass "staged #3 (mute→on)" \
    || fail "staged mute line missing"
wait_for_count "$UI_LOG" "PREFS staged name=YC 的 Mac res=720p fps=60 mute=on sleep=on notify=on lang=en profile=預設 dirty=1" 1 10 \
    && pass "staged #4 (name→YC 的 Mac)" \
    || fail "staged device-name line missing"

wait_for_count "$UI_LOG" "PREFS apply enabled=1" 1 8 \
    && pass "Apply becomes enabled after staging (dirty detected)" \
    || fail "apply-button enabled state line missing after staging"

# No apply, no action: no settings-changed anywhere in the block, no new spawn, PID unchanged, engine not written back.
STAGED_SC="$(count_in 'ACTION settings-changed' "$UI_LOG")"
STAGED_SPAWNS="$(spawn_count)"
LIVE_PID="$(pgrep -x uxplay 2>/dev/null | head -1)"
if [ "$STAGED_SC" = "0" ] && [ "$STAGED_SPAWNS" = "1" ] && [ "$LIVE_PID" = "$PID1" ]; then
    pass "nothing applied, nothing moved: settings-changed=0, spawn=1, uxplay PID unchanged (${PID1})"
else
    fail "nothing-applied invariant violated — settings-changed=$STAGED_SC spawn=$STAGED_SPAWNS pid=$LIVE_PID (expected 0/1/$PID1)"
fi
if [ ! -f "$SETTINGS" ] || ! grep -Fq '"resolution" : "720p"' "$SETTINGS"; then
    pass "nothing applied: staged values never reach settings.json (the engine did not write back)"
else
    fail "staged values leaked into settings.json before the apply"
fi

# --- 8. ② apply takes effect in one shot: exactly one restart + argv with all four fields ---

wait_for_count "$UI_LOG" "PREFS apply requested" 1 10 \
    && pass "② Apply clicked (PREFS apply requested)" \
    || fail "apply never invoked"

wait_for_count "$UI_LOG" "ACTION settings-changed (restart)" 1 12 \
    && pass "② Apply → E1 restart (ACTION settings-changed (restart))" \
    || fail "apply did not signal the E1 restart"

PID2="$(wait_pid_change "$PID1" 10)" \
    && pass "restart: uxplay PID changed ($PID1 → $PID2 — terminate+respawn)" \
    || fail "restart: uxplay PID never changed"

wait_for_count "$LAUNCH_LOG" 'MIRRORBOARD SPAWN pid=' 2 8 \
    && pass "spawn #2 marker written" \
    || fail "no spawn #2 marker"

if line_has "$(spawn_line 2)" '"-n" "YC 的 Mac"' \
    && line_has "$(spawn_line 2)" '"-s" "1280x720"' \
    && line_has "$(spawn_line 2)" '"-fps" "60"' \
    && line_has "$(spawn_line 2)" '"-vsync" "no" "-a" "-rc"' \
    && line_has "$(spawn_line 2)" "\"$RC_FILE\""; then
    pass "② spawn #2 argv carries all four fields at once (-n \"YC 的 Mac\" / -s 1280x720 / -fps 60 / -a; -rc tail)"
else
    fail "spawn #2 argv does not carry the full applied batch — got: $(spawn_line 2)"
fi
if [ -n "$PID2" ]; then
    ARGS2="$(ps_args_stable "$PID2")"
    printf '%s\n' "$ARGS2" > "$RUN/ps-args-2.txt"
    if args_start_inside_bundle "$ARGS2"; then
        pass "host-side executable after the apply is this run's bundle (argv[0] inside $BUNDLE_ROOT)"
    else
        fail "host-side executable after the apply is outside this run's bundle ($BUNDLE_ROOT) — got: $ARGS2"
    fi
    args_end_with_vector "$ARGS2" "${ARGV2_EXPECT[@]}" \
        && pass "host-side argv (ps, argv[0] excluded) == full batch snapshot (all four fields present)" \
        || fail "host-side argv after the apply mismatch — got: $ARGS2 (expected vector: ${ARGV2_EXPECT[*]})"
fi
grep -Fq 'n "YC 的 Mac"' "$RC_FILE" && grep -Fq 's 1280x720' "$RC_FILE" && grep -Fq 'fps 60' "$RC_FILE" && grep -Fxq 'a' "$RC_FILE" \
    && pass "rc file re-rewritten with the full batch (n \"YC 的 Mac\" / s 1280x720 / fps 60 / a)" \
    || fail "rc file not rewritten with the applied batch"

# Exactly once: even after settling there is only 1 settings-changed and 1 apply-staged.
sleep 2
RESTARTS_AFTER_APPLY="$(count_in 'ACTION settings-changed (restart)' "$UI_LOG")"
APPLY_LINES="$(count_in 'ACTION apply-staged' "$UI_LOG")"
SPAWNS_AFTER_APPLY="$(spawn_count)"
if [ "$RESTARTS_AFTER_APPLY" = "1" ] && [ "$APPLY_LINES" = "1" ] && [ "$SPAWNS_AFTER_APPLY" = "2" ]; then
    pass "② exactly once: 4 staged fields → 1 restart, 1 apply-staged, total spawn=2"
else
    fail "exactly-once invariant violated — restarts=$RESTARTS_AFTER_APPLY apply=$APPLY_LINES spawns=$SPAWNS_AFTER_APPLY (expected 1/1/2)"
fi
grep -Fq 'ACTION apply-staged receiver-related=1 shell-held=0' "$UI_LOG" \
    && pass "② apply-staged classification line (receiver-related=1 shell-held=0)" \
    || fail "apply-staged classification line missing"

wait_for_count "$UI_LOG" "PREFS apply enabled=0" 2 8 \
    && pass "② dirty cleared after Apply (apply enabled=0 again)" \
    || fail "apply-button not reset to disabled after the apply"

# --- 9. reopen real values + ③ close without applying = staged discarded ----------

wait_for_count "$UI_LOG" "PREFS shown (reused)" 1 10 \
    && pass "prefs reopen (singleton reuse)" \
    || fail "prefs never reopened"
wait_for_count "$UI_LOG" "PREFS values res=720p fps=60 mute=on name=YC 的 Mac" 1 10 \
    && pass "reopen refresh reads the applied truth (res=720p fps=60 mute=on name=YC 的 Mac)" \
    || fail "reopened PREFS values do not show the applied values"

wait_for_count "$UI_LOG" "PREFS staged name=YC 的 Mac res=720p fps=120 mute=on sleep=on notify=on lang=en profile=預設 dirty=1" 1 10 \
    && pass "staged frame rate→120 (not applied)" \
    || fail "second staged line (fps=120) missing"
wait_for_count "$UI_LOG" "PREFS staged discarded (unapplied)" 1 8 \
    && pass "③ closing without Apply discards staged (PREFS staged discarded (unapplied))" \
    || fail "discard line missing on close"
wait_for_count "$UI_LOG" "PREFS shown (reused)" 2 8 \
    && pass "prefs reopen #2 (reopen after the discard)" \
    || fail "second reopen missing"
wait_for_count "$UI_LOG" "PREFS values res=720p fps=60 mute=on name=YC 的 Mac" 2 10 \
    && pass "③ reopen shows the persisted value (fps=60; staged 120 discarded)" \
    || fail "reopened truth line after discard missing"
if ! grep -Fq 'PREFS values res=720p fps=120' "$UI_LOG"; then
    pass "③ discard proven: fps=120 never appears in PREFS values (never applied, never written back)"
else
    fail "discarded staged value leaked into the truth line"
fi
if [ "$(count_in 'ACTION settings-changed' "$UI_LOG")" = "1" ]; then
    pass "③ closing and discarding adds no action (settings-changed still =1)"
else
    fail "discard produced a settings-changed line"
fi

# --- 10. stop → uxplay down ----------------------------------------------------

wait_for_count "$UI_LOG" "ACTION stop" 1 10 \
    && pass "Stop (ACTION stop)" \
    || fail "Stop never invoked"
wait_pgrep_down uxplay 5 \
    && pass "stop → uxplay gone" \
    || fail "uxplay still running after Stop"

# E4: the panel never flipped back to the not-open state while running (idle=0 within the segment).
awk '/ACTION start/{f=1} f{print} /ACTION stop/{exit}' "$UI_LOG" > "$RUN/segment-running.txt"
IDLE_IN_RUN="$(count_in "STATE idle" "$RUN/segment-running.txt")"
WAITING_IN_RUN="$(count_in "STATE waiting" "$RUN/segment-running.txt")"
if [ "$IDLE_IN_RUN" = "0" ] && [ "$WAITING_IN_RUN" -ge 2 ]; then
    pass "E4: panel stayed in the Start presentation (STATE idle=0; STATE waiting=$WAITING_IN_RUN)"
else
    fail "E4 violated: STATE idle=$IDLE_IN_RUN / STATE waiting=$WAITING_IN_RUN inside the running segment"
fi

# --- 11. ④ not started = write-back only (staged mute off + apply) --------------

wait_for_count "$UI_LOG" "PREFS staged name=YC 的 Mac res=720p fps=60 mute=off sleep=on notify=on lang=en profile=預設 dirty=1" 1 10 \
    && pass "④ after stop, staged mute→off" \
    || fail "stopped-state staged line missing"
wait_for_count "$UI_LOG" "ACTION settings-changed (write-back only)" 1 10 \
    && pass "④ not started = write-back only (ACTION settings-changed (write-back only))" \
    || fail "stopped-state apply did not signal write-back"
grep -Fq 'ACTION apply-staged receiver-related=1 shell-held=0' "$UI_LOG" \
    && true # running apply already asserted; the stopped one is the second
STOPPED_APPLY="$(count_in 'ACTION apply-staged' "$UI_LOG")"
[ "$STOPPED_APPLY" = "2" ] \
    && pass "④ two apply-staged (one while running, one while stopped)" \
    || fail "apply-staged count = $STOPPED_APPLY (expected 2)"

sleep 2
SPAWN_TOTAL="$(spawn_count)"
if [ "$SPAWN_TOTAL" = "2" ]; then
    pass "④ applying while stopped spawns nothing (SPAWN count stays 2)"
else
    fail "spawn count changed while stopped (expected 2, got $SPAWN_TOTAL)"
fi
wait_pgrep_down uxplay 3 \
    && pass "④ uxplay stays down (write-back only, no receiver action)" \
    || fail "uxplay came back while stopped"

# --- 12. quit + residue -------------------------------------------------------

wait_for_count "$UI_LOG" "ACTION quit" 1 15 \
    && pass "Quit (ACTION quit, S5)" \
    || fail "Quit never invoked"

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

sleep 1
pgrep -x MiragePlay >/dev/null 2>&1 && fail "residue: MiragePlay still running" || pass "residue: no MiragePlay"
pgrep -x uxplay >/dev/null 2>&1 && fail "residue: uxplay still running" || pass "residue: no uxplay"

# --- 13. post-run ledger ------------------------------------------------------

grep -F -- 'MIRRORBOARD SPAWN pid=' "$LAUNCH_LOG" > "$RUN/spawn-lines.txt" 2>/dev/null
FINAL_SPAWNS="$(spawn_count)"
FINAL_RESTARTS="$(count_in 'ACTION settings-changed (restart)' "$UI_LOG")"
FINAL_WRITEBACKS="$(count_in 'ACTION settings-changed (write-back only)' "$UI_LOG")"
[ "$FINAL_SPAWNS" = "2" ] \
    && pass "final ledger: exactly 2 spawns (1 start + 1 exactly-once restart)" \
    || fail "final ledger: spawn count = $FINAL_SPAWNS (expected 2)"
[ "$FINAL_RESTARTS" = "1" ] \
    && pass "final ledger: exactly 1 E1 restart (one 4-field batch, exactly once)" \
    || fail "final ledger: restart count = $FINAL_RESTARTS (expected 1)"
[ "$FINAL_WRITEBACKS" = "1" ] \
    && pass "final ledger: exactly 1 write-back-only apply" \
    || fail "final ledger: write-back count = $FINAL_WRITEBACKS (expected 1)"

# settings.json — the write-back landed (⑫), including the stopped-state apply
if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$RUN/settings.json.test-run"
    grep -Fq '"deviceName" : "YC 的 Mac"' "$SETTINGS" \
        && pass "settings.json: deviceName persisted (YC 的 Mac)" \
        || fail "settings.json: deviceName not persisted"
    grep -Fq '"resolution" : "720p"' "$SETTINGS" \
        && pass "settings.json: resolution persisted (720p)" \
        || fail "settings.json: resolution not persisted"
    grep -Fq '"frameRate" : 60' "$SETTINGS" \
        && pass "settings.json: frameRate persisted (60; staged 120 never landed)" \
        || fail "settings.json: frameRate not persisted"
    grep -Fq '"muted" : false' "$SETTINGS" \
        && pass "settings.json: stopped-state write-back landed (muted=false)" \
        || fail "settings.json: stopped-state write-back missing"
else
    fail "settings.json missing — no write-back happened"
fi

# rc file — final state of the LAST spawn (the stopped-state write-back must
# NOT have rewritten it — it takes effect on the next start)
cp "$RC_FILE" "$RUN/snapshot.rc" 2>/dev/null
if [ -f "$RC_FILE" ] \
    && grep -Fq 'n "YC 的 Mac"' "$RC_FILE" \
    && grep -Fq 's 1280x720' "$RC_FILE" \
    && grep -Fq 'fps 60' "$RC_FILE" \
    && grep -Fxq 'a' "$RC_FILE"; then
    pass "rc file == last spawn's snapshot (n \"YC 的 Mac\" / s 1280x720 / fps 60 / a) — untouched by the stopped-state apply"
else
    fail "rc file does not match the last spawn's snapshot"
fi

# --- 14. evidence copy + summary ----------------------------------------------

cp "$UI_LOG" "$RUN/ui.log" 2>/dev/null
cp "$LAUNCH_LOG" "$RUN/launch.log" 2>/dev/null
cp "$TEST_APP_CONSOLE" "$RUN/app-console.log" 2>/dev/null

restore_settings

log ""
log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
log "   ui.log:     $UI_LOG"
log "   evidence:   $RUN"
if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
testkit_mark_failed
exit 1
