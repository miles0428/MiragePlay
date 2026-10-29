#!/bin/bash
# test-sleep-notify.sh — Stage2-E (wave1e) SleepGuard + SessionNotifier test.
#
# Covers (per the wave1e task card + the wave1r1 staged alignment):
#   ① sleep prevention on/off → IOKit assertion held/released (proved with `pmset -g assertions`):
#      receiver start (sleep prevention defaults to on) = assertion held; toggling = STAGED (zero action),
#      apply = released / re-held immediately (zero restart); stop = must already be released (receiver-off
#      red line); staged off while stopped + apply, then start = zero assertions while running (prevent
#      gating).
#   ② notifier event flow (injection): connect / disconnect events are dispatched by SessionNotifier to
#      subscribers (NOTIFY trace; a real connection is still a YC on-device item). D8: the connect-notification switch was
#      withdrawn from the settings page, so the retained B2 slot GATES NOTHING —
#      while the slot is false the very next event must STILL write its NOTIFY
#      trace (recording is unconditional; the status row is unaffected too — status ≠ notification).
#   ③ persistence round trip: settings.json preventSleep false→true→false,
#      notificationsEnabled false→true (field retained, value still written); reopening prefs =
#      reading real PREFS values back (the line carries sleep=/notify=; the second line differs from the first).
#   ④ E1 exception (does not touch the receiver): neither toggle emits settings-changed, the uxplay PID
#      never changes, and total spawns = 2 (two starts only).
#
# Also: readable assertion names (pmset named column); SRP-5 static check (both units have zero UI dependency /
# do not import each other); the IF-2 sha is unchanged; red lines (banned word / the uxplay tree matches the pinned commit).
#
# Re-runnable. Self-contained. Never touches a RUNNING MiragePlay/uxplay
# instance (aborts — that would be YC's own instance; the test cleans up after itself, zero residue).
# User state restore: before the test, `~/Library/Application Support/com.ycchung.
# mirageplay/settings.json` (if present) is moved into this run's directory for safekeeping and put back unchanged at the end;
# if it did not exist, the one produced by the test is moved into the run directory (zero residue, zero deletion).
#
# The scripted sequence is driven by the app itself:
# MIRRORBOARD_UITEST_SLEEPNOTIFY=1 → UITestDriver.runSleepNotify drives the
# exact entry points the real controls take (performPrimaryAction = start/stop;
# togglePreferencesPreventSleep = the sleep-prevention toggle's staged path; applyPreferencesChanges
# = apply; togglePreferencesNotifications = the connect-notification toggle's staged path;
# injectReceiverEvent = real events injected through the same path). Timeline: panel 1.0s /
# start#1 1.6s / prefs 4.2s / page2 4.5s / sleep-prevention off staged 5.2s + apply 5.6s /
# sleep-prevention on staged 7.0s + apply 7.4s / conn#1 8.8s / render 9.6s / disc#1 10.4s /
# notifications off staged 12.2s + apply 12.6s / conn#2 13.2s / render 14.0s / notifications on staged
# 15.0s + apply 15.4s / disc#2 15.8s / conn#3 16.7s / prefs close 17.4s /
# stop#1 18.2s / sleep-prevention off (stopped) staged 19.6s + apply 20.2s / prefs reopen
# 21.2s / prefs close 21.9s / start#2 23.2s / stop#2 25.2s / quit 26.8s — see
# UITestDriver.swift Timeline ⑤.
#
# Usage:  ./scripts/tests/test-sleep-notify.sh
# Evidence: <testkit evidence dir>/testrun-sleep-<YYYYmmdd_HHMMSS>/ — the testkit
# keeps that temp directory only when the run fails.

set -u

# Every helper path is derived from this script's own location, so the suite
# runs from any cwd and never spells the repository layout itself.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Shared testkit (frozen interface, scripts/lib/testkit.sh): per-run temp
# workspace, a bundle built into that temp dir, the per-run UI log, the
# per-run evidence dir, and the app's whole lifecycle.
# shellcheck source=scripts/lib/testkit.sh
. "$SCRIPT_DIR/../lib/testkit.sh"

# Repo root as the testkit resolved it — canonical on-disk spelling. This root
# reaches swift/clang, whose module cache is keyed by path STRING, so a
# caller-typed spelling (projects vs Projects on this case-insensitive volume)
# would create a second module identity and segfault ASTReader. The testkit
# already ran mp_canonical_dir; see scripts/lib/_canonical-path.sh.
PROJ="$TESTKIT_REPO_ROOT"

testkit_init || {
    echo "test-sleep-notify: cannot create the per-run temp workspace" >&2
    exit 1
}
RUN="$(testkit_evidence_dir)/testrun-sleep-$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$RUN" || exit 1

# Assertions read the testkit's per-run UI log (one file per run, so a line left
# behind by an earlier run can never satisfy this run's assertion). The app's
# PNG/scratch artefacts stay in the fixed per-bundle temp subtree the app owns.
UI_LOG="$(testkit_ui_log)"
SCRATCH_ROOT="${TMPDIR:-/tmp}"; SCRATCH_ROOT="${SCRATCH_ROOT%/}"
SCRATCH="$SCRATCH_ROOT/com.ycchung.mirageplay"
SG_SWIFT="$PROJ/app/Sources/SleepGuard/SleepGuard.swift"
SN_SWIFT="$PROJ/app/Sources/SessionNotifier/SessionNotifier.swift"
TPL_SWIFT="$PROJ/app/Sources/SessionNotifier/Templates.swift"
LC_SWIFT="$PROJ/app/Sources/AppShell/LifecycleCoordinator.swift"
IH_SWIFT="$PROJ/app/Sources/AppShell/PreferencesIntentHandler.swift"
PI_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesIntent.swift"
PW_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesWindowController.swift"
PF_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesFormViews.swift"
SI_SWIFT="$PROJ/app/Sources/AppShell/StatusItemMenu.swift"
CR_SWIFT="$PROJ/app/Sources/AppShell/CompositionRoot.swift"
AD_SWIFT="$PROJ/app/Sources/AppShell/AppDelegate.swift"
UTD_SWIFT="$PROJ/app/Sources/AppShell/UITestDriver.swift"
TERMS_JSON="$PROJ/app/Resources/Strings/terms.json"
IF2_SWIFT="$PROJ/app/Sources/ConfigEngine/ConfigEngineProtocol.swift"
IF2_SHA="9de23cd19b784ed8b9000485e35b62adf14a542fd8c6812eb2c725e8056eb3a4"
APPSUP="$HOME/Library/Application Support/com.ycchung.mirageplay"
SETTINGS="$APPSUP/settings.json"
# launch.log is the receiver's spawn channel (the three frozen match strings and
# the MIRRORBOARD SPAWN argv ledger live there). The app keeps it in Application
# Support so it survives a relaunch, which is also where the ledger tails it.
LAUNCH_LOG="$APPSUP/launch.log"

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
# A failed assertion marks the run failed so the testkit keeps the temp
# workspace (bundle, per-run ui.log, evidence) for diagnosis.
fail() { FAIL=$((FAIL + 1)); testkit_mark_failed; log "FAIL  $1"; }

# --- user-state restore (exact; runs from cleanup and from the normal tail) --

restore_settings() {
    [ "$RESTORED" = "1" ] && return
    RESTORED=1
    if [ "$SETTINGS_PREEXISTED" = "1" ] && [ -f "$RUN/settings.json.prev" ]; then
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

cleanup() {
    if [ -n "$COLLECT_PID" ] && kill -0 "$COLLECT_PID" 2>/dev/null; then
        kill "$COLLECT_PID" 2>/dev/null
        wait "$COLLECT_PID" 2>/dev/null
    fi
    # The testkit owns the app's lifecycle (SIGINT → SIGTERM → SIGKILL, then it
    # clears TEST_APP_PID) instead of a bare kill here.
    testkit_quit >/dev/null 2>&1 || true
    for _ in $(seq 1 12); do
        pgrep -x uxplay >/dev/null 2>&1 || break
        sleep 0.25
    done
    if pgrep -x uxplay >/dev/null 2>&1; then
        log "WARN  cleanup: uxplay still alive after app exit"
    fi
    restore_settings
    # This trap replaces the one testkit_init installed, so it must finish the
    # teardown itself: kill leftovers, then drop or keep the temp directory.
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

wait_for_file_content() { # <file> <fixed-pattern> <timeout_sec>
    local file="$1" pattern="$2" timeout_s="${3:-8}" waited=0
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        [ -f "$file" ] && grep -Fq -- "$pattern" "$file" && return 0
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

# pmset: the app's own power-assertion line (pid-scoped + type-scoped).
assertion_line_of_app() {
    /usr/bin/pmset -g assertions 2>/dev/null | grep -F "pid $APP_PID(" | grep -F 'PreventUserIdleDisplaySleep'
}

wait_for_assertion_present() { # <timeout_sec>
    local t="${1:-6}" w=0
    while [ "$w" -lt $((t * 4)) ]; do
        [ -n "$(assertion_line_of_app)" ] && return 0
        sleep 0.25; w=$((w + 1))
    done
    return 1
}

wait_for_assertion_absent() { # <timeout_sec>
    local t="${1:-6}" w=0
    while [ "$w" -lt $((t * 4)) ]; do
        [ -z "$(assertion_line_of_app)" ] && return 0
        sleep 0.25; w=$((w + 1))
    done
    return 1
}

dump_pmset() { # <tag>
    /usr/bin/pmset -g assertions > "$RUN/pmset-$1.txt" 2>&1
}

# launch.log is a generation file truncated on every new user start (C segment semantics) — a collector copies every
# SPAWN marker it sees (deduplicated by pid) into $RUN/spawn-collected.txt as the ledger.
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

# --- 0. preflight: never touch a live instance ------------------------------

log "== Stage2-E SleepGuard+SessionNotifier test — $(date '+%Y-%m-%d %H:%M:%S %Z') =="
log "   run dir: $RUN"

if ! testkit_preflight_clean; then
    log "ABORT: MiragePlay or uxplay is already running — refusing to touch a live instance."
    exit 2
fi
pass "preflight: zero pre-existing MiragePlay/uxplay"

# --- 1. contract statics -----------------------------------------------------

if grep -Fq 'IOPMAssertionCreateWithName' "$SG_SWIFT" \
    && grep -Fq 'IOPMAssertionRelease' "$SG_SWIFT" \
    && grep -Fq 'PreventUserIdleDisplaySleep' "$SG_SWIFT" \
    && grep -Fq 'func enable()' "$SG_SWIFT" \
    && grep -Fq 'func disable()' "$SG_SWIFT" \
    && grep -Fq 'deinit' "$SG_SWIFT"; then
    pass "SleepGuard: IOKit assertion implemented (enable/disable + internal hold + deinit fallback)"
else
    fail "SleepGuard: IOKit assertion implementation incomplete"
fi

if ! grep -Eq 'import (AppKit|ConfigEngine|SessionNotifier|SettingsUI|AppShell)' "$SG_SWIFT" \
    && ! grep -Fq 'NSWindow' "$SG_SWIFT"; then
    pass "SRP-5: SleepGuard zero dependencies (no mutual import / no window / no config)"
else
    fail "SRP-5: SleepGuard gained out-of-scope dependencies"
fi

# Reality after wave1r11 Q3 (bbf1909): unsubscribe is retired (the persistent carrier has no public
# teardown seam) → assert its absence; notifyConnected / notifyDisconnected dropped to internal
# (declared without the public prefix, still asserted present via 'func notify…').
if grep -Fq 'func subscribe' "$SN_SWIFT" \
    && ! grep -Fq 'func unsubscribe' "$SN_SWIFT" \
    && grep -Fq 'func handle(_ event: ReceiverEvent)' "$SN_SWIFT" \
    && ! grep -Fq 'notificationsEnabledProvider' "$SN_SWIFT" \
    && ! grep -Fq 'notificationsEnabled' "$SN_SWIFT" \
    && ! grep -Fq '訂閱靜默' "$SN_SWIFT" \
    && grep -Fq 'func notifyConnected' "$SN_SWIFT" \
    && grep -Fq 'func notifyDisconnected' "$SN_SWIFT"; then
    pass "SessionNotifier: event container (subscribe/dispatch + event entry); D8 — no gate, notificationsEnabled never referenced (logging is unconditional)"
else
    fail "SessionNotifier: container surface incomplete"
fi

if ! grep -Eq 'import (AppKit|SleepGuard|ConfigEngine|SettingsUI|AppShell)' "$SN_SWIFT" \
    && ! grep -Fq 'NSWindow' "$SN_SWIFT"; then
    pass "SRP-5: SessionNotifier depends on ReceiverKit only (no mutual import / no window / no config)"
else
    fail "SRP-5: SessionNotifier gained out-of-scope dependencies"
fi

# G segment (wave1g) alignment update: the template texts are dictionary lookups now
# (source = keys; values in app/Resources/Strings/terms.json).
if grep -Fq 'notify.connected' "$TPL_SWIFT" && grep -Fq 'notify.disconnected' "$TPL_SWIFT" \
    && grep -Fq '已連線：%@' "$TERMS_JSON" && grep -Fq '已斷線' "$TERMS_JSON"; then
    pass "Templates: fallback copy = dictionary lookup (notify.connected / notify.disconnected; values in terms.json)"
else
    fail "Templates: dictionary lookup missing"
fi

if grep -Fq 'applySleepGuard' "$LC_SWIFT" \
    && grep -Fq 'preventSleepChanged' "$LC_SWIFT" \
    && grep -Fq 'notificationsChanged' "$LC_SWIFT" \
    && grep -Fq 'sessionNotifier?.handle' "$LC_SWIFT" \
    && grep -Fq 'injectReceiverEvent' "$LC_SWIFT"; then
    pass "coordinator: ⑩ applySleepGuard drive + ⑪ notifier feed + prevent-sleep/B2 hooks + inject seam"
else
    fail "coordinator: section-E hooks missing"
fi

if grep -Fq 'preferencesApplyRequested' "$IH_SWIFT" \
    && grep -Fq 'preventSleepChanged()' "$IH_SWIFT" \
    && grep -Fq 'notificationsChanged()' "$IH_SWIFT"; then
    pass "adapter: staged apply classification (shell-held goes through its own hook; PreferencesIntentHandler)"
else
    fail "adapter: shell-held hooks missing from PreferencesIntentHandler"
fi

# E1 exception (static): the apply block gates settingsChanged on the receiverRelated flag —
# shell-held-only batches do not touch settingsChanged (zero restart).
APPLY_BODY="$(awk '/func preferencesApplyRequested/,/^    }$/' "$IH_SWIFT")"
if printf '%s\n' "$APPLY_BODY" | grep -Fq 'if receiverRelated {' \
    && printf '%s\n' "$APPLY_BODY" | grep -Fq 'if sleepChanged {' \
    && printf '%s\n' "$APPLY_BODY" | grep -Fq 'if notificationsChanged {'; then
    pass "E1 exception: settingsChanged gated by receiverRelated; sleep/notify use their own hooks (no restart)"
else
    fail "E1 exception wiring missing in the staged apply path"
fi

if grep -Fq 'StagedSettings' "$PI_SWIFT" \
    && grep -Fq 'preferencesApplyRequested' "$PI_SWIFT" \
    && ! grep -Fq 'preferencesPreventSleepToggled' "$PI_SWIFT"; then
    pass "intent: staged intent surface (both toggles go through Apply; per-field intents retired)"
else
    fail "intent: staged intents missing from the SettingsUI intent protocol"
fi

if grep -Fq 'preventSleepToggled' "$PW_SWIFT" \
    && ! grep -Fq 'notificationsToggled' "$PW_SWIFT" \
    && grep -Fq 'sleep=\(snapshot.preventSleep' "$PW_SWIFT" \
    && grep -Fq 'notify=\(snapshot.notificationsEnabled' "$PW_SWIFT" \
    && grep -Fq 'togglePreventSleepForTesting' "$PW_SWIFT" \
    && grep -Fq 'toggleNotificationsForTesting' "$PW_SWIFT" \
    && grep -Fq 'PREFS staged' "$PW_SWIFT"; then
    pass "prefs: prevent-sleep action wired + B2 has no action (retired) + notify= real-value line + test seam"
else
    fail "prefs: section-E switch wiring incomplete"
fi

if ! grep -Fq 'switchControl(isOn: snapshot.notificationsEnabled)' "$PF_SWIFT" \
    && ! grep -Fq 'prefs.row.notifications' "$PF_SWIFT"; then
    pass "prefs: the connection-notification row no longer exists (D8 ruling B — no switch, no label key, not disabled)"
else
    fail "prefs: the connection-notification row is still on the settings page"
fi

if grep -Fq 'presentSessionNotification' "$SI_SWIFT" \
    && grep -Fq 'togglePreferencesPreventSleep' "$SI_SWIFT" \
    && grep -Fq 'togglePreferencesNotifications' "$SI_SWIFT"; then
    pass "wiring: fallback subscription endpoint (presentSessionNotification) + two-window seam (StatusItemMenu)"
else
    fail "wiring: section-E wiring incomplete in StatusItemMenu"
fi

if grep -Fq 'sleepGuard' "$CR_SWIFT" \
    && grep -Fq 'sessionNotifier' "$CR_SWIFT" \
    && ! grep -Fq 'notificationsEnabledProvider' "$CR_SWIFT" \
    && grep -Fq 'presentSessionNotification' "$CR_SWIFT"; then
    pass "wiring: CompositionRoot injects both units + no B2 provider (D8 decoupled) + fallback subscription"
else
    fail "wiring: section-E injection missing in CompositionRoot"
fi

if grep -Fq 'MIRRORBOARD_UITEST_SLEEPNOTIFY' "$AD_SWIFT" \
    && grep -Fq 'runSleepNotify' "$UTD_SWIFT" \
    && grep -Fq 'snInjectedDeviceName' "$UTD_SWIFT"; then
    pass "harness: MIRRORBOARD_UITEST_SLEEPNOTIFY branch + Timeline ⑤"
else
    fail "harness: sleep-notify harness missing"
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
if grep -rq "$BANNED_WORD" "$PROJ/app/Sources/AppShell" "$PROJ/app/Sources/SettingsUI" "$PROJ/app/Sources/SleepGuard" "$PROJ/app/Sources/SessionNotifier" 2>/dev/null; then
    fail "red-line: banned wording found in section-E sources"
else
    pass "red-line: no banned wording in section-E sources"
fi

# --- red-line: uxplay tree must match the pinned commit ----------------------
# 2026-10-19 decouple: core/uxplay is no longer git-tracked. The upstream tree
# now lives in a vendored directory outside version control, materialized on
# demand by scripts/build/vendor-uxplay.sh from the fork pinned in
# core/vendor.lock. The red line is therefore no longer "only the renderer file
# may differ" but "the whole tree must equal the pinned commit" — any unapproved
# local edit (the renderer file included) trips it. vendor-uxplay.sh --check
# verifies the commit, the tree hash, the file count and every per-file sha256
# against the manifest, and exits 1 on any mismatch.
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
# launch.log is a per-generation file the app truncates on every fresh start;
# drop the previous generation now (same point in the flow, one step earlier)
# so the ledger collector below can never mistake an earlier run's spawn lines
# for this run's.
[ -f "$LAUNCH_LOG" ] && : > "$LAUNCH_LOG"
[ -f "$SCRATCH/panel-notify-connected.png" ] && mv "$SCRATCH/panel-notify-connected.png" "$RUN/panel-notify-connected.prev.png"
[ -f "$SCRATCH/panel-notify-unconditional.png" ] && mv "$SCRATCH/panel-notify-unconditional.png" "$RUN/panel-notify-unconditional.prev.png"

# --- 3. build ----------------------------------------------------------------
# The testkit assembles the bundle into this run's temp dir (core and the
# SwiftPM cache stay in one reusable cache outside the checkout), so the app
# this suite launches is the app it just built — never a repo-local leftover.

if testkit_build >"$RUN/build.log" 2>&1; then
    if grep -Eq 'warning:|error:' "$RUN/build.log"; then
        fail "build has warnings/errors — see $RUN/build.log"
        log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
        exit 1
    fi
    pass "build ok (scripts/build/build-app.sh, 0 warnings/0 errors)"
else
    fail "build failed — see $RUN/build.log"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ==="
    exit 1
fi

EXE="$(testkit_app_binary)"
if [ -z "$EXE" ] || [ ! -x "$EXE" ]; then
    fail "built executable not found ($EXE)"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    exit 1
fi
log "   executable: $EXE"

# --- 4. launch (+ SPAWN marker collector) ------------------------------------

spawn_collector &
COLLECT_PID=$!

# The harness launches the ASSEMBLED BUNDLE's executable: Bundle.main is the
# .app, so the projection helper resolves from inside the bundle exactly as it
# does in the shipped product. The DEBUG-only helper seam is no longer needed.
MIRRORBOARD_UITEST_SLEEPNOTIFY=1 \
    MIRRORBOARD_STRINGS_PATH="$PROJ/app/Resources/Strings/terms.json" \
    testkit_launch
APP_PID="${TEST_APP_PID:-}"
sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "launch ok (pid $APP_PID)"
else
    cp "$TEST_APP_CONSOLE" "$RUN/app.stdout.log" 2>/dev/null
    fail "launch failed — see $RUN/app.stdout.log"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    exit 1
fi

# --- 5. ① receiver not started: zero assertions -------------------------------

wait_for_count "$UI_LOG" "PANEL shown" 1 10 \
    && pass "panel opens (PANEL shown)" \
    || fail "panel never shown"
wait_for_assertion_absent 3 \
    && pass "receiver not started → zero assertions (pmset)" \
    || fail "assertion present although receiver not started"
dump_pmset "0-idle"

# --- 6. ① start#1 (sleep prevention on by default): assertion held; toggle off = immediate release, zero restart ---

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

wait_for_count "$UI_LOG" "SLEEPGUARD assertion held" 1 8 \
    && pass "start → SLEEPGUARD assertion held (assertion acquired)" \
    || fail "no SLEEPGUARD held line after start"
wait_for_assertion_present 6 \
    && pass "pmset: assertion held (PreventUserIdleDisplaySleep, owning pid=${APP_PID})" \
    || fail "pmset: assertion not present while running with prevent-sleep on"
dump_pmset "a-start-on"
if grep -Fq 'named: "MiragePlay SleepGuard (receiver session)"' "$RUN/pmset-a-start-on.txt"; then
    pass "pmset: assertion name readable (named column = MiragePlay SleepGuard (receiver session))"
else
    fail "pmset: assertion name not readable in named field"
fi

# the initial prefs real-value line (first read-back of sleep=/notify=).
wait_for_count "$UI_LOG" "PREFS values res=1080p fps=30 mute=off name=MiragePlay pin=- sleep=on notify=on" 1 14 \
    && pass "prefs real-value line (initial): PREFS values … pin=- sleep=on notify=on" \
    || fail "initial PREFS values line (with sleep=/notify=) missing"

# wave1r1: sleep prevention off goes STAGED first (zero action; only apply takes effect).
wait_for_count "$UI_LOG" "PREFS staged name=MiragePlay res=1080p fps=30 mute=off sleep=off notify=on lang=en profile=預設 dirty=1" 1 10 \
    && pass "prevent-sleep off = staged (PREFS staged sleep=off; no action before Apply)" \
    || fail "staged sleep-off line missing"

# sleep prevention off (while running): apply = immediate release; the receiver is untouched.
wait_for_count "$UI_LOG" "ACTION prevent-sleep off (shell-held, no restart)" 1 10 \
    && pass "prevent-sleep off (while running) → Apply ACTION prevent-sleep off (shell-held)" \
    || fail "prevent-sleep off never invoked"
wait_for_count "$UI_LOG" "SLEEPGUARD assertion released" 1 8 \
    && pass "toggle off → SLEEPGUARD assertion released (immediately)" \
    || fail "no SLEEPGUARD released line after toggle off"
wait_for_assertion_absent 6 \
    && pass "pmset: toggle off → assertion released (proven absent)" \
    || fail "pmset: assertion still present after toggle off"
dump_pmset "b-sleep-off"
if [ "$(pgrep -x uxplay 2>/dev/null | head -1)" = "$PID1" ]; then
    pass "no receiver touch, immediate: uxplay PID unchanged after toggle off (${PID1})"
else
    fail "toggle off touched the receiver (uxplay pid changed)"
fi
if [ "$(count_in 'ACTION settings-changed' "$UI_LOG")" = "0" ]; then
    pass "no receiver touch, immediate: zero settings-changed lines after the toggle"
else
    fail "a shell-held toggle emitted settings-changed"
fi
wait_for_file_content "$SETTINGS" '"preventSleep" : false' 8 \
    && pass "persisted: settings.json preventSleep=false (written back)" \
    || fail "settings.json did not persist preventSleep=false"

# sleep prevention on (while running): re-held immediately.
wait_for_count "$UI_LOG" "ACTION prevent-sleep on (shell-held, no restart)" 1 10 \
    && pass "prevent-sleep on (while running) → ACTION prevent-sleep on" \
    || fail "prevent-sleep on never invoked"
wait_for_count "$UI_LOG" "SLEEPGUARD assertion held" 2 8 \
    && pass "toggle on → SLEEPGUARD assertion held (re-held immediately)" \
    || fail "no second SLEEPGUARD held line"
wait_for_assertion_present 6 \
    && pass "pmset: toggle on → assertion re-held (proven present)" \
    || fail "pmset: assertion not present after toggle on"
dump_pmset "c-sleep-on"
if [ "$(pgrep -x uxplay 2>/dev/null | head -1)" = "$PID1" ]; then
    pass "no receiver touch, immediate: uxplay PID still unchanged after toggle on (${PID1})"
else
    fail "toggle on touched the receiver (uxplay pid changed)"
fi
wait_for_file_content "$SETTINGS" '"preventSleep" : true' 8 \
    && pass "persistence round-trip: settings.json preventSleep true (false→true)" \
    || fail "settings.json did not persist preventSleep=true"

# --- 7. ② notifier dispatch (connect notifications on): NOTIFY trace ----------

wait_for_count "$UI_LOG" "STATE connected(測試用 iPad)" 1 10 \
    && pass "inject connected#1 → STATE connected(測試用 iPad)" \
    || fail "connected injection never surfaced"
wait_for_count "$UI_LOG" "NOTIFY connected message=Connected to 測試用 iPad" 1 8 \
    && pass "NOTIFY connected (dispatched; copy = fallback EN default Connected to〈device name〉)" \
    || fail "NOTIFY connected trace missing"
if [ "$(pgrep -x uxplay 2>/dev/null | head -1)" = "$PID1" ]; then
    pass "injected event does not touch the receiver (PID still ${PID1})"
else
    fail "event injection touched the receiver"
fi

wait_for_count "$UI_LOG" "NOTIFY disconnected message=Disconnected" 1 8 \
    && pass "inject disconnected#1 → NOTIFY disconnected（Disconnected）" \
    || fail "NOTIFY disconnected trace missing"

# --- 8. ② B2 slot=false still writes NOTIFY (D8 core: recording ignores settings) ---

wait_for_count "$UI_LOG" "ACTION notifications off (shell-held, no restart)" 1 10 \
    && pass "B2 slot → false → ACTION notifications off (shell-held; the control no longer exists on the page)" \
    || fail "notifications slot change never invoked"
wait_for_file_content "$SETTINGS" '"notificationsEnabled" : false' 8 \
    && pass "persisted: settings.json notificationsEnabled=false (field kept, value still written)" \
    || fail "settings.json did not persist notificationsEnabled=false"

wait_for_count "$UI_LOG" "STATE connected(測試用 iPad)" 2 10 \
    && pass "with B2=false, inject connected#2 → STATE connected still emitted (state channel healthy)" \
    || fail "state chain stopped updating while the B2 slot was false"
sleep 0.8
GATED_CONN="$(count_in 'NOTIFY connected' "$UI_LOG")"
GATED_TOTAL="$(count_in 'NOTIFY ' "$UI_LOG")"
# Lower-bound assertion (not a snapshot): this block proves "connected#2 still writes NOTIFY while B2=false".
# snapshot-style ==2/==3 races the app's fixed timeline (a script 3-4 s slow reads connected#3),
# so this pins the lower bound; the exact totals are pinned by the §14 ledger (connected×3 / disconnected×2).
if [ "$GATED_CONN" -ge 2 ] && [ "$GATED_TOTAL" -ge 3 ]; then
    pass "logging is unconditional (D8 core): connected#2 still writes NOTIFY while B2=false (measured connected=$GATED_CONN total=${GATED_TOTAL}, lower bound 2/3)"
else
    fail "NOTIFY was gated by the B2 slot — connected=$GATED_CONN total=$GATED_TOTAL (expected >=2/>=3)"
fi
if [ "$(pgrep -x uxplay 2>/dev/null | head -1)" = "$PID1" ]; then
    pass "B2 slot change does not touch the receiver (PID still ${PID1})"
else
    fail "the B2 slot change touched the receiver"
fi

# --- 9. ② B2 slot back to true (dispatch never stopped) -----------------------

wait_for_count "$UI_LOG" "ACTION notifications on (shell-held, no restart)" 1 10 \
    && pass "B2 slot → true → ACTION notifications on" \
    || fail "notifications on never invoked"
wait_for_file_content "$SETTINGS" '"notificationsEnabled" : true' 8 \
    && pass "persistence round-trip: settings.json notificationsEnabled true (false→true)" \
    || fail "settings.json did not persist notificationsEnabled=true"
wait_for_count "$UI_LOG" "NOTIFY disconnected message=Disconnected" 2 10 \
    && pass "inject disconnected#2 → NOTIFY disconnected (2nd entry)" \
    || fail "disconnected#2 trace missing"
wait_for_count "$UI_LOG" "NOTIFY connected message=Connected to 測試用 iPad" 3 8 \
    && pass "inject connected#3 → NOTIFY connected (3rd entry; never silent)" \
    || fail "connected#3 trace missing"

# --- 10. ① stop#1: in the receiver-off state the assertion must be released (red line) ---

wait_for_count "$UI_LOG" "ACTION stop" 1 10 \
    && pass "Stop #1 (ACTION stop)" \
    || fail "Stop #1 never invoked"
wait_for_count "$UI_LOG" "SLEEPGUARD assertion released" 2 8 \
    && pass "Stop → SLEEPGUARD assertion released (2nd time)" \
    || fail "no release on stop"
wait_for_assertion_absent 6 \
    && pass "red line: receiver stopped → assertion released (proven absent via pmset)" \
    || fail "red-line violation: assertion still held after stop"
dump_pmset "d-stopped"
wait_pgrep_down uxplay 5 \
    && pass "stop #1 → uxplay gone" \
    || fail "uxplay still running after Stop #1"

# --- 11. ③ toggle off while stopped = write-back only; reopen reads the real values ---

wait_for_count "$UI_LOG" "ACTION prevent-sleep off (shell-held, no restart)" 2 10 \
    && pass "prevent-sleep off (receiver not started / write-back only) → ACTION prevent-sleep off ×2" \
    || fail "second prevent-sleep off never invoked"
wait_for_file_content "$SETTINGS" '"preventSleep" : false' 8 \
    && pass "persisted: settings.json preventSleep=false (final state)" \
    || fail "settings.json did not persist the final preventSleep=false"

wait_for_count "$UI_LOG" "PREFS values res=1080p fps=30 mute=off name=MiragePlay pin=- sleep=off notify=on" 1 14 \
    && pass "prefs reopen re-reads the real value: PREFS values … sleep=off notify=on (differs from the initial line = a real read)" \
    || fail "reopened PREFS values line (sleep=off notify=on) missing"

# --- 12. ① start#2 (sleep prevention off): zero assertions while running -------

wait_for_count "$UI_LOG" "ACTION start" 2 10 \
    && pass "Start #2 (ACTION start ×2; prevent-sleep off)" \
    || fail "Start #2 never invoked"
PID2="$(wait_pid_change "$PID1" 10)" \
    && pass "start #2: uxplay running (pid $PID1 → $PID2)" \
    || fail "start #2: no new uxplay pid"
wait_for_count "$SPAWN_EVID" 'MIRRORBOARD SPAWN pid=' 2 8 \
    && pass "spawn #2 marker written" \
    || fail "no spawn #2 marker"
wait_for_assertion_absent 4 \
    && pass "prevent-sleep off while running → zero assertions (gating proven; pmset)" \
    || fail "assertion present although prevent-sleep is off"
dump_pmset "e-start2-prevent-off"
if [ "$(count_in 'SLEEPGUARD assertion held' "$UI_LOG")" = "2" ]; then
    pass "SLEEPGUARD: no 3rd hold (the off state never acquires an assertion)"
else
    fail "unexpected extra SLEEPGUARD held line (count $(count_in 'SLEEPGUARD assertion held' "$UI_LOG"))"
fi

wait_for_count "$UI_LOG" "ACTION stop" 2 10 \
    && pass "Stop #2 (ACTION stop ×2)" \
    || fail "Stop #2 never invoked"
wait_pgrep_down uxplay 5 \
    && pass "stop #2 → uxplay gone" \
    || fail "uxplay still running after Stop #2"

# --- 13. quit + residue -------------------------------------------------------

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
fi

sleep 1
pgrep -x MiragePlay >/dev/null 2>&1 && fail "residue: MiragePlay still running" || pass "residue: no MiragePlay"
pgrep -x uxplay >/dev/null 2>&1 && fail "residue: uxplay still running" || pass "residue: no uxplay"
wait_for_assertion_absent 3 \
    && pass "zero assertions left after quit (pmset)" \
    || fail "assertion survived the app"
dump_pmset "f-quit"

# --- 14. post-run ledger ------------------------------------------------------

grep -F -- 'MIRRORBOARD SPAWN pid=' "$LAUNCH_LOG" > "$RUN/spawn-lines.final-generation.txt" 2>/dev/null
cp "$SPAWN_EVID" "$RUN/spawn-lines.txt" 2>/dev/null

FINAL_SPAWNS="$(spawn_count)"
FINAL_STARTS="$(count_in 'ACTION start' "$UI_LOG")"
FINAL_STOPS="$(count_in 'ACTION stop' "$UI_LOG")"
FINAL_RESTARTS="$(count_in 'ACTION settings-changed (restart)' "$UI_LOG")"
FINAL_WRITEBACKS="$(count_in 'ACTION settings-changed (write-back only)' "$UI_LOG")"
FINAL_SLEEP_OFF="$(count_in 'ACTION prevent-sleep off' "$UI_LOG")"
FINAL_SLEEP_ON="$(count_in 'ACTION prevent-sleep on' "$UI_LOG")"
FINAL_NOTIFY_OFF="$(count_in 'ACTION notifications off' "$UI_LOG")"
FINAL_NOTIFY_ON="$(count_in 'ACTION notifications on' "$UI_LOG")"
FINAL_NC="$(count_in 'NOTIFY connected' "$UI_LOG")"
FINAL_ND="$(count_in 'NOTIFY disconnected' "$UI_LOG")"
FINAL_HELD="$(count_in 'SLEEPGUARD assertion held' "$UI_LOG")"
FINAL_RELEASED="$(count_in 'SLEEPGUARD assertion released' "$UI_LOG")"
FINAL_CONN_STATES="$(count_in 'STATE connected(測試用 iPad)' "$UI_LOG")"

[ "$FINAL_SPAWNS" = "2" ] \
    && pass "final ledger: exactly 2 spawns (only two Starts; no restart spawns)" \
    || fail "final ledger: spawn count = $FINAL_SPAWNS (expected 2)"
[ "$FINAL_STARTS" = "2" ] && [ "$FINAL_STOPS" = "2" ] \
    && pass "final ledger: 2 starts / 2 stops" \
    || fail "final ledger: starts=$FINAL_STARTS stops=$FINAL_STOPS (expected 2/2)"
[ "$FINAL_RESTARTS" = "0" ] && [ "$FINAL_WRITEBACKS" = "0" ] \
    && pass "final ledger: zero settings-changed (both toggles are shell-held, never touch the receiver)" \
    || fail "final ledger: settings-changed leaked (restart=$FINAL_RESTARTS write-back=$FINAL_WRITEBACKS)"
[ "$FINAL_SLEEP_OFF" = "2" ] && [ "$FINAL_SLEEP_ON" = "1" ] \
    && pass "final ledger: prevent-sleep off×2 / on×1" \
    || fail "final ledger: sleep toggles off=$FINAL_SLEEP_OFF on=$FINAL_SLEEP_ON (expected 2/1)"
[ "$FINAL_NOTIFY_OFF" = "1" ] && [ "$FINAL_NOTIFY_ON" = "1" ] \
    && pass "final ledger: connection notification off×1 / on×1" \
    || fail "final ledger: notifications toggles off=$FINAL_NOTIFY_OFF on=$FINAL_NOTIFY_ON (expected 1/1)"
[ "$FINAL_NC" = "3" ] && [ "$FINAL_ND" = "2" ] \
    && pass "final ledger: NOTIFY connected×3 / disconnected×2 (5 injections, never silent — D8)" \
    || fail "final ledger: NOTIFY counts nc=$FINAL_NC nd=$FINAL_ND (expected 3/2)"
[ "$FINAL_HELD" = "2" ] && [ "$FINAL_RELEASED" = "2" ] \
    && pass "final ledger: SLEEPGUARD held×2 / released×2 (transitions symmetric)" \
    || fail "final ledger: SLEEPGUARD held=$FINAL_HELD released=$FINAL_RELEASED (expected 2/2)"
[ "$FINAL_CONN_STATES" = "3" ] \
    && pass "final ledger: STATE connected(測試用 iPad)×3 (every injected event reached the state chain)" \
    || fail "final ledger: connected-state count = $FINAL_CONN_STATES (expected 3)"

if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$RUN/settings.json.test-run"
    grep -Fq '"preventSleep" : false' "$SETTINGS" \
        && pass "settings.json final state: preventSleep=false (restart carries the last value back)" \
        || fail "settings.json: preventSleep not at the final false"
    grep -Fq '"notificationsEnabled" : true' "$SETTINGS" \
        && pass "settings.json final state: notificationsEnabled=true" \
        || fail "settings.json: notificationsEnabled not at the final true"
else
    fail "settings.json missing — no write-back happened"
fi

# --- 15. evidence copy + summary ----------------------------------------------

cp "$UI_LOG" "$RUN/ui.log" 2>/dev/null
cp "$LAUNCH_LOG" "$RUN/launch.log" 2>/dev/null
cp "$TEST_APP_CONSOLE" "$RUN/app.stdout.log" 2>/dev/null
cp "$SCRATCH/panel-notify-connected.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/panel-notify-unconditional.png" "$RUN/" 2>/dev/null

restore_settings

log ""
log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
log "   ui.log:     $UI_LOG"
log "   evidence:   $RUN"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
