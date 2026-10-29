#!/bin/bash
# test-ui-prefs.sh — wave1r3 (B2 slider batch) UI test: panel Settings… entry →
# single-page preferences window (450 fixed; content column 336 centred)
# + slider control (128 + read-only value 48, variant ①; zero stepper / zero value field)
# + Profiles withdrawn (3 group caps; zero-residue regression guard)
# + About entry = a small button at the bottom right of the in-window footer (B2 correction: bottom right, not bottom left)
# + the full R1 reminder (Unsaved changes) + About mini-window
# + singleton guard.
#
# Re-runnable. Self-contained. Never touches a RUNNING MiragePlay/uxplay
# instance (aborts — that would be YC's own instance; the test cleans up after itself, zero residue).
#
# Verifies:
#   0. contract statics (spawn argv = snapshot argv() / pty line buffering
#      (openpty) + single executableURL, stdbuf retired /
#      prepareForReceiverStart wiring), StatusItemMenu instantiation, no
#      auto-start, prefs entry present, PreferencesWindowController
#      instantiated, PIN protection / PIN code rows present + panel section order
#      (status row→PIN block→start button→settings→quit — wave1r3: the About row is withdrawn, B2 ruling ③)
#      + the trust-device editor sheet shell, single-page statics (zero tabs / sliders present / stepper and value
#      field gone for good / 3 group caps / full R1 reminder / zero Profiles residue / About inside the window at bottom right),
#      singleton-guard source, red-line self-check
#   1. build OK                    (scripts/lib/testkit.sh -> build-app.sh --out <tmp>)
#   2. launch OK                   (MIRRORBOARD_UITEST_PREFS=1, this run's bundle)
#   3. panel opens + panel snapshot
#   4. icon sheet REBORN           (new YC shape; replaced old file, sha differs)
#   5. singleton guard runtime     — second launch with the first alive:
#      detects the existing instance, focuses (best-effort), exits 0;
#      the first instance is untouched
#   6. Settings… entry clicked     (ui.log ACTION prefs-open)
#   7. preferences window opens    (PREFS shown (created); PREFS frame 450x429
#                                   — B2 single page sans Profiles; the
#                                   steady-state width is 450 in every
#                                   language/state, and
#                                   `PREFS layout formx=57 formw=336 winw=450`
#                                   proves the centred 336 column)
#   8. clean-state render          (prefs-window.png; apply grey, no reminder)
#   9. dirty-state render (R1)     (prefs-window-dirty.png; apply enabled=1,
#                                   reminder=1; same height — R1 adds no height;
#                                   + footer close-up prefs-footer-dirty.png
#                                   (About at bottom right + the full R1 text) + the `PREFS footer`
#                                   measurement line full=1)
#  10. About mini-window           (in-window footer bottom-right button pressed → PREFS about entry
#                                   clicked → ACTION about-open / ABOUT shown /
#                                   frame 360x169 / about-window.png render /
#                                   LANGAUDIT about / WINDOWS about=1 / closed)
#  11. trust editor (implementation) (presented rows=0 — this session moves the real file away for safekeeping first →
#                                   Reset = truncate 0 (file-level assertion) → dismissed)
#  12. apply clears dirty         (apply enabled=0 reminder=0 again)
#  13. single instance             (PREFS shown (reused); WINDOWS audit 1+1+0)
#  14. close / reopen / close      (reuse + zero residue; a staged slider is discarded on close)
#  15. PIN protection toggle (D segment power-on): the code row appears/hides, panel
#      300x212 ⇄ 300x192 (wave1r3: the height after the About row was withdrawn — B2 ruling ③),
#      renders panel-pin-on.png
#  16. connected-name visual layer: STATE connected(YC's iPad) +
#      panel-connected.png (a real connection cannot be simulated in the harness — visual-layer evidence)
#  17. quit → app exits, zero residue (no MiragePlay, no uxplay)
#
# The scripted sequence is driven by the app itself: MIRRORBOARD_UITEST_PREFS=1
# makes UITestDriver exercise the exact entry points the UI uses (icon click /
# Settings… row / slider settled edit / About footer entry / trust editor /
# apply / red-light close / PIN toggle / quit) on a fixed timeline — see
# UITestDriver.swift. Timeline: panel open 1.5s / prefs open 2.2s / clean
# snapshot 2.5s / slider staged 1440p 2.8s / dirty snapshot + footer close-up
# 3.1s / About in-window entry 3.4–3.8s / trust editor 4.0–4.25s / apply 4.5s /
# reopen 4.8s / slider staged 2160p 5.1s / close 5.4s (discard) / reopen 5.8s /
# close 6.2s / panel close 6.6s / panel reopen 7.1s / PIN on 7.3s / pin-on
# render 7.65s / connected render 7.8s / PIN off 8.1s / idle 8.3s / panel
# close 8.5s / quit 10.0s.
#
# Usage:  ./scripts/tests/test-ui-prefs.sh
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
    echo "test-ui-prefs: cannot resolve the repo root to its on-disk spelling" >&2
    exit 1
}
# Shared harness foundation (build into tmp + per-run ui.log + process
# hygiene). Located relative to THIS script — the repository root is never
# spelled as an absolute literal here. The testkit also brings in
# scripts/lib/_uxplay-path.sh (UxPlay tree resolution + red-line gate,
# 2026-10-19 decouple: the upstream tree is materialized on demand by
# scripts/build/vendor-uxplay.sh from the fork pinned in core/vendor.lock).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
[ -f "$LIB_DIR/testkit.sh" ] || {
    echo "test-ui-prefs: the shared harness library is missing at $LIB_DIR/testkit.sh" >&2
    exit 1
}
# shellcheck source=scripts/lib/testkit.sh
. "$LIB_DIR/testkit.sh"

# C1 runtime-path repair (D8): UILog / UITestDriver write their per-bundle
# TEMP scratch (NSTemporaryDirectory). The RENDERS still land there (the app
# has no environment override for them); the LOG is per run now, so it comes
# from testkit_ui_log below.
SCRATCH_ROOT="${TMPDIR:-/tmp}"; SCRATCH_ROOT="${SCRATCH_ROOT%/}"
SCRATCH="$SCRATCH_ROOT/com.ycchung.mirageplay"
CB_SWIFT="$PROJ/app/Sources/core-bridge/CoreBridgeReceiverController.swift"
CR_SWIFT="$PROJ/app/Sources/AppShell/CompositionRoot.swift"
AD_SWIFT="$PROJ/app/Sources/AppShell/AppDelegate.swift"
SI_SWIFT="$PROJ/app/Sources/AppShell/StatusItemMenu.swift"
SP_SWIFT="$PROJ/app/Sources/AppShell/StatusPanelController.swift"
PW_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesWindowController.swift"
PF_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesFormViews.swift"
PI_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesIntent.swift"
IH_SWIFT="$PROJ/app/Sources/AppShell/PreferencesIntentHandler.swift"
AW_SWIFT="$PROJ/app/Sources/SettingsUI/AboutWindowController.swift"
UTD_SWIFT="$PROJ/app/Sources/AppShell/UITestDriver.swift"
SG_SWIFT="$PROJ/app/Sources/AppShell/SingletonGuard.swift"
MAIN_SWIFT="$PROJ/app/Sources/AppShell/main.swift"
TERMS_JSON="$PROJ/app/Resources/Strings/terms.json"
APPSUP="$HOME/Library/Application Support/com.ycchung.mirageplay"
SETTINGS="$APPSUP/settings.json"
# The receiver log lives in Application Support (not the temp scratch): the app
# owns that location and truncates it on every fresh Start. Read-only input here.
LAUNCH_LOG="$APPSUP/launch.log"
# wave1r4 — the trust registry file: the suite moves the REAL one away for the
# run (deterministic empty rows) and restores it afterwards (zero destruction;
# see restore_settings). The Reset probe now TRUNCATES this file.
REGISTRY="$APPSUP/registration.list"
# cleanfails-diag §2.2: the placeholder-era icon-sheet digest is a FIXTURE, not
# a build product, so it lives beside the shared build cache (outside the
# checkout). Resolved after testkit_init (the cache root is exported there).
# When the fixture is absent the assertion below records a SKIP with a reason —
# it never invents a digest.
BASELINE_FILE=""

PASS=0
FAIL=0
SKIP=0
APP_PID=""
SECOND_PID=""
SETTINGS_PREEXISTED=0
APPSUP_PREEXISTED=0
REGISTRY_PREEXISTED=0
RESTORED=0

# --- this run's workspace ----------------------------------------------------

testkit_init || {
    echo "test-ui-prefs: testkit_init failed (no temp workspace for this run)" >&2
    exit 1
}
RUN="$(testkit_evidence_dir)" || {
    echo "test-ui-prefs: testkit_evidence_dir failed" >&2
    exit 1
}
UI_LOG="$(testkit_ui_log)" || {
    echo "test-ui-prefs: testkit_ui_log failed" >&2
    exit 1
}
BASELINE_FILE="$MIRAGE_PLAY_BUILD_ROOT/test-baselines/icon-sheet-placeholder-baseline.txt"

log()  { echo "$@" | tee -a "$RUN/summary.txt"; }
pass() { PASS=$((PASS + 1)); log "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); log "FAIL  $1"; }
skip() { SKIP=$((SKIP + 1)); log "SKIP  $1"; }

# --- user-state restore (D segment: the PIN toggle goes through the real engine, ⑫ writes back) ---

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
    # wave1r4 — the trust registry: the exact same keep/restore convention.
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
    if [ -n "$SECOND_PID" ] && kill -0 "$SECOND_PID" 2>/dev/null; then
        kill "$SECOND_PID" 2>/dev/null
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
    # testkit_init installed its own EXIT trap; this suite needed the user's
    # settings.json / registry put back on EVERY exit path first, so it
    # reinstalled the trap (below) and runs both jobs here, in that order.
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

wait_for_count() { # <file> <fixed-pattern> <min-count> <timeout_sec> (0.25s steps)
    local file="$1" pattern="$2" want="$3" timeout_s="${4:-12}" waited=0
    while [ "$waited" -lt $((timeout_s * 4)) ]; do
        [ "$(count_in "$pattern" "$file")" -ge "$want" ] && return 0
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}

wait_for_line() { # <fixed-pattern> <timeout_sec>
    wait_for_count "$UI_LOG" "$1" 1 "${2:-10}"
}

file_nonempty() { [ -s "$1" ]; }

png_width() { sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/ {print $2}'; }
png_height() { sips -g pixelHeight "$1" 2>/dev/null | awk '/pixelHeight/ {print $2}'; }

# --- 0. preflight: never touch a live instance ------------------------------

log "== wave1r3 B2-prefs UI test — $(date '+%Y-%m-%d %H:%M:%S %Z') =="
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

# G segment alignment: the panel's visible strings live in the term dictionary and the
# source looks them up by KEY; the assertion checks BOTH sides.
if grep -Fq 'panel.entry.preferences' "$SP_SWIFT" && grep -Fq 'onOpenPreferences' "$SP_SWIFT" \
    && grep -Fq '偏好設定…' "$TERMS_JSON"; then
    pass "entry: Settings… row present in StatusPanelController (dictionary lookup + callback wired)"
else
    fail "entry: Settings… row missing from StatusPanelController"
fi

if grep -Fq 'panel.pin.protection' "$SP_SWIFT" && grep -Fq 'panel.pin.code' "$SP_SWIFT" \
    && grep -Fq 'PIN 保護' "$TERMS_JSON" && grep -Fq 'PIN 碼' "$TERMS_JSON" \
    && grep -Fq 'contentHeight(pinOn:' "$SP_SWIFT"; then
    pass "panel: PIN protection/PIN code rows + conditional code-row height in source"
else
    fail "panel: PIN rows or conditional height missing from StatusPanelController"
fi

# Panel section order (status row→PIN block→start button→settings→quit — wave1r3: the About row
# is retired, B2 ruling ③): the constraint chain must run statusRow → pinProtectionRow
# → pinCodeRow → pinSeparator → primaryButton → separator → preferencesButton
# → quitButton (quitButton takes the bottom pin).
if grep -Fq 'pinProtectionRow.topAnchor.constraint(equalTo: statusRow.bottomAnchor' "$SP_SWIFT" \
    && grep -Fq 'primaryButton.topAnchor.constraint(equalTo: pinSeparator.bottomAnchor' "$SP_SWIFT" \
    && grep -Fq 'preferencesButton.topAnchor.constraint(equalTo: separator.bottomAnchor' "$SP_SWIFT" \
    && grep -Fq 'quitButton.topAnchor.constraint(equalTo: preferencesButton.bottomAnchor' "$SP_SWIFT" \
    && grep -Fq 'quitButton.bottomAnchor.constraint(equalTo: effectView.bottomAnchor' "$SP_SWIFT"; then
    ORDER_OK=1
    PREV=0
    for needle in 'statusRow.topAnchor' 'pinProtectionRow.topAnchor' 'pinSeparator.topAnchor' 'primaryButton.topAnchor' 'preferencesButton.topAnchor' 'quitButton.topAnchor'; do
        LINE="$(grep -n "$needle" "$SP_SWIFT" | head -1 | cut -d: -f1)"
        if [ -z "$LINE" ] || [ "$LINE" -le "$PREV" ]; then
            ORDER_OK=0
            break
        fi
        PREV="$LINE"
    done
    if [ "$ORDER_OK" = "1" ]; then
        pass "panel section order: status row→PIN area→Start button→Settings→Quit (no About row — B2 ruling ③)"
    else
        fail "panel section order wrong (source order check failed)"
    fi
else
    fail "panel section order wrong (constraint chain broken)"
fi

# wave1r3 — the panel's bottom About row is withdrawn (B2 ruling ③: "put the about button inside preferences"):
# zero about row traces in the panel source/dictionary; height math loses the
# 20+8 row (PIN on 212 / off 192).
if ! grep -Fq 'aboutButton' "$SP_SWIFT" \
    && ! grep -Fq 'aboutRowHeight' "$SP_SWIFT" \
    && ! grep -Fq 'panel.entry.about' "$SP_SWIFT" \
    && ! grep -Fq '"panel.entry.about"' "$TERMS_JSON" \
    && grep -Fq '12+20+8+24+20+8+1+8+26+8+1+8+24+8+24+12 = 212' "$SP_SWIFT"; then
    pass "panel About row retired: zero about rows left (source + dictionary); height math = 212/192"
else
    fail "panel About row not fully retired (source / dictionary / height math)"
fi

# icons removed everywhere (YC ruling): only the status dot and the menu-bar icon remain.
if grep -Fq 'image = ' "$SP_SWIFT"; then
    fail "icon sweep: an image assignment crept back into the panel rows"
elif [ -f "$PROJ/app/Sources/SettingsUI/PanelGlyphs.swift" ]; then
    fail "icon sweep: PanelGlyphs.swift is back (glyph library was removed)"
elif grep -Fq 'imagePosition' "$PW_SWIFT"; then
    fail "icon sweep: an imagePosition setting crept back into the preferences window"
else
    pass "icon sweep: zero row/tab glyphs (panel + prefs window are text-only; the glyph library is gone)"
fi

# wave1r2 — B1 single-page change (ruling ③): tabs removed, future rows withdrawn (the Profiles group separately —
# wave1r3 ruling ②).
if grep -Fq 'buildSinglePage' "$PW_SWIFT" && grep -Fq 'buildSinglePage' "$PF_SWIFT" \
    && ! grep -Fq 'pageAHeight' "$PW_SWIFT" && ! grep -Fq 'pageBHeight' "$PW_SWIFT" \
    && ! grep -Fq 'tabStrip' "$PW_SWIFT" && ! grep -Fq 'tabButtons' "$PW_SWIFT" \
    && ! grep -Fq 'selectPreferencesPage' "$SI_SWIFT" && ! grep -Fq 'selectPage' "$PW_SWIFT"; then
    pass "single page: buildSinglePage + zero tabs (tabStrip/tabButtons/pageA/BHeight/selectPage all retired)"
else
    fail "single page incomplete (tabs or page heights still present)"
fi

# wave1r3 — group caps 4→3 (B2 ruling ②): Video & Audio / Connection & Session /
# Language; dictionary-driven + zero Profiles cap keys.
if grep -Fq 'prefs.tab.videoAudio' "$PF_SWIFT" && grep -Fq 'prefs.tab.connection' "$PF_SWIFT" \
    && grep -Fq 'prefs.tab.language' "$PF_SWIFT" \
    && ! grep -Fq 'prefs.tab.profiles' "$PF_SWIFT" \
    && ! grep -Fq '"prefs.tab.profiles"' "$TERMS_JSON" \
    && grep -Fq 'groupCaps: [capVideo, capConnection, capLanguage]' "$PF_SWIFT"; then
    pass "3 group caps: videoAudio / connection / language; zero Profiles cap-key residue"
else
    fail "3 group caps missing (cap keys / zero profiles residue)"
fi

# future rows withdrawn (ruling ③): the recording / screen-switch rows are GONE from the settings source AND
# the dictionary; the "coming later" strings ride along.
if ! grep -Fq 'prefs.row.recording' "$PF_SWIFT" && ! grep -Fq 'prefs.row.switchScreen' "$PF_SWIFT" \
    && ! grep -Fq 'prefs.row.recording' "$PW_SWIFT" && ! grep -Fq 'disabledRow' "$PF_SWIFT" \
    && ! grep -Fq '"prefs.row.recording"' "$TERMS_JSON" \
    && ! grep -Fq '"prefs.row.switchScreen"' "$TERMS_JSON" \
    && ! grep -Fq '"prefs.tag.laterVersion"' "$TERMS_JSON"; then
    pass "future rows hidden: Recording / Switch screen (+ follow-up labels) retired from the settings surface and the dictionary (code entry points kept at feature level)"
else
    fail "future rows still present in settings source or dictionary"
fi

# wave1r3 — sliders (B2 ruling ①, control correction): [slider 128] + [readout 48]; the pre-B2
# "no slider" assertions are inverted — the whole tree has zero NSStepper, zero stepper / value-field components.
if grep -Fq 'NSSlider' "$PF_SWIFT" \
    && grep -Fq 'SliderControl' "$PF_SWIFT" \
    && grep -Fq 'allowsTickMarkValuesOnly = true' "$PF_SWIFT" \
    && grep -Fq 'isContinuous = false' "$PF_SWIFT" \
    && grep -Fq 'sliderWidth: CGFloat = 128' "$PF_SWIFT" \
    && grep -Fq 'readoutWidth: CGFloat = 48' "$PF_SWIFT" \
    && grep -Fq 'readoutLabel' "$PF_SWIFT" \
    && ! grep -rq 'NSStepper' "$PROJ/app/Sources" 2>/dev/null \
    && ! grep -Fq 'NumericStepperControl' "$PF_SWIFT" && ! grep -Fq 'NumericStepperControl' "$PW_SWIFT" \
    && ! grep -Fq 'valueField' "$PF_SWIFT" && ! grep -Fq 'stepperWidth' "$PF_SWIFT"; then
    pass "slider: NSSlider 128 (spec value) + read-only value 48 (labelWithString, read-only); zero NSStepper / zero value text fields repo-wide (assertion inverted from the previous batch)"
else
    fail "slider sweep failed（NSSlider/128/48 missing, or stepper/value-field residue）"
fi

# wave1r3 — slider driving path: both numeric rows feed staged (the settled commit on release).
if grep -Fq 'page.resolution.onValueChanged' "$PW_SWIFT" \
    && grep -Fq 'page.frameRate.onValueChanged' "$PW_SWIFT" \
    && grep -Fq 'func commit(step:' "$PF_SWIFT" \
    && grep -Fq 'selectResolutionForTesting' "$PW_SWIFT" \
    && grep -Fq 'selectFrameRateForTesting' "$PW_SWIFT"; then
    pass "slider drive path: onValueChanged → stage; commit(step:) is the settled seam"
else
    fail "slider driver path incomplete（onValueChanged / commit seam）"
fi

# wave1r2 — content centred as a whole (ruling ①): the 336 content column (136+15+185) is horizontally centred.
if grep -Fq 'contentColumnWidth: CGFloat = labelWidth + labelGap + controlAreaWidth' "$PF_SWIFT" \
    && grep -Fq 'controlAreaWidth: CGFloat = 185' "$PF_SWIFT" \
    && grep -Fq 'centerXAnchor.constraint(equalTo: page.centerXAnchor)' "$PF_SWIFT"; then
    pass "centring: content column 336 (136+15+185) + stack centred on centerX (margins 57/57)"
else
    fail "centring constants missing（contentColumnWidth / controlAreaWidth / centerX）"
fi

# window 450 + close-only traffic light (S-6); heights are CONTENT-driven.
if grep -Fq 'width: CGFloat = 450' "$PW_SWIFT" \
    && grep -Fq 'styleMask: [.titled, .closable]' "$PW_SWIFT" \
    && grep -Fq 'fitWindowToContent' "$PW_SWIFT" \
    && grep -Fq 'layoutSubtreeIfNeeded' "$PW_SWIFT"; then
    pass "window: 450 fixed + close-only traffic light + settled-frame evidence (layout-first read)"
else
    fail "window: width / styleMask / settled-frame evidence missing"
fi

# wave1r3 — the full R1 reminder (YC's correction, "restore the full text when it fits"): text beside the button, two states;
# the `PREFS footer` measurement line (about at bottom right + derived slot/full); MUST be the FULL text.
if grep -Fq 'prefs.apply.reminder' "$PW_SWIFT" && grep -Fq 'prefs.apply.reminder' "$TERMS_JSON" \
    && grep -Fq 'Unsaved changes' "$TERMS_JSON" && grep -Fq '尚未套用的變更' "$TERMS_JSON" \
    && grep -Fq '尚未套用的变更' "$TERMS_JSON" \
    && grep -Fq 'reminderStack' "$PW_SWIFT" && grep -Fq 'reminderStack.isHidden = !enabled' "$PW_SWIFT" \
    && grep -Fq 'PREFS footer' "$PW_SWIFT" && grep -Fq 'full=' "$PW_SWIFT" \
    && ! grep -Fq 'prefs.helper.appliesOnApply' "$PW_SWIFT" \
    && ! grep -Fq 'prefs.helper.appliesOnApply' "$PF_SWIFT" \
    && ! grep -Fq '"prefs.helper.appliesOnApply"' "$TERMS_JSON"; then
    pass "R1 full-text reminder: prefs.apply.reminder (full sentence in three languages) + two-state isHidden + footer measurement line (full= decision)"
else
    fail "R1 reminder wiring incomplete (key/two-state/full-text/measurement line)"
fi

# wave1r3 — About entry = a small button at the bottom right of the in-window footer (B2 ruling ③ + YC's correction "about belongs
# at the bottom right, not the bottom left"): pinned 18 from the right edge; in-window button→onOpenAbout→performOpenAbout.
if grep -Fq 'prefs.button.about' "$PW_SWIFT" && grep -Fq 'prefs.button.about' "$TERMS_JSON" \
    && grep -Fq 'About…' "$TERMS_JSON" && grep -Fq '關於…' "$TERMS_JSON" && grep -Fq '关于…' "$TERMS_JSON" \
    && grep -Fq 'aboutEntryTrailingGap' "$PW_SWIFT" \
    && grep -Fq 'aboutButton.trailingAnchor.constraint(' "$PW_SWIFT" \
    && grep -Fq 'onOpenAbout' "$PW_SWIFT" && grep -Fq 'onOpenAbout' "$SI_SWIFT" \
    && grep -Fq 'pressAboutForTesting' "$PW_SWIFT" \
    && grep -Fq 'pressPreferencesAboutForTesting' "$SI_SWIFT" \
    && grep -Fq 'about=\(aboutButton.title)' "$PW_SWIFT"; then
    pass "About entry: small button at the footer bottom-right of the window (trailing 18) + dictionary key + callback + seam + LANGAUDIT about="
else
    fail "About in-window entry missing（button / right-edge / callback / key）"
fi

# wave1r2 — About mini-window (ruling ②: credits = About; B1 §E-1 option A). wave1r3: the body
# is untouched (renaming is not in this unit).
if [ -f "$AW_SWIFT" ] \
    && grep -Fq 'class AboutWindowController' "$AW_SWIFT" \
    && grep -Fq 'about.title' "$AW_SWIFT" && grep -Fq 'about.copyright' "$AW_SWIFT" \
    && grep -Fq 'about.license' "$AW_SWIFT" && grep -Fq 'about.thirdParty' "$AW_SWIFT" \
    && grep -Fq '"about.copyright"' "$TERMS_JSON" \
    && grep -Fq '© 2026 Yu-Cheng Chung and Contributors' "$TERMS_JSON" \
    && grep -Fq 'GPL-3.0-only' "$TERMS_JSON" \
    && grep -Fq 'UxPlay v1.73.6' "$TERMS_JSON" \
    && grep -Fq 'AboutWindowController' "$SI_SWIFT" \
    && grep -Fq 'renderAboutSnapshot' "$SI_SWIFT" \
    && grep -Fq 'preferredMaxLayoutWidth' "$AW_SWIFT" \
    && grep -Fq 'https://github.com/miles0428/MiragePlay' "$AW_SWIFT" \
    && grep -Fq 'NSWorkspace.shared.open' "$AW_SWIFT"; then
    pass "About mini window: AboutWindowController (title / copyright attribution / GPL-3.0-only / third-party deps.lock; long lines wrap; source link → NSWorkspace.open) + wiring"
else
    fail "About mini-window missing（controller / keys / wiring / wrap）"
fi

# Credits (YC verbatim): © 2026 Yu-Cheng Chung and Contributors (same in all three languages).
if grep -Fq '"about.copyright": { "en": "© 2026 Yu-Cheng Chung and Contributors"' "$TERMS_JSON"; then
    pass "copyright attribution: © 2026 Yu-Cheng Chung and Contributors (en verbatim)"
else
    fail "copyright attribution wrong or missing"
fi

# wave1r3 — zero Profiles residue (regression guard; B2 ruling ②): the UI side (dropdown / save-as /
# providers / seams / sheet keys) is fully retired; the engine side is kept (ConfigEngine untouched).
if ! grep -Fq 'profilePopup' "$PF_SWIFT" && ! grep -Fq 'profilePopup' "$PW_SWIFT" \
    && ! grep -Fq 'syncProfilePopup' "$PF_SWIFT" \
    && ! grep -Fq 'saveAsButton' "$PF_SWIFT" && ! grep -Fq 'saveAsButton' "$PW_SWIFT" \
    && ! grep -Fq 'profileSelected' "$PW_SWIFT" && ! grep -Fq 'saveAsClicked' "$PW_SWIFT" \
    && ! grep -Fq 'presentSaveAsSheet' "$PW_SWIFT" && ! grep -Fq 'commitSaveAs' "$PW_SWIFT" \
    && ! grep -Fq 'selectProfileForTesting' "$PW_SWIFT" \
    && ! grep -Fq 'selectPreferencesProfile' "$SI_SWIFT" \
    && ! grep -Fq 'savePreferencesProfileAs' "$SI_SWIFT" \
    && ! grep -Fq 'profilesProvider:' "$CR_SWIFT" && ! grep -Fq 'profilesProvider' "$PW_SWIFT" \
    && ! grep -Fq 'profilePreviewProvider' "$CR_SWIFT" && ! grep -Fq 'profilePreviewProvider' "$SI_SWIFT" \
    && ! grep -Fq 'factoryProfileName' "$CR_SWIFT" && ! grep -Fq 'factoryProfileName' "$SI_SWIFT" \
    && ! grep -Fq 'preferencesProfileSaveAsCommitted' "$PI_SWIFT" \
    && ! grep -Fq 'preferencesProfileSaveAsCommitted' "$IH_SWIFT" \
    && ! grep -Fq 'ProfileSaveAsOutcome' "$PI_SWIFT" \
    && ! grep -Fq 'prefs.tab.profiles' "$TERMS_JSON" \
    && ! grep -Fq 'prefs.row.profile' "$TERMS_JSON" \
    && ! grep -Fq 'prefs.profile.default' "$TERMS_JSON" \
    && ! grep -Fq 'prefs.profile.saveAs' "$TERMS_JSON" \
    && ! grep -Fq 'prefs.saveAs.' "$TERMS_JSON"; then
    pass "zero Profiles residue (regression guard): settings-window UI / providers / seams / save-as intents + dictionary display keys all retired"
else
    fail "Profiles residue found（UI / providers / seams / dictionary keys）"
fi

# wave1r2 — singleton guard (YC ruling "add it"): main.swift call + flock implementation.
if grep -Fq 'SingletonGuard.claimOrExit()' "$MAIN_SWIFT" \
    && [ -f "$SG_SWIFT" ] \
    && grep -Fq 'flock' "$SG_SWIFT" \
    && grep -Fq 'SINGLETON detected existing instance' "$SG_SWIFT" \
    && grep -Fq 'exit(0)' "$SG_SWIFT" \
    && grep -Fq 'singleton.lock' "$SG_SWIFT"; then
    pass "singleton guard: main.swift call + flock lock (detect→focus→exit 0)"
else
    fail "singleton guard missing（call site / flock / exit path）"
fi

# wave1r1: the window-bottom apply bar — title via dictionary.
# wave1r2-fix1 (R1 review required): the title must ALSO be re-looked-up in
# applyLanguage() — chrome strings are not rebuilt by rebuildForm(), so the
# flip path is the only refresh point (the original gap: assigned only at construction ⇒ the zh-Hant bottom button
# still read "Apply"; this assertion locks that refresh). wave1r3: the About chrome re-look-up rides
# the same duty.
if grep -Fq 'prefs.button.apply' "$PW_SWIFT" \
    && grep -Fq 'applyClicked' "$PW_SWIFT" \
    && grep -Fq 'applyButton?.title = localization.t("prefs.button.apply")' "$PW_SWIFT" \
    && grep -Fq 'aboutButton?.title = localization.t("prefs.button.about")' "$PW_SWIFT" \
    && grep -Fq 'prefs.button.apply' "$TERMS_JSON" \
    && grep -Fq '套用' "$TERMS_JSON"; then
    pass "controls: bottom Apply row + About button (re-checked when the chrome flips; wave1r2-fix1 gap lock)"
else
    fail "controls: apply bar missing from the preferences window (or flip refresh lost)"
fi

# wave1r4 — trust device block (implementation): rows = the registry's real values (provider injection along the whole chain); each row's ✕
# = delist, the one-click Reset = truncate; the write-side seams (onTrustDeviceRemove / onTrustReset)
# = share the same writer as the prompt's distrust.
if grep -Fq 'prefs.trust.edit' "$PW_SWIFT" && grep -Fq 'editTrustDevicesClicked' "$PW_SWIFT" \
    && grep -Fq 'prefs.trust.editorTitle' "$PW_SWIFT" && grep -Fq 'prefs.trust.reset' "$PW_SWIFT" \
    && grep -Fq 'prefs.trust.edit' "$TERMS_JSON" && grep -Fq 'prefs.trust.reset' "$TERMS_JSON" \
    && grep -Fq 'trustDevicesProvider' "$PW_SWIFT" && grep -Fq 'makeTrustAccessory' "$PW_SWIFT" \
    && grep -Fq 'onTrustDeviceRemove' "$PW_SWIFT" && grep -Fq 'onTrustReset' "$PW_SWIFT" \
    && grep -Fq 'editTrustButton' "$PF_SWIFT"; then
    pass "trust-device editor sheet: edit button + registry real-value rows + ✕ / Reset write-side seam (dictionary-driven; the list is not embedded)"
else
    fail "trust editor wiring missing (button / rows source / write-side seam)"
fi

if grep -Fq 'PreferencesWindowController(' "$SI_SWIFT"; then
    pass "wiring: PreferencesWindowController instantiated in StatusItemMenu"
else
    fail "wiring: PreferencesWindowController has no instantiation point"
fi

# Red-line self-check: the banned wording (construction by bytes so the
# literal never appears in this file).
BANNED_WORD=$'\xe4\xb8\x8a\xe8\xaa\xb2'
if grep -rq "$BANNED_WORD" "$PROJ/app/Sources/AppShell" "$PROJ/app/Sources/SettingsUI" 2>/dev/null; then
    fail "red-line: banned wording found in AppShell/SettingsUI"
else
    pass "red-line: no banned wording in AppShell/SettingsUI"
fi

# --- red-line: uxplay tree must match the pinned commit ----------------------
# 2026-10-19 decouple: core/uxplay is no longer git-tracked. The upstream tree
# now lives in the build cache, materialized on demand by
# scripts/build/vendor-uxplay.sh from the fork pinned in core/vendor.lock. The red
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

# --- 2. build (into this run's temp directory, via the shared testkit) --------

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

# --- 3. archive previous artefacts (never destroy evidence) ------------------

[ -d "$APPSUP" ] && APPSUP_PREEXISTED=1
if [ -f "$SETTINGS" ]; then
    SETTINGS_PREEXISTED=1
    mv "$SETTINGS" "$RUN/settings.json.prev"
    log "   settings.json pre-existed — moved to run dir (will be restored)"
else
    log "   settings.json absent — fresh-state run (test-created file will be archived out)"
fi

# ui.log needs no archive step any more: testkit_launch pins it to this run's
# own file, so nothing from a previous run can be read here.
[ -f "$LAUNCH_LOG" ] && mv "$LAUNCH_LOG" "$RUN/launch.log.prev"
# wave1r4 — move the REAL trust registry out of the way (the suite would
# otherwise read YC's real devices into the editor and Reset would truncate
# them). Restored exactly by restore_settings.
if [ -f "$REGISTRY" ]; then
    REGISTRY_PREEXISTED=1
    mv "$REGISTRY" "$RUN/registration.list.prev"
    log "   registration.list pre-existed — moved to run dir (will be restored)"
else
    log "   registration.list absent — fresh-state run (test-created file will be archived out)"
fi
[ -f "$SCRATCH/statusicon-sheet.png" ] && mv "$SCRATCH/statusicon-sheet.png" "$RUN/statusicon-sheet.prev.png"
[ -f "$SCRATCH/panel-snapshot.png" ] && mv "$SCRATCH/panel-snapshot.png" "$RUN/panel-snapshot.prev.png"
[ -f "$SCRATCH/panel-pin-on.png" ] && mv "$SCRATCH/panel-pin-on.png" "$RUN/panel-pin-on.prev.png"
[ -f "$SCRATCH/panel-connected.png" ] && mv "$SCRATCH/panel-connected.png" "$RUN/panel-connected.prev.png"
for name in prefs-window prefs-window-dirty prefs-footer-dirty about-window; do
    [ -f "$SCRATCH/$name.png" ] && mv "$SCRATCH/$name.png" "$RUN/$name.prev.png"
done

# --- 4. launch (this run's bundle + this run's ui.log) ------------------------

MIRRORBOARD_UITEST_PREFS=1 testkit_launch
APP_PID="${TEST_APP_PID:-}"
sleep 1
if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    pass "launch ok (pid $APP_PID)"
else
    # testkit sends the app's stdout+stderr to TEST_APP_CONSOLE; mirror it into
    # the run dir before reporting (same diagnostic file name as before).
    cp "$TEST_APP_CONSOLE" "$RUN/app.stdout.log" 2>/dev/null
    fail "launch failed — see $RUN/app.stdout.log"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    testkit_mark_failed
    exit 1
fi

# --- 5. singleton guard runtime (first instance alive → second launch detects + focuses + exit 0) ---

sleep 1.5
# The second instance is launched straight from the bundle testkit_build
# assembled (not via testkit_launch): testkit_launch overwrites TEST_APP_PID,
# and this suite must keep tracking the FIRST instance to prove it survives.
# It gets the same per-run log on purpose — the SINGLETON detection line is
# written by the second process and asserted in this run's ui.log.
MIRAGE_PLAY_UI_LOG="$UI_LOG" MIRRORBOARD_UITEST_PREFS=1 "$EXE" >"$RUN/singleton-second.stdout.log" 2>&1 &
SECOND_PID=$!
waited=0
while kill -0 "$SECOND_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do
    sleep 0.25
    waited=$((waited + 1))
done
if kill -0 "$SECOND_PID" 2>/dev/null; then
    fail "singleton guard: second launch did not exit"
    kill "$SECOND_PID" 2>/dev/null
else
    wait "$SECOND_PID"
    SECOND_RC=$?
    if [ "$SECOND_RC" = "0" ]; then
        pass "singleton guard: second launch exited 0 (self-exit)"
    else
        fail "singleton guard: second launch exit code = $SECOND_RC (expected 0)"
    fi
    SECOND_PID=""
fi
if grep -Fq "SINGLETON detected existing instance pid=$APP_PID" "$UI_LOG" \
    && grep -Fq "SINGLETON detected existing instance pid=$APP_PID focus=" "$UI_LOG" \
    && grep -Fq "focus=" "$UI_LOG"; then
    pass "singleton guard: detected the existing instance pid=${APP_PID} + focus attempt (focus= recorded) + self-exit"
else
    fail "singleton guard: SINGLETON detection line missing (see ui.log)"
fi
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "singleton guard: first instance untouched (pid $APP_PID still alive)"
else
    fail "singleton guard: first instance died during the check"
fi

# --- 6. scripted UI sequence assertions --------------------------------------

wait_for_line "STATUSITEM created" 10 \
    && pass "status item created (ui.log STATUSITEM)" \
    || fail "no STATUSITEM line in ui.log (icon never created)"

wait_for_line "PANEL shown" 8 \
    && pass "panel opens (ui.log PANEL shown)" \
    || fail "panel never shown (no PANEL shown line)"

wait_for_line "PANEL snapshot " 5 \
    && pass "panel render written (visual evidence, AppKit render)" \
    || fail "panel snapshot not written"

# icon sheet rebirth — the file was moved away before launch, so its
# existence now proves a fresh render; the baseline comparison proves the
# shape genuinely replaced the placeholder-era artwork.
wait_for_line "ICONSHEET " 5 \
    && pass "icon sheet reborn (ICONSHEET line)" \
    || fail "icon sheet not written"
if file_nonempty "$SCRATCH/statusicon-sheet.png"; then
    pass "icon sheet file exists and is non-empty (new YC shape render)"
    if [ -f "$BASELINE_FILE" ]; then
        BASE_SUM="$(grep -v '^#' "$BASELINE_FILE" | head -1 | awk '{print $1}')"
        NEW_SUM="$(shasum -a 256 "$SCRATCH/statusicon-sheet.png" | awk '{print $1}')"
        if [ -n "$BASE_SUM" ] && [ "$BASE_SUM" != "$NEW_SUM" ]; then
            pass "icon sheet differs from the placeholder-era baseline — new YC shape rendered"
        elif [ -z "$BASE_SUM" ]; then
            skip "placeholder baseline file has no digest line"
        else
            fail "icon sheet identical to placeholder-era baseline — new shape not rendered"
        fi
    else
        skip "no placeholder baseline recorded ($BASELINE_FILE missing)"
    fi
else
    fail "statusicon-sheet.png missing or empty"
fi

wait_for_line "ACTION prefs-open" 8 \
    && pass "Settings… clicked (ui.log ACTION prefs-open — entry present and clickable)" \
    || fail "Settings… never invoked (entry missing or not clickable)"

wait_for_line "PREFS shown (created)" 8 \
    && pass "preferences window opens (PREFS shown (created))" \
    || fail "preferences window never shown"

# B2 single-page window (wave1r3): the steady frame is 450 wide — the "settled read"
# after a layout pass (cleanfails-diag fix direction ②) — and the geometry line
# proves the centred 336 content column (ruling ①).
wait_for_line "PREFS frame 450x429" 5 \
    && pass "preferences window steady frame 450x429 (EN single page sans Profiles; settled read after layout)" \
    || fail "steady frame line 450x429 missing (see ui.log PREFS frame lines)"
wait_for_line "PREFS layout formx=57 formw=336 winw=450" 5 \
    && pass "geometry: content column 336 @ x=57 (margins 57/57; winw=450)" \
    || fail "geometry line missing or off-centre"

# wave1r3 — footer measurement line (B2 §F; full R1 text judged first): About on the right (aboutx hugs the right edge)
# + the reminder block width vs the available slot full=1 (restore the full text when it fits).
wait_for_line "PREFS footer show" 5 \
    && pass "footer measurement line written (PREFS footer show …)" \
    || fail "footer measurement line missing"
FOOTER_LINE="$(grep -F "PREFS footer show" "$UI_LOG" | head -1)"
FOOTER_ABOUTX="$(printf '%s' "$FOOTER_LINE" | sed -n 's/.*aboutx=\([0-9]*\).*/\1/p')"
if printf '%s' "$FOOTER_LINE" | grep -Fq "full=1"; then
    pass "R1 full text: footer full=1 (the reminder block fits the full text — not truncated)"
else
    fail "R1 full text: footer full=0 (the reminder block does not fit the full text) — got: $FOOTER_LINE"
fi
if [ -n "$FOOTER_ABOUTX" ] && [ "$FOOTER_ABOUTX" -ge 300 ]; then
    pass "About bottom-right: aboutx=${FOOTER_ABOUTX} (18 px from the right edge; right side of the 450 window)"
else
    fail "About bottom-right: aboutx=${FOOTER_ABOUTX:-?} (expected ≥300) — got: $FOOTER_LINE"
fi

wait_for_line "PREFS apply enabled=0 reminder=0" 5 \
    && pass "clean state: apply disabled (grey) + no reminder (reminder=0)" \
    || fail "clean-state apply line missing"

wait_for_line "PREFS snapshot ${SCRATCH}/prefs-window.png" 5 \
    && pass "clean-state render written (prefs-window.png)" \
    || fail "clean render line missing"

# B1 dirty state (R1): a staged edit flips apply on + reminder visible; the render
# is the dirty-state evidence; window height UNCHANGED (R1 adds no height).
wait_for_line "PREFS apply enabled=1 reminder=1" 5 \
    && pass "dirty state: apply enabled (lit) + reminder visible (reminder=1)" \
    || fail "dirty-state apply line missing"
wait_for_line "PREFS snapshot ${SCRATCH}/prefs-window-dirty.png" 5 \
    && pass "dirty-state render written (prefs-window-dirty.png)" \
    || fail "dirty render line missing"
# wave1r3 — footer close-up (B2 §F: About at bottom right + the full R1 reminder).
wait_for_line "PREFS footer snapshot ${SCRATCH}/prefs-footer-dirty.png" 5 \
    && pass "footer close-up render written (prefs-footer-dirty.png)" \
    || fail "footer close-up render line missing"

# About mini-window (credits; wave1r3: entry = the in-window footer's bottom-right button).
wait_for_line "PREFS about entry clicked" 8 \
    && pass "About entry = footer bottom-right button inside the window (PREFS about entry clicked)" \
    || fail "About in-window entry never clicked"
wait_for_line "ACTION about-open" 8 \
    && pass "About entry → window opens (ACTION about-open)" \
    || fail "About entry never invoked"
ENTRY_LINE="$(grep -n -F 'PREFS about entry clicked' "$UI_LOG" | head -1 | cut -d: -f1)"
ACTION_LINE="$(grep -n -F 'ACTION about-open' "$UI_LOG" | head -1 | cut -d: -f1)"
if [ -n "$ENTRY_LINE" ] && [ -n "$ACTION_LINE" ] && [ "$ENTRY_LINE" -le "$ACTION_LINE" ]; then
    pass "About entry ordering: in-window button pressed (line ${ENTRY_LINE}) → about-open (line ${ACTION_LINE})"
else
    fail "About entry chain order wrong (entry line ${ENTRY_LINE:-?} / action line ${ACTION_LINE:-?})"
fi
wait_for_line "ABOUT shown (created)" 5 \
    && pass "About window opens (ABOUT shown (created))" \
    || fail "About window never shown"
wait_for_line "ABOUT frame 360x192" 5 \
    && pass "About window 360x192 (compact mini-window; 169 + the source-link row)" \
    || fail "About frame line missing"
wait_for_line "ABOUT snapshot ${SCRATCH}/about-window.png" 5 \
    && pass "About render written (about-window.png)" \
    || fail "About render line missing"
wait_for_line "LANGAUDIT about lang=en title=About MiragePlay appname=MiragePlay copyright=© 2026 Yu-Cheng Chung and Contributors license=License: GPL-3.0-only thirdParty=Third-party: UxPlay v1.73.6, OpenSSL 3, libplist, GStreamer (fallback leg only) source=Source code" 5 \
    && pass "About rendered strings: copyright attribution + GPL-3.0-only + third-party list + source link (EN)" \
    || fail "About rendered-string audit missing/wrong"
# wave1r3 — window census while About is open (panel + prefs window + About coexist).
wait_for_line "WINDOWS panel=1 prefs=1 about=1 (about open (in-window entry))" 5 \
    && pass "windows audit: About opened from the in-window entry (panel=1 prefs=1 about=1)" \
    || fail "windows audit at About open wrong (see ui.log WINDOWS lines)"
wait_for_line "ABOUT closed" 5 \
    && pass "About window closes (ABOUT closed)" \
    || fail "About never closed"

# wave1r4 — trust editor sheet (implementation): rows = the registry's real values (this suite has already moved the real
# registration.list away for safekeeping → empty registry → rows=0; provider injection is live);
# the one-click Reset = truncate 0 (the same writer as the prompt's distrust; evidence line + file level).
wait_for_line "PREFS trust editor presented (rows=0)" 8 \
    && pass "trust editor sheet: presented (rows=0 — empty registry in this scene; provider injection is live)" \
    || fail "trust editor never presented"
wait_for_line "PREFS trust reset requested (rows=0)" 8 \
    && pass "trust editor sheet: one-click Reset submitted (rows=0)" \
    || fail "trust reset request line missing"
wait_for_line "TRUST reset origin=editor rows=0 removed=0 (file truncated to 0)" 8 \
    && pass "trust editor sheet: Reset → write-side seam (truncate 0; same writer)" \
    || fail "trust reset write-side line missing"
if [ -f "$REGISTRY" ] && [ ! -s "$REGISTRY" ]; then
    pass "trust editor sheet: registration.list is 0 bytes on disk (truncate proven)"
else
    fail "trust reset did not truncate the registry file (missing or non-empty)"
fi
wait_for_line "PREFS trust editor dismissed" 8 \
    && pass "trust editor sheet: dismissed (the sheet collapses, the flow continues)" \
    || fail "trust editor never dismissed"

# apply clears the dirty state (ruling ⑤/R1: after applying the reminder goes and the button turns grey).
wait_for_line "PREFS apply requested" 8 \
    && pass "Apply clicked (PREFS apply requested)" \
    || fail "apply never invoked"
wait_for_count "$UI_LOG" "PREFS apply enabled=0 reminder=0" 2 8 \
    && pass "after Apply: dirty cleared + reminder gone (enabled=0 reminder=0 again)" \
    || fail "apply did not return the window to the clean state"

# wave1r3 — slider settled path: the resolution slider→2160p (staged; dirty=1); after closing the window
# the reopened real value is still res=1440p (never took effect).
wait_for_line "PREFS staged name=MiragePlay res=2160p fps=30 mute=off sleep=on notify=on lang=en profile=預設 dirty=1" 8 \
    && pass "slider path: resolution slider→2160p (settled commit; staged)" \
    || fail "slider staged line missing (res=2160p)"
wait_for_line "PREFS staged discarded (unapplied)" 8 \
    && pass "staged slider value discarded on close (PREFS staged discarded (unapplied))" \
    || fail "discard line missing after slider-stage close"
wait_for_count "$UI_LOG" "PREFS values res=1440p fps=30 mute=off name=MiragePlay pin=- sleep=on notify=on profile=預設" 2 8 \
    && pass "discard proven: reopen shows the real value res=1440p (2160p never written back)" \
    || fail "reopened truth line after slider discard missing"
if ! grep -Fq 'PREFS values res=2160p' "$UI_LOG"; then
    pass "discard proven: res=2160p never appears in PREFS values"
else
    fail "discarded slider value leaked into the truth line"
fi

wait_for_line "PREFS shown (reused)" 8 \
    && pass "single instance: reopening reuses the window (PREFS shown (reused))" \
    || fail "reopen created a new instance / never reused"

wait_for_line "WINDOWS panel=1 prefs=1 about=0 (after reopen (singleton))" 5 \
    && pass "windows audit: panel + prefs coexist, About closed (panel=1 prefs=1 about=0)" \
    || fail "windows audit after reopen wrong (see ui.log WINDOWS lines)"

wait_for_line "PREFS closed" 8 \
    && pass "red-light close works (PREFS closed)" \
    || fail "preferences window never closed"

wait_for_line "WINDOWS panel=1 prefs=0 about=0 (after close)" 5 \
    && pass "windows audit: panel remains, prefs gone (panel=1 prefs=0 about=0)" \
    || fail "windows audit after close wrong"

wait_for_line "WINDOWS panel=1 prefs=1 about=0 (after reopen 2)" 5 \
    && pass "windows audit: reopen after close works (panel=1 prefs=1 about=0)" \
    || fail "reopen 2 audit wrong"

wait_for_line "WINDOWS panel=1 prefs=0 about=0 (after close 2)" 5 \
    && pass "windows audit: second close clean (panel=1 prefs=0 about=0)" \
    || fail "close 2 audit wrong"

wait_for_line "PANEL hidden" 8 \
    && pass "panel closes (ui.log PANEL hidden)" \
    || fail "panel never hidden"

wait_for_line "WINDOWS panel=0 prefs=0 about=0 (final)" 5 \
    && pass "windows audit: zero control-surface windows left (panel=0 prefs=0 about=0)" \
    || fail "final windows audit not clean — residue window risk"

# visual evidence files (renders were moved away pre-launch too)
if file_nonempty "$SCRATCH/prefs-window.png"; then
    pass "prefs-window.png written (clean-state render, non-empty)"
    WIDTH="$(png_width "$SCRATCH/prefs-window.png")"
    HEIGHT_CLEAN="$(png_height "$SCRATCH/prefs-window.png")"
    if [ "$WIDTH" = "450" ]; then
        pass "prefs-window.png width == 450 px (width lock holds; one of the two cleanfails-diag acceptance locks)"
    else
        fail "prefs-window.png width = ${WIDTH:-?} px (expected exactly 450)"
    fi
else
    fail "prefs-window.png missing or empty"
fi
if file_nonempty "$SCRATCH/prefs-window-dirty.png"; then
    pass "prefs-window-dirty.png written (dirty-state render, non-empty)"
    WIDTH_D="$(png_width "$SCRATCH/prefs-window-dirty.png")"
    HEIGHT_DIRTY="$(png_height "$SCRATCH/prefs-window-dirty.png")"
    if [ "$WIDTH_D" = "450" ]; then
        pass "prefs-window-dirty.png width == 450 px (the dirty state keeps the same width lock)"
    else
        fail "prefs-window-dirty.png width = ${WIDTH_D:-?} px (expected exactly 450)"
    fi
    if [ -n "$HEIGHT_CLEAN" ] && [ "$HEIGHT_CLEAN" = "$HEIGHT_DIRTY" ]; then
        pass "R1 adds no height: clean/dirty heights identical (${HEIGHT_CLEAN} px)"
    else
        fail "R1 height drift: clean=${HEIGHT_CLEAN:-?} dirty=${HEIGHT_DIRTY:-?}"
    fi
    if [ "$(shasum -a 256 "$SCRATCH/prefs-window.png" | awk '{print $1}')" != "$(shasum -a 256 "$SCRATCH/prefs-window-dirty.png" | awk '{print $1}')" ]; then
        pass "dirty-state render differs from the clean state (the reminder is in frame)"
    else
        fail "dirty render identical to clean render — R1 reminder not rendered"
    fi
else
    fail "prefs-window-dirty.png missing or empty"
fi
# wave1r3 — footer close-up: 450 wide, compact band (≈50 px), non-empty.
if file_nonempty "$SCRATCH/prefs-footer-dirty.png"; then
    pass "prefs-footer-dirty.png written (footer close-up, non-empty)"
    WIDTH_F="$(png_width "$SCRATCH/prefs-footer-dirty.png")"
    HEIGHT_F="$(png_height "$SCRATCH/prefs-footer-dirty.png")"
    if [ "$WIDTH_F" = "450" ]; then
        pass "prefs-footer-dirty.png width == 450 px (the footer band spans the window)"
    else
        fail "prefs-footer-dirty.png width = ${WIDTH_F:-?} px (expected 450)"
    fi
    if [ -n "$HEIGHT_F" ] && [ "$HEIGHT_F" -ge 40 ] && [ "$HEIGHT_F" -le 80 ]; then
        pass "prefs-footer-dirty.png height == ${HEIGHT_F} px (footer band: separator→window bottom)"
    else
        fail "prefs-footer-dirty.png height = ${HEIGHT_F:-?} px (expected ~40–80)"
    fi
else
    fail "prefs-footer-dirty.png missing or empty"
fi
if file_nonempty "$SCRATCH/about-window.png"; then
    pass "about-window.png written (About render, non-empty)"
    WIDTH_A="$(png_width "$SCRATCH/about-window.png")"
    if [ "$WIDTH_A" = "360" ]; then
        pass "about-window.png width == 360 px"
    else
        fail "about-window.png width = ${WIDTH_A:-?} px (expected 360)"
    fi
else
    fail "about-window.png missing or empty"
fi

# --- PIN protection + name (added by YC) visual layer -------------------------
# D segment power-on: the toggle now goes through the real engine write (+⑫) and the
# code row shows the engine truth; receiver is not started here (write-back
# only, zero spawn). settings.json is restored by the cleanup trap.
# wave1r3: panel heights 212/192 (the About row withdrawn — B2 ruling ③).

wait_for_line "PIN toggled on (panel 300x212)" 12 \
    && pass "PIN on → code row appears, panel re-sizes to 300x212 (after the About row was retired)" \
    || fail "PIN on never applied (conditional code row missing?)"

wait_for_line "STATE connected(YC 的 iPad)" 8 \
    && pass "connected status row rendered (name: Connected to <device name>, real updateState path)" \
    || fail "connected state never rendered"

wait_for_line "PIN toggled off (panel 300x192)" 8 \
    && pass "PIN off → code row hides, panel re-sizes to 300x192 (after the About row was retired)" \
    || fail "PIN off never applied"

wait_for_line "WINDOWS panel=0 prefs=0 about=0 (post-pin final)" 8 \
    && pass "windows audit after the PIN/name exercise: clean (panel=0 prefs=0 about=0)" \
    || fail "post-PIN windows audit not clean"

if file_nonempty "$SCRATCH/panel-pin-on.png"; then
    pass "panel-pin-on.png written (PIN-on + code row render, visual evidence)"
else
    fail "panel-pin-on.png missing or empty"
fi
if file_nonempty "$SCRATCH/panel-connected.png"; then
    pass "panel-connected.png written (connected-name render, visual evidence)"
else
    fail "panel-connected.png missing or empty"
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

# --- 7. residue ---------------------------------------------------------------

sleep 1
if pgrep -x MiragePlay >/dev/null 2>&1; then
    fail "residue: MiragePlay still running"
else
    pass "residue: no MiragePlay"
fi
if pgrep -x uxplay >/dev/null 2>&1; then
    fail "residue: uxplay still running"
else
    pass "residue: no uxplay (receiver was never started in this sequence)"
fi

# advisory: receiver-side crash respawn lines in this run's launch.log
if [ -f "$LAUNCH_LOG" ] && grep -Fq "CRASH respawn" "$LAUNCH_LOG"; then
    log "NOTE  launch.log contains 'CRASH respawn' during this run — inspect $RUN/launch.log"
fi

# --- evidence copy + summary --------------------------------------------------

cp "$UI_LOG" "$RUN/ui.log" 2>/dev/null
cp "$LAUNCH_LOG" "$RUN/launch.log" 2>/dev/null
cp "$SCRATCH/panel-snapshot.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/panel-pin-on.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/panel-connected.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/statusicon-sheet.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/prefs-window.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/prefs-window-dirty.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/prefs-footer-dirty.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/about-window.png" "$RUN/" 2>/dev/null

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
