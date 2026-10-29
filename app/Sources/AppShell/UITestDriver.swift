#if DEBUG
import AppKit
import ReceiverKit
import SettingsUI
import core_bridge

/// Scripted UI-exercise driver for `scripts/test-ui-cp2.sh` (increment ①)
/// and `scripts/test-ui-prefs.sh` (increment ②).
///
/// Activated **only** when the environment variable `MIRRORBOARD_UITEST=1`
/// (increment ① sequence) or `MIRRORBOARD_UITEST_PREFS=1` (increment ②
/// sequence) is set — normal launches are untouched, zero effect. It drives
/// the exact entry points the UI uses — `togglePanel()` (icon click),
/// `performPrimaryAction()` (the start/stop button), `performOpenPreferences()`
/// (the preferences… row), `performOpenAbout()` (the about row → the About mini-window),
/// `closePreferences()` (the red-light close), `performQuit()` (the quit row) —
/// on a fixed timeline, so the test scripts can observe every step WITHOUT
/// synthetic clicks (which would need Accessibility permission the test
/// environment does not reliably have).
///
/// It also writes visual evidence into the same temp scratch subtree it shares
/// with `UILog` (`<NSTemporaryDirectory()>/com.ycchung.mirageplay/`): an AppKit render
/// of the open panel (`panel-snapshot.png`), a two-row 18/16-pt icon sheet
/// (`statusicon-sheet.png`) and the preferences window on both pages
/// (`prefs-window.png` / `prefs-window-b.png`) — screen capture is
/// unavailable in the test environment (Screen Recording TCC).
///
/// Timeline ① (seconds after launch — keep in sync with test-ui-cp2.sh):
///   1.5  open panel    → ui.log: PANEL shown
///   1.8  snapshots     → ui.log: PANEL snapshot / ICONSHEET
///   2.5  close panel   → ui.log: PANEL hidden
///   3.0  start                → ui.log: ACTION start   (uxplay spawns)
///  14.0  stop                 → ui.log: ACTION stop    (uxplay terminates)
///  20.0  quit                 → ui.log: ACTION quit    (the app exits, zero residue)
///
/// Timeline ③ (MIRRORBOARD_UITEST_WIRING=1; wave1r1 staged-apply wiring test —
/// receiver runs; four field edits stay STAGED, then ONE Apply commits them
/// with exactly one restart; unapplied edits are discarded at close;
/// keep in sync with scripts/test-wiring-e1.sh):
///   1.0  open panel                → PANEL shown
///   1.5  start                          → ACTION start (spawn #1, defaults)
///   3.6  preferences…                    → PREFS shown (created); apply enabled=0
///   4.4  resolution → 720p (staged)     → PREFS staged … dirty=1; zero engine action
///   5.2  framerate cap → 60 (staged)     → as above
///   6.0  mute → on (staged)
///   6.8  device name → the YC Mac fixture name (staged)
///   7.6  Apply                          → ONE restart: settings-changed (restart)×1,
///        spawn #2 argv carries all four in one go; after apply, dirty clears (apply enabled=0)
///   9.0  prefs close
///   9.8  prefs reopen                   → PREFS values = the applied truth
///  11.0  framerate cap → 120 (staged; not applied)
///  11.8  prefs close               → staged discarded (unapplied)
///  12.6  prefs reopen                   → PREFS values fps=60 (the discard proof)
///  13.4  prefs close
///  14.2  stop                           → ACTION stop (uxplay down)
///  15.8  mute → off (staged; not started)
///  16.6  Apply                          → settings-changed (write-back only); zero spawn
///  20.0  quit                           → ACTION quit (S5, zero residue)
///
/// Timeline ② (MIRRORBOARD_UITEST_PREFS=1; receiver never starts — zero
/// uxplay involvement; keep in sync with test-ui-prefs.sh. wave1r3: the B2 slider batch
/// — a staged slider edit, the About entry = the preferences window's footer bottom-right
/// button, the R1 full-text reminder, and a footer close-up render):
///   1.5  open panel              → PANEL shown
///   1.8  snapshots               → PANEL snapshot / ICONSHEET
///   2.2  preferences…                   → ACTION prefs-open / PREFS shown (created)
///   2.5  prefs snapshot                 → PREFS snapshot (a single page, clean state)
///        clean audit             → WINDOWS audit (reminder absent, apply grey)
///   2.8  slider staged edit             → the resolution slider→1440p (a settled commit;
///                                   PREFS apply enabled=1 reminder=1)
///   3.1  prefs snapshot dirty           → prefs-window-dirty.png (the R1 full-text reminder shows)
///        footer close-up                → prefs-footer-dirty.png (About bottom-right + the full text)
///   3.4  About open (in-window)         → the bottom-right footer button inside the window pressed
///                                   → ACTION about-open / ABOUT shown (created)
///   3.6  About snapshot          → about-window.png + LANGAUDIT about
///                                   + WINDOWS audit (about=1)
///   3.8  About close             → ABOUT closed
///   4.0  trust editor present    → PREFS trust editor presented (rows=0)
///  4.12  reset probe             → PREFS trust reset requested (rows=0)
///                                   + TRUST reset origin=editor rows=0
///  4.25  trust editor dismiss    → PREFS trust editor dismissed
///   4.5  Apply                          → the write-back (not started; a pure write-back); dirty clears + the reminder goes
///   4.8  reopen (singleton)      → PREFS shown (reused)
///   5.1  slider staged edit             → the resolution slider→2160p (staged; dirty=1)
///   5.4  close (red light)              → PREFS closed; staged discarded (2160p not applied)
///   5.8  reopen again                   → PREFS shown (reused); the values are still res=1440p
///   6.2  close again             → PREFS closed
///   6.6  close panel             → PANEL hidden
///   7.1  reopen the panel (the PIN/name visual layer) → PANEL shown
///   7.3  PIN on                  → PIN toggled on (panel 300x212) + panel-pin-on.png
///   7.8  connected visual               → STATE connected(the YC iPad fixture name) + panel-connected.png
///   8.1  PIN off                 → PIN toggled off (panel 300x192)
///   8.3  restore idle            → STATE idle
///   8.5  close panel             → PANEL hidden
///  10.0  quit                           → ACTION quit (S5, zero residue)
///
/// Timeline ④ (MIRRORBOARD_UITEST_PIN=1; the stage D PIN chain test — keep in sync
/// with scripts/test-pin-chain.sh):
///   1.0  open panel                 → PANEL shown (read-through: PIN off)
///   1.6  PIN on (unset)                   → an engine write (write-back only) + a code is generated
///   3.4  start (#1)                      → spawn#1 (unset = generate a new code; argv -pin)
///   6.0  stop                            → stop
///   8.2  start (#2)                      → spawn#2 (unset = generate yet another new code)
///  10.8  stop                            → stop
///  13.0  start (#3)                      → spawn#3
///  15.5  regenerate                      → a new code + an E1 restart → spawn#4 (argv updated)
///  16.8  panel-pin-change render         → a scratch image
///  18.5  preferences… open               → PREFS values pin=C (the truth; a read-only field)
///  19.3  prefs close
///  20.2  stop                            → stop
///  21.2  PIN off                         → write-back only; the button greys out and the code area hides
///  21.9  panel-pin-off render
///  22.4  regenerate (PIN off)            → ACTION pin-change ignored (no effect)
///  23.8  start (#4)                      → spawn#5 (argv without -pin)
///  26.8  stop                            → stop
///  28.0  PIN on (already set to C)       → reused (C is displayed; write-back only)
///  29.5  start (#5)                      → spawn#6 (-pin C reused, not regenerated)
///  32.5  PIN off (while running)         → an E1 restart → spawn#7 (argv without -pin)
///  34.8  stop                            → stop
///  36.3  quit                            → ACTION quit (S5, zero residue)
///
/// Timeline ⑤ (MIRRORBOARD_UITEST_SLEEPNOTIFY=1; the stage E SleepGuard +
/// SessionNotifier test, wave1r1 staged flips — keep in sync with
/// scripts/test-sleep-notify.sh):
///   1.0  open the panel                 → PANEL shown (zero assertion — the receiver is not started)
///   1.6  start #1                        → spawn#1; SLEEPGUARD held (prevent-sleep is on by default)
///   4.2  preferences… open               → PREFS values … pin=- sleep=on notify=on
///        (wave1r2: a single-page window — the switches are reached directly on the page, no tabs)
///   5.2  prevent-sleep → off (staged)    → zero action (not applied)
///   5.6  Apply                          → ACTION prevent-sleep off; the assertion is released (immediate, zero restart)
///   7.0  prevent-sleep → on (staged); apply at 7.4 → ACTION prevent-sleep on; the assertion is held
///   8.8  inject connected #1             → NOTIFY connected + STATE connected
///   9.6  panel render              → scratch/panel-notify-connected.png
///  10.4  inject disconnected #1          → NOTIFY disconnected + STATE waiting
///  12.2  B2 slot → false (staged); apply at 12.6 → ACTION notifications off
///  13.2  inject connected #2       → NOTIFY connected STILL written (D8:
///        recording is unconditional — the retained B2 value gates nothing; STATE proceeds as usual)
///  14.0  panel render              → scratch/panel-notify-unconditional.png
///  15.0  B2 slot → true (staged); apply at 15.4 → ACTION notifications on
///  15.8  inject disconnected #2    → NOTIFY disconnected
///  16.7  inject connected #3       → NOTIFY connected
///  17.4  prefs close
///  18.2  stop #1                         → ACTION stop; the assertion is released (the stopped-state red line)
///  19.6  prevent-sleep → off (staged; not started); apply at 20.2 → ACTION prevent-sleep off (a pure write-back)
///  21.2  prefs reopen                    → PREFS values … sleep=off notify=on (reading the truth back)
///  21.9  prefs close
///  23.2  start #2                        → spawn#2 (prevent-sleep off → zero assertion)
///  25.2  stop #2                         → stop
///  26.8  quit                            → ACTION quit (S5, zero residue)
///
/// Timeline ⑧ (MIRRORBOARD_UITEST_LANGUAGE=1; the stage G language test, wave1r3 —
/// the B2 slider batch: the THREE group-cap audit + EN / zh-Hant / zh-Hans renders + a
/// zh-Hant dirty render (the R1 full-text reminder) + a footer close-up render + the About
/// window render; switching is staged and flips on Apply; keep in sync with scripts/test-language.sh):
///   1.0  open panel              → PANEL shown
///   1.4  LANGAUDIT panel                → the en defaults (English is the first-run default)
///   2.0  preferences… open              → PREFS shown (created)
///   2.4  LANGAUDIT prefs + render       → en (the title/4 caps/the language row/the selected item) +
///        scratch/prefs-window-en.png
///   2.8  language → zh-Hant (staged)     → zero flip (staged; the picker shows Traditional Chinese)
///   3.1  LANGAUDIT prefs                → the strings stay en + language=Traditional Chinese (the staged proof)
///   3.4  Apply                          → ACTION language zh-Hant + an instant whole-UI flip
///   3.8  LANGAUDIT panel+prefs   → zh-Hant
///   4.1  render                  → scratch/prefs-window-hant.png
///   4.4  language → en (staged)         → dirty (the reminder shows; not applied)
///   4.7  render                  → scratch/prefs-window-hant-dirty.png
///        footer close-up          → scratch/prefs-footer-hant-dirty.png
///                                    (About bottom-right + the R1 full-text reminder)
///   4.9  language → zh-Hant (staged reset) → dirty=0 (not applied)
///   5.2  About open              → ABOUT shown (created)
///   5.4  About render + audit    → scratch/about-window-hant.png
///   5.6  About close             → ABOUT closed
///   5.9  language → zh-Hans (staged); apply at 6.2 → ACTION language zh-Hans
///   6.5  LANGAUDIT panel+prefs   → zh-Hans
///   6.8  language → zh-Hant (staged); apply at 7.1 → switching back (persistence ends on zh-Hant)
///   7.4  prefs close             → PREFS closed
///   7.9  start                          → ACTION start; spawn#1 (waiting)
///   8.7  LANGAUDIT panel                → the waiting-for-connection string (zh-Hant)
///   9.1  language → zh-Hans (staged; while running); apply at 9.4 → ACTION language
///        zh-Hans; zero restart (E1 row 12: immediate, receiver untouched)
///   9.8  LANGAUDIT panel                → the waiting-for-connection string (immediately)
///  10.4  stop                           → ACTION stop
///  11.0  quit                           → ACTION quit (S5, zero residue)
///
/// Timeline ⑧-B (MIRRORBOARD_UITEST_LANGUAGE=2; same script, relaunch):
///   1.0  open panel              → PANEL shown
///   1.4  LANGAUDIT panel                → zh-Hant not-started / start (a restart brings back the language)
///   2.6  quit                           → ACTION quit
///
/// Timeline ⑧-C (MIRRORBOARD_UITEST_LANGUAGE=3; dictionary fixture run —
/// MIRRORBOARD_STRINGS_PATH points at a fixture with a deliberately missing
/// zh-Hant entry):
///   1.0  open panel              → PANEL shown
///   1.4  LANGAUDIT panel         → zh-Hant idle strings (fixture hit)
///   2.2  start                          → waiting → a missing term falls back to EN
///        (LANG missing term=panel.status.waiting lang=zh-Hant fallback=en)
///   3.2  LANGAUDIT panel         → status=Waiting for connection… (en fallback)
///   4.4  stop                           → ACTION stop
///   5.4  quit                           → ACTION quit
enum UITestDriver {

    // MARK: - Increment ① timeline (MIRRORBOARD_UITEST=1)

    static let openPanelAt: TimeInterval = 1.5
    static let snapshotAt: TimeInterval = 1.8
    static let closePanelAt: TimeInterval = 2.5
    static let startAt: TimeInterval = 3.0
    static let stopAt: TimeInterval = 14.0
    static let quitAt: TimeInterval = 20.0

    // MARK: - Increment ② timeline (MIRRORBOARD_UITEST_PREFS=1)

    static let prefsOpenPanelAt: TimeInterval = 1.5
    static let prefsSnapshotsAt: TimeInterval = 1.8
    static let prefsOpenAt: TimeInterval = 2.2
    static let prefsCleanSnapshotAt: TimeInterval = 2.5
    // wave1r2 — B1 changed state: one staged edit puts the window into the dirty state
    // (the R1 reminder shows + the button brightens); the later apply returns it to the clean state.
    static let prefsDirtyStageAt: TimeInterval = 2.8
    static let prefsDirtySnapshotAt: TimeInterval = 3.1
    // wave1r2 — the About mini-window (the copyright; B1 §E-1 option A).
    static let prefsAboutOpenAt: TimeInterval = 3.4
    static let prefsAboutSnapshotAt: TimeInterval = 3.6
    static let prefsAboutCloseAt: TimeInterval = 3.8
    // wave1r1 R2: the trust editor shell (present → Reset no-op probe → dismiss).
    static let prefsTrustPresentAt: TimeInterval = 4.0
    static let prefsTrustResetAt: TimeInterval = 4.12
    static let prefsTrustDismissAt: TimeInterval = 4.25
    // wave1r2 — Apply commits the staged edit (a pure write-back; the receiver never starts).
    static let prefsApplyAt: TimeInterval = 4.5
    static let prefsReopenAt: TimeInterval = 4.8
    static let prefsReopenAuditAt: TimeInterval = 4.95
    // wave1r3 — the B2 staged slider edit: the resolution slider→2160p (a settled commit;
    // it settles only on release); the close then DISCARDS it.
    static let prefsSliderStageAt: TimeInterval = 5.1
    static let prefsCloseAt: TimeInterval = 5.4
    static let prefsCloseAuditAt: TimeInterval = 5.6
    static let prefsReopenAgainAt: TimeInterval = 5.8
    static let prefsReopenAgainAuditAt: TimeInterval = 6.0
    static let prefsCloseAgainAt: TimeInterval = 6.2
    static let prefsCloseAgainAuditAt: TimeInterval = 6.4
    static let prefsClosePanelAt: TimeInterval = 6.6
    static let prefsFinalAuditAt: TimeInterval = 6.8
    static let prefsPinOpenPanelAt: TimeInterval = 7.1
    static let prefsPinOnAt: TimeInterval = 7.3
    static let prefsPinOnSnapshotAt: TimeInterval = 7.65
    static let prefsConnectedAt: TimeInterval = 7.8
    static let prefsPinOffAt: TimeInterval = 8.1
    static let prefsRestoreIdleAt: TimeInterval = 8.3
    static let prefsClosePanelAgainAt: TimeInterval = 8.5
    static let prefsPostPinAuditAt: TimeInterval = 8.7
    static let prefsQuitAt: TimeInterval = 10.0

    // MARK: - Wiring (stage C / wave1r1 staged) timeline (MIRRORBOARD_UITEST_WIRING=1)

    static let wiringOpenPanelAt: TimeInterval = 1.0
    static let wiringStartAt: TimeInterval = 1.5
    static let wiringOpenPrefsAt: TimeInterval = 3.6
    static let wiringResolutionStageAt: TimeInterval = 4.4
    static let wiringFrameRateStageAt: TimeInterval = 5.2
    static let wiringMuteStageAt: TimeInterval = 6.0
    static let wiringDeviceNameStageAt: TimeInterval = 6.8
    static let wiringApplyAt: TimeInterval = 7.6
    static let wiringClosePrefsAt: TimeInterval = 9.0
    static let wiringReopenPrefsAt: TimeInterval = 9.8
    static let wiringFrameRateBackStageAt: TimeInterval = 11.0
    static let wiringClosePrefs2At: TimeInterval = 11.8
    static let wiringReopenPrefs2At: TimeInterval = 12.6
    static let wiringClosePrefs3At: TimeInterval = 13.4
    static let wiringStopAt: TimeInterval = 14.2
    static let wiringMuteOffStoppedStageAt: TimeInterval = 15.8
    static let wiringApplyWhileStoppedAt: TimeInterval = 16.6
    static let wiringQuitAt: TimeInterval = 20.0

    // MARK: - PIN chain (stage D) timeline (MIRRORBOARD_UITEST_PIN=1)
    static let pinOpenPanelAt: TimeInterval = 1.0
    static let pinToggleOnAt: TimeInterval = 1.6
    static let pinStart1At: TimeInterval = 3.4
    static let pinStop1At: TimeInterval = 6.0
    static let pinStart2At: TimeInterval = 8.2
    static let pinStop2At: TimeInterval = 10.8
    static let pinStart3At: TimeInterval = 13.0
    static let pinChangeAt: TimeInterval = 15.5
    static let pinRenderChangeAt: TimeInterval = 16.8
    static let pinPrefsOpenAt: TimeInterval = 18.5
    static let pinPrefsCloseAt: TimeInterval = 19.3
    static let pinStop3At: TimeInterval = 20.2
    static let pinToggleOffAt: TimeInterval = 21.2
    static let pinRenderOffAt: TimeInterval = 21.9
    static let pinChangeWhileOffAt: TimeInterval = 22.4
    static let pinStart4At: TimeInterval = 23.8
    static let pinStop4At: TimeInterval = 26.8
    static let pinToggleOnAgainAt: TimeInterval = 28.0
    static let pinStart5At: TimeInterval = 29.5
    static let pinToggleOffRunningAt: TimeInterval = 32.5
    static let pinStop5At: TimeInterval = 34.8
    static let pinQuitAt: TimeInterval = 36.3

    // MARK: - SleepGuard / SessionNotifier (stage E / wave1r1 staged) timeline (MIRRORBOARD_UITEST_SLEEPNOTIFY=1)

    static let snOpenPanelAt: TimeInterval = 1.0
    static let snStart1At: TimeInterval = 1.6
    static let snPrefsOpenAt: TimeInterval = 4.2
    static let snSleepOffStageAt: TimeInterval = 5.2
    static let snSleepOffApplyAt: TimeInterval = 5.6
    static let snSleepOnStageAt: TimeInterval = 7.0
    static let snSleepOnApplyAt: TimeInterval = 7.4
    static let snInjectConnected1At: TimeInterval = 8.8
    static let snSnapshotConnectedAt: TimeInterval = 9.6
    static let snInjectDisconnected1At: TimeInterval = 10.4
    static let snNotifyOffStageAt: TimeInterval = 12.2
    static let snNotifyOffApplyAt: TimeInterval = 12.6
    static let snInjectConnected2At: TimeInterval = 13.2
    static let snSnapshotNotifyAlwaysAt: TimeInterval = 14.0
    static let snNotifyOnStageAt: TimeInterval = 15.0
    static let snNotifyOnApplyAt: TimeInterval = 15.4
    static let snInjectDisconnected2At: TimeInterval = 15.8
    static let snInjectConnected3At: TimeInterval = 16.7
    static let snPrefsCloseAt: TimeInterval = 17.4
    static let snStop1At: TimeInterval = 18.2
    static let snSleepOffStoppedStageAt: TimeInterval = 19.6
    static let snSleepOffStoppedApplyAt: TimeInterval = 20.2
    static let snPrefsReopenAt: TimeInterval = 21.2
    static let snPrefsRecloseAt: TimeInterval = 21.9
    static let snStart2At: TimeInterval = 23.2
    static let snStop2At: TimeInterval = 25.2
    static let snQuitAt: TimeInterval = 26.8

    // MARK: - Trust (the wave1r4 base; the wave1r6 apply-on-disconnect / PIN rotation / in-place ✕ rebuild;
    //         the wave1r10 app-modal forced interaction) timeline (MIRRORBOARD_UITEST_TRUST=1)
    //
    // wave1r6 coverage: ① PIN-off gate + PIN-off editor removal (apply
    // DROPPED — zero restart); ② the prompt's EN render/merge/keep (as before);
    // ③ distrust answered with NO live connection → CORNER apply
    // (gate=immediate: PIN rotate + restart); ④ removal while CONNECTED →
    // held; the socket close → DISCONNECT apply (gate=disconnect);
    // ⑤ two devices (sockets 20/21)→ editor ✕ held, live-view rebuild +
    // renders, a repeat click = a miss. The census counts sockets, so a close
    // flips the device only when the last socket drains: in ⑨ closing 丁's
    // socket 22 while 21 is live is a socket-level close (no flip), closing 丙's
    // 20 leaves 丁 online (nothing restarts), and 丁's last socket → apply;
    // ⑥ stop + a language flip for phase B.
    //
    // wave1r10d (YC ruled route ①: skip runModal, lock the app yourself) coverage: the app-side
    // lock engages (the level 26 re-asserted on show; the other windows masked; a local event
    // monitor swallowing events not for the prompt window); the no-close-button audit; a REAL posted-click answer on
    // the locked window; REAL Escape answer (prompt B); queue serialization
    // (device F queued while A is visible, presented only after A settles); a genuine
    // deactivate scenario (a thief app on the script side; active=0 ∧ visible=1); the
    // lock-blocking probe (the same posted click on the prefs Apply: it fires before
    // the lock / it is swallowed during the lock / it fires again after the lock).

    static let trOpenPanelAt: TimeInterval = 1.0
    /// ① PIN still OFF: the register event must be ignored (no prompt).
    static let trStart1At: TimeInterval = 1.4
    static let trInjectIgnoredAt: TimeInterval = 2.6
    static let trStop1At: TimeInterval = 3.2
    /// ①-B PIN OFF editor removal: write happens, cycle DROPPED (no trust
    /// semantics), live-view rebuild + repeat-click miss provable here.
    static let trPrefsOpenAt: TimeInterval = 3.5
    static let trEditorPresentAt: TimeInterval = 3.8
    static let trEditorAuditEAt: TimeInterval = 4.0
    static let trEditorRemoveEAt: TimeInterval = 4.2
    static let trEditorAuditEAfterAt: TimeInterval = 4.35
    static let trEditorRemoveEAgainAt: TimeInterval = 4.5
    static let trEditorDismissAt: TimeInterval = 4.8
    static let trPrefsCloseAt: TimeInterval = 5.1
    /// ② PIN on (write-back; stopped)→ spawn #2 (-pin/-key/-reg).
    static let trPinOnAt: TimeInterval = 5.4
    static let trStart2At: TimeInterval = 5.8
    /// wave1r10 — modal-blocking probe setup: open prefs → stage prevent-sleep on
    /// (dirty ⇒ Apply brightens) → **control leg** posted click (no modal: it must
    /// fire); the same click is dropped while prompt A's modal is up (the blocked leg),
    /// and fires again after the modal ends (the post leg). The net effect is zero (on…off once each).
    ///
    /// The r10b timing fix: the prefs window must open first (the syncFromTruth inside show()
    /// zeroes the staged values), so prefsOpen < stageOn; and at least 500ms must be left
    /// between the stage-on and the control click (700ms was actually measured) so that
    /// updateApplyState / the runloop finishes one full cycle; otherwise the click lands on an Apply button that has not brightened yet = a false injection failure.
    static let trProbePrefsOpenAt: TimeInterval = 5.9
    static let trProbeStageOnAt: TimeInterval = 6.0
    static let trProbeControlClickAt: TimeInterval = 6.7
    /// ③ The registration record for A → the ask → an EN render → merge → trust (keep).
    static let trInjectAAt: TimeInterval = 7.1
    static let trProbeStageOffAt: TimeInterval = 7.2
    static let trRenderPromptEnAt: TimeInterval = 7.7
    /// wave1r10 — during the modal: a genuine deactivate scenario (armed → the script thief →
    /// the marker → the probe → re-activation); F's registration (queued while A is visible =
    /// the serialization carrier); the blocked-leg click (during the modal). Order: deactivate
    /// settles first (the script finishes the handshake ~1.2s after arming), and the
    /// blocked/answer click only fires after re-activation (the scenarioActive guard).
    static let trDeactivateArmAt: TimeInterval = 7.35
    static let trInjectFAt: TimeInterval = 8.05
    static let trProbeModalClickAt: TimeInterval = 8.5
    static let trInjectAMergeAt: TimeInterval = 8.6
    /// The answer/dismiss steps POLL until the prompt is actually visible
    /// (the register record reaches the window asynchronously — log-watcher
    /// parse + main-queue hop; a fixed-time press can race it and no-op).
    /// wave1r10: A is answered by a REAL posted click on the trust button (the modal window itself
    /// still interacts normally); F (taking over from the queue) answers trust (keep) via the
    /// direct seam → the post-leg click (the modal has already closed: it must fire) → close the prefs.
    static let trAnswerTrustByClickAt: TimeInterval = 8.9
    static let trAnswerTrustFAt: TimeInterval = 9.05
    static let trProbePostClickAt: TimeInterval = 9.25
    static let trProbePrefsCloseAt: TimeInterval = 9.45
    /// ④ A pairs again → do-not-trust (no live connection → the CORNER applies, spawn #3).
    static let trInjectA2At: TimeInterval = 9.6
    static let trAnswerDistrustAt: TimeInterval = 10.2
    /// ⑤ The test device C connects (socket 10) → C registers → trust (keep).
    static let trInjectConnectCAt: TimeInterval = 11.3
    static let trInjectCAt: TimeInterval = 11.75
    static let trAnswerTrustCAt: TimeInterval = 12.55
    static let trPromptClosedAuditAt: TimeInterval = 13.2
    /// ⑥ B registers → answered with **ESC** (= do-not-trust → removal) while
    /// CONNECTED → held (wave1r10: ESC goes through the real key path; M1's unanswered close is
    /// carried by phase B's E).
    static let trInjectBAt: TimeInterval = 13.4
    static let trEscapeBAt: TimeInterval = 14.2
    /// ⑦ socket 10 closes → disconnect gate → apply #2 (spawn #4);
    /// the panel render carries the ROTATED code (the PIN rotation trace).
    static let trInjectClose10At: TimeInterval = 15.0
    static let trRenderPanelPinAt: TimeInterval = 16.6
    /// ⑧ two devices connect (sockets 20/21); editor: live rows → ✕ D
    /// (held — connected) → the on-screen renders before/after → a repeat click = a miss
    /// → Reset (pending updated)→ rows=0 render.
    static let trInjectAccept20At: TimeInterval = 17.2
    static let trInjectAccept21At: TimeInterval = 17.7
    static let trPrefsOpen2At: TimeInterval = 18.3
    static let trEditorPresent2At: TimeInterval = 18.6
    static let trEditorRenderBeforeAt: TimeInterval = 18.9
    static let trEditorRemoveDAt: TimeInterval = 19.2
    static let trEditorRenderAfterAt: TimeInterval = 19.5
    static let trEditorRemoveDAgainAt: TimeInterval = 19.8
    static let trEditorResetAt: TimeInterval = 20.1
    static let trEditorRenderResetAt: TimeInterval = 20.4
    static let trEditorDismiss2At: TimeInterval = 20.7
    static let trPrefsClose2At: TimeInterval = 21.0
    /// ⑨ census (fix-socket-census-r1): 丁 holds TWO connections — socket 22
    /// (accepted at 21.1, AFTER 丁's real name was revealed at 17.7) closes at
    /// 21.5 while 丁's own socket 21 is still live → socket-level close, no
    /// device flip. 丙's socket 20 closes at 22.0 while a different device is
    /// still online → nothing may restart. 丁's last socket (21) closes at
    /// 22.4 → apply #3 → spawn #5.
    static let trInjectAccept22At: TimeInterval = 21.1
    static let trInjectClose22At: TimeInterval = 21.5
    static let trInjectClose20At: TimeInterval = 22.0
    static let trInjectClose21At: TimeInterval = 22.4
    /// ⑩ Stop; flip the persisted language to zh-Hant (write-back only) for
    /// phase B's zh-Hant ask.
    static let trStop2At: TimeInterval = 24.4
    static let trPrefsReopenAt: TimeInterval = 25.0
    static let trLangStageAt: TimeInterval = 25.4
    static let trLangApplyAt: TimeInterval = 25.7
    static let trPrefsClose3At: TimeInterval = 26.1
    static let trQuitAt: TimeInterval = 26.5

    // MARK: - Trust phase B (MIRRORBOARD_UITEST_TRUST=2) — zh-Hant + the last rotation

    static let trhOpenPanelAt: TimeInterval = 1.0
    static let trhStartAt: TimeInterval = 1.4
    static let trhInjectEAt: TimeInterval = 2.8
    static let trhRenderPromptHantAt: TimeInterval = 3.1
    /// Dismiss E unanswered (M1) with no live connection → CORNER apply
    /// (gate=immediate)→ PIN rotate + restart (spawn #7).
    static let trhDismissEAt: TimeInterval = 3.5
    static let trhStopAt: TimeInterval = 6.5
    /// ⑪ Receiver STOPPED: an editor ✕F is an effective removal → the gate
    /// DEFERS (nothing to restart — the next start loads the new file) but
    /// still rotates the PIN now (the next session must not get through via auto-entry).
    static let trhPrefsOpenAt: TimeInterval = 7.1
    static let trhEditorPresentAt: TimeInterval = 7.4
    static let trhEditorRemoveFAt: TimeInterval = 7.75
    static let trhEditorDismissAt: TimeInterval = 8.1
    static let trhPrefsCloseAt: TimeInterval = 8.4
    /// ⑫ wave1r6b N-1 — a `.disconnected` that LAGS behind the stop above
    /// (the reviewer's race: the close line was already read/dispatched, the
    /// buffered event gets consumed after the receiver settled idle) while the
    /// pending removal (✕F — deferred, dirty still set) is on the flag.
    /// Injected via `injectReceiverEvent` = the exact consumer path a real
    /// in-flight event takes. Guarded builds: "TRUST apply skipped"(no
    /// revive); the pre-fix code restarts the receiver the user just closed
    /// (spawn appears 0.5s later — see the script's N-1 window).
    static let trhStaleDisconnectAt: TimeInterval = 8.6
    static let trhQuitAt: TimeInterval = 10.2

    /// Synthetic trust devices for the trust suite — marked as such so no
    /// a trace can be mistaken for a real device (real-device pairing is still a YC hands-on item; the
    /// injection drives the very parse path a real record takes).
    static let trDeviceZeroID = "00:00:00:00:00:00"
    static let trDeviceAID = "AA:AA:AA:AA:AA:01"
    static let trDeviceBID = "BB:BB:BB:BB:BB:02"
    static let trDeviceCID = "CC:CC:CC:CC:CC:03"
    static let trDeviceDID = "DD:DD:DD:DD:DD:04"
    static let trDeviceEID = "EE:EE:EE:EE:EE:05"
    static let trDeviceFID = "FF:FF:FF:FF:FF:06"
    /// Synthetic socket numbers for the census injections (the accept/close
    /// pairing the wave1r6 apply gate counts).
    static let trSocketC = 10
    static let trSocketD1 = 20
    /// 丁's FIRST TCP connection (video) — accepted at 17.7 with 丁's real name.
    static let trSocketD2 = 21
    /// 丁's SECOND TCP connection (audio): the SAME name and deviceID as
    /// `trSocketD2` (丁 / D) — see `trInjectAccept22At`. The census counts
    /// sockets, not devices, so the ⑨ window needs two connections that belong
    /// to ONE device for "a close with a survivor" to be a same-device case.
    static let trSocketD2b = 22
    /// Synthetic pk64 values (44-char base64 shapes)— the continuation line
    /// the parser must consume.
    static let trPKZero = String(repeating: "Z", count: 43) + "="
    static let trPKA = String(repeating: "A", count: 43) + "="
    static let trPKB = String(repeating: "B", count: 43) + "="
    static let trPKC = String(repeating: "C", count: 43) + "="
    static let trPKE = String(repeating: "E", count: 43) + "="
    static let trPKF = String(repeating: "F", count: 43) + "="

    // wave1r3 — the former Profile UI timelines (⑥/⑦; MIRRORBOARD_UITEST_
    // PROFILE) are RETIRED along with the Profiles section itself (B2 ruling ②): the engine side
    // tests live in ConfigEngineSelfTest (scripts/test-config-engine.sh).

    // MARK: - Language (stage G / wave1r3) timeline (MIRRORBOARD_UITEST_LANGUAGE=1)

    static let lgOpenPanelAt: TimeInterval = 1.0
    static let lgAuditPanelDefaultAt: TimeInterval = 1.4
    static let lgOpenPrefsAt: TimeInterval = 2.0
    static let lgAuditPrefsDefaultAt: TimeInterval = 2.4
    static let lgSwitchHantStageAt: TimeInterval = 2.8
    static let lgAuditStagedAt: TimeInterval = 3.1
    static let lgApplyHantAt: TimeInterval = 3.4
    static let lgAuditHantAt: TimeInterval = 3.8
    static let lgRenderHantAt: TimeInterval = 4.1
    // wave1r2 — the zh-Hant dirty render + the About window render (the ⑨ renders delivery).
    static let lgDirtyStageHantAt: TimeInterval = 4.4
    static let lgRenderHantDirtyAt: TimeInterval = 4.7
    static let lgResetHantStageAt: TimeInterval = 4.9
    static let lgAboutOpenAt: TimeInterval = 5.2
    static let lgAboutSnapshotAt: TimeInterval = 5.4
    static let lgAboutCloseAt: TimeInterval = 5.6
    static let lgSwitchHansStageAt: TimeInterval = 5.9
    static let lgApplyHansAt: TimeInterval = 6.2
    static let lgAuditHansAt: TimeInterval = 6.5
    static let lgSwitchBackHantStageAt: TimeInterval = 6.8
    static let lgApplyBackHantAt: TimeInterval = 7.1
    static let lgClosePrefsAt: TimeInterval = 7.4
    static let lgStartAt: TimeInterval = 7.9
    static let lgAuditRunningHantAt: TimeInterval = 8.7
    static let lgSwitchHansRunningStageAt: TimeInterval = 9.1
    static let lgApplyHansRunningAt: TimeInterval = 9.4
    static let lgAuditRunningHansAt: TimeInterval = 9.8
    static let lgStopAt: TimeInterval = 10.4
    static let lgQuitAt: TimeInterval = 11.0

    // MARK: - Language restart phase B (stage G) timeline (MIRRORBOARD_UITEST_LANGUAGE=2)

    static let lgrOpenPanelAt: TimeInterval = 1.0
    static let lgrAuditAt: TimeInterval = 1.4
    static let lgrQuitAt: TimeInterval = 2.6

    // MARK: - Language dictionary-fixture phase C (stage G) timeline (MIRRORBOARD_UITEST_LANGUAGE=3)

    static let lgcOpenPanelAt: TimeInterval = 1.0
    static let lgcAuditIdleAt: TimeInterval = 1.4
    static let lgcStartAt: TimeInterval = 2.2
    static let lgcAuditWaitingAt: TimeInterval = 3.2
    static let lgcStopAt: TimeInterval = 4.4
    static let lgcQuitAt: TimeInterval = 5.4

    /// Simulated device name for the injected events — marked as such so no
    /// a trace can be mistaken for a real device connection (a real connection is still a YC
    /// hands-on item; the injection drives the very path a real event takes).
    static let snInjectedDeviceName = "測試用 iPad"

    /// Debug-only snapshot/evidence output directory — the ONE temp scratch
    /// subtree shared with `CoreBridgeReceiverController` and `UILog`
    /// (P-2.2: one-shot scratch, no project-root path in the source).
    private static let scratchDir: String = {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("com.ycchung.mirageplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }()

    /// Schedules the increment-① sequence on the main queue.
    static func run(coordinator: LifecycleCoordinator) {
        UILog.line("UITEST armed")
        schedule(at: openPanelAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: snapshotAt) { writeVisualSnapshots(coordinator: coordinator) }
        schedule(at: closePanelAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: startAt) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: stopAt) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: quitAt) { coordinator.statusItemMenu?.performQuit() }
    }

    /// Schedules the increment-② (preferences window) sequence — the B1 single-page window.
    static func runPreferences(coordinator: LifecycleCoordinator) {
        UILog.line("UITEST prefs armed")
        schedule(at: prefsOpenPanelAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: prefsSnapshotsAt) { writeVisualSnapshots(coordinator: coordinator) }
        schedule(at: prefsOpenAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        // B1 clean state: a single-page render + audit (the reminder is absent, apply is grey).
        schedule(at: prefsCleanSnapshotAt) {
            coordinator.statusItemMenu?.renderPreferencesSnapshot(to: "\(scratchDir)/prefs-window.png")
            audit(coordinator, phase: "after prefs open")
        }
        // B1 changed state (R1): stage one slider edit → the reminder appears + apply
        // turns on; the render is the dirty-state evidence (wave1r3: a settled slider
        // commit — it settles only on release).
        schedule(at: prefsDirtyStageAt) {
            coordinator.statusItemMenu?.selectPreferencesResolutionStep(3)
        }
        schedule(at: prefsDirtySnapshotAt) {
            coordinator.statusItemMenu?.renderPreferencesSnapshot(to: "\(scratchDir)/prefs-window-dirty.png")
            // wave1r3 — a footer close-up (B2 §F: About bottom-right + the R1 full-text reminder).
            coordinator.statusItemMenu?.renderPreferencesFooterSnapshot(to: "\(scratchDir)/prefs-footer-dirty.png")
            audit(coordinator, phase: "dirty state (R1 reminder)")
        }
        // wave1r3 — the About entry = the preferences window's footer bottom-right button (B2 ruling ③ + the fix
        // "about belongs bottom-right, not bottom-left"): the press drives the exact in-window
        // button path → ACTION about-open → About mini-window; render +
        // rendered-string audit + close.
        schedule(at: prefsAboutOpenAt) { coordinator.statusItemMenu?.pressPreferencesAboutForTesting() }
        schedule(at: prefsAboutSnapshotAt) {
            coordinator.statusItemMenu?.renderAboutSnapshot(to: "\(scratchDir)/about-window.png")
            coordinator.statusItemMenu?.languageAuditAbout()
            audit(coordinator, phase: "about open (in-window entry)")
        }
        schedule(at: prefsAboutCloseAt) { coordinator.statusItemMenu?.closeAbout() }
        // wave1r1 R2: the trust editor SHELL — present (rows=0), probe the
        // one-click Reset no-op path, then dismiss (the sheet itself is not driven).
        schedule(at: prefsTrustPresentAt) { coordinator.statusItemMenu?.presentTrustEditorForTesting() }
        schedule(at: prefsTrustResetAt) { coordinator.statusItemMenu?.pressTrustResetForTesting() }
        schedule(at: prefsTrustDismissAt) { coordinator.statusItemMenu?.dismissTrustEditorForTesting() }
        // B1 ruling ⑤: Apply commits the staged edit — the dirty state clears
        // (the reminder goes and the button greys out again); the receiver never starts in this suite (a pure write-back).
        schedule(at: prefsApplyAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: prefsReopenAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        schedule(at: prefsReopenAuditAt) { audit(coordinator, phase: "after reopen (singleton)") }
        // wave1r3 — the B2 staged slider edit: the resolution slider→2160p (a settled commit);
        // the close DISCARDS the staged value (PM micro-decision 1).
        schedule(at: prefsSliderStageAt) { coordinator.statusItemMenu?.selectPreferencesResolutionStep(4) }
        schedule(at: prefsCloseAt) { coordinator.statusItemMenu?.closePreferences() }
        schedule(at: prefsCloseAuditAt) { audit(coordinator, phase: "after close") }
        schedule(at: prefsReopenAgainAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        schedule(at: prefsReopenAgainAuditAt) { audit(coordinator, phase: "after reopen 2") }
        schedule(at: prefsCloseAgainAt) { coordinator.statusItemMenu?.closePreferences() }
        schedule(at: prefsCloseAgainAuditAt) { audit(coordinator, phase: "after close 2") }
        schedule(at: prefsClosePanelAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: prefsFinalAuditAt) { audit(coordinator, phase: "final") }
        // the PIN protection + name visual layer (YC's addition): exercises the panel's
        // PIN toggle and the connected status row — rendered as visual
        // evidence (the visual layer as corroboration); the wave1r3 heights 212/192 (the about row
        // is withdrawn — B2 ruling ③).
        schedule(at: prefsPinOpenPanelAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: prefsPinOnAt) {
            coordinator.statusItemMenu?.setPanelPinProtection(true)
        }
        // Snapshot a beat later so the NSSwitch flip animation has settled
        // (immediate capture caught a mid-animation knob; found in run 4).
        schedule(at: prefsPinOnSnapshotAt) {
            coordinator.statusItemMenu?.renderPanelSnapshot(to: "\(scratchDir)/panel-pin-on.png")
        }
        schedule(at: prefsConnectedAt) {
            coordinator.statusItemMenu?.updateState(.connected(deviceName: "YC 的 iPad"))
            coordinator.statusItemMenu?.renderPanelSnapshot(to: "\(scratchDir)/panel-connected.png")
        }
        schedule(at: prefsPinOffAt) { coordinator.statusItemMenu?.setPanelPinProtection(false) }
        schedule(at: prefsRestoreIdleAt) { coordinator.statusItemMenu?.updateState(.idle) }
        schedule(at: prefsClosePanelAgainAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: prefsPostPinAuditAt) { audit(coordinator, phase: "post-pin final") }
        schedule(at: prefsQuitAt) { coordinator.statusItemMenu?.performQuit() }
    }

    /// Schedules the wave1r1 (R1 tuning) wiring sequence — see Timeline ③ in
    /// the type doc. Four field edits stay STAGED (zero engine action), and ONE Apply
    /// commits them with exactly one restart; an unapplied edit is discarded
    /// at close; the stopped-state apply is a pure write-back.
    static func runWiringE1(coordinator: LifecycleCoordinator) {
        UILog.line("UITEST wiring-e1 armed")
        schedule(at: wiringOpenPanelAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: wiringStartAt) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: wiringOpenPrefsAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        // Four STAGED edits — no engine write, no restart may follow until the apply.
        schedule(at: wiringResolutionStageAt) { coordinator.statusItemMenu?.selectPreferencesResolutionStep(1) }
        schedule(at: wiringFrameRateStageAt) { coordinator.statusItemMenu?.selectPreferencesFrameRateStep(3) }
        schedule(at: wiringMuteStageAt) { coordinator.statusItemMenu?.togglePreferencesMute(true) }
        schedule(at: wiringDeviceNameStageAt) { coordinator.statusItemMenu?.commitPreferencesDeviceName("YC 的 Mac") }
        // ONE Apply — all four fields in a single batch; exactly one restart.
        schedule(at: wiringApplyAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: wiringClosePrefsAt) { coordinator.statusItemMenu?.closePreferences() }
        // Reopen (singleton): syncFromTruth re-reads the engine — the PREFS
        // values line shows the committed values, apply is disabled again.
        schedule(at: wiringReopenPrefsAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        // A staged-but-unapplied edit: discarded at close (PM micro-decision 1).
        schedule(at: wiringFrameRateBackStageAt) { coordinator.statusItemMenu?.selectPreferencesFrameRateStep(4) }
        schedule(at: wiringClosePrefs2At) { coordinator.statusItemMenu?.closePreferences() }
        schedule(at: wiringReopenPrefs2At) { coordinator.statusItemMenu?.performOpenPreferences() }
        schedule(at: wiringClosePrefs3At) { coordinator.statusItemMenu?.closePreferences() }
        schedule(at: wiringStopAt) { coordinator.statusItemMenu?.performPrimaryAction() }
        // While stopped: stage + apply → pure write-back — no receiver action
        // may follow (the script asserts zero new spawns after this point).
        schedule(at: wiringMuteOffStoppedStageAt) { coordinator.statusItemMenu?.togglePreferencesMute(false) }
        schedule(at: wiringApplyWhileStoppedAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: wiringQuitAt) { coordinator.statusItemMenu?.performQuit() }
    }

    /// Schedules the stage D (wave1d) PIN-chain sequence — see Timeline ④ in
    /// the type doc. Every step goes through the same entry points the real
    /// controls take (`StatusItemMenu` seams → the panel's own action methods
    /// → `PreferencesIntentHandler` → ConfigEngine → E1 in the coordinator).
    static func runPinChain(coordinator: LifecycleCoordinator) {
        UILog.line("UITEST pin-chain armed")
        schedule(at: pinOpenPanelAt) { coordinator.statusItemMenu?.togglePanel() }
        // PIN on (the unset mode) while NOT running: a code is generated + written back,
        // zero receiver action.
        schedule(at: pinToggleOnAt) { coordinator.statusItemMenu?.setPanelPinProtection(true) }
        schedule(at: pinStart1At) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: pinStop1At) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: pinStart2At) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: pinStop2At) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: pinStart3At) { coordinator.statusItemMenu?.performPrimaryAction() }
        // regenerate while running: a fresh code + an E1 auto-restart (a new argv).
        schedule(at: pinChangeAt) { coordinator.statusItemMenu?.pressPanelPinChange() }
        schedule(at: pinRenderChangeAt) {
            coordinator.statusItemMenu?.renderPanelSnapshot(to: "\(scratchDir)/panel-pin-change.png")
        }
        // Preferences window: PIN field must show the engine truth (read-only).
        schedule(at: pinPrefsOpenAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        schedule(at: pinPrefsCloseAt) { coordinator.statusItemMenu?.closePreferences() }
        schedule(at: pinStop3At) { coordinator.statusItemMenu?.performPrimaryAction() }
        // PIN off while NOT running: write-back only; regenerate becomes greyed out.
        schedule(at: pinToggleOffAt) { coordinator.statusItemMenu?.setPanelPinProtection(false) }
        schedule(at: pinRenderOffAt) {
            coordinator.statusItemMenu?.renderPanelSnapshot(to: "\(scratchDir)/panel-pin-off.png")
        }
        // A press on the greyed button must be a no-op (P6).
        schedule(at: pinChangeWhileOffAt) { coordinator.statusItemMenu?.pressPanelPinChange() }
        schedule(at: pinStart4At) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: pinStop4At) { coordinator.statusItemMenu?.performPrimaryAction() }
        // PIN back on (already set): the changed code is reused — display and argv.
        schedule(at: pinToggleOnAgainAt) { coordinator.statusItemMenu?.setPanelPinProtection(true) }
        schedule(at: pinStart5At) { coordinator.statusItemMenu?.performPrimaryAction() }
        // P4 flip while running: E1 restart applies immediately (argv drops -pin).
        schedule(at: pinToggleOffRunningAt) { coordinator.statusItemMenu?.setPanelPinProtection(false) }
        schedule(at: pinStop5At) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: pinQuitAt) { coordinator.statusItemMenu?.performQuit() }
    }

    /// Schedules the stage E (wave1e) SleepGuard + SessionNotifier sequence —
    /// see Timeline ⑤ in the type doc. Drives the exact entry points the real
    /// controls take: the panel start/stop (`performPrimaryAction`), the prevent-sleep
    /// switch (`togglePreferencesPreventSleep` → the staged control action
    /// path, and then `applyPreferencesChanges` = Apply commits it), the retained B2
    /// slot (`togglePreferencesNotifications` — no page control any more, D8)
    /// and the connection events
    /// via `injectReceiverEvent` (a real connection is still a YC hands-on item — the injection runs
    /// the very path a real CoreBridge event takes).
    static func runSleepNotify(coordinator: LifecycleCoordinator) {
        UILog.line("UITEST sleep-notify armed")
        schedule(at: snOpenPanelAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: snStart1At) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: snPrefsOpenAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        // wave1r2: the B1 single-page window shows both switches right away
        // (no page switch seam exists any more).
        // prevent-sleep off: STAGED first (zero action), then Apply — immediate
        // assertion release, NO restart.
        schedule(at: snSleepOffStageAt) { coordinator.statusItemMenu?.togglePreferencesPreventSleep(false) }
        schedule(at: snSleepOffApplyAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: snSleepOnStageAt) { coordinator.statusItemMenu?.togglePreferencesPreventSleep(true) }
        schedule(at: snSleepOnApplyAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        // Connection events (injected): every one of them is notified.
        schedule(at: snInjectConnected1At) {
            coordinator.injectReceiverEvent(.connected(deviceName: snInjectedDeviceName))
        }
        schedule(at: snSnapshotConnectedAt) {
            coordinator.statusItemMenu?.renderPanelSnapshot(to: "\(scratchDir)/panel-notify-connected.png")
        }
        schedule(at: snInjectDisconnected1At) {
            coordinator.injectReceiverEvent(.disconnected)
        }
        // the B2 slot → false (staged + applied). D8: this NO LONGER silences
        // anything — the very next injected event must still produce its
        // the NOTIFY trace (recording is unaffected by the setting), while the panel status row keeps
        // updating through the state chain.
        schedule(at: snNotifyOffStageAt) { coordinator.statusItemMenu?.togglePreferencesNotifications(false) }
        schedule(at: snNotifyOffApplyAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: snInjectConnected2At) {
            coordinator.injectReceiverEvent(.connected(deviceName: snInjectedDeviceName))
        }
        schedule(at: snSnapshotNotifyAlwaysAt) {
            coordinator.statusItemMenu?.renderPanelSnapshot(to: "\(scratchDir)/panel-notify-unconditional.png")
        }
        // the B2 slot back to true (staged + applied): nothing about delivery changes.
        schedule(at: snNotifyOnStageAt) { coordinator.statusItemMenu?.togglePreferencesNotifications(true) }
        schedule(at: snNotifyOnApplyAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: snInjectDisconnected2At) {
            coordinator.injectReceiverEvent(.disconnected)
        }
        schedule(at: snInjectConnected3At) {
            coordinator.injectReceiverEvent(.connected(deviceName: snInjectedDeviceName))
        }
        schedule(at: snPrefsCloseAt) { coordinator.statusItemMenu?.closePreferences() }
        // stop #1: the assertion must be released (the stopped-state red line).
        schedule(at: snStop1At) { coordinator.statusItemMenu?.performPrimaryAction() }
        // prevent-sleep off while NOT running: staged + applied → a pure write-back; the next start uses it.
        schedule(at: snSleepOffStoppedStageAt) { coordinator.statusItemMenu?.togglePreferencesPreventSleep(false) }
        schedule(at: snSleepOffStoppedApplyAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: snPrefsReopenAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        schedule(at: snPrefsRecloseAt) { coordinator.statusItemMenu?.closePreferences() }
        // start #2 with prevent-sleep off: the receiver runs, zero assertion.
        schedule(at: snStart2At) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: snStop2At) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: snQuitAt) { coordinator.statusItemMenu?.performQuit() }
    }

    // MARK: - Trust (wave1r4) sequences

    /// Schedules the wave1r6 trust chain — see the timeline constants above
    /// and scripts/test-trust.sh. The register/connect/close records are
    /// injected as RAW launch.log lines in uxplay's exact LOGI shape
    /// (uxplay.cpp:2624/httpd.c:238,312), so the run exercises the REAL
    /// CoreBridge parse path — not a synthetic event shortcut. Covers:
    /// PIN-off gate + dropped apply / ask present / EN render / merge /
    /// trust keep / the corner apply (gate=immediate, PIN rotation) / connected →
    /// held (live=2: the session stays connected, and further closes are counted
    /// per socket — the device flips only once the census drains)
    /// / disconnect apply (gate=disconnect)
    /// / editor live-view rebuild + renders + repeat-click miss / Reset.
    static func runTrust(coordinator: LifecycleCoordinator) {
        UILog.line("UITEST trust armed (phase A)")
        schedule(at: trOpenPanelAt) { coordinator.statusItemMenu?.togglePanel() }
        // ① PIN OFF: the registration event must be ignored (the trust semantics exist only
        // while the PIN is on; this gate is redundant defence — with the PIN off uxplay never triggers register).
        schedule(at: trStart1At) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: trInjectIgnoredAt) {
            injectLaunchLogLine(trustRecord(
                name: "測試機零", deviceID: trDeviceZeroID, pk: trPKZero))
        }
        schedule(at: trStop1At) { coordinator.statusItemMenu?.performPrimaryAction() }
        // ①-B PIN OFF editor removal: the write happens, the pending cycle is
        // DROPPED (no trust semantics without PIN — zero restart), and the
        // live-view rebuild / repeat-click miss is already provable here.
        schedule(at: trPrefsOpenAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        schedule(at: trEditorPresentAt) { coordinator.statusItemMenu?.presentTrustEditorForTesting() }
        schedule(at: trEditorAuditEAt) { coordinator.statusItemMenu?.auditTrustEditorLiveRowsForTesting() }
        schedule(at: trEditorRemoveEAt) {
            coordinator.statusItemMenu?.removeTrustRowForTesting(machineCode: trDeviceEID)
        }
        schedule(at: trEditorAuditEAfterAt) { coordinator.statusItemMenu?.auditTrustEditorLiveRowsForTesting() }
        schedule(at: trEditorRemoveEAgainAt) {
            coordinator.statusItemMenu?.pressLiveTrustRowForTesting(machineCode: trDeviceEID)
        }
        schedule(at: trEditorDismissAt) { coordinator.statusItemMenu?.dismissTrustEditorForTesting() }
        schedule(at: trPrefsCloseAt) { coordinator.statusItemMenu?.closePreferences() }
        // ② PIN on (write-back; stopped)→ receiver start = spawn #2 with
        // -pin/-key/-reg.
        schedule(at: trPinOnAt) { coordinator.statusItemMenu?.setPanelPinProtection(true) }
        schedule(at: trStart2At) { coordinator.statusItemMenu?.performPrimaryAction() }
        // wave1r10 — modal probe setup: the prefs must come first (open it and make it dirty) +
        // the control leg (the posted click must fire = the injection method itself is
        // trustworthy). r10b — the engine truth preventSleep defaults to on (Presets; a
        // shell-held value is never serialized ⇒ it is always on at every start). So "making it
        // dirty" has to turn prevent-sleep **off** (only a value differing from the truth
        // creates dirt and brightens Apply); the original r10 wrote toggle(true), which is a
        // no-op when the truth is already on ⇒ the injected click landed on a grey button = a false failure (the root cause). The correspondence: the control leg's apply = prevent-sleep off; the post leg switches it back on.
        schedule(at: trProbePrefsOpenAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        schedule(at: trProbeStageOnAt) { coordinator.statusItemMenu?.togglePreferencesPreventSleep(false) }
        schedule(at: trProbeControlClickAt) {
            postApplyClickWhen(coordinator: coordinator, leg: "control", requiresLock: false)
        }
        // ③ A registers → the ask appears (at the moment pairing succeeds) → an EN render →
        // a same-device repeat = merge (not re-shown) → trust = keep (zero action).
        schedule(at: trInjectAAt) {
            injectLaunchLogLine(trustRecord(
                name: "測試機甲", deviceID: trDeviceAID, pk: trPKA))
        }
        // keep making it dirty (switch it back on): the blocked/post legs' criterion (it must not be applied during the modal).
        schedule(at: trProbeStageOffAt) { coordinator.statusItemMenu?.togglePreferencesPreventSleep(true) }
        schedule(at: trRenderPromptEnAt) {
            whenTrustPromptVisible(coordinator: coordinator, label: "trust-render-en") {
                coordinator.statusItemMenu?.renderTrustPromptSnapshot(to: "\(scratchDir)/trust-prompt-en.png")
                coordinator.statusItemMenu?.trustPromptStateAudit()
                coordinator.statusItemMenu?.trustPromptAudit()
            }
        }
        // wave1r10 — during the modal: a genuine deactivate scenario (the script-side thief takes
        // activation; armed → the marker → the probe (active=0 ∧ visible=1) → re-activation) +
        // F's registration (queued while A is visible) + the blocked-leg click (during the
        // modal it must be dropped).
        schedule(at: trDeactivateArmAt) { runDeactivateScenario(coordinator: coordinator) }
        schedule(at: trInjectFAt) {
            injectLaunchLogLine(trustRecord(
                name: "測試機己", deviceID: trDeviceFID, pk: trPKF))
        }
        schedule(at: trProbeModalClickAt) {
            postApplyClickWhen(coordinator: coordinator, leg: "locked", requiresLock: true)
        }
        schedule(at: trInjectAMergeAt) {
            injectLaunchLogLine(trustRecord(
                name: "測試機甲", deviceID: trDeviceAID, pk: trPKA))
        }
        // wave1r10 — A answers trust with a REAL posted click (the modal window itself still
        // interacts normally; after it settles, F (the queue) takes over) → F answers trust (keep)
        // → the post-leg click (after the modal settles it must fire) → close the prefs.
        schedule(at: trAnswerTrustByClickAt) { answerTrustByClickWhenVisible(coordinator: coordinator, deviceID: trDeviceAID) }
        schedule(at: trAnswerTrustFAt) { answerTrustWhenVisible(coordinator: coordinator, trusted: true, deviceID: trDeviceFID) }
        schedule(at: trProbePostClickAt) {
            postApplyClickWhen(coordinator: coordinator, leg: "post-lock", requiresLock: false)
        }
        schedule(at: trProbePrefsCloseAt) { coordinator.statusItemMenu?.closePreferences() }
        // ④ A pairs again (a re-pairing asks every time) → do-not-trust → removal + pending;
        // NO live connection at the answer → CORNER apply (gate=immediate):
        // PIN rotate + restart (spawn #3).
        schedule(at: trInjectA2At) {
            injectLaunchLogLine(trustRecord(
                name: "測試機甲", deviceID: trDeviceAID, pk: trPKA))
        }
        schedule(at: trAnswerDistrustAt) { answerTrustWhenVisible(coordinator: coordinator, trusted: false, deviceID: trDeviceAID) }
        // ⑤ The test device C connects (socket 10) → C registers → trust (keep);
        // the connection event itself must raise no ask.
        schedule(at: trInjectConnectCAt) {
            injectLaunchLogLine(connectRecord(socket: trSocketC, name: "測試機丙", deviceID: trDeviceCID))
        }
        schedule(at: trInjectCAt) {
            injectLaunchLogLine(trustRecord(
                name: "測試機丙", deviceID: trDeviceCID, pk: trPKC))
        }
        schedule(at: trAnswerTrustCAt) { answerTrustWhenVisible(coordinator: coordinator, trusted: true, deviceID: trDeviceCID) }
        schedule(at: trPromptClosedAuditAt) { coordinator.statusItemMenu?.trustPromptAudit() }
        // ⑥ B registers → close WITHOUT answering (M1 → removal) while
        // CONNECTED → held (the red line: never force an apply during a projection).
        schedule(at: trInjectBAt) {
            injectLaunchLogLine(trustRecord(
                name: "測試機乙", deviceID: trDeviceBID, pk: trPKB))
        }
        schedule(at: trEscapeBAt) { pressEscapeWhenVisible(coordinator: coordinator, deviceID: trDeviceBID) }
        // ⑦ socket 10 closes → disconnect gate → apply #2 (spawn #4);
        // the panel render carries the ROTATED code (the PIN rotation trace).
        schedule(at: trInjectClose10At) {
            injectLaunchLogLine(closeRecord(socket: trSocketC))
        }
        schedule(at: trRenderPanelPinAt) {
            coordinator.statusItemMenu?.renderPanelSnapshot(to: "\(scratchDir)/panel-pin-rotated.png")
        }
        // ⑧ two devices connect (sockets 20/21); editor: live rows → ✕ D
        // (held — connected) → the on-screen renders before/after → a repeat click =
        // miss (no second removal)→ Reset (pending updated)→ rows=0 render.
        schedule(at: trInjectAccept20At) {
            injectLaunchLogLine(connectRecord(socket: trSocketD1, name: "測試機丙", deviceID: trDeviceCID))
        }
        schedule(at: trInjectAccept21At) {
            injectLaunchLogLine(connectRecord(socket: trSocketD2, name: "測試機丁", deviceID: trDeviceDID))
        }
        schedule(at: trPrefsOpen2At) { coordinator.statusItemMenu?.performOpenPreferences() }
        schedule(at: trEditorPresent2At) { coordinator.statusItemMenu?.presentTrustEditorForTesting() }
        schedule(at: trEditorRenderBeforeAt) {
            coordinator.statusItemMenu?.auditTrustEditorLiveRowsForTesting()
            coordinator.statusItemMenu?.renderTrustEditorSnapshotForTesting(to: "\(scratchDir)/trust-editor-before-x.png")
        }
        schedule(at: trEditorRemoveDAt) {
            coordinator.statusItemMenu?.removeTrustRowForTesting(machineCode: trDeviceDID)
        }
        schedule(at: trEditorRenderAfterAt) {
            coordinator.statusItemMenu?.auditTrustEditorLiveRowsForTesting()
            coordinator.statusItemMenu?.renderTrustEditorSnapshotForTesting(to: "\(scratchDir)/trust-editor-after-x.png")
        }
        schedule(at: trEditorRemoveDAgainAt) {
            coordinator.statusItemMenu?.pressLiveTrustRowForTesting(machineCode: trDeviceDID)
        }
        schedule(at: trEditorResetAt) { coordinator.statusItemMenu?.pressTrustResetForTesting() }
        schedule(at: trEditorRenderResetAt) {
            coordinator.statusItemMenu?.auditTrustEditorLiveRowsForTesting()
            coordinator.statusItemMenu?.renderTrustEditorSnapshotForTesting(to: "\(scratchDir)/trust-editor-after-reset.png")
        }
        schedule(at: trEditorDismiss2At) { coordinator.statusItemMenu?.dismissTrustEditorForTesting() }
        schedule(at: trPrefsClose2At) { coordinator.statusItemMenu?.closePreferences() }
        // ⑨ census (fix-socket-census-r1, review R1): the honest "one device,
        // several TCP connections" shape — 丁 accepts a SECOND connection
        // (socket 22) AFTER its real name is on the panel, so the accept path's
        // placeholder must not overwrite it (review R2) and the close of 22
        // must not read as 丁 going offline. 丙 (socket 20) is a different
        // device and stays online throughout.
        schedule(at: trInjectAccept22At) {
            injectLaunchLogLine(connectRecord(socket: trSocketD2b, name: "測試機丁", deviceID: trDeviceDID))
        }
        schedule(at: trInjectClose22At) {
            injectLaunchLogLine(closeRecord(socket: trSocketD2b))
        }
        // 丙's last socket closes while 丁 is still online: no restart may fire.
        schedule(at: trInjectClose20At) {
            injectLaunchLogLine(closeRecord(socket: trSocketD1))
        }
        // 丁's LAST socket → the device-level disconnect → apply #3 (spawn #5).
        schedule(at: trInjectClose21At) {
            injectLaunchLogLine(closeRecord(socket: trSocketD2))
        }
        // ⑩ Stop; flip the persisted language to zh-Hant (write-back only —
        // the receiver is down) so phase B's ask renders in zh-Hant.
        schedule(at: trStop2At) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: trPrefsReopenAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        schedule(at: trLangStageAt) { coordinator.statusItemMenu?.selectPreferencesLanguage("zh-Hant") }
        schedule(at: trLangApplyAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: trPrefsClose3At) { coordinator.statusItemMenu?.closePreferences() }
        schedule(at: trQuitAt) { coordinator.statusItemMenu?.performQuit() }
    }

    /// Schedules the trust chain phase B — the persisted zh-Hant renders the
    /// ask; the render + audit carry the zh-Hant acceptance shot, and the
    /// unanswered close proves M1 removal once more end-to-end — now followed
    /// by the wave1r6 CORNER apply (no live connection at the answer) with its
    /// PIN rotation (the persisted set code cycles again).
    static func runTrustHant(coordinator: LifecycleCoordinator) {
        UILog.line("UITEST trust armed (phase B)")
        schedule(at: trhOpenPanelAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: trhStartAt) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: trhInjectEAt) {
            injectLaunchLogLine(trustRecord(
                name: "測試機戊", deviceID: trDeviceEID, pk: trPKE))
        }
        schedule(at: trhRenderPromptHantAt) {
            whenTrustPromptVisible(coordinator: coordinator, label: "trust-render-hant") {
                coordinator.statusItemMenu?.renderTrustPromptSnapshot(to: "\(scratchDir)/trust-prompt-hant.png")
                coordinator.statusItemMenu?.trustPromptAudit()
                audit(coordinator, phase: "trust prompt hant")
            }
        }
        schedule(at: trhDismissEAt) { dismissTrustWhenVisible(coordinator: coordinator) }
        schedule(at: trhStopAt) { coordinator.statusItemMenu?.performPrimaryAction() }
        // ⑪ Receiver stopped: editor ✕F → removal → DEFERRED apply (zero
        // restart — the next start loads the file) + immediate PIN rotate.
        schedule(at: trhPrefsOpenAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        schedule(at: trhEditorPresentAt) { coordinator.statusItemMenu?.presentTrustEditorForTesting() }
        schedule(at: trhEditorRemoveFAt) {
            coordinator.statusItemMenu?.removeTrustRowForTesting(machineCode: trDeviceFID)
        }
        schedule(at: trhEditorDismissAt) { coordinator.statusItemMenu?.dismissTrustEditorForTesting() }
        schedule(at: trhPrefsCloseAt) { coordinator.statusItemMenu?.closePreferences() }
        // ⑫ The wave1r6b N-1 regression: a disconnect that lags after the stop = stale (the receiver
        // is idle + dirty is still set) → the guard blocks it; before the fix this step would apply + restart (a false revival).
        schedule(at: trhStaleDisconnectAt) {
            coordinator.injectReceiverEvent(.disconnected)
        }
        schedule(at: trhQuitAt) { coordinator.statusItemMenu?.performQuit() }
    }

    // MARK: - Language (stage G) sequences

    /// Schedules the stage G (wave1g) language sequence, wave1r3 — see Timeline ⑧
    /// in the type doc. Drives the exact path the language picker takes
    /// (`StatusItemMenu.selectPreferencesLanguage` → the window's STAGED
    /// selection → `applyPreferencesChanges` = Apply →
    /// `PreferencesIntentHandler` → engine write + service flip + coordinator
    /// trace) and audits the RENDERED strings of every surface after every
    /// step. The B2 slider batch: the audits cover the THREE group caps; the renders deliver
    /// EN / zh-Hant clean, zh-Hant dirty (the R1 full-text reminder) + a footer close-up and the About
    /// window.
    static func runLanguage(coordinator: LifecycleCoordinator) {
        UILog.line("UITEST language armed")
        schedule(at: lgOpenPanelAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: lgAuditPanelDefaultAt) { coordinator.statusItemMenu?.languageAuditPanel() }
        schedule(at: lgOpenPrefsAt) { coordinator.statusItemMenu?.performOpenPreferences() }
        schedule(at: lgAuditPrefsDefaultAt) {
            coordinator.statusItemMenu?.languageAuditPanel()
            coordinator.statusItemMenu?.languageAuditPrefs()
            coordinator.statusItemMenu?.renderPreferencesSnapshot(to: "\(scratchDir)/prefs-window-en.png")
        }
        // ② The STAGED switch to zh-Hant: the picker shows Traditional Chinese while the strings stay EN —
        // nothing flips until the apply.
        schedule(at: lgSwitchHantStageAt) { coordinator.statusItemMenu?.selectPreferencesLanguage("zh-Hant") }
        schedule(at: lgAuditStagedAt) {
            coordinator.statusItemMenu?.languageAuditPrefs()
        }
        schedule(at: lgApplyHantAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: lgAuditHantAt) {
            coordinator.statusItemMenu?.languageAuditPanel()
            coordinator.statusItemMenu?.languageAuditPrefs()
        }
        schedule(at: lgRenderHantAt) {
            coordinator.statusItemMenu?.renderPreferencesSnapshot(to: "\(scratchDir)/prefs-window-hant.png")
        }
        // wave1r2 — the zh-Hant dirty render: stage a language change (not applied) so the
        // R1 reminder shows on the zh-Hant window, render, then stage back.
        schedule(at: lgDirtyStageHantAt) { coordinator.statusItemMenu?.selectPreferencesLanguage("en") }
        schedule(at: lgRenderHantDirtyAt) {
            coordinator.statusItemMenu?.renderPreferencesSnapshot(to: "\(scratchDir)/prefs-window-hant-dirty.png")
            // wave1r3 — the zh-Hant footer close-up (About bottom-right + the R1 full-text reminder).
            coordinator.statusItemMenu?.renderPreferencesFooterSnapshot(to: "\(scratchDir)/prefs-footer-hant-dirty.png")
        }
        schedule(at: lgResetHantStageAt) { coordinator.statusItemMenu?.selectPreferencesLanguage("zh-Hant") }
        // wave1r2 — the About window (zh-Hant) rendered-string audit + render + close.
        schedule(at: lgAboutOpenAt) { coordinator.statusItemMenu?.performOpenAbout() }
        schedule(at: lgAboutSnapshotAt) {
            coordinator.statusItemMenu?.languageAuditAbout()
            coordinator.statusItemMenu?.renderAboutSnapshot(to: "\(scratchDir)/about-window-hant.png")
        }
        schedule(at: lgAboutCloseAt) { coordinator.statusItemMenu?.closeAbout() }
        // ③ switch to zh-Hans (staged + applied).
        schedule(at: lgSwitchHansStageAt) { coordinator.statusItemMenu?.selectPreferencesLanguage("zh-Hans") }
        schedule(at: lgApplyHansAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: lgAuditHansAt) {
            coordinator.statusItemMenu?.languageAuditPanel()
            coordinator.statusItemMenu?.languageAuditPrefs()
        }
        // Persist zh-Hant as the final selection (phase B asserts that it survives).
        schedule(at: lgSwitchBackHantStageAt) { coordinator.statusItemMenu?.selectPreferencesLanguage("zh-Hant") }
        schedule(at: lgApplyBackHantAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: lgClosePrefsAt) { coordinator.statusItemMenu?.closePreferences() }
        // ⑤ receiver impact (E1 row 12): the receiver runs while the language
        // flips — zero restart, zero spawn.
        schedule(at: lgStartAt) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: lgAuditRunningHantAt) { coordinator.statusItemMenu?.languageAuditPanel() }
        schedule(at: lgSwitchHansRunningStageAt) { coordinator.statusItemMenu?.selectPreferencesLanguage("zh-Hans") }
        schedule(at: lgApplyHansRunningAt) { coordinator.statusItemMenu?.applyPreferencesChanges() }
        schedule(at: lgAuditRunningHansAt) { coordinator.statusItemMenu?.languageAuditPanel() }
        schedule(at: lgStopAt) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: lgQuitAt) { coordinator.statusItemMenu?.performQuit() }
    }

    /// Schedules the stage G restart phase — see Timeline ⑧-B: the persisted
    /// language must be in force on the very first render after relaunch.
    static func runLanguageRestart(coordinator: LifecycleCoordinator) {
        UILog.line("UITEST language-restart armed")
        schedule(at: lgrOpenPanelAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: lgrAuditAt) { coordinator.statusItemMenu?.languageAuditPanel() }
        schedule(at: lgrQuitAt) { coordinator.statusItemMenu?.performQuit() }
    }

    /// Schedules the stage G dictionary-fixture phase — see Timeline ⑧-C:
    /// MIRRORBOARD_STRINGS_PATH points at a fixture whose
    /// `panel.status.waiting` carries no zh-Hant entry, so the rendered
    /// status text must fall back to the dictionary default language and the
    /// miss must be recorded (LANG missing …).
    static func runLanguageFixture(coordinator: LifecycleCoordinator) {
        UILog.line("UITEST language-fixture armed")
        schedule(at: lgcOpenPanelAt) { coordinator.statusItemMenu?.togglePanel() }
        schedule(at: lgcAuditIdleAt) { coordinator.statusItemMenu?.languageAuditPanel() }
        schedule(at: lgcStartAt) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: lgcAuditWaitingAt) { coordinator.statusItemMenu?.languageAuditPanel() }
        schedule(at: lgcStopAt) { coordinator.statusItemMenu?.performPrimaryAction() }
        schedule(at: lgcQuitAt) { coordinator.statusItemMenu?.performQuit() }
    }

    // MARK: - Visual evidence

    /// Writes the panel render + icon sheet (visual evidence).
    private static func writeVisualSnapshots(coordinator: LifecycleCoordinator) {
        coordinator.statusItemMenu?.renderPanelSnapshot(to: "\(scratchDir)/panel-snapshot.png")
        writeIconSheet(to: "\(scratchDir)/statusicon-sheet.png")
    }

    /// Draws the four icon states side by side — once at the production
    /// 18 pt canvas and once at 16 pt (the A3 conventional value), so the shape's clarity
    /// at both in-band sizes can be judged from one PNG.
    ///
    /// Both rows are drawn at the SAME magnification (48 px per 18 pt);
    /// the 16 pt row therefore gets a TRUE 16-pt frame (48 × 16/18 ≈
    /// 42.67 px), shown smaller — it is NOT the 18 pt render re-stretched
    /// into an equal box. (Reviewer finding N-1: with a common destination
    /// box both renders scale by the identical 0.945 content/canvas ratio
    /// and come out pixel-identical — a fake comparison. Fixed here.)
    private static func writeIconSheet(to path: String) {
        let states: [ReceiverState] = [.idle, .waiting, .connected(deviceName: "iPad"), .stopping]
        let rows: [(label: String, side: CGFloat)] = [("18", 18), ("16", 16)]
        let cell: CGFloat = 48
        let gap: CGFloat = 16
        let labelWidth: CGFloat = 22
        let productionSide: CGFloat = 18
        let width = gap + labelWidth + CGFloat(states.count) * (cell + gap)
        let height = gap + CGFloat(rows.count) * (cell + gap)

        let sheet = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]

            for (rowIndex, row) in rows.enumerated() {
                let y = height - gap - CGFloat(rowIndex + 1) * cell - CGFloat(rowIndex) * gap
                let label = NSAttributedString(string: row.label, attributes: labelAttributes)
                label.draw(at: NSPoint(x: gap, y: y + cell / 2 - 6))
                // Same magnification for every row: cell px per 18 pt. The
                // 16 pt row is a genuine 16-pt frame (cell × 16/18), shown
                // smaller rather than re-stretched to the 18 pt box; a
                // hairline marks each box's true extent so the 16-vs-18
                // size difference is visible and machine-measurable.
                let drawSide = cell * row.side / productionSide
                let inset = (cell - drawSide) / 2
                for (columnIndex, state) in states.enumerated() {
                    let x = gap + labelWidth + CGFloat(columnIndex) * (cell + gap)
                    let box = NSRect(x: x + inset, y: y + inset, width: drawSide, height: drawSide)
                    NSColor.separatorColor.setStroke()
                    let boxFrame = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
                    boxFrame.lineWidth = 1
                    boxFrame.stroke()
                    StatusIconFactory.image(for: state, canvasSize: row.side)
                        .draw(in: box)
                }
            }
            return true
        }
        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            UILog.line("ICONSHEET failed")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            UILog.line("ICONSHEET \(path)")
        } catch {
            UILog.line("ICONSHEET failed (\(error.localizedDescription))")
        }
    }

    // MARK: - Helpers

    /// Appends a windows audit line (while open = the panel + the preferences window; nothing is left after closing).
    private static func audit(_ coordinator: LifecycleCoordinator, phase: String) {
        guard let line = coordinator.statusItemMenu?.windowsAudit() else { return }
        UILog.line("\(line) (\(phase))")
    }

    /// Appends a RAW byte string to launch.log — the uxplay stdout channel —
    /// so the running log watcher parses it through the REAL CoreBridge
    /// pipeline (wave1r4 trust suite; injection drives the very path a real
    /// uxplay record takes). O_APPEND puts every write at the current EOF
    /// (the same discipline as the app's own marker writes).
    ///
    /// The location is NOT rebuilt here: it is the pair the spawn hands the
    /// child and the watcher polls — `CoreBridgeReceiverController
    /// .launchLogDirectory()` + `launchLogFileName`. Log moved once already
    /// (temp scratch → Application Support); taking the location from its
    /// owner is what keeps a second move from silently aiming the injector at
    /// a file nobody reads.
    private static func injectLaunchLogLine(_ text: String) {
        let path = CoreBridgeReceiverController.launchLogDirectory()
            .appendingPathComponent(CoreBridgeReceiverController.launchLogFileName).path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            UILog.line("UITEST trust inject failed (open \(path))")
            return
        }
        defer { close(fd) }
        let data = Data(text.utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        UILog.line("UITEST trust injected lines=\(text.filter { $0 == "\n" }.count)")
    }

    /// uxplay's EXACT two-line registration record (uxplay.cpp:2624 LOGI;
    /// `log()` appends the final `\n`): the prefix line ends `PK = ` and the
    /// pk64 continuation rides the next line.
    private static func trustRecord(name: String, deviceID: String, pk: String) -> String {
        "registered new client: \(name) DeviceID = \(deviceID) PK = \n\(pk)\n"
    }

    /// A socket-accept + connection-request pair — the exact lines a live
    /// uxplay writes when a device connects (httpd.c:312/uxplay.cpp:2334).
    /// The wave1r6 socket census counts the accepts and the closes.
    private static func connectRecord(socket: Int, name: String, deviceID: String) -> String {
        "Accepted IPv4 client on socket \(socket), port 1131\n"
            + "connection request from \(name) (iPad14,1) with deviceID = \(deviceID)\n"
    }

    /// The close line the wave1r6 census removes on (httpd.c:238).
    private static func closeRecord(socket: Int) -> String {
        "Connection closed on socket \(socket)\n"
    }

    /// Answers the trust ask once it is ACTUALLY on screen **_for the target
    /// device_** — the register record reaches the window asynchronously
    /// (log-watcher parse + main-queue hop), so a fixed-time press can race a
    /// not-yet-visible prompt (settle() no-ops then; observed in the first
    /// wave1r6 suite run). wave1r10d — the poll additionally matches the
    /// prompt's DEVICE: under serialization several prompts can be in flight,
    /// and answering "any visible prompt" desynchronises the timeline (r12
    /// the single root cause of the red list). It polls every 0.1s up to `deadline` seconds.
    private static func answerTrustWhenVisible(
        coordinator: LifecycleCoordinator, trusted: Bool, deviceID: String,
        deadline: TimeInterval = 4.0
    ) {
        pollUntil(deadline: deadline, label: trusted ? "trust-answer" : "trust-distrust") {
            guard coordinator.statusItemMenu?.trustPromptVisibleForTesting == true,
                  coordinator.statusItemMenu?.trustPromptDeviceIDForTesting == deviceID else {
                return false
            }
            coordinator.statusItemMenu?.answerTrustPromptForTesting(trusted: trusted)
            return true
        }
    }

    /// The red-light close (the M1 "no answer" case) once the ask is actually on screen —
    /// same poll discipline as `answerTrustWhenVisible`.
    private static func dismissTrustWhenVisible(
        coordinator: LifecycleCoordinator, deadline: TimeInterval = 4.0
    ) {
        pollUntil(deadline: deadline, label: "trust-dismiss") {
            guard coordinator.statusItemMenu?.trustPromptVisibleForTesting == true else { return false }
            coordinator.statusItemMenu?.dismissTrustPromptForTesting()
            return true
        }
    }

    // MARK: - wave1r10d helpers (the empirical proof of the app-side lock for forced
    //                interaction; every probe was measured with the probe plan before landing)

    /// True while the real-deactivation scenario is in flight: other probe
    /// polls must NOT reactivate the app mid-scenario (they would fight the
    /// thief and make the `active=0` probe sample racy).
    private static var deactivateScenarioActive = false

    /// Raises the app so posted events route normally (under macOS 14 cooperative
    /// activation a process launched from the CLI is not active by default; `activate(from:)`
    /// citing the frontmost app is a non-deprecated path proven to work).
    private static func activateForEvents(coordinator: LifecycleCoordinator) {
        _ = coordinator.statusItemMenu?.activateForEventsForTesting()
    }

    /// wave1r10d — posts the prefs-window Apply click once the required
    /// lock condition holds and the app is active. Non-locked legs re-front
    /// the window first (make key — the user-click recipe lands on the key
    /// window); the in-lock leg never touches other windows (the mask would
    /// fight it).
    private static func postApplyClickWhen(
        coordinator: LifecycleCoordinator, leg: String, requiresLock: Bool,
        deadline: TimeInterval = 6.0
    ) {
        pollUntil(deadline: deadline, label: "apply-click-\(leg)") {
            if deactivateScenarioActive { return false }
            let locked = coordinator.statusItemMenu?.trustPromptLockActiveForTesting == true
            if requiresLock {
                guard locked else { return false }
            } else {
                guard !locked else { return false }
            }
            guard NSApp.isActive else {
                activateForEvents(coordinator: coordinator)
                return false
            }
            if !requiresLock {
                coordinator.statusItemMenu?.performOpenPreferences()
            }
            coordinator.statusItemMenu?.postPreferencesApplyClickForTesting(leg: leg)
            return true
        }
    }

    /// wave1r10 — the REAL deactivation scenario: the
    /// deactivation itself is handed to the test script — it launches the
    /// cooperating "thief" helper app, which activates itself citing this
    /// app (probe-verified dethroning)— and confirms with a marker file.
    /// The probe line then reads the prompt's state WHILE the app is
    /// genuinely inactive: `active=0 visible=1` = hidesOnDeactivate=NO holds
    /// under a real deactivation (YC's order c). The app is re-activated right
    /// after (the harness cannot proceed inactive: posted events need an
    /// active app).
    private static func runDeactivateScenario(coordinator: LifecycleCoordinator) {
        let marker = "\(scratchDir)/deactivate-done"
        try? FileManager.default.removeItem(atPath: marker)
        deactivateScenarioActive = true
        UILog.line("UITEST deactivate scenario armed (script: launch thief, then touch deactivate-done)")
        let started = Date()
        func step() {
            let confirmed = FileManager.default.fileExists(atPath: marker)
            if confirmed || Date().timeIntervalSince(started) >= 4.0 {
                coordinator.statusItemMenu?.trustPromptStateAudit()
                UILog.line(
                    "TRUST prompt deactivate probe active=\(NSApp.isActive ? 1 : 0) visible=\(coordinator.statusItemMenu?.trustPromptVisibleForTesting == true ? 1 : 0)\(confirmed ? "" : " (marker timeout — script did not confirm)")"
                )
                reactivate(coordinator: coordinator, attemptsLeft: 8)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: step)
        }
        step()
    }

    /// wave1r10 — re-raises the app after the deactivation scenario and
    /// reports the outcome (retries: activation settles asynchronously).
    private static func reactivate(coordinator: LifecycleCoordinator, attemptsLeft: Int) {
        if NSApp.isActive {
            deactivateScenarioActive = false
            UILog.line("UITEST reactivated active=1")
            return
        }
        guard attemptsLeft > 0 else {
            deactivateScenarioActive = false
            UILog.line("UITEST reactivated active=0 (gave up)")
            return
        }
        activateForEvents(coordinator: coordinator)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            reactivate(coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// wave1r10d — answers trust through the REAL posted-click path on the
    /// visible app-locked prompt **for the target device** (the prompt window
    /// stays fully interactive = not in the "blocked" set). If the posted
    /// click does not land within 1.2 s a loud `trust-click ANSWER MISSED`
    /// line lands and the DIAGNOSTIC fallback answers — tagged `via=fallback`
    /// so it can never masquerade as a real landing. The script asserts both:
    /// `ANSWER MISSED` count=0 (wave1r10e negative assertion) and the answer
    /// line reads `via=button` (a fallback yields `via=fallback` ⇒ red).
    private static func answerTrustByClickWhenVisible(
        coordinator: LifecycleCoordinator, deviceID: String, deadline: TimeInterval = 4.0
    ) {
        pollUntil(deadline: deadline, label: "trust-click-answer") {
            if deactivateScenarioActive { return false }
            guard coordinator.statusItemMenu?.trustPromptVisibleForTesting == true,
                  coordinator.statusItemMenu?.trustPromptDeviceIDForTesting == deviceID,
                  coordinator.statusItemMenu?.trustPromptLockActiveForTesting == true else { return false }
            guard NSApp.isActive else {
                activateForEvents(coordinator: coordinator)
                return false
            }
            coordinator.statusItemMenu?.postTrustClickForTesting()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard coordinator.statusItemMenu?.trustPromptVisibleForTesting == true else { return }
                UILog.line("UITEST trust-click ANSWER MISSED (prompt still visible)")
                coordinator.statusItemMenu?.answerTrustFallbackForTesting(trusted: true)
            }
            return true
        }
    }

    /// wave1r10d — presses ESC through the REAL key path on the visible
    /// app-locked prompt **for the target device** (ESC = do-not-trust). The same
    /// MISSED-fallback discipline as the click path above; the audit line
    /// right before the post carries the pre-ESC window state (locked/key).
    /// The fallback tags `via=fallback` (the script asserts `trust-esc
    /// ANSWER MISSED` count=0 and a `via=button` answer line).
    private static func pressEscapeWhenVisible(
        coordinator: LifecycleCoordinator, deviceID: String, deadline: TimeInterval = 4.0
    ) {
        pollUntil(deadline: deadline, label: "trust-esc") {
            if deactivateScenarioActive { return false }
            guard coordinator.statusItemMenu?.trustPromptVisibleForTesting == true,
                  coordinator.statusItemMenu?.trustPromptDeviceIDForTesting == deviceID,
                  coordinator.statusItemMenu?.trustPromptLockActiveForTesting == true else { return false }
            guard NSApp.isActive else {
                activateForEvents(coordinator: coordinator)
                return false
            }
            coordinator.statusItemMenu?.trustPromptStateAudit()
            coordinator.statusItemMenu?.postTrustEscapeForTesting()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard coordinator.statusItemMenu?.trustPromptVisibleForTesting == true else { return }
                UILog.line("UITEST trust-esc ANSWER MISSED (prompt still visible)")
                coordinator.statusItemMenu?.answerTrustFallbackForTesting(trusted: false)
            }
            return true
        }
    }

    /// Runs `body` once the trust ask is actually on screen — the render +
    /// rendered-string audit steps need the window PRESENTED (a pre-present
    /// audit reads an empty message; observed in the second wave1r6 run).
    private static func whenTrustPromptVisible(
        coordinator: LifecycleCoordinator, label: String, deadline: TimeInterval = 4.0,
        _ body: @escaping () -> Void
    ) {
        pollUntil(deadline: deadline, label: label) {
            guard coordinator.statusItemMenu?.trustPromptVisibleForTesting == true else { return false }
            body()
            return true
        }
    }

    /// Runs `attempt` on the main queue every 0.1s until it returns true or
    /// the deadline passes (test-harness timing helper — makes the suite
    /// independent of log-parse latency).
    private static func pollUntil(deadline: TimeInterval, label: String, attempt: @escaping () -> Bool) {
        let started = Date()
        func step() {
            if attempt() { return }
            if Date().timeIntervalSince(started) < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: step)
            } else {
                UILog.line("UITEST \(label) timed out (prompt never visible)")
            }
        }
        step()
    }

    private static func schedule(at delta: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delta, execute: block)
    }
}
#endif
