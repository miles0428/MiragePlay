#!/bin/bash
# test-language.sh — wave1r3 (B2 slider batch) language test (term-dictionary model; single-page window).
#
# Covers (per the wave1r3 task card ⑤ + the YC rulings):
#   ① first run defaults to English — new profile / first run = en (R4-Q1 "default English")
#   ② language control = the single-page "Language" group — B2 single-page change (tabs withdrawn; 3 group caps); switching =
#      STAGED (nothing takes effect yet: the picker shows the new choice, strings stay untranslated); apply = the whole UI switches
#      at once + persistence (written to settings.json; the phase B relaunch draws zh-Hans from the first frame). (wave1r2-fix1:
#      the LANGAUDIT prefs record carries an apply= field; wave1r3 adds an about= field — the About button at the window bottom;
#      expectations for all three languages)
#   ③ switch to zh-Hans — same as above (staged + apply) + the rendered audit
#   ④ missing-key fallback — LocalizationSelfTest (selected→en→key chain +
#      miss records) + the phase C on-device fixture (MIRRORBOARD_STRINGS_PATH points at a dictionary whose
#      zh-Hans entries are missing → rendering falls back to en + a `LANG missing` line)
#   ⑤ receiver impact follows E1 row 12 — language is shell-owned: apply triggers no restart, no new spawn,
#      and spawn argv shows no language trace (ledger assertion)
#   ⑥ window width 450 in all three languages (width lock; double lock in the cleanfails-diag acceptance) — LANGAUDIT prefs
#      frame=450x{467 EN / 459 zh} (steady-state value after layout) + all three PNG widths ==450;
#      EN / zh-Hant renders kept as evidence (prefs-window-en.png / prefs-window-hant.png)
#      + the zh-Hant dirty render (full R1 reminder) + footer close-up
#      (prefs-footer-hant-dirty.png — About at bottom right + the full R1 text) + the About window render
#      (about-window-hant.png); 51 dictionary keys (wave1r4: + 5 trust.ask keys, + about.source —
#      the trust prompt copy; wave1r3: 18 Profiles display keys
#      retired + prefs.button.about added)
#
# Also: dictionary structure checks (format/languages/term integrity) / source walk (UI files carry zero Chinese
# literals, every dictionary key resolves) / wiring statics / red-line self-check (banned wording, the uxplay tree
# matches the pinned commit) / LocalizationSelfTest / build with 0 warnings.
#
# Phases (one script order; driven by the app's own UITestDriver Timeline ⑧/⑧-B/⑧-C):
#   A: MIRRORBOARD_UITEST_LANGUAGE=1 (en→zh-Hant→zh-Hans→zh-Hant; all staged +
#      applied; switched again while running)
#   B: MIRRORBOARD_UITEST_LANGUAGE=2 (relaunch; the restart brings the language back)
#   C: MIRRORBOARD_UITEST_LANGUAGE=3 + MIRRORBOARD_STRINGS_PATH=<fixture>
#
# The test cleans up after itself (settings.json kept / restored; Abort if a live instance runs).
#
# Usage:  ./scripts/tests/test-language.sh
# Evidence: <testkit evidence dir>/testrun-language-<YYYYmmdd_HHMMSS>/ — the
# testkit keeps that temp directory only when the run fails.

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
    echo "test-language: cannot create the per-run temp workspace" >&2
    exit 1
}
RUN="$(testkit_evidence_dir)/testrun-language-$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$RUN" || exit 1

# Assertions read the testkit's per-run UI log (one file per run, so a line left
# behind by an earlier run can never satisfy this run's assertion). The app's
# PNG/scratch artefacts stay in the fixed per-bundle temp subtree the app owns.
UI_LOG="$(testkit_ui_log)"
SCRATCH_ROOT="${TMPDIR:-/tmp}"; SCRATCH_ROOT="${SCRATCH_ROOT%/}"
SCRATCH="$SCRATCH_ROOT/com.ycchung.mirageplay"
LOC_DIR="$PROJ/app/Sources/Localization"
TERMS_JSON="$PROJ/app/Resources/Strings/terms.json"
SP_SWIFT="$PROJ/app/Sources/AppShell/StatusPanelController.swift"
SI_SWIFT="$PROJ/app/Sources/AppShell/StatusItemMenu.swift"
LC_SWIFT="$PROJ/app/Sources/AppShell/LifecycleCoordinator.swift"
IH_SWIFT="$PROJ/app/Sources/AppShell/PreferencesIntentHandler.swift"
CR_SWIFT="$PROJ/app/Sources/AppShell/CompositionRoot.swift"
AD_SWIFT="$PROJ/app/Sources/AppShell/AppDelegate.swift"
UTD_SWIFT="$PROJ/app/Sources/AppShell/UITestDriver.swift"
PW_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesWindowController.swift"
PF_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesFormViews.swift"
PI_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesIntent.swift"
AW_SWIFT="$PROJ/app/Sources/SettingsUI/AboutWindowController.swift"
TPL_SWIFT="$PROJ/app/Sources/SessionNotifier/Templates.swift"
SN_SWIFT="$PROJ/app/Sources/SessionNotifier/SessionNotifier.swift"
CB_SWIFT="$PROJ/app/Sources/core-bridge/CoreBridgeReceiverController.swift"
APPSUP="$HOME/Library/Application Support/com.ycchung.mirageplay"
SETTINGS="$APPSUP/settings.json"
# launch.log is the receiver's spawn channel (the three frozen match strings and
# the MIRRORBOARD SPAWN argv ledger live there). The app keeps it in Application
# Support so it survives a relaunch, which is also where the ledger tails it.
LAUNCH_LOG="$APPSUP/launch.log"
DICT_REAL_PATH="$PROJ/app/Resources/Strings/terms.json"

FIXTURE="$SCRATCH/terms-fixture-missing-waiting.json"

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
skip() { SKIP=$((SKIP + 1)); log "SKIP  $1"; }

# --- user-state restore (settings.json kept / restored; zero deletion) -------

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

wait_for_line() { # <fixed-pattern> <timeout_sec>
    wait_for_count "$UI_LOG" "$1" 1 "${2:-10}"
}

png_width() { sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/ {print $2}'; }

# launch.log is a generation file truncated on every new user start (C segment semantics) — this sequence does several start/
# stop cycles and several phases, so old-generation markers get truncated; a resident collector therefore copies every
# SPAWN marker it sees (deduplicated by pid) into $RUN/spawn-collected.txt as the complete ledger for this run.
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

log "== wave1r2 language test (B1 single page) — $(date '+%Y-%m-%d %H:%M:%S %Z') =="
log "   run dir: $RUN"

if ! testkit_preflight_clean; then
    log "ABORT: MiragePlay or uxplay is already running — refusing to touch a live instance."
    exit 2
fi
pass "preflight: zero pre-existing MiragePlay/uxplay"

# --- 1. dictionary structure (the config itself) -----------------------------

DICT_SUMMARY="$(python3 - "$TERMS_JSON" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
terms = d.get("terms", {})
manifest = [
    "panel.status.idle","panel.status.waiting","panel.status.connected",
    "panel.status.stopping","panel.status.startFailed","panel.status.startFailedGeneric",
    "panel.button.start","panel.button.stop","panel.pin.protection","panel.pin.code",
    "panel.pin.change","panel.entry.preferences","panel.entry.quit",
    "menu.tooltip",
    "prefs.window.title","prefs.tab.videoAudio","prefs.tab.connection",
    "prefs.tab.language",
    "prefs.row.resolution","prefs.row.frameRate","prefs.row.mute",
    "prefs.button.apply","prefs.button.about","prefs.apply.reminder","prefs.row.deviceName","prefs.row.pinChange",
    "prefs.row.trusted","prefs.trust.empty","prefs.trust.edit","prefs.trust.editorTitle",
    "prefs.trust.reset","prefs.trust.done",
    "trust.ask.windowTitle","trust.ask.title","trust.ask.message",
    "trust.ask.accept","trust.ask.decline",
    "prefs.row.preventSleep",
    "prefs.row.notifications",
    "prefs.row.language","lang.option.en","lang.option.zh-Hant",
    "lang.option.zh-Hans",
    "about.title","about.appName","about.copyright","about.license","about.thirdParty",
    "about.source",
    "notify.connected","notify.disconnected",
]
missing = [k for k in manifest if k not in terms]
incomplete = sorted(t for t, v in terms.items()
                    if any(not v.get(l) for l in ("en","zh-Hant","zh-Hans")))
removed = [k for k in ("prefs.tab.license","prefs.license.copyright",
                       "prefs.license.license","prefs.license.thirdParty",
                       "prefs.helper.appliesOnApply","prefs.tag.laterVersion",
                       "prefs.row.recording","prefs.row.switchScreen","prefs.tag.v1x",
                       "prefs.tab.profiles","prefs.row.profile","prefs.profile.default",
                       "prefs.profile.saveAs",
                       "prefs.saveAs.title","prefs.saveAs.message","prefs.saveAs.placeholder",
                       "prefs.saveAs.confirm","prefs.saveAs.cancel","prefs.saveAs.emptyName",
                       "prefs.saveAs.exists","prefs.saveAs.overwriteMessage",
                       "prefs.saveAs.overwrite","prefs.saveAs.invalidName",
                       "prefs.saveAs.failed","prefs.saveAs.failedMessage","prefs.saveAs.ok",
                       "panel.entry.about")
           if k in terms]
print(json.dumps({
    "format": d.get("format"),
    "languages": d.get("languages"),
    "default": d.get("defaultLanguage"),
    "count": len(terms),
    "missing": missing,
    "incomplete": incomplete,
    "removed_still_present": removed,
}, ensure_ascii=False))
PY
)"
log "   dictionary summary: $DICT_SUMMARY"
if echo "$DICT_SUMMARY" | grep -Fq '"format": "mirrorboard-term-dictionary"' \
    && echo "$DICT_SUMMARY" | grep -Fq '"languages": ["en", "zh-Hant", "zh-Hans"]' \
    && echo "$DICT_SUMMARY" | grep -Fq '"default": "en"'; then
    pass "dictionary: format/languages (three-language set per contract L146) / default=en (English default)"
else
    fail "dictionary: format/languages/default wrong — $DICT_SUMMARY"
fi
if echo "$DICT_SUMMARY" | grep -Fq '"missing": []' \
    && echo "$DICT_SUMMARY" | grep -Fq '"incomplete": []' \
    && echo "$DICT_SUMMARY" | grep -Fq '"removed_still_present": []' \
    && [ "$(echo "$DICT_SUMMARY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')" = "51" ]; then
    pass "dictionary: all 51 manifest keys present + every term non-empty in all three languages + retired keys (copyright page / reminder hint / future rows / Profiles 18 keys) fully gone"
else
    fail "dictionary: manifest/completeness gap — $DICT_SUMMARY"
fi

# --- 2. source migration (walk: no Chinese literals in UI files; every key resolves) ---

if grep -Fq 'panel.status.idle' "$SP_SWIFT" && grep -Fq 'panel.status.waiting' "$SP_SWIFT" \
    && grep -Fq 'panel.entry.preferences' "$SP_SWIFT" && grep -Fq 'panel.pin.change' "$SP_SWIFT" \
    && grep -Fq 'panel.entry.quit' "$SP_SWIFT" \
    && ! grep -Fq '"未開啟"' "$SP_SWIFT" && ! grep -Fq '"偏好設定…"' "$SP_SWIFT" \
    && ! grep -Fq '"更換"' "$SP_SWIFT"; then
    pass "migration: StatusPanelController = dictionary lookups (wave1r3: About row retired) + zero hard-coded CJK strings"
else
    fail "migration: StatusPanelController still carries hard-coded strings"
fi
if grep -Fq 'prefs.window.title' "$PW_SWIFT" && grep -Fq 'prefs.button.about' "$PW_SWIFT" \
    && grep -Fq 'prefs.button.apply' "$PW_SWIFT" && grep -Fq 'prefs.apply.reminder' "$PW_SWIFT" \
    && ! grep -Fq '"偏好設定"' "$PW_SWIFT" && ! grep -Fq '已存在同名配置檔' "$PW_SWIFT"; then
    pass "migration: PreferencesWindowController = dictionary lookups (incl. R1 reminder + About button) + zero hard-coded CJK"
else
    fail "migration: PreferencesWindowController still carries hard-coded strings"
fi
if grep -Fq 'prefs.row.language' "$PF_SWIFT" && grep -Fq 'languagePopup' "$PF_SWIFT" \
    && grep -Fq 'buildSinglePage' "$PF_SWIFT" \
    && ! grep -Fq '"裝置名稱"' "$PF_SWIFT" && ! grep -Fq '"錄影"' "$PF_SWIFT"; then
    pass "migration: PreferencesFormViews = dictionary lookups + B1 single-page builder + zero hard-coded CJK"
else
    fail "migration: PreferencesFormViews still carries hard-coded strings"
fi
if grep -Fq 'about.title' "$AW_SWIFT" && grep -Fq 'about.copyright' "$AW_SWIFT" \
    && ! grep -Fq '鍾宇程' "$AW_SWIFT"; then
    pass "migration: AboutWindowController = dictionary lookups + zero hard-coded CJK"
else
    fail "migration: AboutWindowController hard-coded strings"
fi
if grep -Fq 'localization.t("notify.connected"' "$TPL_SWIFT" \
    && grep -Fq 'localization.t("notify.disconnected")' "$TPL_SWIFT" \
    && ! grep -Fq '已連線：\(device\)' "$TPL_SWIFT"; then
    pass "migration: notification templates = dictionary lookups (hard-coded strings retired)"
else
    fail "migration: Templates still hard-coded"
fi

# --- 3. wiring statics ------------------------------------------------------

if [ -f "$LOC_DIR/TermDictionary.swift" ] && [ -f "$LOC_DIR/LanguageService.swift" ] \
    && grep -Fq 'MIRRORBOARD_STRINGS_PATH' "$LOC_DIR/LanguageService.swift" \
    && grep -Fq 'public static let bundleDictionarySubdirectory = "Strings"' "$LOC_DIR/LanguageService.swift" \
    && grep -Fq 'appendingPathComponent("Contents/Resources"' "$LOC_DIR/LanguageService.swift" \
    && grep -Fq 'bundle: Bundle = .main' "$LOC_DIR/LanguageService.swift" \
    && ! grep -Fq 'defaultProjectRoot' "$LOC_DIR/LanguageService.swift" \
    && ! grep -Fq 'dictionaryRelativePath' "$LOC_DIR/LanguageService.swift"; then
    pass "localization: bundle-relative dictionary resolution + zero hard-coded project root"
else
    fail "localization: bundle-relative dictionary resolution missing or hard-coded path returned"
fi
if grep -Fq 'localization: LanguageService' "$SI_SWIFT" && grep -Fq 'selectPreferencesLanguage' "$SI_SWIFT" \
    && grep -Fq 'languageAuditPanel' "$SI_SWIFT" && grep -Fq 'languageAuditAbout' "$SI_SWIFT"; then
    pass "wiring: StatusItemMenu injects the service + language seam + audit (panel/prefs/about)"
else
    fail "wiring: StatusItemMenu language wiring missing"
fi
if grep -Fq 'preferencesApplyRequested' "$PI_SWIFT" && grep -Fq 'StagedSettings' "$PI_SWIFT" \
    && grep -Fq 'try engine.setLanguage' "$IH_SWIFT" && grep -Fq 'localization.setLanguage' "$IH_SWIFT" \
    && grep -Fq 'coordinator?.languageChanged()' "$IH_SWIFT"; then
    pass "wiring: staged apply intents (language goes through Apply: engine write + service retranslate + coordinator trace)"
else
    fail "wiring: language intent chain incomplete"
fi
# B2 single-page window (wave1r3: 3 group caps; Profiles display keys retired + About button key added):
# the language control moved into the single-page "Language" group; tab / page height / credits-page builders all withdrawn (credits =
# AboutWindowController). Icons removed everywhere (PanelGlyphs is gone).
if grep -Fq 'buildSinglePage' "$PW_SWIFT" && grep -Fq 'prefs.tab.language' "$PF_SWIFT" \
    && grep -Fq 'prefs.button.about' "$TERMS_JSON" \
    && ! grep -Fq '"prefs.tab.profiles"' "$TERMS_JSON" \
    && ! grep -Fq 'buildLicensePage' "$PW_SWIFT" && ! grep -Fq 'buildLanguagePage' "$PW_SWIFT" \
    && ! grep -Fq 'pageLanguageHeight' "$PW_SWIFT" && ! grep -Fq 'pageLicenseHeight' "$PW_SWIFT" \
    && ! grep -Fq 'PanelGlyphs' "$PW_SWIFT" && ! grep -Fq 'PanelGlyphs' "$SP_SWIFT"; then
    pass "B2 single page: buildSinglePage + Language group + tabs/copyright page/page heights all retired (copyright = About) + icons all gone"
else
    fail "B2 single-page wiring missing in PreferencesWindowController"
fi
if grep -Fq 'func languageChanged()' "$LC_SWIFT" && grep -Fq 'launchFailureMarker' "$LC_SWIFT" \
    && grep -Fq 'launchFailureMarker' "$CB_SWIFT" && ! grep -Fq '啟動失敗' "$CB_SWIFT"; then
    pass "wiring: E1-row-12 trace + a2 short-cause marker (core-bridge is language-neutral)"
else
    fail "wiring: coordinator/marker wiring incomplete"
fi
if grep -Fq 'LanguageService(' "$CR_SWIFT" && grep -Fq 'onMissingTerm' "$CR_SWIFT" \
    && grep -Fq 'logDictionaryState' "$CR_SWIFT"; then
    pass "wiring: CompositionRoot builds the service + miss hook + dictionary evidence line"
else
    fail "wiring: CompositionRoot language wiring missing"
fi
if grep -Fq 'MIRRORBOARD_UITEST_LANGUAGE' "$AD_SWIFT" \
    && grep -Fq 'runLanguage' "$UTD_SWIFT" && grep -Fq 'runLanguageRestart' "$UTD_SWIFT" \
    && grep -Fq 'runLanguageFixture' "$UTD_SWIFT"; then
    pass "harness: MIRRORBOARD_UITEST_LANGUAGE three branches + Timeline ⑧/⑧-B/⑧-C"
else
    fail "harness: language harness missing"
fi

# Red-line self-check: the banned wording (construction by bytes so the
# literal never appears in this file).
BANNED_WORD=$'\xe4\xb8\x8a\xe8\xaa\xb2'
if grep -rq "$BANNED_WORD" "$PROJ/app/Sources/AppShell" "$PROJ/app/Sources/SettingsUI" \
    "$PROJ/app/Sources/Localization" "$PROJ/app/Sources/SessionNotifier" "$TERMS_JSON" 2>/dev/null; then
    fail "red-line: banned wording found in section-G sources/dictionary"
else
    pass "red-line: no banned wording in section-G sources/dictionary"
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

# --- 4. LocalizationSelfTest (dictionary + lookup + fallback unit side) --------

# The self-test gets its own SwiftPM scratch dir inside the testkit's build
# cache: outside the checkout, reused across runs (compiled once), and named
# here instead of being read out of the build tool's bundle layout.
if swift run --package-path "$PROJ/app" \
        --scratch-path "$MIRAGE_PLAY_BUILD_ROOT/selftest" LocalizationSelfTest \
        >"$RUN/localization-self-test.log" 2>&1; then
    if grep -Fq "RESULT: PASS" "$RUN/localization-self-test.log"; then
        pass "LocalizationSelfTest: PASS（$(grep -o 'RESULT: PASS ([0-9]* checks)' "$RUN/localization-self-test.log" | head -1)）"
    else
        fail "LocalizationSelfTest: no PASS verdict — see $RUN/localization-self-test.log"
    fi
else
    fail "LocalizationSelfTest: build/run failed — see $RUN/localization-self-test.log"
fi

# --- 5. build (0 warnings / 0 errors) ----------------------------------------
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
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    exit 1
fi

EXE="$(testkit_app_binary)"
if [ -z "$EXE" ] || [ ! -x "$EXE" ]; then
    fail "built executable not found ($EXE)"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    exit 1
fi
log "   executable: $EXE"

# --- 6. archive previous artefacts + user state ------------------------------

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
rm -f "$FIXTURE"

# --- 7. phase A: en → zh-Hant → zh-Hans → zh-Hant (re-flip while running) -----

spawn_collector &
COLLECT_PID=$!

A_FROM=$(($(wc -c < "$TEST_APP_CONSOLE" 2>/dev/null || echo 0) + 1))
# Phase A launches the ASSEMBLED BUNDLE's executable: Bundle.main is the .app,
# so the projection helper resolves from inside the bundle the way it does in
# the shipped product — not from a raw build-directory binary, which hides no
# bundle at all and therefore could never find its helper.
MIRRORBOARD_UITEST_LANGUAGE=1 MIRRORBOARD_STRINGS_PATH="$DICT_REAL_PATH" testkit_launch
APP_PID="${TEST_APP_PID:-}"
sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    pass "phase A: launch ok (pid $APP_PID)"
else
    tail -c "+$A_FROM" "$TEST_APP_CONSOLE" >"$RUN/app.stdout.phase-a.log" 2>/dev/null
    fail "phase A: launch failed — see $RUN/app.stdout.phase-a.log"
    log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
    exit 1
fi

wait_for_line "LANG dictionary loaded path=$DICT_REAL_PATH terms=51 languages=en,zh-Hant,zh-Hans" 10 \
    && pass "phase A: dictionary loaded (injection point + 51 terms + three languages)" \
    || fail "phase A: no dictionary load line"

# ① first run defaults to English — the FIRST audit renders EN.
wait_for_line "LANGAUDIT panel lang=en status=Stopped button=Start pin=PIN Protection change=New Code entry=Preferences… quit=Quit tooltip=MiragePlay" 10 \
    && pass "① first run defaults to English: panel rendered audit (wave1r3: About row retired — panel = PIN code→Start→Settings→Quit; zero CJK strings)" \
    || fail "① default-English panel audit missing"

# ⑥ window width is always 450 (width lock; steady-state value after layout). B2: the en prefs audit has 3 caps + the about field.
wait_for_count "$UI_LOG" "PREFS frame 450x429" 1 8 \
    && pass "phase A: prefs steady frame 450x429 (EN single page without Profiles; value read after layout)" \
    || fail "phase A: steady frame line missing"
wait_for_count "$UI_LOG" "LANGAUDIT prefs lang=en title=Preferences cap0=Video & Audio cap1=Connection & Session cap2=Language langrow=Language language=English apply=Apply about=About… frame=450x429" 1 8 \
    && pass "① prefs rendered audit (title / 3 group caps / language row / English selected / About button; frame=450x429)" \
    || { fail "① default-English prefs audit missing/wrong"; grep -F "LANGAUDIT prefs lang=en" "$UI_LOG" | tail -2 | sed 's/^/      got: /' >> "$RUN/summary.txt"; }
wait_for_count "$UI_LOG" "PREFS snapshot ${SCRATCH}/prefs-window-en.png" 1 8 \
    && pass "⑥ EN render captured (prefs-window-en.png; single page)" \
    || fail "prefs-window-en.png render line missing"

# ② switching to zh-Hant is STAGED: the picker shows Traditional Chinese, strings stay en; only apply takes effect.
wait_for_count "$UI_LOG" "PREFS staged name=MiragePlay res=1080p fps=30 mute=off sleep=on notify=on lang=zh-Hant profile=預設 dirty=1" 1 8 \
    && pass "② staged switch to Traditional Chinese (PREFS staged lang=zh-Hant; not applied)" \
    || fail "② staged zh-Hant line missing"
wait_for_count "$UI_LOG" "LANGAUDIT prefs lang=en title=Preferences cap0=Video & Audio cap1=Connection & Session cap2=Language langrow=Language language=繁體中文 apply=Apply about=About… frame=450x429" 1 8 \
    && pass "② staged proven: strings still en, picker already shows Traditional Chinese (no live retranslate)" \
    || fail "② staged audit (strings still EN) missing"
wait_for_line "ACTION language zh-Hant (shell-held, no restart)" 8 \
    && pass "② Apply → Traditional Chinese: ACTION language zh-Hant (shell-held — receiver untouched)" \
    || fail "② zh-Hant action line missing"
wait_for_count "$UI_LOG" "LANGAUDIT panel lang=zh-Hant status=未開啟 button=啟動 pin=PIN 保護 change=更換 entry=偏好設定… quit=退出 tooltip=MiragePlay" 1 8 \
    && pass "② applied live: panel retranslated to Traditional Chinese (rendered audit; About row retired)" \
    || fail "② zh-Hant panel audit missing"
wait_for_count "$UI_LOG" "LANGAUDIT prefs lang=zh-Hant title=偏好設定 cap0=影像與聲音 cap1=連線與工作階段 cap2=語言 langrow=語言 language=繁體中文 apply=套用 about=關於… frame=450x429" 1 8 \
    && pass "② applied live: prefs window retranslated to Traditional Chinese (rendered audit; frame=450x429 — zh steady-state width lock)" \
    || { fail "② zh-Hant prefs audit missing/wrong"; grep -F "LANGAUDIT prefs lang=zh-Hant" "$UI_LOG" | tail -2 | sed 's/^/      got: /' >> "$RUN/summary.txt"; }
wait_for_count "$UI_LOG" "PREFS snapshot ${SCRATCH}/prefs-window-hant.png" 1 8 \
    && pass "⑥ Traditional Chinese render captured (prefs-window-hant.png; single page)" \
    || fail "prefs-window-hant.png render line missing"

# wave1r2 — zh-Hant dirty render (R1 reminder; language change staged, not applied).
wait_for_count "$UI_LOG" "PREFS staged name=MiragePlay res=1080p fps=30 mute=off sleep=on notify=on lang=en profile=預設 dirty=1" 1 8 \
    && pass "⑨ Traditional Chinese dirty: staged language→en (reminder visible; not applied)" \
    || fail "⑨ hant dirty staged line missing"
wait_for_count "$UI_LOG" "PREFS snapshot ${SCRATCH}/prefs-window-hant-dirty.png" 1 8 \
    && pass "⑨ Traditional Chinese dirty render captured (prefs-window-hant-dirty.png)" \
    || fail "prefs-window-hant-dirty.png render line missing"
wait_for_count "$UI_LOG" "PREFS footer snapshot ${SCRATCH}/prefs-footer-hant-dirty.png" 1 8 \
    && pass "⑨ Traditional Chinese footer close-up captured (prefs-footer-hant-dirty.png — About bottom-right + full R1 text)" \
    || fail "prefs-footer-hant-dirty.png render line missing"
wait_for_count "$UI_LOG" "PREFS staged name=MiragePlay res=1080p fps=30 mute=off sleep=on notify=on lang=zh-Hant profile=預設 dirty=0" 2 8 \
    && pass "⑨ staged language reset (dirty=0; not applied)" \
    || fail "⑨ hant reset staged line missing"

# wave1r2 — About window (zh-Hant): rendered strings + render + close.
wait_for_line "ABOUT shown (created)" 8 \
    && pass "⑨ About window opened (ABOUT shown (created))" \
    || fail "About window never shown"
wait_for_count "$UI_LOG" "LANGAUDIT about lang=zh-Hant title=關於 MiragePlay appname=MiragePlay copyright=© 2026 Yu-Cheng Chung and Contributors license=授權條款：GPL-3.0-only thirdParty=第三方元件：UxPlay v1.73.6、OpenSSL 3、libplist、GStreamer（僅備用腿） source=原始碼" 1 8 \
    && pass "⑨ About rendered audit (Traditional Chinese; copyright attribution verbatim; source link localised)" \
    || fail "About zh-Hant audit missing/wrong"
wait_for_count "$UI_LOG" "ABOUT snapshot ${SCRATCH}/about-window-hant.png" 1 8 \
    && pass "⑨ About Traditional Chinese render captured (about-window-hant.png)" \
    || fail "about-window-hant.png render line missing"
wait_for_line "ABOUT closed" 8 \
    && pass "⑨ About window closed (ABOUT closed)" \
    || fail "About window never closed"

# ③ switch to zh-Hans (staged + apply).
wait_for_count "$UI_LOG" "PREFS staged name=MiragePlay res=1080p fps=30 mute=off sleep=on notify=on lang=zh-Hans profile=預設 dirty=1" 1 8 \
    && pass "③ staged switch to Simplified Chinese (not applied)" \
    || fail "③ staged zh-Hans line missing"
wait_for_line "ACTION language zh-Hans (shell-held, no restart)" 8 \
    && pass "③ Apply → Simplified Chinese: ACTION language zh-Hans" \
    || fail "③ zh-Hans action line missing"
wait_for_count "$UI_LOG" "LANGAUDIT panel lang=zh-Hans status=未开启 button=启动 pin=PIN 保护 change=更换 entry=偏好设置… quit=退出 tooltip=MiragePlay" 1 8 \
    && pass "③ applied live: panel retranslated to Simplified Chinese (rendered audit; About row retired)" \
    || fail "③ zh-Hans panel audit missing"
wait_for_count "$UI_LOG" "LANGAUDIT prefs lang=zh-Hans title=偏好设置 cap0=影像与声音 cap1=连接与工作阶段 cap2=语言 langrow=语言 language=简体中文 apply=套用 about=关于… frame=450x429" 1 8 \
    && pass "③ applied live: prefs window retranslated to Simplified Chinese (rendered audit)" \
    || fail "③ zh-Hans prefs audit missing"

# ⑤ switching while running: start receiver, audit zh-Hant waiting, flip to zh-Hans mid-run.
wait_for_line "ACTION start" 10 \
    && pass "phase A: Start (receiver running)" \
    || fail "phase A: start never invoked"
wait_for_count "$UI_LOG" "LANGAUDIT panel lang=zh-Hant status=等待連線中… button=關閉 pin=PIN 保護 change=更換 entry=偏好設定… quit=退出 tooltip=MiragePlay" 1 10 \
    && pass "⑤ running: waiting for connection… (Traditional Chinese rendered)" \
    || fail "⑤ zh-Hant waiting audit missing"
wait_for_count "$UI_LOG" "PREFS staged name=MiragePlay res=1080p fps=30 mute=off sleep=on notify=on lang=zh-Hans profile=預設 dirty=1" 2 8 \
    && pass "⑤ running, staged switch to Simplified Chinese (staged; not applied yet)" \
    || fail "⑤ running staged zh-Hans line missing"
# Absolute-value assertion (cleanfails-diag §4.4 recommendation): this run is exactly the 2nd zh-Hans flip.
wait_for_count "$UI_LOG" "ACTION language zh-Hans" 2 8 \
    && pass "⑤ running Apply: ACTION language zh-Hans (2nd time; absolute value)" \
    || fail "⑤ running flip never invoked"
wait_for_count "$UI_LOG" "LANGAUDIT panel lang=zh-Hans status=等待连接中… button=关闭 pin=PIN 保护 change=更换 entry=偏好设置… quit=退出 tooltip=MiragePlay" 1 8 \
    && pass "⑤ applied live (while running): waiting for connection… (Simplified Chinese rendered; receiver unaffected)" \
    || fail "⑤ zh-Hans running audit missing"

wait_for_line "ACTION quit" 15 \
    && pass "phase A: Quit clicked (ACTION quit)" \
    || fail "phase A: quit never invoked"
waited=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do
    sleep 0.25
    waited=$((waited + 1))
done
if kill -0 "$APP_PID" 2>/dev/null; then
    fail "phase A: app did not exit after Quit"
else
    pass "phase A: quit → app exited"
    APP_PID=""
fi
sleep 1
tail -c "+$A_FROM" "$TEST_APP_CONSOLE" >"$RUN/app.stdout.phase-a.log" 2>/dev/null
testkit_quit >/dev/null 2>&1 || true

# ⑥ width double lock (cleanfails-diag acceptance): all three PNG widths ==450 (1x render).
if [ "$(png_width "$SCRATCH/prefs-window-en.png")" = "450" ]; then
    pass "⑥ width lock: prefs-window-en.png width == 450 px"
else
    fail "⑥ prefs-window-en.png width = $(png_width "$SCRATCH/prefs-window-en.png") (expected 450)"
fi
if [ "$(png_width "$SCRATCH/prefs-window-hant.png")" = "450" ]; then
    pass "⑥ width lock: prefs-window-hant.png width == 450 px"
else
    fail "⑥ prefs-window-hant.png width = $(png_width "$SCRATCH/prefs-window-hant.png") (expected 450)"
fi
if [ "$(png_width "$SCRATCH/prefs-window-hant-dirty.png")" = "450" ]; then
    pass "⑥ width lock: prefs-window-hant-dirty.png width == 450 px (dirty state keeps the same lock)"
else
    fail "⑥ hant-dirty width != 450"
fi
if [ "$(png_width "$SCRATCH/prefs-footer-hant-dirty.png")" = "450" ]; then
    pass "⑥ width lock: prefs-footer-hant-dirty.png width == 450 px (footer band spans the window; wave1r3)"
else
    fail "⑥ prefs-footer-hant-dirty.png width = $(png_width "$SCRATCH/prefs-footer-hant-dirty.png") (expected 450)"
fi
if [ "$(png_width "$SCRATCH/about-window-hant.png")" = "360" ]; then
    pass "⑥ About window width 360 px (Traditional Chinese render)"
else
    fail "⑥ about-window-hant.png width != 360"
fi

# Ledger ⑤: E1 row 12 — immediate, does not touch the receiver.
A_SPAWNS="$(spawn_count)"
A_SETTINGS_CHANGED="$(count_in 'ACTION settings-changed' "$UI_LOG")"
A_LANG_ACTIONS="$(count_in 'ACTION language ' "$UI_LOG")"
if [ "$A_SPAWNS" = "1" ]; then
    pass "⑤ ledger: exactly 1 spawn overall (runtime language switches spawn nothing)"
else
    fail "⑤ ledger: spawn count = $A_SPAWNS (expected 1)"
fi
if [ "$A_SETTINGS_CHANGED" = "0" ]; then
    pass "⑤ ledger: zero settings-changed overall (language never touches the receiver)"
else
    fail "⑤ ledger: settings-changed = $A_SETTINGS_CHANGED (expected 0)"
fi
if [ "$A_LANG_ACTIONS" = "4" ]; then
    pass "⑤ ledger: ACTION language ×4 (Trad→Simp→Trad→Simp [while running])"
else
    fail "⑤ ledger: ACTION language = $A_LANG_ACTIONS (expected 4)"
fi
if ! grep -Eq 'zh-Hant|zh-Hans' "$SPAWN_EVID" 2>/dev/null; then
    pass "⑤ argv carries no language trace (language = shell-held; never serialised)"
else
    fail "⑤ argv leaked a language code"
fi

# ② persistence: settings.json language = zh-Hans (phase A's final selection = flipped while running).
if [ -f "$SETTINGS" ] && grep -Fq '"language" : "zh-Hans"' "$SETTINGS"; then
    pass "② persisted: settings.json language=zh-Hans (⑫ auto write-back)"
else
    fail "② settings.json did not persist language=zh-Hans"
fi

# --- 8. phase B: relaunch — the restart brings the language back (first frame is the real value) ---

ui_before="$(count_in 'LANGAUDIT panel lang=zh-Hans status=未开启' "$UI_LOG")"
B_FROM=$(($(wc -c < "$TEST_APP_CONSOLE" 2>/dev/null || echo 0) + 1))
# Phase B relaunches the same bundle: the persisted language must come back from
# the first frame.
MIRRORBOARD_UITEST_LANGUAGE=2 MIRRORBOARD_STRINGS_PATH="$DICT_REAL_PATH" testkit_launch
APP_PID="${TEST_APP_PID:-}"
sleep 1
kill -0 "$APP_PID" 2>/dev/null \
    && pass "phase B: launch ok (pid $APP_PID)" \
    || { tail -c "+$B_FROM" "$TEST_APP_CONSOLE" >"$RUN/app.stdout.phase-b.log" 2>/dev/null; fail "phase B: launch failed — see $RUN/app.stdout.phase-b.log"; }

wait_for_count "$UI_LOG" "LANGAUDIT panel lang=zh-Hans status=未开启 button=启动 pin=PIN 保护 change=更换 entry=偏好设置… quit=退出 tooltip=MiragePlay" $((ui_before + 1)) 10 \
    && pass "② persisted: restart first paint is Simplified Chinese (restart carries the last value back; About row retired)" \
    || fail "phase B: persisted language not rendered on relaunch"

wait_for_line "ACTION quit" 12 \
    && pass "phase B: Quit" \
    || fail "phase B: quit never invoked"
waited=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do
    sleep 0.25
    waited=$((waited + 1))
done
if kill -0 "$APP_PID" 2>/dev/null; then
    fail "phase B: app did not exit"
else
    pass "phase B: quit → app exited"
    APP_PID=""
fi
tail -c "+$B_FROM" "$TEST_APP_CONSOLE" >"$RUN/app.stdout.phase-b.log" 2>/dev/null
testkit_quit >/dev/null 2>&1 || true

# --- 9. phase C: dictionary fixture — missing-key fallback (on-device side) ----

python3 - "$TERMS_JSON" "$FIXTURE" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
del d["terms"]["panel.status.waiting"]["zh-Hans"]   # intentional missing key: zh-Hant present, zh-Hans absent
json.dump(d, open(dst, "w"), ensure_ascii=False, indent=2)
PY
if [ -f "$FIXTURE" ]; then
    pass "④ fixture: dictionary missing zh-Hans entries generated (${FIXTURE})"
else
    fail "④ fixture generation failed"
fi

C_FROM=$(($(wc -c < "$TEST_APP_CONSOLE" 2>/dev/null || echo 0) + 1))
# Phase C launches the same bundle against the fixture dictionary, so the app
# exercises the real missing-key fallback path.
MIRRORBOARD_UITEST_LANGUAGE=3 MIRRORBOARD_STRINGS_PATH="$FIXTURE" testkit_launch
APP_PID="${TEST_APP_PID:-}"
sleep 1
kill -0 "$APP_PID" 2>/dev/null \
    && pass "phase C: launch ok (pid $APP_PID)" \
    || { tail -c "+$C_FROM" "$TEST_APP_CONSOLE" >"$RUN/app.stdout.phase-c.log" 2>/dev/null; fail "phase C: launch failed — see $RUN/app.stdout.phase-c.log"; }

wait_for_line "LANG dictionary loaded path=$FIXTURE terms=51" 10 \
    && pass "④ MIRRORBOARD_STRINGS_PATH takes effect (dictionary = fixture; config swappable)" \
    || fail "phase C: fixture dictionary not loaded"

wait_for_count "$UI_LOG" "LANGAUDIT panel lang=zh-Hans status=未开启 button=启动" 2 10 \
    && pass "④ fixture hit: idle string renders in Simplified Chinese" \
    || fail "phase C: fixture idle audit missing"

wait_for_line "LANG missing term=panel.status.waiting lang=zh-Hans fallback=en" 12 \
    && pass "④ missing-key fallback: miss recorded (fallback=en; never silent)" \
    || fail "phase C: missing-term line absent"

wait_for_count "$UI_LOG" "LANGAUDIT panel lang=zh-Hans status=Waiting for connection… button=关闭 pin=PIN 保护 change=更换 entry=偏好设置… quit=退出 tooltip=MiragePlay" 1 10 \
    && pass "④ live scenario: missing key renders back to en (Waiting for connection…; the rest stays Simplified Chinese)" \
    || fail "phase C: fallback rendering missing"

wait_for_line "ACTION quit" 12 \
    && pass "phase C: Quit" \
    || fail "phase C: quit never invoked"
waited=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do
    sleep 0.25
    waited=$((waited + 1))
done
if kill -0 "$APP_PID" 2>/dev/null; then
    fail "phase C: app did not exit"
else
    pass "phase C: quit → app exited"
    APP_PID=""
fi
tail -c "+$C_FROM" "$TEST_APP_CONSOLE" >"$RUN/app.stdout.phase-c.log" 2>/dev/null
testkit_quit >/dev/null 2>&1 || true

# --- 10. residue + evidence ---------------------------------------------------

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

cp "$UI_LOG" "$RUN/ui.log" 2>/dev/null
cp "$LAUNCH_LOG" "$RUN/launch.log" 2>/dev/null
cp "$TEST_APP_CONSOLE" "$RUN/app.stdout.log" 2>/dev/null
cp "$SCRATCH/prefs-window-en.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/prefs-window-hant.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/prefs-window-hant-dirty.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/prefs-footer-hant-dirty.png" "$RUN/" 2>/dev/null
cp "$SCRATCH/about-window-hant.png" "$RUN/" 2>/dev/null
restore_settings

log ""
log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
log "   ui.log:     $UI_LOG"
log "   evidence:   $RUN"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
