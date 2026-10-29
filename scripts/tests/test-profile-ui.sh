#!/bin/bash
# test-profile-ui.sh — wave1r3 (B2 slider batch) profile UI retirement check (trimmed version).
#
# Basis (B2 ruling ②, verbatim: "profiles look pretty useless … no need to add this feature for it"):
#   the whole Profiles block in the settings window is withdrawn (dropdown + "Save As…"); group caps 4→3; the engine side is kept
#   out of sight; the matching dictionary display keys are retired.
#
# This script is the **trimmed** UI-side guard (static scan, no build, no launch — fast, zero interference.
# the previous 916-line in-app sequence (staged preview / apply / save-as / phase A+B) retired
# together with its UI carrier):
#   ① zero residue of Profiles UI (PF/PW/SI/CR source side; intent seam side)
#   ② dictionary display keys retired (terms.json: prefs.tab.profiles / prefs.row.profile /
#      prefs.profile.default / prefs.profile.saveAs / prefs.saveAs.* /
#      panel.entry.about all absent; prefs.button.about present; term=50)
#   ③ engine side kept (out of sight): ConfigEngine live surface saveProfileAs / setProfileName /
#      loadProfile present; ProfileStore (listProfiles / saveProfile / loadProfile)
#      present; ConfigEngine's profile trio (listProfiles / previewProfile /
#      saveProfile) was retired in wave1r11 Q2 (7b7383c) → assert their absence (keeps discriminating power);
#      ConfigEngineSelfTest's PersistenceTests (including "save-as → configs dir +
#      listing") are kept — **engine-side tests stay in config-engine**
#      (scripts/tests/test-config-engine.sh).
#   ④ harness retired: AppDelegate has no MIRRORBOARD_UITEST_PROFILE branch;
#      UITestDriver has no runProfileUI / runProfileRestart.
#   ⑤ red lines: forbidden literals / the uxplay tree matches the pinned commit (see scripts/build/vendor-uxplay.sh --check).
#
# Re-runnable. Self-contained. Zero app launches (touches no live instance).
#
# Usage:  ./scripts/tests/test-profile-ui.sh
# Evidence: MIRAGE_EVIDENCE_DIR/testrun-profile-<YYYYmmdd_HHMMSS>/ when that
# variable is set; otherwise a fresh directory under ${TMPDIR:-/tmp}, which the
# run prints and leaves behind. Nothing is written into the checkout and no
# path is remembered: long-term retention is the caller's job (copy it out).

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
    echo "test-profile-ui: cannot resolve the repo root to its on-disk spelling" >&2
    exit 1
}
# Shared UxPlay tree path resolution + red-line gate (2026-10-19 decouple):
# the upstream tree is no longer git-tracked — it is materialized on demand
# by scripts/build/vendor-uxplay.sh from the fork pinned in core/vendor.lock.
# shellcheck source=scripts/lib/_uxplay-path.sh
. "$PROJ/scripts/lib/_uxplay-path.sh"
# Evidence root: the caller's choice when it sets MIRAGE_EVIDENCE_DIR, else a
# fresh system temp directory per run. Deliberately not a fixed path: a run
# must not write into the checkout, and evidence kept past the run is the
# caller's responsibility (print the path, copy it out if it matters).
if [ -n "${MIRAGE_EVIDENCE_DIR:-}" ]; then
    EVID="$MIRAGE_EVIDENCE_DIR"
    mkdir -p "$EVID" || {
        echo "test-profile-ui: cannot create MIRAGE_EVIDENCE_DIR=$EVID" >&2
        exit 1
    }
else
    EVID="$(mktemp -d "${TMPDIR:-/tmp}/mirageplay-profile-evidence.XXXXXX")" || {
        echo "test-profile-ui: cannot create an evidence directory under ${TMPDIR:-/tmp}" >&2
        exit 1
    }
fi
RUN="$EVID/testrun-profile-$(date '+%Y%m%d_%H%M%S')"

PF_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesFormViews.swift"
PW_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesWindowController.swift"
PI_SWIFT="$PROJ/app/Sources/SettingsUI/PreferencesIntent.swift"
IH_SWIFT="$PROJ/app/Sources/AppShell/PreferencesIntentHandler.swift"
SI_SWIFT="$PROJ/app/Sources/AppShell/StatusItemMenu.swift"
CR_SWIFT="$PROJ/app/Sources/AppShell/CompositionRoot.swift"
AD_SWIFT="$PROJ/app/Sources/AppShell/AppDelegate.swift"
UT_SWIFT="$PROJ/app/Sources/AppShell/UITestDriver.swift"
ENG_SWIFT="$PROJ/app/Sources/ConfigEngine/ConfigEngine.swift"
STORE_SWIFT="$PROJ/app/Sources/ConfigEngine/ProfileStore.swift"
PERSIST_TESTS="$PROJ/app/Tests/ConfigEngineSelfTest/PersistenceTests.swift"
CFG_TEST="$PROJ/scripts/tests/test-config-engine.sh"
TERMS_JSON="$PROJ/app/Resources/Strings/terms.json"

PASS=0
FAIL=0
SKIP=0

mkdir -p "$RUN"

log()  { echo "$@" | tee -a "$RUN/summary.txt"; }
pass() { PASS=$((PASS + 1)); log "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); log "FAIL  $1"; }
skip() { SKIP=$((SKIP + 1)); log "SKIP  $1"; }

log "== wave1r3 Profiles-UI retirement guard — $(date '+%Y-%m-%d %H:%M:%S %Z') =="
log "   run dir: $RUN"

# --- 0. preflight: pure static scan — never touch a live instance -----------

if pgrep -x MiragePlay >/dev/null 2>&1 || pgrep -x uxplay >/dev/null 2>&1; then
    log "NOTE: a MiragePlay/uxplay instance is running — this guard is READ-ONLY (no launch); continuing."
fi
pass "preflight: static scan (no launch; read-only)"

# --- 1. zero residue of Profiles UI (source side) ----------------------------

if ! grep -Fq 'profilePopup' "$PF_SWIFT" && ! grep -Fq 'profilePopup' "$PW_SWIFT" \
    && ! grep -Fq 'syncProfilePopup' "$PF_SWIFT" \
    && ! grep -Fq 'saveAsButton' "$PF_SWIFT" && ! grep -Fq 'saveAsButton' "$PW_SWIFT" \
    && ! grep -Fq 'profileSelected' "$PW_SWIFT" \
    && ! grep -Fq 'saveAsClicked' "$PW_SWIFT" \
    && ! grep -Fq 'presentSaveAsSheet' "$PW_SWIFT" \
    && ! grep -Fq 'commitSaveAs' "$PW_SWIFT" \
    && ! grep -Fq 'confirmOverwrite' "$PW_SWIFT" \
    && ! grep -Fq 'emitSaveAs' "$PW_SWIFT" \
    && ! grep -Fq 'selectProfileForTesting' "$PW_SWIFT" \
    && ! grep -Fq 'saveProfileForTesting' "$PW_SWIFT"; then
    pass "window surface: dropdown / Save As / sheet / seams all retired (PreferencesFormViews + PreferencesWindowController)"
else
    fail "window surface: Profiles UI still present (popup / save-as / seams)"
fi

if ! grep -Fq 'selectPreferencesProfile' "$SI_SWIFT" \
    && ! grep -Fq 'savePreferencesProfileAs' "$SI_SWIFT" \
    && ! grep -Fq 'profilesProvider:' "$CR_SWIFT" \
    && ! grep -Fq 'profilePreviewProvider' "$CR_SWIFT" \
    && ! grep -Fq 'profilePreviewProvider' "$SI_SWIFT" \
    && ! grep -Fq 'factoryProfileName' "$CR_SWIFT" \
    && ! grep -Fq 'factoryProfileName' "$SI_SWIFT"; then
    pass "wiring surface: provider + seam retired from StatusItemMenu / CompositionRoot"
else
    fail "wiring surface: provider / seam still present (StatusItemMenu / CompositionRoot)"
fi

if ! grep -Fq 'preferencesProfileSaveAsCommitted' "$PI_SWIFT" \
    && ! grep -Fq 'preferencesProfileSaveAsCommitted' "$IH_SWIFT" \
    && ! grep -Fq 'ProfileSaveAsOutcome' "$PI_SWIFT" \
    && ! grep -Fq 'ProfileSaveAsOutcome' "$IH_SWIFT"; then
    pass "intent surface: Save As intent method + Outcome type retired (PreferencesIntent / Handler)"
else
    fail "intent surface: save-as intent still present"
fi

# --- 2. dictionary display keys retired --------------------------------------

if ! grep -Fq 'prefs.tab.profiles' "$TERMS_JSON" \
    && ! grep -Fq 'prefs.row.profile' "$TERMS_JSON" \
    && ! grep -Fq 'prefs.profile.default' "$TERMS_JSON" \
    && ! grep -Fq 'prefs.profile.saveAs' "$TERMS_JSON" \
    && ! grep -Fq 'prefs.saveAs.' "$TERMS_JSON" \
    && ! grep -Fq 'panel.entry.about' "$TERMS_JSON" \
    && grep -Fq 'prefs.button.about' "$TERMS_JSON"; then
    pass "dictionary: Profiles display keys (incl. 13 save-as sheet keys) + panel about keys retired; prefs.button.about added"
else
    fail "dictionary: display keys not fully retired or prefs.button.about missing"
fi

TERM_COUNT="$(python3 -c "
import json
print(len(json.load(open('$TERMS_JSON'))['terms']))
")"
if [ "$TERM_COUNT" = "51" ]; then
    pass "dictionary: term count = 51 (wave1r4: 45 + 5 trust.ask keys + about.source)"
else
    fail "dictionary: term count = ${TERM_COUNT} (expected 51)"
fi

# --- 3. engine side kept (out of sight) --------------------------------------

# Reality after wave1r11 Q2 (7b7383c): ConfigEngine's profile trio
# (listProfiles / previewProfile / saveProfile) retired with the ⑫ profile block →
# live surface = ConfigEngine.saveProfileAs / setProfileName / loadProfile
# + ProfileStore (listProfiles / saveProfile / loadProfile).
if grep -Fq 'public func saveProfileAs(named name: String) throws -> URL' "$ENG_SWIFT" \
    && grep -Fq 'public func setProfileName(_ name: String)' "$ENG_SWIFT" \
    && grep -Fq 'public func loadProfile(named name: String) throws' "$ENG_SWIFT" \
    && [ -f "$STORE_SWIFT" ] \
    && grep -Fq 'public func listProfiles() throws -> [String]' "$STORE_SWIFT" \
    && grep -Fq 'public func saveProfile(_ model: SettingModel, named name: String) throws -> URL' "$STORE_SWIFT" \
    && grep -Fq 'public func loadProfile(named name: String) throws -> SettingModel' "$STORE_SWIFT"; then
    pass "engine surface kept: ConfigEngine (saveProfileAs / setProfileName / loadProfile) + ProfileStore (listProfiles / saveProfile / loadProfile) present"
else
    fail "engine surface: ConfigEngine / ProfileStore profile API missing (must be kept)"
fi

# retired surface (wave1r11 Q2 7b7383c): ConfigEngine's trio must not come back —
# assert their absence with exact declaration strings (keeps discriminating power; a comeback fails, not always-true).
if ! grep -Fq 'public func listProfiles() throws -> [String]' "$ENG_SWIFT" \
    && ! grep -Fq 'public func previewProfile(named name: String) throws -> SettingModel' "$ENG_SWIFT" \
    && ! grep -Fq 'public func saveProfile(_ model: SettingModel, named name: String) throws -> URL' "$ENG_SWIFT"; then
    pass "engine surface retired: ConfigEngine profile trio (listProfiles / previewProfile / saveProfile) gone (Q2 7b7383c)"
else
    fail "engine surface retired: ConfigEngine profile trio is back (Q2 retired them)"
fi

if [ -f "$PERSIST_TESTS" ] \
    && grep -Fq 'saveAsProfileDirectoryAndListing' "$PERSIST_TESTS" \
    && grep -Fq 'Save As → configs dir + listing' "$PERSIST_TESTS" \
    && grep -Fq 'ConfigEngineSelfTest' "$CFG_TEST"; then
    pass "engine-surface tests: PersistenceTests (Save As→configs + listing) kept — engine tests stay in config-engine"
else
    fail "engine-surface tests: PersistenceTests coverage missing"
fi

# --- 4. harness retired ------------------------------------------------------

if ! grep -Fq 'MIRRORBOARD_UITEST_PROFILE' "$AD_SWIFT" \
    && ! grep -Fq 'runProfileUI' "$UT_SWIFT" \
    && ! grep -Fq 'runProfileRestart' "$UT_SWIFT" \
    && ! grep -Fq 'pfQuitAt' "$UT_SWIFT" \
    && ! grep -Fq 'pfrQuitAt' "$UT_SWIFT"; then
    pass "harness: MIRRORBOARD_UITEST_PROFILE branch / runProfileUI / runProfileRestart / timeline constants all retired"
else
    fail "harness: profile sequence still present (AppDelegate / UITestDriver)"
fi

# --- 5. red-line self-check ---------------------------------------------------

BANNED_WORD=$'\xe4\xb8\x8a\xe8\xaa\xb2'
if grep -rq "$BANNED_WORD" "$PROJ/app/Sources/AppShell" "$PROJ/app/Sources/SettingsUI" 2>/dev/null; then
    fail "red-line: banned wording found in AppShell/SettingsUI"
else
    pass "red-line: no banned wording in AppShell/SettingsUI"
fi

# --- 5. red-line: uxplay tree must match the pinned commit -------------------
# 2026-10-19 decouple: core/uxplay is no longer git-tracked. The upstream tree
# now lives at _build/uxplay, materialized on demand by
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

# --- summary ------------------------------------------------------------------

log ""
log "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
log "   evidence:   $RUN"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
