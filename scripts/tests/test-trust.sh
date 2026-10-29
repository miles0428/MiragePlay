#!/bin/bash
# test-trust.sh — wave1r4 (trust increment) + wave1r6 (trust timing fix) trust test suite.
#
# Covers (per the wave1r6 task card ④):
#   ① I1 event parsing (fourth mode) — RAW launch.log injection of uxplay's verbatim two-line record
#      (`registered new client: <name> DeviceID = <code> PK = ` + a 44-character pk64
#      continuation; uxplay.cpp:2624), through CoreBridge's real parse path → the event is raised
#      (`TRUST event …`) + the PIN-off gate (`TRUST event ignored (pin off)`).
#   ② I2 prompt — presented the moment pairing succeeds (`TRUST prompt presented`); EN / zh-Hant
#      render + rendered-string audit; a repeated event from the same device = merged (`TRUST prompt
#      merged`); trust = zero action (keep); distrust / no answer (M1) = delist and write the file.
#   ③ wave1r6 apply-on-disconnect — the delist write ⇒ `TRUST pending set`; the apply gate:
#      - answering distrust while disconnected (corner) ⇒ `TRUST apply gate=immediate` (PIN
#        rotation + E1 restart; the PIN value changes on every spawn);
#      - delisting while mirroring ⇒ `TRUST apply held … (connected; awaits disconnect)`;
#        when that session's socket closes ⇒ `TRUST apply gate=disconnect` (the restart makes
#        uxplay reload the file — pinned generation by generation via the boot line `lists N`);
#      - multiple devices (socket-count gate): a close that leaves another connection
#        live is a SOCKET event only — no `.disconnected`, no state flip (the device is
#        offline only when the census empties; `SOCKET closed … live=N` trace); the apply
#        fires when the LAST socket closes, and never while a peer is online;
#      - delisting while stopped ⇒ `TRUST apply deferred` (loaded on the next start) + an immediate PIN
#        rotation; PIN off ⇒ `TRUST apply dropped` (no trust semantics, zero restart).
#   ④ wave1r6 PIN rotation — applying an event emits `TRUST pin-rotate applied`; spawn
#      argv `-pin` differs per generation; the panel `PANEL pin display on code=…` follows;
#      panel-pin-rotated.png render.
#   ⑤ wave1r6 ✕ on-screen rebuild — each editor row's ✕ = delist; after writing, **rebuild in place** (`views
#      rebuilt in place`); the assertion reads the on-screen view (`live-rows=… codes=[…]`),
#      not just the model / log: the removed row's ✕ leaves the view tree ⇒ clicking the same spot again =
#      `live-press miss` (no second `remove requested` — the YC double-click regression);
#      renders: before ✕ / after ✕ / after Reset (on screen).
#   ⑥ M2→R6 semantic flip ledger — applies = restarts; `ACTION settings-changed
#      (restart)` is always 0 (trust apply uses its own carrier, it does not occupy the settings channel); spawns =
#      1 + starts + applies; the PID changes between applies.
#   phase B (TRUST=2) — persisted zh-Hant relaunch: the prompt renders in zh-Hant + audit; no answer
#      = delist + corner apply + another PIN rotation; ✕F while stopped = deferred + immediate rotation;
#      wave1r6b N-1 — a lagging disconnect after stop (stale; still dirty) = the guard
#      holds it back (`TRUST apply skipped`; zero resurrected spawn — before the fix this step resurrected it).
#
# The register/connect/close records are injected by the app harness itself
# (UITestDriver `injectLaunchLogLine`; O_APPEND to launch.log) — the exact
# bytes a live uxplay/httpd would write (uxplay.cpp:2624 / httpd.c:238,312),
# parsed by the live log watcher. Real-device pairing (entering the PIN) is still a YC on-device item.
#
# Re-runnable. Self-contained. Never touches a RUNNING MiragePlay/uxplay
# instance (aborts — that would be YC's own instance; the test cleans up after itself, zero residue).
# User state: before the test, settings.json and registration.list (if present) are moved into this run's
# directory for safekeeping and put back unchanged at the end; the registration.list this session writes (fixture iteration output)
# is kept as evidence and the real file is restored (zero deletion, zero damage; server.pem untouched, shasum locked before/after).
#
# Usage:  ./scripts/tests/test-trust.sh
# Evidence: <testkit_evidence_dir>/testrun-trust-<YYYYmmdd_HHMMSS>/ — inside this run's
# own temp workspace (the testkit keeps it when the run fails, drops it when green).
#   (Rebuilt in the wave that last owned this suite; wave1r12-test-rebuild = rebuilt after the r10b test change
#    + wave1r10d, where YC set the new semantics: app-side lock (no runModal), level 26)

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
    echo "test-trust: cannot resolve the repo root to its on-disk spelling" >&2
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
    echo "test-trust: testkit_init failed (no private temp workspace)" >&2
    exit 1
}
RUN="$(testkit_evidence_dir)/testrun-trust-$(date '+%Y%m%d_%H%M%S')"
UI_LOG="$(testkit_ui_log)"
CB_SWIFT="$PROJ/app/Sources/core-bridge/CoreBridgeReceiverController.swift"
RC_SWIFT="$PROJ/app/Sources/ReceiverKit/ReceiverController.swift"
RE_SWIFT="$PROJ/app/Sources/ReceiverKit/ReceiverEvent.swift"
LC_SWIFT="$PROJ/app/Sources/AppShell/LifecycleCoordinator.swift"
SI_SWIFT="$PROJ/app/Sources/AppShell/StatusItemMenu.swift"
CR_SWIFT="$PROJ/app/Sources/AppShell/CompositionRoot.swift"
UTD_SWIFT="$PROJ/app/Sources/AppShell/UITestDriver.swift"
AD_SWIFT="$PROJ/app/Sources/AppShell/AppDelegate.swift"
PW_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesWindowController.swift"
TP_SWIFT="$PROJ/app/Sources/SettingsUI/TrustPromptWindowController.swift"
STORE_SWIFT="$PROJ/app/Sources/ConfigEngine/TrustRegistryStore.swift"
HANDLER_SWIFT="$PROJ/app/Sources/AppShell/TrustRegistryHandler.swift"
TERMS_JSON="$PROJ/app/Resources/Strings/terms.json"
APPSUP="$HOME/Library/Application Support/com.ycchung.mirageplay"
SETTINGS="$APPSUP/settings.json"
REGISTRY="$APPSUP/registration.list"
# launch.log is an Application Support artefact the app resolves itself
# (~/Library/Application Support/<bundle-id>/launch.log) — not harness scratch.
LAUNCH_LOG="$APPSUP/launch.log"
# The app's own evidence subtree (NSTemporaryDirectory()/<bundle-id>): the UI
# test driver renders its PNGs there and arms/consumes its deactivate marker there.
SCRATCH_ROOT="${TMPDIR:-/tmp}"; SCRATCH_ROOT="${SCRATCH_ROOT%/}"
SCRATCH="$SCRATCH_ROOT/com.ycchung.mirageplay"

# Synthetic devices (same values as UITestDriver — real device identifiers must not enter the repo); pk64 = 44 characters.
PKA="$(python3 -c "print('A'*43+'=')")"
PKB="$(python3 -c "print('B'*43+'=')")"
PKC="$(python3 -c "print('C'*43+'=')")"
PKD="$(python3 -c "print('D'*43+'=')")"
PKE="$(python3 -c "print('E'*43+'=')")"
PKF="$(python3 -c "print('F'*43+'=')")"
DEV_A="AA:AA:AA:AA:AA:01"
DEV_B="BB:BB:BB:BB:BB:02"
DEV_C="CC:CC:CC:CC:CC:03"
DEV_D="DD:DD:DD:DD:DD:04"
DEV_E="EE:EE:EE:EE:EE:05"
DEV_F="FF:FF:FF:FF:FF:06"

PASS=0
FAIL=0
SKIP=0
APP_PID=""
# Background registry sampler armed by start_registry_sampler; empty when none runs.
SAMPLER_PID=""
SETTINGS_PREEXISTED=0
REGISTRY_PREEXISTED=0
APPSUP_PREEXISTED=0
RESTORED=0
SERVER_PEM_SHA_BEFORE=""
SERVER_PEM_SHA_AFTER=""

mkdir -p "$RUN"

log()  { echo "$@" | tee -a "$RUN/summary.txt"; }
pass() { PASS=$((PASS + 1)); log "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); log "FAIL  $1"; }
skip() { SKIP=$((SKIP + 1)); log "SKIP  $1"; }

# --- user-state restore (exact; runs from cleanup and from the normal tail) ---

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
    if [ "$REGISTRY_PREEXISTED" = "1" ] && [ -f "$RUN/registration.list.prev" ]; then
        [ -f "$REGISTRY" ] && cp "$REGISTRY" "$RUN/registration.list.test-run" 2>/dev/null
        mv -f "$RUN/registration.list.prev" "$REGISTRY"
        log "[restore] original registration.list restored"
    elif [ "$REGISTRY_PREEXISTED" = "0" ] && [ -f "$REGISTRY" ]; then
        mv "$REGISTRY" "$RUN/registration.list.self-created"
        log "[restore] test-created registration.list archived (none existed before)"
    fi
    if [ "$APPSUP_PREEXISTED" = "0" ] && [ -d "$APPSUP" ]; then
        rmdir "$APPSUP" 2>/dev/null && log "[restore] empty AppSupport dir removed (created by this run)"
    fi
}

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$APP_PID" 2>/dev/null || break
            sleep 0.25
        done
        kill -0 "$APP_PID" 2>/dev/null && kill -9 "$APP_PID" 2>/dev/null
    fi
    stop_registry_sampler 2>/dev/null || true
    if [ -n "${THIEF_PID:-}" ] && kill -0 "$THIEF_PID" 2>/dev/null; then
        kill "$THIEF_PID" 2>/dev/null
        kill -9 "$THIEF_PID" 2>/dev/null
    fi
    if [ -f "$RUN/thief.pid" ]; then
        local tp; tp="$(cat "$RUN/thief.pid" 2>/dev/null)"
        [ -n "$tp" ] && kill "$tp" 2>/dev/null && kill -9 "$tp" 2>/dev/null
    fi
    rm -f "$SCRATCH/deactivate-done" 2>/dev/null
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
    local file="$1" pattern="$2" want="$3" timeout_s="${4:-15}" waited=0
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        [ "$(count_in "$pattern" "$file")" -ge "$want" ] && return 0
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}

wait_for_count_eq() { # <file> <fixed-pattern> <exact-count> <timeout_sec>
    local file="$1" pattern="$2" want="$3" timeout_s="${4:-15}" waited=0
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        [ "$(count_in "$pattern" "$file")" = "$want" ] && return 0
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}

wait_for_line() { # <fixed-pattern> [timeout_sec] → at least one matching line
    wait_for_count "$UI_LOG" "$1" 1 "${2:-15}"
}

# --- window sampling ----------------------------------------------------------
# A cumulative count ("how many `TRUST apply gate=` lines the log holds so far")
# is not an observable for "nothing restarted while the state was held": the next
# phase's legitimate apply is written to the same file seconds later, so the
# count keeps growing no matter what the product did. These helpers measure a
# WINDOW instead — the lines strictly between a start anchor (the held line) and
# the boundary that ends that state (the apply the disconnect legitimately fires).
# >>> window-sampling helpers  (delimiter kept on purpose: the discrimination
# probe in .task_state/coding_fix-trust-assertion-sampling_20261022.md extracts
# this block with sed and feeds it synthetic logs)
window_end_line() { # <file> <start-fixed> <end-fixed> → line no. closing the window ('' while not closed)
    local file="$1" start_pat="$2" end_pat="$3" start_no
    [ -f "$file" ] || return 0
    start_no="$(grep -nF -- "$start_pat" "$file" 2>/dev/null | head -1 | cut -d: -f1)"
    [ -n "$start_no" ] || return 0
    grep -nF -- "$end_pat" "$file" 2>/dev/null | cut -d: -f1 \
        | awk -v s="$start_no" '$1 > s { print; exit }'
}

count_between() { # <file> <start-fixed> <end-fixed> <count-fixed> → count, or no-file/no-start/no-end
    local file="$1" start_pat="$2" end_pat="$3" count_pat="$4" start_no end_no n
    [ -f "$file" ] || { printf 'no-file'; return 0; }
    start_no="$(grep -nF -- "$start_pat" "$file" 2>/dev/null | head -1 | cut -d: -f1)"
    [ -n "$start_no" ] || { printf 'no-start'; return 0; }
    end_no="$(window_end_line "$file" "$start_pat" "$end_pat")"
    [ -n "$end_no" ] || { printf 'no-end'; return 0; }
    if [ "$end_no" -le $((start_no + 1)) ]; then
        printf '0'                      # the anchors are adjacent: an empty window
        return 0
    fi
    n="$(sed -n "$((start_no + 1)),$((end_no - 1))p" "$file" | grep -Fc -- "$count_pat" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

wait_window_end() { # <file> <start-fixed> <end-fixed> <timeout_sec> → 0 once the closing boundary is in the log
    local file="$1" start_pat="$2" end_pat="$3" timeout_s="${4:-12}" waited=0
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        [ -n "$(window_end_line "$file" "$start_pat" "$end_pat")" ] && return 0
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}

# Sample the shared registry AT the target state instead of afterwards: the moment
# <fixed-pattern> appears in the ui log, copy the file once and stop. The pattern
# is a line the app writes in the same handler that decided not to write the file,
# so the copy is taken while that decision is the latest one.
start_registry_sampler() { # <tag> <fixed-pattern>
    local tag="$1" pattern="$2"
    rm -f "$RUN/registration.list.$tag"
    (
        while :; do
            if grep -Fq -- "$pattern" "$UI_LOG" 2>/dev/null; then
                cp "$REGISTRY" "$RUN/registration.list.$tag" 2>/dev/null
                exit 0
            fi
            sleep 0.05
        done
    ) &
    SAMPLER_PID=$!
}

stop_registry_sampler() { # let a pending sample land (bounded), then retire the watcher
    local pid="${SAMPLER_PID:-}" waited=0
    [ -n "$pid" ] || return 0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 60 ]; do
        sleep 0.05
        waited=$((waited + 1))
    done
    kill "$pid" 2>/dev/null || true
    SAMPLER_PID=""
}
# <<< window-sampling helpers

wait_pgrep_down() { # <procname> <timeout_sec>
    local name="$1" timeout_s="${2:-10}" waited=0
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        pgrep -x "$name" >/dev/null 2>&1 || return 0
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}

wait_for_live_pid_eq() { # <expected-pid> <timeout_sec> — waits past a dying old generation
    local want="$1" timeout_s="${2:-8}" waited=0
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        [ "$(uxplay_pid)" = "$want" ] && return 0
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}

spawn_pid() { # <n> → the pid= of the nth MIRRORBOARD SPAWN line
    spawn_line "$1" | sed -E 's/^.*pid=([0-9]+).*$/\1/'
}

spawn_count() { count_in 'MIRRORBOARD SPAWN pid=' "$LAUNCH_LOG"; }

spawn_line() { # <n> → the nth MIRRORBOARD SPAWN line
    grep -F 'MIRRORBOARD SPAWN pid=' "$LAUNCH_LOG" | sed -n "$1p"
}

pin_of_spawn() { # <n> → the -pin value of the nth spawn ('' when absent)
    spawn_line "$1" | python3 -c '
import sys, re
m = re.findall(r"\"-pin\" \"([0-9]+)\"", sys.stdin.read())
print(m[0] if m else "")
'
}

last_panel_pin_code() { # last `PANEL pin display on code=X` in ui.log
    grep -E 'PANEL pin display on code=[0-9]+' "$UI_LOG" | tail -1 | sed -E 's/.*code=([0-9]+).*/\1/'
}

assert_pin_diff() { # <label> <old> <new>
    if [ -n "$2" ] && [ -n "$3" ] && [ "$2" != "$3" ]; then
        pass "$1: PIN rotation ($2 → $3 — the client remembered code is dead)"
    else
        fail "$1: PIN not rotated (old='$2' new='$3')"
    fi
}

uxplay_pid() { pgrep -x uxplay 2>/dev/null | head -1; }

file_lines() { [ -f "$REGISTRY" ] && wc -l < "$REGISTRY" | tr -d ' ' || printf '0'; }

file_bytes() {
    [ -f "$REGISTRY" ] && wc -c < "$REGISTRY" | tr -d ' ' || printf '-1'
}

snapshot_registry() { # <tag> — evidence copy of the current registry state
    cp "$REGISTRY" "$RUN/registration.list.$1" 2>/dev/null
}

wait_app_exit() { # <timeout_sec>
    local timeout_s="${1:-12}" waited=0
    while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt $((timeout_s * 4)) ]; do
        sleep 0.25
        waited=$((waited + 1))
    done
    kill -0 "$APP_PID" 2>/dev/null && return 1 || return 0
}

# --- 0. preflight: never touch a live instance ------------------------------

log "== wave1r12 trust test — $(date '+%Y-%m-%d %H:%M:%S %Z') =="
log "   (r10b test rebuilt after the change; YC set the new semantics: app-side lock + level 26 re-set; 7 red items removed from the spec)"
log "   run dir: $RUN"

if ! testkit_preflight_clean; then
    log "ABORT: MiragePlay or uxplay is already running — refusing to touch a live instance."
    testkit_mark_failed
    exit 2
fi
pass "preflight: zero pre-existing MiragePlay/uxplay"

if [ "${#PKA}" != "44" ] || [ "${#PKF}" != "44" ]; then
    fail "fixture: pk64 lengths wrong (${#PKA}/${#PKF})"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    exit 1
fi
pass "fixture: pk64 values are 44 chars (base64 shape)"

# --- 1. contract statics -----------------------------------------------------

# ① I1: the fourth parse mode + explicit name/deviceID extraction + the
# two-line pk64 continuation handling.
if grep -Fq 'registered new client: ' "$CB_SWIFT" \
    && grep -Fq 'expectPkContinuation' "$CB_SWIFT" \
    && grep -Fq 'isPk64Line' "$CB_SWIFT" \
    && grep -Fq 'handleTrustPairingRegistered' "$CB_SWIFT" \
    && grep -Fq 'DeviceID = ' "$CB_SWIFT" \
    && grep -Fq ' PK = ' "$CB_SWIFT"; then
    pass "I1 parse: fourth pattern (registered new client) + explicit name/deviceID capture + pk64 continuation consumed"
else
    fail "I1: CoreBridge trust parse mode incomplete"
fi
if grep -Fq 'case trustPairingRegistered(deviceName: String, deviceID: String)' "$RE_SWIFT"; then
    pass "I1 event: ReceiverEvent.trustPairingRegistered（name＋deviceID）"
else
    fail "I1: trustPairingRegistered case missing from ReceiverEvent"
fi

# wave1r6 ①: socket census (accepted/closed → activeSockets; protocol exposure).
# fix-socket-census: the census is also the close-path precondition — the device
# is offline only once the set empties (`guard self.activeSockets.isEmpty else`),
# i.e. a close that leaves a connection behind is a socket event only.
if grep -Fq 'activeSockets' "$CB_SWIFT" \
    && grep -Fq 'socketNumber(in:' "$CB_SWIFT" \
    && grep -Fq 'public var liveConnectionCount: Int' "$CB_SWIFT" \
    && grep -Fq 'activeSockets.removeAll()' "$CB_SWIFT" \
    && grep -Fq 'guard self.activeSockets.isEmpty else' "$CB_SWIFT" \
    && grep -Fq 'var liveConnectionCount: Int { get }' "$RC_SWIFT"; then
    pass "R6 socket census: activeSockets (accept/close) + liveConnectionCount (IF-1) + reset at spawn + close-path emptiness gate"
else
    fail "R6 socket census: a structural piece is missing (accept/close recording, liveConnectionCount, spawn reset, emptiness gate)"
fi
# wave1r6-r1 (review R2/R3): the two asymmetries the re-review found are gone.
#   - R2: the accept path's placeholder is a "not known yet" marker and must not
#     overwrite a name already revealed for this session (pre-fix: name regression).
#   - R3: the close path must not read an empty set as "the device left" unless
#     the socket it removed was actually tracked (pre-fix: conditional remove,
#     unconditional emptiness test).
if grep -Fq 'if deviceName == Self.placeholderDeviceName { return }' "$CB_SWIFT" \
    && grep -Fq 'let wasTracked = self.activeSockets.remove(socket) != nil' "$CB_SWIFT" \
    && grep -Fq 'guard wasTracked else' "$CB_SWIFT"; then
    pass "R2/R3: placeholder never overwrites a known name; the close path only flips on a TRACKED socket"
else
    fail "R2/R3: the placeholder guard or the tracked-socket guard is missing from the receiver"
fi

# ② I2 (wave1r10d): TrustPrompt is a standalone mini window (About pattern, **non-modal, no
# runModal**) + **app-side lock**: a local event monitor swallows mouse/key events aimed at "windows other than the prompt"
# + every other window ignoresMouseEvents; level 26 (statusBar+1) is re-asserted on every show
# (no system modal session ⇒ it is not overwritten to 8); NSApp.activate;
# M1 mapping; merge / single instance. YC's ruling, route ① = "skip NSApp.runModal and block the UI ourselves".
if [ -f "$TP_SWIFT" ] \
    && grep -Fq 'NSEvent.addLocalMonitorForEvents' "$TP_SWIFT" \
    && grep -Fq 'ignoresMouseEvents = true' "$TP_SWIFT" \
    && grep -Fq 'NSWindow.Level.statusBar.rawValue + 1' "$TP_SWIFT" \
    && grep -Fq 'canJoinAllSpaces' "$TP_SWIFT" \
    && grep -Fq 'fullScreenAuxiliary' "$TP_SWIFT" \
    && grep -Fq 'hidesOnDeactivate = false' "$TP_SWIFT" \
    && grep -Fq 'TRUSTPROMPTAUDIT' "$TP_SWIFT" \
    && grep -Fq 'NSApp.activate()' "$TP_SWIFT" \
    && grep -Fq 'TRUST prompt merged' "$TP_SWIFT" \
    && grep -Fq 'TRUST prompt dismissed unanswered (→ distrust)' "$TP_SWIFT" \
    && grep -Fq 'trust.ask.message' "$TP_SWIFT" \
    && grep -Fq 'trust.ask.accept' "$TP_SWIFT" \
    && grep -Fq 'trust.ask.decline' "$TP_SWIFT" \
    && ! grep -Fq 'NSApp.runModal' "$TP_SWIFT" \
    && ! grep -Fq 'styleMask: [.titled, .closable]' "$TP_SWIFT"; then
    pass "I2 prompt (wave1r10d): non-modal + app self-lock (monitor / ignoresMouseEvents) + level 26 re-assert + activate + coalescing + M1 (no runModal)"
else
    fail "I2: trust prompt controller incomplete"
fi
if grep -Fq 'func trustPromptAnswered(deviceID: String, trusted: Bool)' "$LC_SWIFT" \
    && grep -Fq 'TRUST event ignored (pin off)' "$LC_SWIFT" \
    && grep -Fq 'presentTrustPrompt' "$LC_SWIFT"; then
    pass "decision layer: event→prompt (PIN gate) + answer→keep/remove (a single decision in the coordinator)"
else
    fail "decision layer: coordinator trust wiring incomplete"
fi

# ④/I6: the registry store + the ONE write-side handler (shared by ✕ / Reset / the prompt).
if [ -f "$STORE_SWIFT" ] \
    && grep -Fq 'public func entries() -> [Entry]' "$STORE_SWIFT" \
    && grep -Fq 'public func remove(deviceID: String) throws -> RemovalReport' "$STORE_SWIFT" \
    && grep -Fq 'public func reset() throws' "$STORE_SWIFT" \
    && grep -Fq 'options: .atomic' "$STORE_SWIFT" \
    && grep -Fq 'maxSplits: 2' "$STORE_SWIFT"; then
    pass "I3 store: tolerant read / remove (the other lines kept as-is) / reset (truncate) / atomic write (temp→rename)"
else
    fail "I3: TrustRegistryStore incomplete"
fi
if [ -f "$HANDLER_SWIFT" ] \
    && grep -Fq 'func keep(deviceID: String, origin: String)' "$HANDLER_SWIFT" \
    && grep -Fq 'func removeDevice(machineCode: String, origin: String) -> Bool' "$HANDLER_SWIFT" \
    && grep -Fq 'func resetAll(origin: String, rows: Int) -> Bool' "$HANDLER_SWIFT"; then
    pass "I6 writer: TrustRegistryHandler (single writer; file writes only + effective removal reported as Bool)"
else
    fail "I6: TrustRegistryHandler missing"
fi

# wave1r6 ①: the pending-apply gate + apply paths + PIN rotation + spawn clear.
if grep -Fq 'private(set) var trustRegistryDirty' "$LC_SWIFT" \
    && grep -Fq 'markTrustRegistryDirty' "$LC_SWIFT" \
    && grep -Fq 'applyTrustRegistryIfGated' "$LC_SWIFT" \
    && grep -Fq 'performTrustApply(gate:' "$LC_SWIFT" \
    && grep -Fq 'TRUST apply held' "$LC_SWIFT" \
    && grep -Fq 'TRUST apply dropped' "$LC_SWIFT" \
    && grep -Fq 'TRUST apply deferred' "$LC_SWIFT" \
    && grep -Fq 'TRUST apply gate=' "$LC_SWIFT" \
    && grep -Fq 'TRUST pending cleared at spawn' "$LC_SWIFT" \
    && grep -Fq 'rotateTrustPin' "$LC_SWIFT" \
    && grep -Fq 'TRUST pin-rotate applied' "$LC_SWIFT"; then
    pass "R6 gate: dirty flag + disconnect gate (held/apply/deferred/dropped) + PIN rotation + clear at spawn"
else
    fail "R6: coordinator apply gate incomplete"
fi
if grep -Fq 'coordinator.trustPinRotator' "$CR_SWIFT" \
    && grep -Fq 'func trustDeviceRemoved(machineCode: String)' "$LC_SWIFT" \
    && grep -Fq 'func trustResetRequested(rows: Int)' "$LC_SWIFT"; then
    pass "R6 wiring: three removal entry points→dirty; trustPinRotator = changePin (the change mechanism)"
else
    fail "R6: removal wiring / pin rotator injection incomplete"
fi

# ⑤ wave1r6: the editor rebuilds IN PLACE (the visible view updates immediately) + live-view seams.
if grep -Fq 'onTrustDeviceRemove' "$PW_SWIFT" \
    && grep -Fq 'onTrustReset' "$PW_SWIFT" \
    && grep -Fq 'populateTrustStack' "$PW_SWIFT" \
    && grep -Fq 'trustAccessoryStack' "$PW_SWIFT" \
    && grep -Fq 'views rebuilt in place' "$PW_SWIFT" \
    && grep -Fq 'liveTrustRowCodesForTesting' "$PW_SWIFT" \
    && grep -Fq 'pressLiveTrustRowForTesting' "$PW_SWIFT" \
    && grep -Fq 'renderTrustEditorSnapshotForTesting' "$PW_SWIFT" \
    && ! grep -Fq 'wiring pending' "$PW_SWIFT"; then
    pass "R6 editor: rebuilt in place (populateTrustStack) + on-screen live-view seams (live-rows/live-press/render)"
else
    fail "R6 editor: in-place rebuild / live-view seams missing"
fi
if grep -Fq 'TrustRegistryStore(regPath: KeyVault().regPath)' "$CR_SWIFT" \
    && grep -Fq 'TrustRegistryHandler(store: trustRegistryStore)' "$CR_SWIFT" \
    && grep -Fq 'coordinator.trustRegistry = trustRegistry' "$CR_SWIFT" \
    && grep -Fq 'trustDevicesProvider:' "$CR_SWIFT" \
    && grep -Fq 'trustDevicesProvider:' "$SI_SWIFT" \
    && grep -Fq 'auditTrustEditorLiveRowsForTesting' "$SI_SWIFT"; then
    pass "⑤ full injection chain: CompositionRoot (store→handler→coordinator; provider→StatusItemMenu→window)"
else
    fail "⑤ wiring chain incomplete (CompositionRoot/StatusItemMenu)"
fi

# harness: the trust timelines + env branches + the raw-log injectors.
if grep -Fq 'MIRRORBOARD_UITEST_TRUST' "$AD_SWIFT" \
    && grep -Fq 'func runTrust(coordinator: LifecycleCoordinator)' "$UTD_SWIFT" \
    && grep -Fq 'func runTrustHant(coordinator: LifecycleCoordinator)' "$UTD_SWIFT" \
    && grep -Fq 'injectLaunchLogLine' "$UTD_SWIFT" \
    && grep -Fq 'trustRecord(name:' "$UTD_SWIFT" \
    && grep -Fq 'connectRecord(socket:' "$UTD_SWIFT" \
    && grep -Fq 'closeRecord(socket:' "$UTD_SWIFT"; then
    pass "harness: TRUST=1/2 branches + runTrust sequence + raw launch.log injector (register/connect/close)"
else
    fail "harness: trust timelines missing"
fi

# Terminology discipline (§2.7) + dictionary keys.
if grep -Fq 'trust.ask.windowTitle' "$TERMS_JSON" && grep -Fq 'trust.ask.title' "$TERMS_JSON" \
    && grep -Fq 'trust.ask.message' "$TERMS_JSON" && grep -Fq 'trust.ask.accept' "$TERMS_JSON" \
    && grep -Fq 'trust.ask.decline' "$TERMS_JSON" \
    && ! grep -Eq '阻擋|拒絕連線|放行' "$TERMS_JSON"; then
    pass "dictionary: 5 trust.ask keys present; banned wording (block / refuse connection / allow) fully gone"
else
    fail "terms: trust.ask keys missing or banned wording present"
fi
TERM_COUNT="$(python3 -c "
import json
print(len(json.load(open('$TERMS_JSON'))['terms']))
")"
if [ "$TERM_COUNT" = "51" ]; then
    pass "dictionary: term count = 51 (45 + trust.ask 5 + about.source)"
else
    fail "dictionary: term count = ${TERM_COUNT} (expected 51)"
fi

# red lines: zero contact with uxplay, the guard untouched.
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
# wave1r5 rename batch: in-file comment literals were updated with the bundle id (the wave1r5 task card's red-line meaning
# = "zero logical change"); compare the HEAD version and the working version line by line (comments stripped); no difference passes.
if diff <(git -C "$PROJ" show HEAD:app/Sources/AppShell/SingletonGuard.swift | grep -v '^[[:space:]]*//') \
        <(grep -v '^[[:space:]]*//' "$PROJ/app/Sources/AppShell/SingletonGuard.swift") >/dev/null 2>&1; then
    pass "red-line: SingletonGuard.swift logic untouched (zero guard-logic changes; comment lines exempt)"
else
    fail "red-line: SingletonGuard.swift modified beyond comments"
fi

# --- 2. user-state handling + log archive (never destroy evidence) -----------

[ -d "$APPSUP" ] && APPSUP_PREEXISTED=1
if [ -f "$SETTINGS" ]; then
    SETTINGS_PREEXISTED=1
    mv "$SETTINGS" "$RUN/settings.json.prev"
    log "   settings.json pre-existed — moved to run dir (will be restored)"
else
    log "   settings.json absent — fresh-state run"
fi
if [ -f "$REGISTRY" ]; then
    REGISTRY_PREEXISTED=1
    mv "$REGISTRY" "$RUN/registration.list.prev"
    log "   registration.list pre-existed — moved to run dir (will be restored)"
else
    log "   registration.list absent — fresh-state run"
fi
[ -f "$UI_LOG" ] && mv "$UI_LOG" "$RUN/ui.log.prev"
[ -f "$LAUNCH_LOG" ] && mv "$LAUNCH_LOG" "$RUN/launch.log.prev"
if [ -f "$APPSUP/server.pem" ]; then
    SERVER_PEM_SHA_BEFORE="$(shasum -a 256 "$APPSUP/server.pem" | awk '{print $1}')"
    log "   server.pem shasum (before): $SERVER_PEM_SHA_BEFORE"
fi

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

# --- 3b. test helpers (wave1r12): deactivation thief + window probe ------------
# Rebuilt from r10b run output (wave1r10-trustprompt-top/testrun-.../thief.swift +
# window_probe.swift). thief is the cross-process counterpart that makes the app genuinely inactive (the deactivate
# scenario); window_probe reads CGWindowList (this unit does not assert the level, it only leaves evidence).

cat > "$RUN/thief.swift" <<'SWIFT'
import AppKit
import Foundation

// wave1r12 deactivation thief — activates ITSELF citing the given app
// （cooperative activation: activate(from:)）so that app genuinely becomes
// inactive; the trust suite asserts the prompt stays visible (hidesOnDeactivate = NO).
let pidArg: Int32 = CommandLine.arguments.count > 1 ? (Int32(CommandLine.arguments[1]) ?? -1) : -1
final class ThiefDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        if pidArg > 0, let target = NSRunningApplication(processIdentifier: pid_t(pidArg)) {
            let ok = NSRunningApplication.current.activate(from: target, options: [.activateAllWindows])
            print("THIEF activate(from:\(target.localizedName ?? "?") pid=\(pidArg)) -> \(ok)")
        } else {
            print("THIEF target missing")
        }
        fflush(stdout)
    }
}
let app = NSApplication.shared
let thiefDelegate = ThiefDelegate()
app.delegate = thiefDelegate
app.setActivationPolicy(.accessory)
app.run()
SWIFT
THIEF_BIN="$RUN/thief-bin"
if swiftc -O -o "$THIEF_BIN" "$RUN/thief.swift" >"$RUN/thief.compile.log" 2>&1; then
    log "   deactivation thief compiled: $THIEF_BIN"
else
    fail "deactivation thief compile failed (see $RUN/thief.compile.log)"
fi

cat > "$RUN/window_probe.swift" <<'SWIFT'
import CoreGraphics
import Foundation

// window_probe — every on-screen window owned by <pid> from CGWindowList,
// front-to-back order, with layer + alpha + bounds and its list index.
let pids = CommandLine.arguments.dropFirst().compactMap { Int32($0) }
guard !pids.isEmpty else { print("usage: window_probe <pid> [pid2 ...]"); exit(2) }
guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
    print("probe-unavailable"); exit(3)
}
var index = -1
for w in rawList {
    index += 1
    guard let ownerPID = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(ownerPID) else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let alpha = w[kCGWindowAlpha as String] as? Double ?? -1.0
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("idx=\(index) pid=\(ownerPID) layer=\(layer) alpha=\(alpha) bounds=\(bounds)")
}
print("probe-done")
SWIFT
WPROBE_BIN="$RUN/window_probe"
if swiftc -O -o "$WPROBE_BIN" "$RUN/window_probe.swift" >"$RUN/window_probe.compile.log" 2>&1; then
    log "   window probe compiled: $WPROBE_BIN"
else
    fail "window probe compile failed (see $RUN/window_probe.compile.log)"
fi
THIEF_PID=""

# --- 4. phase A: fixture + launch --------------------------------------------

mkdir -p "$APPSUP"
{
    printf '%s,%s,%s\n' "$PKA" "$DEV_A" "測試機甲"
    printf '%s,%s,%s\n' "$PKB" "$DEV_B" "測試機乙"
    printf '%s,%s,%s\n' "$PKC" "$DEV_C" "測試機丙"
    printf '%s,%s,%s\n' "$PKD" "$DEV_D" "測試機丁, 含逗號"
    printf '%s,%s,%s\n' "$PKE" "$DEV_E" "測試機戊"
    printf '%s,%s,%s\n' "$PKC" "$DEV_C" "測試機丙（舊）"
    printf 'malformed-short-line\n'
    printf '\n'
} > "$REGISTRY"
cp "$REGISTRY" "$RUN/registration.list.fixture"
if [ "$(file_lines)" = "8" ]; then
    pass "fixture: 8 lines (6 valid + 1 duplicate + 1 bad line + 1 empty line)"
else
    fail "fixture write failed (lines=$(file_lines))"
fi

rm -f "$SCRATCH/deactivate-done" "$UI_LOG" "$LAUNCH_LOG" 2>/dev/null
rm -rf "$SCRATCH/Thief.app" 2>/dev/null

# The bundle's console is the testkit's $TEST_APP_CONSOLE; point it at this
# phase's evidence file so the failure messages below stay truthful.
TEST_APP_CONSOLE="$RUN/app.stdout.phase-a.log"
export TEST_APP_CONSOLE
MIRRORBOARD_UITEST_TRUST=1 testkit_launch
APP_PID="${TEST_APP_PID:-}"
sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "phase A: launch ok (pid $APP_PID)"
else
    fail "phase A: launch failed — see $RUN/app.stdout.phase-a.log"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    exit 1
fi

# --- 5. ① PIN-off gate + I1 parsing --------------------------------------------

wait_for_line "UITEST trust armed (phase A)" 15 \
    && pass "phase A: harness armed" \
    || fail "phase A: harness never armed"

wait_for_count "$UI_LOG" "TRUST event registered new client name=測試機零 deviceID=00:00:00:00:00:00" 1 15 \
    && pass "I1: the two raw records are parsed (name + deviceID captured explicitly; PIN off scene)" \
    || fail "I1: register record not parsed (pin-off injection)"
wait_for_count "$UI_LOG" "TRUST event ignored (pin off) deviceID=00:00:00:00:00:00" 1 8 \
    && pass "① PIN off = not shown, no effect (event ignored)" \
    || fail "PIN-off gate missing"
if [ "$(count_in 'TRUST prompt presented name=測試機零' "$UI_LOG")" = "0" ]; then
    pass "① PIN off: zero prompts (測試機零 was never presented)"
else
    fail "PIN-off gate leaked a prompt"
fi
if [ "$(count_in 'UITEST trust injected lines=2' "$UI_LOG")" -ge 1 ]; then
    pass "injection: two records (prefix + pk64 continuation) injected into launch.log verbatim"
else
    fail "injection evidence missing"
fi

# --- 5b. ① PIN off + editor ✕E: the write lands, apply dropped (zero restart) ---

wait_for_line "PREFS trust editor presented (rows=5)" 12 \
    && pass "⑤ editor rows=5 (registry real values + dedupe: C×2→1, A B D E)" \
    || fail "editor rows wrong (expected 5)"
wait_for_line "PREFS trust editor live-rows=5 codes=[$DEV_A,$DEV_B,$DEV_C,$DEV_D,$DEV_E]" 8 \
    && pass "⑤ live view: live-rows=5 (read from the view tree; five ✕ present)" \
    || fail "live view rows (before ✕E) missing"
wait_for_line "PREFS trust remove requested code=$DEV_E" 8 \
    && pass "⑤ ✕ submitted (code=E; live-view seam)" \
    || fail "row ✕ never fired"
wait_for_line "TRUST remove origin=editor deviceID=$DEV_E removed=1 kept=5 dropped=2" 8 \
    && pass "⑤ ✕ = removal (same writer; origin=editor; bad/empty lines cleaned)" \
    || fail "editor removal line missing/wrong"
wait_for_line "TRUST pending set origin=editor" 8 \
    && pass "R6 pending: removal written to the file→pending flag raised" \
    || fail "pending set line missing"
wait_for_line "TRUST apply dropped origin=editor (pin off — no trust semantics)" 8 \
    && pass "R6 dropped: PIN off = no trust semantics (zero restarts; the file loads at the next spawn with PIN on)" \
    || fail "apply-dropped (pin off) line missing"
wait_for_line "PREFS trust editor refreshed (rows=4)" 8 \
    && pass "⑤ rows refresh immediately after removal (rows=4)" \
    || fail "editor row refresh missing"
wait_for_line "PREFS trust editor views rebuilt in place (rows=4)" 8 \
    && pass "⑤ rebuilt in place (the on-screen sheet really updates; not a swap)" \
    || fail "in-place rebuild line missing"
wait_for_line "PREFS trust editor live-rows=4 codes=[$DEV_A,$DEV_B,$DEV_C,$DEV_D]" 8 \
    && pass "⑤ live view: the E row is gone from the view tree (live-rows=4, codes checked one by one)" \
    || fail "live view rows (after ✕E) missing"
wait_for_line "PREFS trust live-press miss code=$DEV_E (row not on screen)" 8 \
    && pass "⑤ clicking the same spot again = miss (the old button is no longer in the view tree — YC double-click regression)" \
    || fail "live-press miss missing"
if [ "$(count_in "PREFS trust remove requested code=$DEV_E" "$UI_LOG")" = "1" ]; then
    pass "⑤ regression: remove requested exactly 1 time (the second click triggers nothing)"
else
    fail "regression: clicking ✕ again still triggers remove (count=$(count_in "PREFS trust remove requested code=$DEV_E" "$UI_LOG"))"
fi
if [ "$(file_lines)" = "5" ] && [ "$(count_in "$DEV_E" "$REGISTRY")" = "0" ]; then
    pass "④ file layer: 5 lines (the E row removed, the rest as-is)"
else
    fail "registry after ✕E wrong (lines=$(file_lines))"
fi
snapshot_registry "after-remove-e"
if [ "$(count_in 'ACTION settings-changed (restart)' "$UI_LOG")" = "0" ] \
    && [ "$(count_in 'TRUST apply gate=' "$UI_LOG")" = "0" ]; then
    pass "R6: removing with PIN off triggers no apply action (settings restart=0, apply=0)"
else
    fail "pin-off removal triggered unintended actions"
fi

# Arm the registry sampler for the ③ keep check below: it copies the shared file
# the instant the keep line appears. Reading the file later is what made that
# assertion read phase ⑥'s state (the file is rewritten ~5s after the keep).
start_registry_sampler "after-keep" "TRUST keep origin=prompt deviceID=$DEV_A (remember — registry untouched)"

# --- 6. ②③ two rounds of A connecting + the wave1r10d probe (interleaved; rebuilt from r10b §8) ---
#
# YC's ruling, route ①: TrustPrompt does not use the system modal (no runModal) — the app locks itself (level 26
# + a local event monitor swallowing events for non-prompt windows). The probe uses app-side log patterns
# to observe (the three posted-click legs / a real deactivate / a real event answer / the lock swallowing events), and
# TRUSTPROMPTAUDIT level=26 is the runtime evidence for "always on top".

# 6a. A is presented
wait_for_count "$UI_LOG" "TRUST prompt presented name=測試機甲 deviceID=$DEV_A" 1 15 \
    && pass "② prompt: presented the moment pairing succeeds (測試機甲)" \
    || fail "trust prompt never presented for A"

# 6a-3. runtime evidence for the app-side lock + level 26 (the core contract of route ①)
wait_for_count "$UI_LOG" "TRUST prompt lock engaged (app-side lock" 1 12 \
    && pass "⑧ app self-lock: lock engaged (local event monitor; events for non-prompt windows are swallowed)" \
    || fail "⑧ app self-lock: lock never engaged"
# wave1r10e (weak assertion, reviewer Findings-3): the lock's "other windows ignoresMouseEvents
# mask" behaviour had zero assertions before (only a static literal grep). It asserts maskedWindows≥1 (weak: not pinned
# to an exact value; while locked the panel / prefs and other windows must exist ⇒ zero risk).
MASKED_N="$(grep -Eo 'lock engaged \(app-side lock.*maskedWindows=[0-9]+' "$UI_LOG" 2>/dev/null | tail -1 | sed -E 's/.*maskedWindows=([0-9]+)/\1/')"
if [ -n "$MASKED_N" ] && [ "$MASKED_N" -ge 1 ] 2>/dev/null; then
    pass "⑧ app self-lock: the other windows are masked (maskedWindows=$MASKED_N ≥1; behavioural assertion)"
else
    fail "⑧ app self-lock: maskedWindows ineffective (='$MASKED_N')"
fi
wait_for_count "$UI_LOG" "TRUST prompt lock liveness" 1 8 \
    && pass "⑧ app self-lock: main-queue liveness while locked (the disconnect-apply / write pipeline is not blocked)" \
    || fail "⑧ app self-lock: liveness line missing"
wait_for_count "$UI_LOG" "TRUSTPROMPTAUDIT level=26" 1 12 \
    && pass "⑧ always on top: TRUSTPROMPTAUDIT level=26 (no modal-session override; re-asserted on every show)" \
    || fail "⑧ prompt level never reached 26"
wait_for_count "$UI_LOG" "closable=0 closeButton=absent canJoinAllSpaces=1 fullScreenAuxiliary=1 hidesOnDeactivate=0" 1 8 \
    && pass "⑧ no close button + joins all spaces + full-screen auxiliary + never hides (audit column by column)" \
    || fail "⑧ prompt audit fields wrong"
wait_for_count "$UI_LOG" "locked=1" 1 8 \
    && pass "⑧ app self-lock: audit locked=1" \
    || fail "⑧ prompt audit never showed locked=1"

# 6a-2. deactivate handshake watchdog (non-blocking): as soon as the scenario is armed, start thief + touch the marker.
#       the app deletes the marker when it arms (runDeactivateScenario), so touch it only after armed.
( for _ in $(seq 1 300); do
    grep -Fq "UITEST deactivate scenario armed" "$UI_LOG" 2>/dev/null && break
    sleep 0.1
  done
  if [ -n "$APP_PID" ] && [ -x "$THIEF_BIN" ]; then
      "$THIEF_BIN" "$APP_PID" >"$RUN/thief.log" 2>&1 &
      echo "$!" > "$RUN/thief.pid"
      sleep 0.4
      touch "$SCRATCH/deactivate-done"
  fi
) &
DEACT_WATCHER=$!

# 6b. probe control leg (prefs apply; the app-side UITestDriver r10b probe) + probe-dirt
wait_for_line "UITEST prefs-apply-click posted leg=control" 15 \
    && pass "⑧ probe: control leg posted a click (prefs Apply; injection-method control group)" \
    || fail "⑧ probe: control leg never posted"
wait_for_line "ACTION prevent-sleep off (shell-held, no restart)" 8 \
    && pass "⑧ probe: control click triggers (apply works — the injection method is trustworthy; truth on→off counts as dirty)" \
    || fail "⑧ probe: control click did not fire (probe-dirt missing)"

# 6c. real deactivate scenario (handshake outcome: scenario armed → active=0∧visible=1 → reactivated)
wait_for_line "UITEST deactivate scenario armed" 10 \
    && pass "⑧ deactivate: scenario armed (cross-process handshake start)" \
    || fail "⑧ deactivate: scenario never armed"
wait_for_line "TRUST prompt deactivate probe active=0 visible=1" 12 \
    && pass "⑧ deactivate: under a real deactivation active=0 ∧ visible=1 (hidesOnDeactivate=NO; proven by the thief)" \
    || fail "⑧ deactivate: active=0 ∧ visible=1 never observed"

# 6d. render EN (after the deactivate settles)
wait_for_count "$UI_LOG" "TRUST prompt snapshot $SCRATCH/trust-prompt-en.png" 1 10 \
    && pass "② render: trust-prompt-en.png (EN acceptance image)" \
    || fail "EN prompt render missing"
wait_for_count "$UI_LOG" "LANGAUDIT trust lang=en title=Trust this device? message=Trust “測試機甲”? accept=Trust decline=Don't Trust visible=1" 1 8 \
    && pass "② rendered strings (EN): title/message (remember semantics) / Trust / Don't Trust / visible=1" \
    || fail "EN prompt audit missing/wrong"
wait_for_line "UITEST reactivated active=1" 10 \
    && pass "⑧ deactivate: reactivated (active=1; the sequence continues)" \
    || fail "⑧ deactivate: reactivation never observed"
# thief steps down (so it does not grab the foreground and block the posted click)
if [ -f "$RUN/thief.pid" ]; then
    THIEF_PID="$(cat "$RUN/thief.pid" 2>/dev/null)"
    [ -n "$THIEF_PID" ] && kill "$THIEF_PID" 2>/dev/null; THIEF_PID=""
fi

# 6e. probe locked leg (posted while the app lock is on; swallowed by the monitor) + evidence of the swallow
wait_for_line "UITEST prefs-apply-click posted leg=locked" 12 \
    && pass "⑧ probe: locked leg posted (during the app self-lock; same click)" \
    || fail "⑧ probe: locked leg never posted"
wait_for_count "$UI_LOG" "TRUST prompt lock swallowed event" 1 8 \
    && pass "⑧ app self-lock: a posted click on a non-prompt window is swallowed (the monitor intercepts it; zero leakage)" \
    || fail "⑧ app self-lock: no swallowed-event evidence"

# 6f. a repeated event from the same device = merged (no second prompt)
wait_for_count "$UI_LOG" "TRUST prompt merged (same device) deviceID=$DEV_A" 1 8 \
    && pass "② duplicate events from the same device = coalesced (no second prompt)" \
    || fail "same-device merge evidence missing"
if [ "$(count_in "TRUST prompt presented name=測試機甲" "$UI_LOG")" = "1" ]; then
    pass "② still one prompt after coalescing (presented count=1)"
else
    fail "merge leaked a second presentation"
fi

# 6g. click-answer: A goes through the real posted-click path (the trust button)
wait_for_line "UITEST trust-click posted" 12 \
    && pass "⑧ click-answer: trust click posted (REAL event path)" \
    || fail "⑧ click-answer: trust click never posted"
wait_for_count "$UI_LOG" "TRUST prompt answered trust deviceID=$DEV_A via=button" 1 8 \
    && pass "⑧ click-answer: A answers trust (via=button; the posted click lands)" \
    || fail "⑧ click-answer: A trust answer missing"
# wave1r10e anti-false-green (reviewer Findings-1, High): the silent fallback used when a posted click
# does not land must not pass for a real landing. Double binding —
#   ① negative assertion (the original gap): the `trust-click ANSWER MISSED` count must be 0 (else fail).
#   ② distinguishable: the fallback exit now prints via=fallback while a real landing keeps via=button ⇒ the above
#      via=button assertion must fail in a fallback case (even if ① is bypassed).
# sleep 1.5s (> the 1.2s grace) so the MISSED timer has a chance to fire before absence is judged (no race false-green).
sleep 1.5
if [ "$(count_in 'UITEST trust-click ANSWER MISSED' "$UI_LOG")" = "0" ]; then
    pass "⑧ click-answer anti-false-green: zero fallbacks (trust-click ANSWER MISSED ×0; a real posted click lands)"
else
    fail "⑧ click-answer anti-false-green: the posted click did not land→the silent fallback fired (ANSWER MISSED ×$(count_in 'UITEST trust-click ANSWER MISSED' "$UI_LOG"))"
fi

# 6h. F queues up (injected while A is visible) → it takes over the prompt → trust answered (keep)
wait_for_count "$UI_LOG" "TRUST prompt presented name=測試機己 deviceID=$DEV_F" 1 12 \
    && pass "⑧ serialisation: F takes over the presentation (after A settles)" \
    || fail "⑧ serialisation: F never presented"
wait_for_count "$UI_LOG" "TRUST keep origin=prompt deviceID=$DEV_F (remember — registry untouched)" 1 8 \
    && pass "⑧ F answers trust (keep; no action)" \
    || fail "⑧ F keep missing"

# 6i. probe post-lock leg (the app lock has settled) → trigger (switch back on)
wait_for_line "UITEST prefs-apply-click posted leg=post-lock" 12 \
    && pass "⑧ probe: post-lock leg posted (the self-lock has settled)" \
    || fail "⑧ probe: post-lock leg never posted"

# 6j. keep path: the registry is unchanged (A is still there)
wait_for_count "$UI_LOG" "TRUST keep origin=prompt deviceID=$DEV_A (remember — registry untouched)" 1 8 \
    && pass "③ answering Trust = no action (TRUST keep; the registry stays)" \
    || fail "trust answer did not take the keep path"
# Sample AT the keep line instead of afterwards (the sampler was armed before the
# A click). The keep path writes nothing, but phase ⑥ rewrites the shared file ~5s
# later: the old form read the file whenever the shell got here, which on a lagging
# run was after ⑥'s removal (observed 5→4→0 lines across runs).
stop_registry_sampler
KEEP_SAMPLE="$RUN/registration.list.after-keep"
KEEP_SAMPLE_LINES="none"
[ -f "$KEEP_SAMPLE" ] && KEEP_SAMPLE_LINES="$(wc -l < "$KEEP_SAMPLE" | tr -d ' ')"
KEEP_SAMPLE_SHA="$(shasum -a 256 "$KEEP_SAMPLE" 2>/dev/null | awk '{print $1}')"
PRE_KEEP_SHA="$(shasum -a 256 "$RUN/registration.list.after-remove-e" 2>/dev/null | awk '{print $1}')"
if [ "$KEEP_SAMPLE_LINES" = "5" ] && [ "$(count_in "$DEV_A" "$KEEP_SAMPLE")" = "1" ] \
    && [ -n "$KEEP_SAMPLE_SHA" ] && [ "$KEEP_SAMPLE_SHA" = "$PRE_KEEP_SHA" ]; then
    pass "③ file layer: registry untouched at the keep moment (5 lines; byte-identical to the pre-keep file; 測試機甲 still there)"
else
    fail "keep path touched the registry (sampled at the keep line: lines=$KEEP_SAMPLE_LINES sha=$KEEP_SAMPLE_SHA)"
fi
log "   [evidence] registry as it stood at the keep line: $KEEP_SAMPLE"

# --- 7. ④ distrust (while disconnected) = corner apply + PIN rotation + spawn #3 --

wait_for_count "$UI_LOG" "TRUST prompt presented name=測試機甲 deviceID=$DEV_A" 2 10 \
    && pass "③ every untrusted connection (re-pairing) asks again (second presentation)" \
    || fail "re-ask after keep missing"
wait_for_count "$UI_LOG" "TRUST prompt answered distrust deviceID=$DEV_A via=button" 1 8 \
    && pass "③ Declined trust = explicit answer (via=button)" \
    || fail "distrust answer evidence missing"
wait_for_line "TRUST remove origin=prompt deviceID=$DEV_A removed=1 kept=4 dropped=0" 8 \
    && pass "③ removal: the target line is deleted (removed=1) + 4 valid lines left" \
    || fail "distrust removal line missing/wrong"
wait_for_line "TRUST pending set origin=prompt" 8 \
    && pass "R6 pending: removal→pending (origin=prompt)" \
    || fail "pending set (prompt) missing"
wait_for_line "TRUST apply gate=immediate restart=1 pin-rotated=1" 8 \
    && pass "R6 corner apply: no connection left at answer time→apply immediately (E1 restart; gate=immediate)" \
    || fail "corner apply (gate=immediate) missing"
wait_for_line "TRUST pin-rotate applied (immediate)" 8 \
    && pass "R6 rotation: the apply event rotates the PIN automatically (reusing the change mechanism)" \
    || fail "pin-rotate (immediate) missing"
wait_for_count "$LAUNCH_LOG" "MIRRORBOARD SPAWN pid=" 2 12 \
    && pass "R6 restart: corner apply→spawn #3 (registry reloaded)" \
    || fail "spawn #3 never appeared"
wait_for_count "$UI_LOG" "TRUST pending cleared at spawn (registry reloaded)" 1 8 \
    && pass "R6 takes effect: the restarted spawn loads the new file (pending cleared at spawn)" \
    || fail "pending-cleared-at-spawn missing"

# launch.log is truncated on every fresh start (start#2) — its first line is spawn #2.
wait_for_count "$LAUNCH_LOG" "lists 5 pin-registered clients" 1 20 \
    && pass "R6 file layer: spawn #2 boot line lists 5 (the 5-line new file after E was removed, really read)" \
    || fail "spawn #2 boot did not load the fixture registry (lists 5 missing)"
C0="$(pin_of_spawn 1)"
C1="$(pin_of_spawn 2)"
assert_pin_diff "④ spawn #2→#3" "$C0" "$C1"
wait_for_count "$LAUNCH_LOG" "lists 4 pin-registered clients" 1 20 \
    && pass "R6 file layer: spawn #3 boot line lists 4 (the post-removal file was really read by uxplay)" \
    || fail "spawn #3 boot did not load the new registry (lists 4 missing)"
if [ "$(file_lines)" = "4" ] && [ "$(count_in "$DEV_A" "$REGISTRY")" = "0" ] \
    && [ "$(count_in "$DEV_B" "$REGISTRY")" = "1" ]; then
    pass "④ file layer: the A row removed, the B row kept (4 lines)"
else
    fail "registry after distrust-A wrong (lines=$(file_lines))"
fi
snapshot_registry "after-distrust-a"

# --- 8. ⑤ C connects (socket 10) + trust (keep); a connect event opens no prompt ---

wait_for_count "$LAUNCH_LOG" "CONNECTION 測試機丙" 1 10 \
    && pass "⑤ connection events flow as usual (CONNECTION 測試機丙; socket 10 accept + request)" \
    || fail "⑤ connection event (C, socket 10) wait failed"
wait_for_count "$UI_LOG" "TRUST prompt presented name=測試機丙 deviceID=$DEV_C" 1 10 \
    && pass "⑤ 測試機丙 presented" \
    || fail "prompt for C missing"
wait_for_count "$UI_LOG" "TRUST keep origin=prompt deviceID=$DEV_C (remember — registry untouched)" 1 8 \
    && pass "⑤ answering Trust = keep (C; no action)" \
    || fail "keep for C missing"
wait_for_count "$UI_LOG" "NOTIFY connected message=Connected to 測試機丙" 1 10 \
    && pass "⑤ non-pairing connection events flow as usual (NOTIFY connected)" \
    || fail "plain connection line never processed"
if [ "$(count_in "TRUST prompt presented name=測試機丙" "$UI_LOG")" = "1" ]; then
    pass "⑤ connection event ≠ pairing event: zero new prompts (isomorphic evidence for a trusted re-connection needing no code and showing no prompt)"
else
    fail "a plain connection raised an extra prompt"
fi

# --- 9. ⑥ B answers with ESC (= distrust) + held while mirroring (nobody kicked) ---
# wave1r12: B answers with a real key press (ESC) = distrust (r10b app: trEscapeBAt → pressEscape;
# ESC maps to distrust, via=button). It no longer takes the M1 "programmatic close" path.

wait_for_count "$UI_LOG" "TRUST prompt presented name=測試機乙 deviceID=$DEV_B" 1 10 \
    && pass "⑥ 測試機乙 presented" \
    || fail "prompt for B missing"
wait_for_line "UITEST trust-esc posted" 8 \
    && pass "⑥ ESC: real key post (prompt B; r10b real event path)" \
    || fail "ESC post evidence missing"
wait_for_line "TRUST prompt answered distrust deviceID=$DEV_B via=button" 8 \
    && pass "⑥ ESC = distrust (answer distrust; the ESC→distrust mapping lands)" \
    || fail "ESC-answer (distrust) evidence missing"
# wave1r10e anti-false-green (same treatment for the ESC item): the silent fallback used when a posted ESC
# does not land must not pass for a real key press. Negative assertion: the `trust-esc ANSWER MISSED` count must be 0 (else fail);
# distinguishable: the fallback exit now prints via=fallback (a real key press keeps via=button ⇒ the above must fail).
sleep 1.5
if [ "$(count_in 'UITEST trust-esc ANSWER MISSED' "$UI_LOG")" = "0" ]; then
    pass "⑥ ESC anti-false-green: zero fallbacks (trust-esc ANSWER MISSED ×0; a real key post lands)"
else
    fail "⑥ ESC anti-false-green: the posted ESC did not land→the silent fallback fired (ANSWER MISSED ×$(count_in 'UITEST trust-esc ANSWER MISSED' "$UI_LOG"))"
fi
wait_for_line "TRUST remove origin=prompt deviceID=$DEV_B removed=1 kept=3 dropped=0" 8 \
    && pass "⑥ ESC → removal written to the file (the B row removed; kept=3)" \
    || fail "ESC removal line missing/wrong"
wait_for_line "TRUST apply held origin=prompt live=1 (connected; awaits disconnect)" 8 \
    && pass "R6 held: removal during projection is not force-applied (wait for disconnect; red line respected)" \
    || fail "connected-held line missing"
# Window sampling: "nothing restarted while held" is only observable INSIDE the
# held window — from the held line to the apply the disconnect legitimately fires
# (⑦). The old form counted every `TRUST apply gate=` line in the whole log and
# expected 1, so ⑦'s legal apply (0.8s later) could not avoid turning it red; a
# restart stolen while held would print its own apply line inside this window.
HELD_AT="TRUST apply held origin=prompt live=1 (connected; awaits disconnect)"
HELD_WINDOW_ENDS_AT="TRUST apply gate=disconnect restart=1 pin-rotated=1"
wait_window_end "$UI_LOG" "$HELD_AT" "$HELD_WINDOW_ENDS_AT" 12
HELD_APPLIES="$(count_between "$UI_LOG" "$HELD_AT" "$HELD_WINDOW_ENDS_AT" 'TRUST apply gate=')"
if [ "$HELD_APPLIES" = "0" ]; then
    pass "R6: zero new restarts inside the held window (held line → the disconnect apply: apply=0)"
else
    fail "held removal fired a restart inside the held window (apply=$HELD_APPLIES between the held line and the disconnect apply)"
fi
if [ "$(file_lines)" = "3" ]; then
    pass "④ file layer: 3 lines (C×2 + D)"
else
    fail "registry after dismiss-B wrong (lines=$(file_lines))"
fi
snapshot_registry "after-dismiss-b"

# --- 10. ⑦ disconnect = apply (socket 10 closes→gate=disconnect→spawn #4) + panel rotation trace ---

wait_for_line "TRUST apply gate=disconnect restart=1 pin-rotated=1" 12 \
    && pass "R6 apply on disconnect: the last connection in the scene closes→E1 restart (gate=disconnect)" \
    || fail "disconnect apply missing"
wait_for_line "TRUST pin-rotate applied (disconnect)" 8 \
    && pass "R6 rotation: the disconnect-driven apply rotates the PIN too (disconnect)" \
    || fail "pin-rotate (disconnect) missing"
wait_for_count "$LAUNCH_LOG" "MIRRORBOARD SPAWN pid=" 3 12 \
    && pass "R6 restart: spawn #4" \
    || fail "spawn #4 never appeared"
wait_for_count "$UI_LOG" "TRUST pending cleared at spawn (registry reloaded)" 2 8 \
    && pass "R6 takes effect: the disconnect-triggered restart really loads the new file (cleared=2)" \
    || fail "second pending-cleared missing"
C2="$(pin_of_spawn 3)"
assert_pin_diff "④ spawn #3→#4" "$C1" "$C2"
wait_for_count "$LAUNCH_LOG" "lists 3 pin-registered clients" 1 20 \
    && pass "R6 file layer: spawn #4 boot line lists 3 (the new file after B was removed, really read)" \
    || fail "spawn #4 boot did not load the new registry (lists 3 missing)"
PID_SPAWN3="$(spawn_pid 2)"
PID_SPAWN4="$(spawn_pid 3)"
if [ -n "$PID_SPAWN3" ] && [ -n "$PID_SPAWN4" ] && [ "$PID_SPAWN3" != "$PID_SPAWN4" ]; then
    pass "R6 PID turnover: spawn #3 pid=${PID_SPAWN3} → spawn #4 pid=${PID_SPAWN4} (the reload happens in a new generation)"
else
    fail "spawn PIDs identical or missing (spawn3='$PID_SPAWN3' spawn4='$PID_SPAWN4')"
fi
if wait_for_live_pid_eq "$PID_SPAWN4" 8; then
    pass "R6 live generation alignment: uxplay pid=${PID_SPAWN4} (current generation = spawn #4)"
else
    fail "live uxplay pid $(uxplay_pid) != spawn #4 pid $PID_SPAWN4"
fi
wait_for_line "PANEL snapshot $SCRATCH/panel-pin-rotated.png" 10 \
    && pass "④ render: panel-pin-rotated.png (panel after the rotation)" \
    || fail "panel-pin-rotated render missing"
if [ "$(last_panel_pin_code)" = "$C2" ]; then
    pass "④ panel sync: PANEL pin display code=${C2} (= the -pin of spawn #4)"
else
    fail "panel pin display not synced (last='$(last_panel_pin_code)' expected '$C2')"
fi

# --- 11. ⑤ editor (two devices mirroring): on-screen rebuild + render + re-click miss + Reset ---

wait_for_count "$UI_LOG" "PREFS trust editor presented (rows=2)" 1 12 \
    && pass "⑤ editor rows=2 (registry real values + duplicate dedupe: C×2→1, D)" \
    || fail "editor rows wrong (expected 2)"
wait_for_line "PREFS trust editor live-rows=2 codes=[$DEV_C,$DEV_D]" 8 \
    && pass "⑤ live view: live-rows=2 (the ✕ for C and D are present)" \
    || fail "live view rows (before ✕D) missing"
wait_for_line "PREFS trust editor snapshot $SCRATCH/trust-editor-before-x.png" 8 \
    && pass "④ render: trust-editor-before-x.png (on screen before ✕)" \
    || fail "editor before-x render missing"
wait_for_line "PREFS trust remove requested code=$DEV_D" 8 \
    && pass "⑤ ✕ submitted (code=D; live-view seam)" \
    || fail "row ✕ (D) never fired"
wait_for_line "TRUST remove origin=editor deviceID=$DEV_D removed=1 kept=2 dropped=0" 8 \
    && pass "⑤ ✕ = removal (same writer; origin=editor)" \
    || fail "editor removal (D) line missing/wrong"
wait_for_line "TRUST pending set origin=editor" 8 \
    && pass "R6 pending: editor removal→pending" \
    || fail "pending set (editor) missing"
wait_for_line "TRUST apply held origin=editor live=2 (connected; awaits disconnect)" 8 \
    && pass "R6 held: two devices projecting = not force-applied (live=2)" \
    || fail "two-device held line missing"
wait_for_line "PREFS trust editor refreshed (rows=1)" 8 \
    && pass "⑤ rows refresh immediately after removal (rows=1)" \
    || fail "editor row refresh (D) missing"
wait_for_line "PREFS trust editor views rebuilt in place (rows=1)" 8 \
    && pass "⑤ rebuilt in place (the on-screen sheet really updates)" \
    || fail "in-place rebuild (D) missing"
wait_for_line "PREFS trust editor live-rows=1 codes=[$DEV_C]" 8 \
    && pass "⑤ live view: the D row is gone from the view tree (only C is left)" \
    || fail "live view rows (after ✕D) missing"
wait_for_line "PREFS trust editor snapshot $SCRATCH/trust-editor-after-x.png" 8 \
    && pass "④ render: trust-editor-after-x.png (on screen after ✕)" \
    || fail "editor after-x render missing"
wait_for_line "PREFS trust live-press miss code=$DEV_D (row not on screen)" 8 \
    && pass "⑤ clicking the same spot again = miss (the YC double-click regression is dead at the view layer)" \
    || fail "live-press miss (D) missing"
if [ "$(count_in "PREFS trust remove requested code=$DEV_D" "$UI_LOG")" = "1" ]; then
    pass "⑤ regression: remove requested exactly 1 time (no second removal)"
else
    fail "regression: clicking ✕D again still triggers remove (count=$(count_in "PREFS trust remove requested code=$DEV_D" "$UI_LOG"))"
fi
wait_for_line "PREFS trust reset requested (rows=1)" 8 \
    && pass "⑤ one-click Reset submitted (rows=1)" \
    || fail "reset request missing"
wait_for_line "TRUST reset origin=editor rows=1 removed=1 (file truncated to 0)" 8 \
    && pass "⑤ Reset = truncate (same removal mechanism; removed=1)" \
    || fail "reset write-side line missing/wrong"
wait_for_line "TRUST pending updated origin=editor (cycle already pending)" 8 \
    && pass "R6: a second removal in the same cycle = pending updated (no duplicate gate)" \
    || fail "pending-updated line missing"
wait_for_line "PREFS trust editor live-rows=0 codes=[]" 8 \
    && pass "⑤ live view: empty state after Reset (zero ✕ left)" \
    || fail "live view rows (after reset) missing"
wait_for_line "PREFS trust editor snapshot $SCRATCH/trust-editor-after-reset.png" 8 \
    && pass "④ render: trust-editor-after-reset.png (on screen after Reset)" \
    || fail "editor after-reset render missing"
if [ "$(file_bytes)" = "0" ]; then
    pass "④ file layer: 0 bytes after Reset"
else
    fail "reset did not truncate the file (bytes=$(file_bytes))"
fi
snapshot_registry "after-reset"
if ls -a "$APPSUP" 2>/dev/null | grep -Eq 'dat\.nosync|[.]mb-tmp|write-probe'; then
    fail "atomic-write leftovers (temp/probe) left in AppSupport: $(ls "$APPSUP")"
else
    pass "④ zero atomic-write leftovers (no dat.nosync/tmp/probe)"
fi
wait_for_line "PREFS trust editor dismissed" 8 \
    && pass "⑤ editor collapsed" \
    || fail "editor dismiss missing"

# --- 12. ⑨ census: a socket close is not the device going offline ---
# (fix-socket-census, re-based by fix-socket-census-r1 / review R1)
#
# FIXTURE TRUTH — the census counts SOCKETS, not devices, so the only honest
# "one device, several connections" pair is a pair that shares ONE deviceID:
#   socket 20 = 測試機丙 (deviceID C) — a DIFFERENT device, online throughout ⑨
#   socket 21 = 測試機丁 (deviceID D) — 丁's first TCP connection
#   socket 22 = 測試機丁 (deviceID D) — 丁's second TCP connection, accepted at
#               21.1, i.e. AFTER 丁's real name was already revealed (17.7)
# The window assertion below closes 丁's SECOND socket (22) while 丁's OWN first
# socket is still live: the survivor belongs to the same device, which is exactly
# the case the census claims to handle. Closing 丙's last socket (20) while 丁 is
# live is deliberately NOT asserted in either direction — the set is session-wide
# and a device-level close there is not implemented (device-level accounting =
# review R1 option (a), deferred by PM). Asserting it either way would encode a
# contract the code does not have.
#
# NOTE (review R6): the pre-32bb225 line `TRUST apply held live=1 (disconnect
# gate)` is unreachable BY CONSTRUCTION now — the gate only runs on
# `.disconnected`, which is emitted only when the census drains, so
# `viaDisconnect` never meets `live > 0`. The "another device online must not be
# kicked" red line is therefore anchored on its reachable form: the editor
# removal is held while the session is connected (live=2), and the window from
# that held line to apply #3 carries zero restarts (assertion e below).
#
# Raw lines and the app's own census/state markers all land in launch.log, so the
# causal assertions stay inside one file (one append order).

MULTI_D_REVEAL_AT="CONNECTION 測試機丁"
MULTI_CLOSE_22_AT="Connection closed on socket 22"
MULTI_CLOSE_20_AT="Connection closed on socket 20"
MULTI_CLOSE_21_AT="Connection closed on socket 21"
MULTI_HELD_AT="TRUST apply held origin=editor live=2 (connected; awaits disconnect)"
MULTI_APPLY_AT="TRUST apply gate=disconnect restart=1 pin-rotated=1"
MULTI_SPAWN_AT="MIRRORBOARD SPAWN pid="

# >>> fix-socket-census assertions  (delimiter kept on purpose: the discrimination
# probe (task fix-socket-census-r1) extracts this block verbatim and feeds it
# the pre-fix, 32bb225 and post-fix log shapes)
wait_for_count "$LAUNCH_LOG" "$MULTI_CLOSE_21_AT" 1 14 \
    && pass "⑨ window: 丁 accepted a second connection (22), then 22 / 20 / 21 close (all close lines in launch.log)" \
    || fail "⑨ window: the socket 22/20/21 close lines never landed in launch.log"
wait_for_count "$UI_LOG" "$MULTI_APPLY_AT" 2 14 \
    && pass "R6: all offline→apply (second gate=disconnect)" \
    || fail "second disconnect apply missing"
# (a) the census case, on a pair that really is ONE device: 丁's audio socket 22
# closes while 丁's own first socket (21) is still live → no device-level event.
# (Under the two-device reading this line would be the bug, not the expectation —
# hence the fixture above: 22 and 21 carry the same name AND the same deviceID.)
MID_DISCONNECTS="$(count_between "$LAUNCH_LOG" "$MULTI_CLOSE_22_AT" "$MULTI_CLOSE_20_AT" 'DISCONNECTION ')"
if [ "$MID_DISCONNECTS" = "0" ]; then
    pass "census: 丁's second socket (22) closed while 丁's first (21) was live → zero device-level DISCONNECTION (same deviceID D)"
else
    fail "census: a close of a STILL-CONNECTED device was treated as the device going offline (DISCONNECTION=$MID_DISCONNECTS between close 22 and close 20)"
fi
# (b) positive trace of the socket-level branch: the close is recorded WITH the
# surviving count (20 and 21), i.e. the census was actually consulted.
wait_for_count "$LAUNCH_LOG" "SOCKET closed socket=22 live=2 (device still connected)" 1 10 \
    && pass "census: the close is recorded as socket-level with the survivors counted (live=2) — device still online" \
    || fail "census: no socket-level close trace for the same-device pair (the close handler ignored the census)"
# The window below is closed by the restart the last close legitimately fires:
# wait for that spawn line BEFORE sampling, otherwise `count_between` sees no end
# anchor and reports `no-end` (observed in the first real run of this block).
wait_for_count "$LAUNCH_LOG" "$MULTI_SPAWN_AT" 4 14
# (c) the other direction: the fix must not silence a real disconnect.
LAST_DISCONNECTS="$(count_between "$LAUNCH_LOG" "$MULTI_CLOSE_21_AT" "$MULTI_SPAWN_AT" 'DISCONNECTION ')"
if [ "$LAST_DISCONNECTS" = "1" ]; then
    pass "census: the LAST socket closing is still exactly one device-level disconnect"
else
    fail "census: the last-socket disconnect was lost or duplicated (DISCONNECTION=$LAST_DISCONNECTS after the socket-21 close)"
fi
# (d) one device-level event per SESSION, not per close: three socket closes land
# in this window and exactly one of them may flip the device.
#
# The panel's `STATE waiting` line is NOT usable for this count: `updateState`
# runs from `refreshStatusItem()`, which the `.disconnected` path does not call —
# the line is written by the APPLY (after the `TRUST apply gate=` line), so it
# samples "how often we restarted", not "how often the panel flipped". The
# launch.log disconnects are the flip counter (and the panel renders exactly
# those).
THREE_DISCONNECTS="$(count_between "$LAUNCH_LOG" "$MULTI_CLOSE_22_AT" "$MULTI_SPAWN_AT" 'DISCONNECTION ')"
if [ "$THREE_DISCONNECTS" = "1" ]; then
    pass "census: three socket closes → exactly one device-level DISCONNECTION (the panel leaves connected once)"
else
    fail "census: per-socket flips (DISCONNECTION=$THREE_DISCONNECTS across the three-close window; expected 1)"
fi
# (e) the unchanged R6 red line: nothing restarted while a peer device was
# online (丙's socket 20 closes at 22.0 with 丁 still connected → zero restarts).
MULTI_APPLIES="$(count_between "$UI_LOG" "$MULTI_HELD_AT" "$MULTI_APPLY_AT" 'TRUST apply gate=')"
if [ "$MULTI_APPLIES" = "0" ]; then
    pass "R6: zero restarts while another device was online (held window: apply=0)"
else
    fail "restart fired while another device was connected (apply=$MULTI_APPLIES inside the held window)"
fi
# (f) review R2 — identity must survive a second accept of the same session. The
# accept path carries the placeholder, and 丁's real name is already on the
# panel, so the payload is the pre-R2 regression exactly: a `.connected` that
# falls back to `Unknown Device` (and the extra `.connected` that follows it).
IDENTITY_CHURN="$(count_between "$LAUNCH_LOG" "$MULTI_D_REVEAL_AT" "$MULTI_CLOSE_21_AT" 'CONNECTION ')"
if [ "$IDENTITY_CHURN" = "0" ]; then
    pass "identity: the second accept (socket 22) re-yielded nothing — no fall-back to Unknown Device, no duplicate .connected"
else
    fail "identity: a second accept of the same session churned the panel identity (CONNECTION lines=$IDENTITY_CHURN between 丁's reveal and the last close)"
fi
# <<< fix-socket-census assertions
wait_for_count "$LAUNCH_LOG" "$MULTI_SPAWN_AT" 4 12 \
    && pass "R6 restart: spawn #5" \
    || fail "spawn #5 never appeared"
C3="$(pin_of_spawn 4)"
assert_pin_diff "④ spawn #4→#5" "$C2" "$C3"
wait_for_count "$UI_LOG" "TRUST pending cleared at spawn (registry reloaded)" 3 8 \
    && pass "R6 takes effect: the third cleared at spawn" \
    || fail "third pending-cleared missing"

# --- 13. ⑩ phase A ledger (R6 inversion: apply = restart; the settings channel is not involved) ---

TRUST_APPLIES="$(count_in 'TRUST apply gate=' "$UI_LOG")"
TRUST_HELD="$(count_in 'TRUST apply held' "$UI_LOG")"
TRUST_UPDATED="$(count_in 'TRUST pending updated' "$UI_LOG")"
TRUST_DROPPED="$(count_in 'TRUST apply dropped' "$UI_LOG")"
TRUST_ROTATES="$(count_in 'TRUST pin-rotate applied' "$UI_LOG")"
TRUST_CLEARED="$(count_in 'TRUST pending cleared at spawn' "$UI_LOG")"
SETTINGS_RESTARTS="$(count_in 'ACTION settings-changed (restart)' "$UI_LOG")"
TRUST_SPAWNS="$(spawn_count)"
if [ "$TRUST_APPLIES" = "3" ] && [ "$TRUST_ROTATES" = "3" ]; then
    pass "⑥ ledger: apply 3 (immediate 1 + disconnect 2), rotate 3 (one per apply)"
else
    fail "ledger: applies=$TRUST_APPLIES rotates=$TRUST_ROTATES (expected 3/3)"
fi
if [ "$TRUST_HELD" = "2" ] && [ "$TRUST_UPDATED" = "1" ] && [ "$TRUST_DROPPED" = "1" ] \
    && [ "$TRUST_CLEARED" = "3" ]; then
    pass "⑥ ledger: held=2 (projecting ×2 — a socket close no longer reaches the gate: the census precondition stops it), updated=1, dropped=1, cleared=3"
else
    fail "ledger: held=$TRUST_HELD updated=$TRUST_UPDATED dropped=$TRUST_DROPPED cleared=$TRUST_CLEARED (expected 2/1/1/3)"
fi
if [ "$SETTINGS_RESTARTS" = "0" ]; then
    pass "⑥ ledger: trust applies use their own carrier — ACTION settings-changed (restart) stays 0"
else
    fail "settings-changed (restart) leaked: $SETTINGS_RESTARTS"
fi
if [ "$TRUST_SPAWNS" = "4" ]; then
    pass "⑥ ledger: spawn=4 (generations alive after the last start: spawn#2 + apply×3; exactly one restart per apply)"
else
    fail "spawn ledger = $TRUST_SPAWNS (expected 4)"
fi
if [ -n "$(uxplay_pid)" ]; then
    printf '%s\n' "$(uxplay_pid)" > "$RUN/uxplay-pid.live"
    pass "⑥ uxplay survives (pid $(uxplay_pid); the projection service never drops across applies)"
else
    fail "uxplay not running after the apply chain"
fi

# --- 14. ⑧ stop → zh-Hant persisted (stopped = write-back only) → quit --------------

wait_for_count "$UI_LOG" "ACTION stop" 2 10 \
    && pass "Stop #2 (ACTION stop)" \
    || fail "second stop missing"
wait_pgrep_down uxplay 6 \
    && pass "stop → uxplay gone" \
    || fail "uxplay still running after stop"

wait_for_count "$UI_LOG" "PREFS shown (reused)" 1 10 \
    && pass "before the Traditional Chinese flip: prefs reopen" \
    || fail "prefs reopen missing"
wait_for_count "$UI_LOG" "ACTION language zh-Hant (shell-held, no restart)" 1 10 \
    && pass "⑧ language flip (stopped → write-back only; zero restarts)" \
    || fail "language flip trace missing"
wait_for_count "$UI_LOG" "ACTION settings-changed (write-back only)" 1 5 \
    && pass "⑧ write-back only proven (PIN on once before; no new restarts after that)" \
    || fail "write-back trace missing"

wait_for_count "$UI_LOG" "ACTION quit" 1 15 \
    && pass "phase A: Quit (S5)" \
    || fail "phase A quit missing"
wait_app_exit 12 \
    && pass "phase A: quit → app exited" \
    || fail "phase A: app did not exit"
APP_PID=""

FINAL_APPLIES_A="$(count_in 'TRUST apply gate=' "$UI_LOG")"
FINAL_RESTARTS_A="$(count_in 'ACTION settings-changed (restart)' "$UI_LOG")"
if [ "$FINAL_APPLIES_A" = "3" ] && [ "$FINAL_RESTARTS_A" = "0" ]; then
    pass "phase A final ledger: apply=3 (whole run), settings restart=0"
else
    fail "phase A final ledger: apply=$FINAL_APPLIES_A restart=$FINAL_RESTARTS_A (expected 3/0)"
fi
cp "$UI_LOG" "$RUN/ui.log.phase-a" 2>/dev/null
cp "$LAUNCH_LOG" "$RUN/launch.log.phase-a" 2>/dev/null

# --- 15. phase B: zh-Hant prompt + corner apply + delist while stopped deferred (re-fixture → relaunch) ---

{
    printf '%s,%s,%s\n' "$PKE" "$DEV_E" "測試機戊"
    printf '%s,%s,%s\n' "$PKF" "$DEV_F" "測試機己"
} > "$REGISTRY"
cp "$REGISTRY" "$RUN/registration.list.fixture-phase-b"

TEST_APP_CONSOLE="$RUN/app.stdout.phase-b.log"
export TEST_APP_CONSOLE
MIRRORBOARD_UITEST_TRUST=2 testkit_launch
APP_PID="${TEST_APP_PID:-}"
sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "phase B: launch ok (pid ${APP_PID}; persisted PIN on + zh-Hant + the user-set code carried back)"
else
    fail "phase B: launch failed — see $RUN/app.stdout.phase-b.log"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    exit 1
fi

wait_for_count "$UI_LOG" "UITEST trust armed (phase B)" 1 15 \
    && pass "phase B: harness armed" \
    || fail "phase B: harness not armed (wait timed out)"
wait_for_count_eq "$LAUNCH_LOG" "MIRRORBOARD SPAWN pid=" 1 15 \
    && pass "phase B: new generation spawn #B1 (fresh start truncate + the user-set code carried back)" \
    || fail "phase B: spawn #B1 not reached"
C3B="$(pin_of_spawn 1)"
if [ -n "$C3B" ] && [ "$C3B" = "$C3" ]; then
    pass "④ persisted: the user-set code ${C3B} is carried back (= the last rotated value from phase A)"
else
    fail "phase B carried pin '$C3B' (expected '$C3')"
fi
wait_for_count "$LAUNCH_LOG" "lists 2 pin-registered clients" 1 20 \
    && pass "R6 file layer: spawn #B1 boot line lists 2 (the 2-line E/F file really read)" \
    || fail "phase B: initial registry not loaded (lists 2 missing)"
wait_for_count "$UI_LOG" "TRUST event registered new client name=測試機戊 deviceID=$DEV_E" 1 12 \
    && pass "phase B: event parsed (測試機戊)" \
    || fail "phase B: event parse missing"
wait_for_count "$UI_LOG" "TRUST prompt presented name=測試機戊 deviceID=$DEV_E" 1 8 \
    && pass "phase B: prompt presented (zh-Hant scene)" \
    || fail "phase B: prompt missing"
wait_for_count "$UI_LOG" "TRUST prompt snapshot $SCRATCH/trust-prompt-hant.png" 1 8 \
    && pass "phase B: trust-prompt-hant.png (Traditional Chinese acceptance image)" \
    || fail "phase B: hant render missing"
wait_for_count "$UI_LOG" "LANGAUDIT trust lang=zh-Hant title=信任此裝置？ message=要信任「測試機戊」嗎？ accept=信任 decline=不信任 visible=1" 1 8 \
    && pass "phase B: rendered strings (Traditional Chinese; remember semantics)" \
    || fail "phase B: hant audit missing/wrong"
wait_for_count "$UI_LOG" "TRUST prompt dismissed unanswered (→ distrust) deviceID=$DEV_E" 1 8 \
    && pass "phase B: no answer = declined trust (proven again)" \
    || fail "phase B: dismiss evidence missing"
wait_for_count "$UI_LOG" "TRUST remove origin=prompt deviceID=$DEV_E removed=1 kept=1 dropped=0" 1 8 \
    && pass "phase B: removal written to the file (E removed, F kept)" \
    || fail "phase B: removal line missing/wrong"
wait_for_count "$UI_LOG" "TRUST pending set origin=prompt" 1 8 \
    && pass "phase B: pending (proven again)" \
    || fail "phase B: pending (re-assert) wait failed"
wait_for_count "$UI_LOG" "TRUST apply gate=immediate restart=1 pin-rotated=1" 2 12 \
    && pass "phase B: corner apply (no connection at that moment) + rotation (the second immediate one in total)" \
    || fail "phase B: corner apply missing"
wait_for_count_eq "$LAUNCH_LOG" "MIRRORBOARD SPAWN pid=" 2 14 \
    && pass "phase B: spawn #B2 (apply restart)" \
    || fail "phase B: spawn #B2 not reached"
C4="$(pin_of_spawn 2)"
assert_pin_diff "④ phase B spawn #B1→#B2" "$C3B" "$C4"
wait_for_count "$LAUNCH_LOG" "lists 1 pin-registered clients" 1 20 \
    && pass "R6 file layer: spawn #B2 boot line lists 1 (the new file after E was removed, really read)" \
    || fail "spawn #B2 boot did not load the new registry (lists 1 missing)"
if [ "$(file_lines)" = "1" ] && [ "$(count_in "$DEV_E" "$REGISTRY")" = "0" ] \
    && [ "$(count_in "$DEV_F" "$REGISTRY")" = "1" ]; then
    pass "phase B: file layer (1 line = F)"
else
    fail "phase B: registry wrong (lines=$(file_lines))"
fi
snapshot_registry "phase-b-after-dismiss"

# ⑪ delisting while stopped = deferred + immediate rotation (the next session must not pass by auto-entry).
wait_for_count "$UI_LOG" "ACTION stop" 3 10 \
    && pass "phase B: Stop (ACTION stop#3)" \
    || fail "phase B: stop missing"
wait_for_count "$UI_LOG" "PREFS trust editor presented (rows=1)" 1 12 \
    && pass "phase B: editor while stopped rows=1 (F)" \
    || fail "phase B: editor rows wrong"
wait_for_count "$UI_LOG" "PREFS trust remove requested code=$DEV_F" 1 8 \
    && pass "phase B: ✕ submitted (code=F)" \
    || fail "phase B: row ✕ never fired"
wait_for_count "$UI_LOG" "TRUST remove origin=editor deviceID=$DEV_F removed=1 kept=0 dropped=0" 1 8 \
    && pass "phase B: ✕ = removal (while stopped)" \
    || fail "phase B: removal (F) missing"
wait_for_count "$UI_LOG" "TRUST apply deferred origin=editor (receiver not running; next start loads registry)" 1 8 \
    && pass "R6 deferred: receiver not started = zero restarts (the next start loads the new file)" \
    || fail "phase B: deferred line missing"
wait_for_count "$UI_LOG" "TRUST pin-rotate applied (deferred)" 1 8 \
    && pass "R6 rotation: deferred still rotates the PIN immediately (editing the list while stopped = real blocking next time)" \
    || fail "phase B: deferred rotate missing"
SPAWNS_PRE="$(spawn_count)"
if [ "$SPAWNS_PRE" = "2" ]; then
    pass "R6: zero new spawns while deferred (deferred lives up to its name)"
else
    fail "deferred spawned something (spawn=$SPAWNS_PRE, expected 2)"
fi
C5="$(last_panel_pin_code)"
if [ -n "$C5" ] && [ "$C5" != "$C4" ]; then
    pass "④ panel sync: displayed code ${C5} after the rotation while stopped (≠ ${C4} of spawn #B2)"
else
    fail "deferred rotation not reflected on the panel (got '$C5', previous '$C4')"
fi

# ⑫ wave1r6b N-1 (race replay; the harness injects a lagging .disconnected after stop):
# a stale disconnect with dirty still set → the guard reads CoreBridge's real state (idle) and holds it back:
# zero applies (apply stays 4), zero resurrection (spawn stays 2). Before the fix: no guard → apply +
# a resurrection spawn 0.5s later (these two assertions went red — the before/after comparison).
wait_for_count "$UI_LOG" "TRUST apply skipped (stale disconnect after stop; receiver idle)" 1 8 \
    && pass "N-1 guard: a late disconnect after stop is caught (receiver idle; nothing applied)" \
    || fail "N-1: stale-disconnect guard line missing (the late disconnect was not caught)"
sleep 2   # a window: if the guard fails, the restart's 0.5s spawn must show up
SPAWNS_POST_N1="$(spawn_count)"
APPLIES_POST_N1="$(count_in 'TRUST apply gate=' "$UI_LOG")"
if [ "$SPAWNS_POST_N1" = "2" ] && [ "$APPLIES_POST_N1" = "4" ]; then
    pass "N-1: no revival on a stale disconnect (spawn still 2; apply still 4 — no restart triggered)"
else
    fail "N-1: stale disconnect revived the receiver (spawn=$SPAWNS_POST_N1 apply=$APPLIES_POST_N1; expected 2/4)"
fi

wait_for_count "$UI_LOG" "ACTION quit" 2 15 \
    && pass "phase B: Quit" \
    || fail "phase B: quit missing"
wait_app_exit 12 \
    && pass "phase B: quit → app exited" \
    || fail "phase B: app did not exit"
APP_PID=""

# --- 16. residue + restore ----------------------------------------------------

sleep 1
pgrep -x MiragePlay >/dev/null 2>&1 && fail "residue: MiragePlay still running" || pass "residue: no MiragePlay"
pgrep -x uxplay >/dev/null 2>&1 && fail "residue: uxplay still running" || pass "residue: no uxplay"

# Whole-run (A+B) ledger alignment (launch.log is truncated on the phase B fresh start —
# phase A's 5 spawn generations are counted from the archived copy).
PHASE_A_SPAWNS="$(count_in 'MIRRORBOARD SPAWN pid=' "$RUN/launch.log.phase-a")"
TOTAL_SPAWNS=$((PHASE_A_SPAWNS + $(spawn_count)))
TOTAL_APPLIES="$(count_in 'TRUST apply gate=' "$UI_LOG")"
TOTAL_ROTATES="$(count_in 'TRUST pin-rotate applied' "$UI_LOG")"
TOTAL_HELD="$(count_in 'TRUST apply held' "$UI_LOG")"
TOTAL_CLEARED="$(count_in 'TRUST pending cleared at spawn' "$UI_LOG")"
if [ "$TOTAL_SPAWNS" = "6" ] && [ "$TOTAL_APPLIES" = "4" ] && [ "$TOTAL_ROTATES" = "5" ]; then
    pass "⑥ whole-run ledger: spawn=6, apply=4, rotate=5 (every apply rotates + one deferred)"
else
    fail "total ledger: spawn=$TOTAL_SPAWNS apply=$TOTAL_APPLIES rotate=$TOTAL_ROTATES (expected 6/4/5)"
fi
if [ "$TOTAL_HELD" = "2" ] && [ "$TOTAL_CLEARED" = "4" ]; then
    pass "⑥ whole-run ledger: held=2, cleared=4 (all four apply restarts loaded the new file)"
else
    fail "total ledger: held=$TOTAL_HELD cleared=$TOTAL_CLEARED (expected 2/4)"
fi

cp "$UI_LOG" "$RUN/ui.log" 2>/dev/null
cp "$LAUNCH_LOG" "$RUN/launch.log" 2>/dev/null
cp "$SCRATCH/trust-prompt-en.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/trust-prompt-hant.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/trust-editor-before-x.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/trust-editor-after-x.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/trust-editor-after-reset.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/panel-pin-rotated.png" "$RUN/" 2>/dev/null

if [ -n "$SERVER_PEM_SHA_BEFORE" ] && [ -f "$APPSUP/server.pem" ]; then
    SERVER_PEM_SHA_AFTER="$(shasum -a 256 "$APPSUP/server.pem" | awk '{print $1}')"
    if [ "$SERVER_PEM_SHA_BEFORE" = "$SERVER_PEM_SHA_AFTER" ]; then
        pass "identity material untouched: server.pem shasum identical before and after"
    else
        fail "server.pem changed during the run!"
    fi
fi

# restore (save the evidence first) and verify the restore.
FINAL_REGISTRY_BYTES="$(file_bytes)"
[ -f "$RUN/registration.list.prev" ] && cp "$RUN/registration.list.prev" "$RUN/registration.list.prev.keep"
[ -f "$RUN/settings.json.prev" ] && cp "$RUN/settings.json.prev" "$RUN/settings.json.prev.keep"
restore_settings
if [ "$REGISTRY_PREEXISTED" = "1" ]; then
    if [ -f "$REGISTRY" ] && cmp -s "$RUN/registration.list.prev.keep" "$REGISTRY"; then
        pass "restore: registration.list byte-identical to the original (zero damage)"
    else
        fail "registration.list restore mismatch"
    fi
fi
if [ "$SETTINGS_PREEXISTED" = "1" ]; then
    if [ -f "$SETTINGS" ] && cmp -s "$RUN/settings.json.prev.keep" "$SETTINGS"; then
        pass "restore: settings.json byte-identical to the original"
    else
        fail "settings.json restore mismatch"
    fi
fi

# --- 17. summary ---------------------------------------------------------------

log ""
log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
log "   final registry bytes (pre-restore): $FINAL_REGISTRY_BYTES"
log "   evidence:   $RUN"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
