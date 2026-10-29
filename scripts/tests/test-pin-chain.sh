#!/bin/bash
# test-pin-chain.sh — Stage2-D (wave1d) PIN base-chain test.
#
# Covers (per the wave1d task card):
#   ① panel PIN toggle → engine: on = code generated + shown + (after start) spawn argv carries -pin <code>
#      (toggling while stopped = write-back only, zero spawn; toggling while running (P4) = an E1 restart applies it).
#   ② the regenerate button (P6/R3-Q1=A): press = a new code (≠ the old one) + display update + (while running)
#      an E1 restart + new spawn argv carrying the new code.
#   ③ PIN off: the button is greyed out (change=disabled), the code row is hidden, argv after a restart has no -pin
#      (and no -key/-reg); pressing regenerate does nothing (ignored).
#   ④ not set = a new code on every start (spawn#1≠spawn#2); once regenerated = reuse it (a restart / a start
#      other than the restart animation does not regenerate; after PIN off→on the same code is reused).
#   ⑤ the prefs PIN row shows the real value (PREFS values pin=<code>; read-only — source assertion).
#   Also: the rc file carries the pin on every spawn; settings.json is written (pinEnabled/pinCode);
#   the E1 ledger (exact counts of starts/stops/restarts/write-backs/spawns).
#
# Re-runnable. Self-contained. Never touches a RUNNING MiragePlay/uxplay
# instance (aborts — that would be YC's own instance; the test cleans up after itself, zero residue).
# User state restore: before the test, `~/Library/Application Support/com.ycchung.
# mirageplay/settings.json` (if present) is moved into this run's directory for safekeeping and put back unchanged at the end;
# if it did not exist, the one produced by the test is moved into the run directory (zero residue, zero deletion).
#
# Generation ledger: launch.log is a generation file truncated on every new user start (C segment semantics); this sequence has
# several start/stop cycles, so a resident collector copies every SPAWN marker it sees (deduplicated by pid) into
# $RUN/spawn-collected.txt — every spawn assertion is settled against it.
#
# The scripted sequence is driven by the app itself:
# MIRRORBOARD_UITEST_PIN=1 → UITestDriver.runPinChain drives the exact entry
# points the panel controls take (setPanelPinProtection = switch flip;
# pressPanelPinChange = the regenerate button; performPrimaryAction = start/stop;
# prefs open/close). Timeline: panel 1.0s / PIN on 1.6s / start#1 3.4s /
# stop 6.0s / start#2 8.2s / stop 10.8s / start#3 13.0s / regenerate 15.5s /
# panel-pin-change render 16.8s / prefs 18.5s / prefs close 19.3s /
# stop 20.2s / PIN off 21.2s / panel-pin-off render 21.9s /
# regenerate (PIN off, ignored) 22.4s / start#4 23.8s / stop 26.8s /
# PIN on (already set) 28.0s / start#5 29.5s / PIN off (while running) 32.5s / stop 34.8s /
# quit 36.3s — see UITestDriver.swift Timeline ④.
#
# Usage:  ./scripts/tests/test-pin-chain.sh
# Evidence: <testkit_evidence_dir>/testrun-<YYYYmmdd_HHMMSS>/ — inside this run's
# own temp workspace (the testkit keeps it when the run fails, drops it when green).

set -u

# Paths are derived from this script's own location: no repository-absolute
# literal, and no build product read out of the checkout.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
# Canonical spelling (2026-10-20): this root is handed to scripts/build/build-app.sh,
# whose --package-path/--build-path reach swift/clang. clang keys its module
# cache by path STRING, so a caller-typed spelling (projects vs Projects on
# this case-insensitive volume) creates a second module identity and ASTReader
# segfaults. `pwd`/`pwd -P` keep the caller's spelling; readlink -f does not.
# See scripts/lib/_canonical-path.sh.
. "$HERE/../lib/_canonical-path.sh"
PROJ="$(mp_canonical_dir "$PROJ")" || {
    echo "test-pin-chain: cannot resolve the repo root to its on-disk spelling" >&2
    exit 1
}
# Shared UxPlay tree path resolution + red-line gate (2026-10-19 decouple):
# the upstream tree is no longer git-tracked — it is materialized on demand
# by scripts/build/vendor-uxplay.sh from the fork pinned in core/vendor.lock.
# shellcheck source=scripts/lib/_uxplay-path.sh
. "$HERE/../lib/_uxplay-path.sh"
# Frozen harness foundation: this run assembles its own bundle in its own temp
# directory, and every log/evidence path below is asked of the testkit.
# shellcheck source=scripts/lib/testkit.sh
. "$HERE/../lib/testkit.sh"
testkit_init || {
    echo "test-pin-chain: testkit_init failed (no private temp workspace)" >&2
    exit 1
}
RUN="$(testkit_evidence_dir)/testrun-$(date '+%Y%m%d_%H%M%S')"
UI_LOG="$(testkit_ui_log)"
APPSUP="$HOME/Library/Application Support/com.ycchung.mirageplay"
SETTINGS="$APPSUP/settings.json"
# launch.log and snapshot.rc are Application Support artefacts the app resolves
# itself (~/Library/Application Support/<bundle-id>/) — not harness scratch.
LAUNCH_LOG="$APPSUP/launch.log"
RC_FILE="$APPSUP/snapshot.rc"
# The app's own evidence subtree (NSTemporaryDirectory()/<bundle-id>): the UI
# test driver renders its PNGs there.
SCRATCH_ROOT="${TMPDIR:-/tmp}"; SCRATCH_ROOT="${SCRATCH_ROOT%/}"
SCRATCH="$SCRATCH_ROOT/com.ycchung.mirageplay"
SP_SWIFT="$PROJ/app/Sources/AppShell/StatusPanelController.swift"
SI_SWIFT="$PROJ/app/Sources/AppShell/StatusItemMenu.swift"
CR_SWIFT="$PROJ/app/Sources/AppShell/CompositionRoot.swift"
AD_SWIFT="$PROJ/app/Sources/AppShell/AppDelegate.swift"
IH_SWIFT="$PROJ/app/Sources/AppShell/PreferencesIntentHandler.swift"
PI_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesIntent.swift"
PF_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesFormViews.swift"
PW_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesWindowController.swift"
TERMS_JSON="$PROJ/app/Resources/Strings/terms.json"
IF2_SWIFT="$PROJ/app/Sources/ConfigEngine/ConfigEngineProtocol.swift"
IF2_SHA="9de23cd19b784ed8b9000485e35b62adf14a542fd8c6812eb2c725e8056eb3a4"

PASS=0
FAIL=0
SKIP=0
APP_PID=""
COLLECT_PID=""
SETTINGS_PREEXISTED=0
APPSUP_PREEXISTED=0
RESTORED=0

mkdir -p "$RUN"

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
    # if the AppSupport dir itself did not exist before and is now empty,
    # take it back out (non-recursive rmdir — fails safely if anything is in)
    if [ "$APPSUP_PREEXISTED" = "0" ] && [ -d "$APPSUP" ]; then
        rmdir "$APPSUP" 2>/dev/null && log "[restore] empty AppSupport dir removed (created by this run)"
    fi
}

cleanup() {
    if [ -n "$COLLECT_PID" ] && kill -0 "$COLLECT_PID" 2>/dev/null; then
        kill "$COLLECT_PID" 2>/dev/null
        wait "$COLLECT_PID" 2>/dev/null
    fi
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$APP_PID" 2>/dev/null || break
            sleep 0.25
        done
        kill -0 "$APP_PID" 2>/dev/null && kill -9 "$APP_PID" 2>/dev/null
    fi
    for _ in $(seq 1 12); do
        pgrep -x uxplay >/dev/null 2>&1 || break
        sleep 0.25
    done
    if pgrep -x uxplay >/dev/null 2>&1; then
        log "WARN  cleanup: uxplay still alive after app exit"
    fi
    restore_settings
    # The script owns the EXIT trap, so the testkit's own teardown trap is
    # replaced — call it here (idempotent): leftover processes + temp workspace.
    testkit_quit 2>/dev/null || true
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

# launch.log is a generation file truncated on every new user start (C segment semantics) — across several start/stop
# cycles old-generation markers get truncated, so a resident collector copies every SPAWN marker it sees
# (deduplicated by pid) into $RUN/spawn-collected.txt as the complete generation ledger for this run.
SPAWN_EVID="$RUN/spawn-collected.txt"

spawn_collector() {
    local seen="$RUN/.spawn-seen"
    : > "$seen"
    : > "$SPAWN_EVID"
    while :; do
        if [ -f "$LAUNCH_LOG" ]; then
            while IFS= read -r line; do
                local pid
                pid="$(printf '%s' "$line" | sed -n 's/.*MIRRORBOARD SPAWN pid=\([0-9]*\).*/\1/p')"
                [ -n "$pid" ] || continue
                if ! grep -Fqx -- "$pid" "$seen" 2>/dev/null; then
                    printf '%s\n' "$pid" >> "$seen"
                    printf '%s\n' "$line" >> "$SPAWN_EVID"
                fi
            done < <(grep -F -- 'MIRRORBOARD SPAWN pid=' "$LAUNCH_LOG" 2>/dev/null)
        fi
        sleep 0.2
    done
}

spawn_count() { count_in 'MIRRORBOARD SPAWN pid=' "$SPAWN_EVID"; }

spawn_line() { # <lineno> — the Nth collected MIRRORBOARD SPAWN line
    sed -n "${1}p" "$SPAWN_EVID" 2>/dev/null
}

spawn_pin() { # <lineno> → the -pin value on the Nth SPAWN line ("" when absent)
    spawn_line "$1" | sed -n 's/.*"-pin" "\([0-9][0-9]*\)".*/\1/p'
}

last_display_code() { # last "PANEL pin display" code value ("-" when PIN off)
    grep -F -- 'PANEL pin display ' "$UI_LOG" 2>/dev/null | tail -1 \
        | sed -n 's/.*code=\([^ ]*\) .*/\1/p'
}

valid_code() { # exactly 4 digits (0001-9999 display form)
    printf '%s' "$1" | grep -Eq '^[0-9]{4}$'
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

log "== Stage2-D PIN-chain test — $(date '+%Y-%m-%d %H:%M:%S %Z') =="
log "   run dir: $RUN"

if ! testkit_preflight_clean; then
    log "ABORT: MiragePlay or uxplay is already running — refusing to touch a live instance."
    testkit_mark_failed
    exit 2
fi
pass "preflight: zero pre-existing MiragePlay/uxplay"

# --- 1. contract statics -----------------------------------------------------

if grep -Fq 'onPinProtectionToggled' "$SP_SWIFT" \
    && grep -Fq 'onPinChangeRequested' "$SP_SWIFT" \
    && grep -Fq 'refreshPinDisplay' "$SP_SWIFT" \
    && grep -Fq 'panel.pin.change' "$SP_SWIFT" \
    && grep -Fq '更換' "$TERMS_JSON" \
    && grep -Fq 'pinChangeButton.isEnabled' "$SP_SWIFT"; then
    pass "panel: PIN toggle intent + Change button + read-through (StatusPanelController; dictionary lookup)"
else
    fail "panel: PIN intent/change button/refresh missing from StatusPanelController"
fi

if grep -Fq 'pinProtectionToggled' "$IH_SWIFT" \
    && grep -Fq 'pinChangeRequested' "$IH_SWIFT" \
    && grep -Fq 'settingsChanged()' "$IH_SWIFT"; then
    pass "adapter: PIN intents → engine write + E1 signal (PreferencesIntentHandler)"
else
    fail "adapter: PIN intents missing from PreferencesIntentHandler"
fi

if grep -Fq 'pinProtectionToggled' "$PI_SWIFT" && grep -Fq 'pinChangeRequested' "$PI_SWIFT"; then
    pass "intent: SettingsUI intent surface carries both PIN intents (PreferencesIntent)"
else
    fail "intent: PIN intents missing from the SettingsUI intent protocol"
fi

if grep -Fq 'pinStateProvider' "$SI_SWIFT" && grep -Fq 'refreshPinDisplays' "$SI_SWIFT" \
    && grep -Fq 'pressPanelPinChange' "$SI_SWIFT"; then
    pass "wiring: pinStateProvider + refresh hook + change seam (StatusItemMenu)"
else
    fail "wiring: PIN wiring incomplete in StatusItemMenu"
fi

if grep -Fq 'prepareForReceiverStart' "$CR_SWIFT" && grep -Fq 'receiverStartPrepared' "$CR_SWIFT"; then
    pass "wiring: pre-spawn = prepareForReceiverStart + PIN display re-read (CompositionRoot)"
else
    fail "wiring: prepare hook missing in CompositionRoot"
fi

if grep -Fq 'MIRRORBOARD_UITEST_PIN' "$AD_SWIFT"; then
    pass "harness: MIRRORBOARD_UITEST_PIN branch present (AppDelegate)"
else
    fail "harness: MIRRORBOARD_UITEST_PIN branch missing"
fi

if grep -Fq 'pinField.isEditable = false' "$PF_SWIFT" \
    && grep -Fq 'pin=\(snapshot.pinCode' "$PW_SWIFT"; then
    pass "prefs: PIN field read-only (isEditable=false) + refresh reads the real value (pin= line)"
else
    fail "prefs: PIN field read-only or pin= evidence line missing"
fi

IF2_SHA_NOW="$(shasum -a 256 "$IF2_SWIFT" | awk '{print $1}')"
if [ "$IF2_SHA_NOW" = "$IF2_SHA" ]; then
    pass "IF-2 freeze: ConfigEngineProtocol.swift sha unchanged ($IF2_SHA)"
else
    fail "IF-2 freeze: ConfigEngineProtocol.swift sha changed ($IF2_SHA_NOW)"
fi

# Red-line self-check: the banned wording (construction by bytes so the
# literal never appears in this file — mechanical scanners must come back
# clean on the sources, not trip over the checker itself).
BANNED_WORD=$'\xe4\xb8\x8a\xe8\xaa\xb2'
if grep -rq "$BANNED_WORD" "$PROJ/app/Sources/AppShell" "$PROJ/app/Sources/SettingsUI" 2>/dev/null; then
    fail "red-line: banned wording found in AppShell/SettingsUI"
else
    pass "red-line: no banned wording in AppShell/SettingsUI"
fi

# --- red-line: uxplay tree must match the pinned commit ----------------------
# 2026-10-19 decouple: core/uxplay is no longer git-tracked. The upstream tree
# now lives in a vendored source tree outside the checkout, materialized on
# demand by scripts/build/vendor-uxplay.sh from the fork pinned in
# core/vendor.lock (its location is resolved by scripts/lib/_uxplay-path.sh). The red
# line is therefore no longer "only the renderer file may differ" but "the
# whole tree must equal the pinned commit" — any unapproved local edit
# (the renderer file included) trips it. vendor-uxplay.sh --check verifies the
# commit, the tree hash, the file count and every per-file sha256 against the
# manifest, and exits 1 on any mismatch.
if uxplay_redline_check "$RUN/uxplay-redline.log"; then
    pass "red-line: uxplay tree matches the pinned commit in core/vendor.lock (byte-identical, $(uxplay_pinned_file_count) files)"
else
    fail "red-line: uxplay tree deviates from the pinned commit in core/vendor.lock (details: $RUN/uxplay-redline.log)"
fi

# --- 2. user-state handling + log archive (never destroy evidence) -----------

[ -d "$APPSUP" ] && APPSUP_PREEXISTED=1
if [ -f "$SETTINGS" ]; then
    SETTINGS_PREEXISTED=1
    mv "$SETTINGS" "$RUN/settings.json.prev"
    log "   settings.json pre-existed — moved to run dir (will be restored)"
else
    log "   settings.json absent — fresh-state run (test-created file will be archived out)"
fi
[ -f "$UI_LOG" ] && mv "$UI_LOG" "$RUN/ui.log.prev"
[ -f "$LAUNCH_LOG" ] && mv "$LAUNCH_LOG" "$RUN/launch.log.prev"
[ -f "$RC_FILE" ] && cp "$RC_FILE" "$RUN/snapshot.rc.prev"
[ -f "$SCRATCH/panel-pin-change.png" ] && mv "$SCRATCH/panel-pin-change.png" "$RUN/panel-pin-change.prev.png"
[ -f "$SCRATCH/panel-pin-off.png" ] && mv "$SCRATCH/panel-pin-off.png" "$RUN/panel-pin-off.prev.png"

# --- 3. build ----------------------------------------------------------------

if testkit_build >"$RUN/build.log" 2>&1; then
    if grep -Eq 'warning:|error:' "$RUN/build.log"; then
        fail "build has warnings/errors — see $RUN/build.log"
        log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
        testkit_mark_failed
        exit 1
    fi
    pass "build ok (scripts/build/build-app.sh, 0 warnings/0 errors)"
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

# --- 4. launch (+ SPAWN marker collector) ------------------------------------

spawn_collector &
COLLECT_PID=$!

# The bundle's console is the testkit's $TEST_APP_CONSOLE; point it at this run's
# evidence file so the failure messages below stay truthful.
TEST_APP_CONSOLE="$RUN/app.stdout.log"
export TEST_APP_CONSOLE
MIRRORBOARD_UITEST_PIN=1 testkit_launch
APP_PID="${TEST_APP_PID:-}"
sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "launch ok (pid $APP_PID)"
else
    fail "launch failed — see $RUN/app.stdout.log"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    exit 1
fi

# --- 5. ① PIN on while NOT running: code generated + displayed, zero spawn ----

wait_for_count "$UI_LOG" "PANEL shown" 1 10 \
    && pass "panel opens (PANEL shown)" \
    || fail "panel never shown"

wait_for_count "$UI_LOG" "PIN toggled on (panel 300x212)" 1 8 \
    && pass "PIN on → code row appears, panel 300x212 (toggle event; wave1r3 About row retired)" \
    || fail "PIN on never applied"

wait_for_count "$UI_LOG" "PANEL pin display on code=" 1 5 \
    && pass "PIN on → code generated and displayed (PANEL pin display on)" \
    || fail "no PIN display line after toggle on"

# Zero-receiver-action check ran immediately after the write-back signal (in time
# it was still before start#1) — the strict spawn-by-now count is lag-tolerant here
# because nothing can spawn before the first start.
if [ "$(spawn_count)" = "0" ]; then
    pass "PIN on while stopped → zero spawns at this point (no receiver action)"
else
    fail "unexpected spawn after PIN toggle while stopped (count $(spawn_count))"
fi

C1="$(last_display_code)"
if valid_code "$C1"; then
    pass "display code is a 4-digit zero-padded form ($C1)"
else
    fail "display code not a 4-digit form — got: $C1"
fi
if grep -Fq "PANEL pin display on code=$C1 change=enabled" "$UI_LOG"; then
    pass "change button state follows the engine (change=enabled while PIN on)"
else
    fail "change button state line missing/incorrect for PIN on"
fi

wait_for_count "$UI_LOG" "ACTION settings-changed (write-back only)" 1 8 \
    && pass "PIN on while stopped → pure write-back（ACTION settings-changed (write-back only)）" \
    || fail "PIN on while stopped never signalled"

# --- 6. ①④ start #1 (not set = new code): spawn argv carries -pin <code> = the shown code ---

wait_for_count "$UI_LOG" "ACTION start" 1 10 \
    && pass "Start #1 (ACTION start)" \
    || fail "Start #1 never invoked"

waited=0
while [ "$waited" -lt 40 ] && [ -z "$(pgrep -x uxplay 2>/dev/null)" ]; do
    sleep 0.25
    waited=$((waited + 1))
done
PID1="$(pgrep -x uxplay 2>/dev/null | head -1)"
[ -n "$PID1" ] \
    && pass "start #1 → uxplay running (pid $PID1)" \
    || fail "uxplay did not start after Start #1"

wait_for_count "$SPAWN_EVID" 'MIRRORBOARD SPAWN pid=' 1 8 \
    && pass "spawn #1 marker written" \
    || fail "no SPAWN marker for start #1"

C2="$(spawn_pin 1)"
if valid_code "$C2"; then
    pass "spawn #1 argv carries -pin <4-digit code> ($C2)"
else
    fail "spawn #1 argv missing -pin 4-digit code — got: $C2 (line: $(spawn_line 1))"
fi
if [ -n "$C2" ] && [ "$C2" != "$C1" ]; then
    pass "unset: Start #1 regenerates the code (at toggle $C1 → after start ${C2})"
else
    fail "unset: start #1 code did not differ from toggle-time code ($C1 → $C2)"
fi
wait_for_count "$UI_LOG" "PANEL pin display on code=$C2" 1 5 \
    && pass "displayed code == actual spawn code (spawn sync: display=${C2})" \
    || fail "display did not follow the spawned code $C2 (last display: $(last_display_code))"

if line_has "$(spawn_line 1)" "MIRRORBOARD SPAWN pid=$PID1 "; then
    pass "spawn #1 marker pid == live uxplay pid ($PID1)"
else
    fail "spawn #1 marker pid != live uxplay pid ($PID1)"
fi
ARGS1="$(ps_args_stable "$PID1")"
printf '%s\n' "$ARGS1" > "$RUN/ps-args-1.txt"
line_has "$ARGS1" "-pin $C2" \
    && pass "host-side argv (ps) carries -pin $C2" \
    || fail "host-side argv missing -pin $C2 — got: $ARGS1"

if [ -s "$RC_FILE" ] && grep -Fq "pin $C2" "$RC_FILE"; then
    pass "rc file carries the same code (pin $C2)"
else
    fail "rc file missing 'pin $C2'"
fi

# --- 7. ④ stop #1 → start #2 (not set = new code every time) -----------------

wait_for_count "$UI_LOG" "ACTION stop" 1 10 \
    && pass "Stop #1 (ACTION stop)" \
    || fail "Stop #1 never invoked"
wait_pgrep_down uxplay 5 \
    && pass "stop #1 → uxplay gone" \
    || fail "uxplay still running after Stop #1"

wait_for_count "$UI_LOG" "ACTION start" 2 10 \
    && pass "Start #2 (ACTION start ×2)" \
    || fail "Start #2 never invoked"
PID2="$(wait_pid_change "$PID1" 10)" \
    && pass "start #2: uxplay (re)started (pid $PID1 → $PID2)" \
    || fail "start #2: no new uxplay pid"
wait_for_count "$SPAWN_EVID" 'MIRRORBOARD SPAWN pid=' 2 8 \
    && pass "spawn #2 marker written" \
    || fail "no spawn #2 marker"
C3="$(spawn_pin 2)"
if valid_code "$C3" && [ "$C3" != "$C2" ]; then
    pass "unset: Start #2 generates a fresh code ($C2 → ${C3}; every Start generates a new code)"
else
    fail "unset: start #2 code not fresh — got: $C3 (prev $C2)"
fi
wait_for_count "$UI_LOG" "PANEL pin display on code=$C3" 1 5 \
    && pass "display follows start #2 code ($C3)" \
    || fail "display did not follow start #2 code $C3"

wait_for_count "$UI_LOG" "ACTION stop" 2 10 \
    && pass "Stop #2 (ACTION stop ×2)" \
    || fail "Stop #2 never invoked"
wait_pgrep_down uxplay 5 \
    && pass "stop #2 → uxplay gone" \
    || fail "uxplay still running after Stop #2"

# --- 8. ② start #3 (not set) → regenerate: new code + display + E1 restart + argv update ---

wait_for_count "$UI_LOG" "ACTION start" 3 10 \
    && pass "Start #3 (ACTION start ×3)" \
    || fail "Start #3 never invoked"
PID3="$(wait_pid_change "$PID2" 10)" \
    && pass "start #3: uxplay running (pid $PID3)" \
    || fail "start #3: no new uxplay pid"
wait_for_count "$SPAWN_EVID" 'MIRRORBOARD SPAWN pid=' 3 8 \
    && pass "spawn #3 marker written" \
    || fail "no spawn #3 marker"
C4="$(spawn_pin 3)"
valid_code "$C4" \
    && pass "spawn #3 argv carries -pin $C4" \
    || fail "spawn #3 missing -pin — got: $C4"

wait_for_count "$UI_LOG" "ACTION pin-change" 1 8 \
    && pass "Change clicked (ACTION pin-change)" \
    || fail "Change never invoked"

C5=""
waited=0
while [ "$waited" -lt 40 ]; do
    C5="$(last_display_code)"
    [ -n "$C5" ] && [ "$C5" != "-" ] && [ "$C5" != "$C4" ] && break
    sleep 0.25
    waited=$((waited + 1))
done
if valid_code "$C5" && [ "$C5" != "$C4" ]; then
    pass "Change → new code ≠ old ($C4 → ${C5}) + display updated"
else
    fail "Change did not produce a new displayed code (prev $C4, now $C5)"
fi

wait_for_count "$UI_LOG" "ACTION settings-changed (restart)" 1 8 \
    && pass "Change while running → E1 restart (ACTION settings-changed (restart))" \
    || fail "Change did not signal E1 restart"
PID4="$(wait_pid_change "$PID3" 10)" \
    && pass "restart: uxplay PID changed ($PID3 → $PID4 — terminate+respawn)" \
    || fail "restart: uxplay PID never changed"
wait_for_count "$SPAWN_EVID" 'MIRRORBOARD SPAWN pid=' 4 8 \
    && pass "spawn #4 marker written" \
    || fail "no spawn #4 marker"
C4B="$(spawn_pin 4)"
if [ -n "$C4B" ] && [ "$C4B" = "$C5" ]; then
    pass "spawn #4 argv carries the NEW code (-pin ${C5} == displayed code; argv updated)"
else
    fail "spawn #4 argv does not carry the new code — got: $C4B (expected $C5)"
fi
# The prepare-time refresh runs before process.run() (same thread), so by the
# time the marker exists the display line for the spawn must exist — assert ≥2
# C5 lines (regenerate refresh + the refresh before spawn).
if [ "$(count_in "PANEL pin display on code=$C5" "$UI_LOG")" -ge 2 ]; then
    pass "displayed code re-read before spawn (display lines ≥2: change + pre-spawn; ${C5})"
else
    fail "display did not refresh to the spawned code $C5 at restart (count $(count_in "PANEL pin display on code=$C5" "$UI_LOG"))"
fi
if [ -n "$PID4" ]; then
    ARGS4="$(ps_args_stable "$PID4")"
    printf '%s\n' "$ARGS4" > "$RUN/ps-args-4.txt"
    line_has "$ARGS4" "-pin $C5" \
        && pass "host-side argv (ps) after restart carries -pin $C5" \
        || fail "host-side argv after restart missing -pin $C5 — got: $ARGS4"
fi

# --- 9. ⑤ preferences window shows the true code (read-only field) ------------

wait_for_count "$UI_LOG" "PREFS shown" 1 12 \
    && pass "prefs window opens" \
    || fail "preferences window never shown"
wait_for_count "$UI_LOG" "pin=$C5" 1 8 \
    && pass "prefs window PIN field == real value (PREFS values … pin=${C5})" \
    || fail "preferences PIN value missing — expected pin=$C5"
grep -Fq "PREFS values res=1080p fps=30 mute=off name=MiragePlay pin=$C5" "$UI_LOG" \
    && pass "prefs real-value line complete (untouched fields keep their defaults; pin = current code)" \
    || fail "preferences values line does not match the expected truth"

wait_for_count "$UI_LOG" "PREFS closed" 1 8 \
    && pass "prefs window close (red-button path)" \
    || fail "preferences window never closed"

wait_for_count "$UI_LOG" "ACTION stop" 3 10 \
    && pass "Stop #3 (ACTION stop ×3)" \
    || fail "Stop #3 never invoked"
wait_pgrep_down uxplay 5 \
    && pass "stop #3 → uxplay gone" \
    || fail "uxplay still running after Stop #3"

# --- 10. ③ PIN off while stopped: write-back, greyed button, ignored regenerate ---

wait_for_count "$UI_LOG" "PIN toggled off (panel 300x192)" 1 8 \
    && pass "PIN off → code row hides, panel 300x192 (wave1r3 About row retired)" \
    || fail "PIN off never applied"

wait_for_count "$UI_LOG" "PANEL pin display off code=- change=disabled" 1 5 \
    && pass "PIN off → button greyed (change=disabled) + code area empty (code=-)" \
    || fail "PIN-off display state line missing"

wait_for_count "$UI_LOG" "ACTION settings-changed (write-back only)" 2 8 \
    && pass "PIN off while stopped → pure write-back（×2）" \
    || fail "PIN off while stopped never signalled"

wait_for_count "$UI_LOG" "ACTION pin-change ignored (PIN off)" 1 8 \
    && pass "Change pressed while PIN off → ignored (greyed button does nothing)" \
    || fail "ignored pin-change line missing"

# Lag-proof: from the ignored press up to the next start there must be no
# settings-changed line at all (any restart / write-back would leave an ACTION line in this span).
awk '/ACTION pin-change ignored \(PIN off\)/{f=1;next} f&&/ACTION start/{exit} f{print}' "$UI_LOG" \
    > "$RUN/segment-ignored.txt"
if [ "$(count_in 'settings-changed' "$RUN/segment-ignored.txt")" = "0" ]; then
    pass "ignored change → zero receiver/settings action (no settings-changed in the segment)"
else
    fail "ignored change produced a settings action — see $RUN/segment-ignored.txt"
fi

# --- 11. ③ start #4 (PIN off): argv has no -pin (and no -key/-reg) ------------

wait_for_count "$UI_LOG" "ACTION start" 4 10 \
    && pass "Start #4 (ACTION start ×4; PIN off)" \
    || fail "Start #4 never invoked"
PID5="$(wait_pid_change "$PID4" 10)" \
    && pass "start #4: uxplay running (pid $PID5)" \
    || fail "start #4: no new uxplay pid"
wait_for_count "$SPAWN_EVID" 'MIRRORBOARD SPAWN pid=' 5 8 \
    && pass "spawn #5 marker written" \
    || fail "no spawn #5 marker"
S5_LINE="$(spawn_line 5)"
if ! line_has "$S5_LINE" '"-pin"'; then
    pass "spawn #5 argv has NO -pin（PIN off）"
else
    fail "spawn #5 argv still carries -pin — got: $S5_LINE"
fi
if ! line_has "$S5_LINE" '"-key"' && ! line_has "$S5_LINE" '"-reg"'; then
    pass "spawn #5 argv has NO -key/-reg (PIN off = zero identity-file artifacts)"
else
    fail "spawn #5 argv carries identity paths while PIN off — got: $S5_LINE"
fi
if [ -n "$PID5" ]; then
    ARGS5="$(ps_args_stable "$PID5")"
    printf '%s\n' "$ARGS5" > "$RUN/ps-args-5.txt"
    if ! line_has "$ARGS5" "-pin "; then
        pass "host-side argv (ps) has NO -pin"
    else
        fail "host-side argv still carries -pin — got: $ARGS5"
    fi
fi

wait_for_count "$UI_LOG" "ACTION stop" 4 10 \
    && pass "Stop #4 (ACTION stop ×4)" \
    || fail "Stop #4 never invoked"
wait_pgrep_down uxplay 5 \
    && pass "stop #4 → uxplay gone" \
    || fail "uxplay still running after Stop #4"

# --- 12. ④ PIN on again (already set): the same code is reused; start #5 does not regenerate ---

C5_LINES_BEFORE_TOGGLE="$(count_in "PANEL pin display on code=$C5" "$UI_LOG")"
wait_for_count "$UI_LOG" "PIN toggled on (panel 300x212)" 2 8 \
    && pass "PIN on again (user-set mode) → code row reappears" \
    || fail "second PIN-on never applied"
wait_for_count "$UI_LOG" "PANEL pin display on code=$C5" $((C5_LINES_BEFORE_TOGGLE + 1)) 12 \
    && pass "user-set: display reuses the same code ($C5 — no auto-regeneration)" \
    || fail "display did not reuse the change-generated code $C5 (last: $(last_display_code))"
wait_for_count "$UI_LOG" "ACTION settings-changed (write-back only)" 3 8 \
    && pass "PIN on again while stopped → pure write-back（×3）" \
    || fail "second PIN-on write-back never signalled"

wait_for_count "$UI_LOG" "ACTION start" 5 10 \
    && pass "Start #5 (ACTION start ×5)" \
    || fail "Start #5 never invoked"
PID6="$(wait_pid_change "$PID5" 10)" \
    && pass "start #5: uxplay running (pid $PID6)" \
    || fail "start #5: no new uxplay pid"
wait_for_count "$SPAWN_EVID" 'MIRRORBOARD SPAWN pid=' 6 8 \
    && pass "spawn #6 marker written" \
    || fail "no spawn #6 marker"
C6="$(spawn_pin 6)"
if [ -n "$C6" ] && [ "$C6" = "$C5" ]; then
    pass "user-set: spawn #6 argv reuses -pin ${C5} (no regeneration across starts)"
else
    fail "spawn #6 argv did not reuse the set code — got: $C6 (expected $C5)"
fi
if [ "$(last_display_code)" = "$C5" ]; then
    pass "display stays on the set code across the start（${C5}）"
else
    fail "display drifted from the set code after start #5 (last: $(last_display_code))"
fi

# --- 13. P4 flip while running: PIN off while running → E1 restart, argv has no -pin ---

OFF_LINES_BEFORE_FLIP="$(count_in "PANEL pin display off code=- change=disabled" "$UI_LOG")"
wait_for_count "$UI_LOG" "ACTION settings-changed (restart)" 2 10 \
    && pass "PIN off while running → E1 restart (takes effect immediately)" \
    || fail "running-state PIN off never signalled"
PID7="$(wait_pid_change "$PID6" 10)" \
    && pass "restart: uxplay PID changed ($PID6 → $PID7)" \
    || fail "restart: uxplay PID never changed"
wait_for_count "$SPAWN_EVID" 'MIRRORBOARD SPAWN pid=' 7 8 \
    && pass "spawn #7 marker written" \
    || fail "no spawn #7 marker"
S7_LINE="$(spawn_line 7)"
if ! line_has "$S7_LINE" '"-pin"'; then
    pass "spawn #7 argv has NO -pin (toggle takes effect immediately)"
else
    fail "spawn #7 argv still carries -pin — got: $S7_LINE"
fi
wait_for_count "$UI_LOG" "PANEL pin display off code=- change=disabled" $((OFF_LINES_BEFORE_FLIP + 1)) 12 \
    && pass "PIN off display state restored after the running flip" \
    || fail "PIN-off display state missing after running flip"
if [ "$(last_display_code)" = "-" ]; then
    pass "display currently reads off (code=-; code area empty)"
else
    fail "display did not settle to the off state (last: $(last_display_code))"
fi

wait_for_count "$UI_LOG" "ACTION stop" 5 10 \
    && pass "Stop #5 (ACTION stop ×5)" \
    || fail "Stop #5 never invoked"
wait_pgrep_down uxplay 5 \
    && pass "stop #5 → uxplay gone" \
    || fail "uxplay still running after Stop #5"

# --- 14. quit + residue -------------------------------------------------------

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

# --- 15. post-run ledger ------------------------------------------------------

grep -F -- 'MIRRORBOARD SPAWN pid=' "$LAUNCH_LOG" > "$RUN/spawn-lines.final-generation.txt" 2>/dev/null
cp "$SPAWN_EVID" "$RUN/spawn-lines.txt" 2>/dev/null   # generation ledger for the whole run (collector; every assertion is settled here)
FINAL_SPAWNS="$(spawn_count)"
FINAL_STARTS="$(count_in 'ACTION start' "$UI_LOG")"
FINAL_STOPS="$(count_in 'ACTION stop' "$UI_LOG")"
FINAL_RESTARTS="$(count_in 'ACTION settings-changed (restart)' "$UI_LOG")"
FINAL_WRITEBACKS="$(count_in 'ACTION settings-changed (write-back only)' "$UI_LOG")"
FINAL_PINCHANGE_LINES="$(count_in 'ACTION pin-change' "$UI_LOG")"
FINAL_PINCHANGE_IGNORED="$(count_in 'ACTION pin-change ignored (PIN off)' "$UI_LOG")"
FINAL_PINCHANGES=$((FINAL_PINCHANGE_LINES - FINAL_PINCHANGE_IGNORED))
[ "$FINAL_SPAWNS" = "7" ] \
    && pass "final ledger: exactly 7 spawns (5 starts + 2 E1 restarts)" \
    || fail "final ledger: spawn count = $FINAL_SPAWNS (expected 7)"
[ "$FINAL_STARTS" = "5" ] && [ "$FINAL_STOPS" = "5" ] \
    && pass "final ledger: 5 starts / 5 stops" \
    || fail "final ledger: starts=$FINAL_STARTS stops=$FINAL_STOPS (expected 5/5)"
[ "$FINAL_RESTARTS" = "2" ] \
    && pass "final ledger: exactly 2 E1 restarts (change ×1, runtime PIN off ×1)" \
    || fail "final ledger: restart count = $FINAL_RESTARTS (expected 2)"
[ "$FINAL_WRITEBACKS" = "3" ] \
    && pass "final ledger: exactly 3 write-back-only changes" \
    || fail "final ledger: write-back count = $FINAL_WRITEBACKS (expected 3)"
[ "$FINAL_PINCHANGES" = "1" ] \
    && pass "final ledger: exactly 1 effective change (+1 ignored)" \
    || fail "final ledger: pin-change count = $FINAL_PINCHANGES (expected 1)"

# settings.json — the write-back landed (⑫): PIN off, the regenerated code persisted
if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$RUN/settings.json.test-run"
    grep -Fq '"pinEnabled" : false' "$SETTINGS" \
        && pass "settings.json: pinEnabled=false persisted (final PIN off)" \
        || fail "settings.json: pinEnabled not persisted"
    grep -Fq "\"pinCode\" : \"$C5\"" "$SETTINGS" \
        && pass "settings.json: pinCode=$C5 persisted (changed = user-set; carried back on restart)" \
        || fail "settings.json: pinCode not persisted as expected (want $C5)"
else
    fail "settings.json missing — no write-back happened"
fi

# rc file — final state of the LAST spawn (#7: PIN off → no pin/key/reg lines)
cp "$RC_FILE" "$RUN/snapshot.rc" 2>/dev/null
if [ -f "$RC_FILE" ] \
    && ! grep -Fq 'pin ' "$RC_FILE" \
    && ! grep -Fq 'key ' "$RC_FILE" \
    && ! grep -Fq 'reg ' "$RC_FILE"; then
    pass "rc file == last spawn's snapshot (PIN off → no pin/key/reg lines)"
else
    fail "rc file does not match the last spawn's snapshot (unexpected pin/key/reg)"
fi

# --- 16. evidence copy + summary ----------------------------------------------

cp "$UI_LOG" "$RUN/ui.log" 2>/dev/null
cp "$LAUNCH_LOG" "$RUN/launch.log" 2>/dev/null
cp "$SCRATCH/panel-pin-change.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/panel-pin-off.png" "$RUN/" 2>/dev/null

restore_settings

log ""
log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
log "   ui.log:     $UI_LOG"
log "   evidence:   $RUN"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
