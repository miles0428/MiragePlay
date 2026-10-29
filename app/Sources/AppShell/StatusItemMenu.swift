import AppKit
import Localization
import ReceiverKit
import SessionNotifier
import SettingsUI

/// Menu bar status item — J1 (LSUIElement resident, no Dock icon).
///
/// CP-2 / increment ① (2026-10-16): the item is a real, instantiated status
/// item whose click opens an **anchored panel** (MenuBarExtra-style control
/// surface; AppKit NSStatusItem + NSPanel route per the 2026-10-16 ruling —
/// "MenuBarExtra" = a description of the form; the implementation framework = AppKit, not the old NSMenu dropdown).
///
/// Panel content (increment ②, 2026-10-17): status row / start·stop /
/// preferences… (opens the single preferences window) / quit.
/// PIN switch + code row + the regenerate button (stage D / wave1d): engine-wired — the panel reads
/// the engine truth (pinStateProvider) and emits intent through the same
/// AppShell adapter as the preferences window (engine write + E1).
///
/// The icon carries the YC hand-drawn fixed shape whose COLOUR carries the
/// three states (YC ruling ③) — see StatusIconFactory for the single
/// replacement point of the final YC icon file.
///
/// UI-side evidence log: every lifecycle-visible step appends a line to
/// `<NSTemporaryDirectory()>/com.ycchung.mirageplay/ui.log` via UILog
/// (STATUSITEM / PANEL / PREFS / ACTION /
/// STATE / WINDOWS) — the launch.log (uxplay stdout) channel is untouched.
final class StatusItemMenu: NSObject {

    private var statusItem: NSStatusItem!
    private weak var lifecycleCoordinator: LifecycleCoordinator?
    private let panelController: StatusPanelController
    private let preferencesController: PreferencesWindowController
    /// wave1r2 — the About mini-window (B1 §E-1 option A); wave1r3: the entry point is a
    /// small button at the preferences window's footer bottom-right (B2 ruling ③ + "about belongs bottom-right, not bottom-left").
    /// Single instance, owned here.
    private let aboutController: AboutWindowController
    /// wave1r4 — the trust ask prompt (I2).
    /// Single instance, owned here; presented by the coordinator when a PIN
    /// pairing registers a new client. wave1r10d — the app-side lock forces interaction
    /// (always topmost at level 26, no close button, ESC = do-not-trust; see TrustPromptWindowController).
    private let trustPromptController: TrustPromptWindowController
    /// Retained so the intent handler outlives CompositionRoot.build()
    /// (the preferences window holds it weakly).
    private let preferencesIntent: PreferencesIntentHandling?
    /// stage G (wave1g): the term lookup behind every user-visible string in
    /// the two control surfaces and the menu-bar tooltip.
    private let localization: LanguageService

    init(
        lifecycleCoordinator: LifecycleCoordinator,
        localization: LanguageService,
        preferencesIntent: PreferencesIntentHandling? = nil,
        trustDevicesProvider: @escaping () -> [TrustDeviceEntry]
    ) {
        self.lifecycleCoordinator = lifecycleCoordinator
        self.localization = localization
        self.preferencesIntent = preferencesIntent
        self.panelController = StatusPanelController(localization: localization)
        // the preferences panel (window body) — a single instance, owned here (CP-2 ②); the values are
        // read through from the coordinator's config engine on every show.
        // wave1r3: the Profiles provider plumbing is GONE (the whole profile section is withdrawn —
        // B2 ruling ②); the engine surface stays untouched (CompositionRoot no
        // longer feeds it into the UI).
        // stage G (wave1g): every string is looked up via `localization`.
        // wave1r4: the trust editor gets its REAL row source through the
        // injected provider (the registry is the truth; the construction point = this class, see spec §5·2.7).
        preferencesController = PreferencesWindowController(
            snapshotProvider: { [weak lifecycleCoordinator] in
                lifecycleCoordinator?.configEngine?.effectiveSnapshot() ?? .default
            },
            trustDevicesProvider: trustDevicesProvider,
            localization: localization
        )
        // wave1r2 — the About mini-window (copyright and licence notice; B1 §E-1 option A). Owned
        // here; wave1r3: opened from the preferences window's footer
        // by the bottom-right entry (a small button at bottom-right).
        aboutController = AboutWindowController(localization: localization)
        // wave1r4 — the trust prompt dialog (I2; a single instance, non-modal).
        trustPromptController = TrustPromptWindowController(localization: localization)
        super.init()
        // stage C (wave1c): the window reports intent; the AppShell adapter
        // executes it (engine write + E1 arrangement in the coordinator).
        preferencesController.intentHandler = preferencesIntent
        // wave1r4 — the trust editor's write side (✕ / Reset) goes through the AppShell decision layer: it shares
        // the same writer as the dialog's do-not-trust; it only writes the file and does not touch E1 (M2 does not kick in this session).
        preferencesController.onTrustDeviceRemove = { [weak self] machineCode in
            self?.lifecycleCoordinator?.trustDeviceRemoved(machineCode: machineCode)
        }
        preferencesController.onTrustReset = { [weak self] rows in
            self?.lifecycleCoordinator?.trustResetRequested(rows: rows)
        }
        // wave1r4 — the trust dialog's answer is thrown up (trust = keep / do-not-trust = remove + write the file).
        trustPromptController.onAnswer = { [weak self] deviceID, trusted in
            self?.lifecycleCoordinator?.trustPromptAnswered(deviceID: deviceID, trusted: trusted)
        }
        // wave1r3 — the About entry rides the preferences window's footer
        // bottom-right button; the window hands the request up through this
        // callback (SettingsUI does not know AppShell).
        preferencesController.onOpenAbout = { [weak self] in self?.performOpenAbout() }
        // stage D (wave1d): the panel PIN chain reads the engine truth through
        // this provider and emits intent through the same adapter as the
        // window (engine write + E1 in the coordinator).
        panelController.pinStateProvider = { [weak lifecycleCoordinator] in
            let snapshot = lifecycleCoordinator?.configEngine?.effectiveSnapshot() ?? .default
            return (enabled: snapshot.pinEnabled, code: snapshot.pinCode)
        }
        panelController.onPinProtectionToggled = { [weak self] on in
            self?.preferencesIntent?.pinProtectionToggled(on)
            // The preferences window (when open) shows the same truth.
            self?.preferencesController.refreshValuesIfVisible()
        }
        panelController.onPinChangeRequested = { [weak self] in
            self?.preferencesIntent?.pinChangeRequested()
            self?.preferencesController.refreshValuesIfVisible()
        }
        panelController.onPrimaryAction = { [weak self] in self?.performPrimaryAction() }
        panelController.onOpenPreferences = { [weak self] in self?.performOpenPreferences() }
        panelController.onQuit = { [weak self] in self?.performQuit() }
        setupStatusItem()
    }

    /// Creates the status item: placeholder icon (state colour) + a click
    /// action that toggles the anchored panel. No NSMenu is attached — the
    /// old dropdown has been replaced by the panel (2026-10-16).
    /// stage G: the tooltip + accessibility label ride the dictionary
    /// (menu.tooltip; the display-name hard constraint follows O-1 — "MiragePlay" in every language)
    /// and follow a language flip.
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusIconFactory.image(for: .idle)
            button.target = self
            button.action = #selector(statusItemClicked)
            _ = button.sendAction(on: [.leftMouseUp])
        }
        applyMenuBarStrings()
        localization.observe { [weak self] in
            self?.applyMenuBarStrings()
        }
        UILog.line("STATUSITEM created")
    }

    /// Re-applies the menu-bar tooltip / accessibility label (language flip).
    private func applyMenuBarStrings() {
        let name = localization.t("menu.tooltip")
        statusItem.button?.toolTip = name
        statusItem.button?.setAccessibilityLabel(name)
    }

    @objc private func statusItemClicked() {
        togglePanel()
    }

    /// Icon-click entry point (click the icon → anchor the panel) — also driven by the UI test
    /// harness (UITestDriver), so the scripted run exercises the very path a
    /// real click takes.
    func togglePanel() {
        panelController.toggle(relativeTo: statusItem.button)
    }

    /// start/stop main-button entry point — the ONLY receiver start/stop path
    /// from the UI (2026-10-16 lifecycle ruling: the receiver opens only when the user clicks start
    /// in the panel, and closes on stop). Stop lands the intent via receiverController.stop()
    /// (wantsRunning = false), so the crash guard must not respawn it.
    func performPrimaryAction() {
        guard let coordinator = lifecycleCoordinator else { return }
        switch coordinator.currentState {
        case .idle:
            UILog.line("ACTION start")
            coordinator.start()
        case .waiting, .connected:
            UILog.line("ACTION stop")
            coordinator.stop()
        case .stopping:
            break // transient; button is disabled in this state anyway
        }
    }

    /// The quit row entry point — S5: quit everything, never ask (no confirmation
    /// dialog; the receiver is stopped as part of the quit sequence).
    func performQuit() {
        UILog.line("ACTION quit")
        lifecycleCoordinator?.quit()
    }

    /// The "preferences…" row entry point (increment ②) — opens the single
    /// preferences-window instance. The panel deliberately stays open
    /// (two-window acceptance scenario; hiding it instead would be a
    /// one-line change).
    func performOpenPreferences() {
        UILog.line("ACTION prefs-open")
        preferencesController.show()
    }

    /// The "about" entry point (wave1r3 — the entry is a small button at the preferences window's
    /// footer bottom-right; B2 ruling ③ + the fix "about belongs bottom-right, not bottom-left"; the copyright lives in the About mini-window).
    /// A single instance, closable, with no window left behind. Driven by the window's `onOpenAbout` callback
    /// and by the test seam.
    func performOpenAbout() {
        UILog.line("ACTION about-open")
        aboutController.show()
    }

    /// Test-seam: the red-light close path for the About window.
    func closeAbout() {
        aboutController.close()
    }

    // MARK: - Trust prompt dialog (wave1r4)

    /// Presents the trust ask for one freshly-registered device — called by
    /// the coordinator when the CoreBridge `registered new client` event
    /// lands (PIN-on only; a code-free reconnect does not trigger it = zero dialogs once trusted).
    func presentTrustPrompt(deviceName: String, deviceID: String) {
        trustPromptController.present(deviceName: deviceName, deviceID: deviceID)
    }

    /// Test-seam (wave1r6): whether the trust ask is currently on screen
    /// (the poll-based answer helper waits on this — a fixed-time press can
    /// race a not-yet-visible prompt; observed in the first wave1r6 run).
    var trustPromptVisibleForTesting: Bool { trustPromptController.isVisible }

    /// Test-seam (wave1r10d): the device the visible prompt is asking about
    /// (nil = no prompt in flight). The harness answers only the prompt whose
    /// device matches its target (the discriminator when several devices interleave under serialization).
    var trustPromptDeviceIDForTesting: String? { trustPromptController.currentDeviceID }

    /// Test-seam (wave1r10d): whether the app-side lock (route ①; a local event
    /// monitor + ignoresMouseEvents on every other window) is holding the UI on the prompt.
    var trustPromptLockActiveForTesting: Bool { trustPromptController.isLockActive }

    /// Test-seam (wave1r4): answers through the exact button action path
    /// (trust = keep / do-not-trust = remove; see UITestDriver).
    func answerTrustPromptForTesting(trusted: Bool) {
        if trusted {
            trustPromptController.pressTrustForTesting()
        } else {
            trustPromptController.pressDistrustForTesting()
        }
    }

    /// Test-seam (wave1r10e): the DIAGNOSTIC silent-fallback answer (anti-fake-green).
    /// The harness reaches this ONLY when a posted click/ESC failed to land; it
    /// lands the same answer funnel but tags the audit line `via=fallback`, so the
    /// script can tell a real event landing (`via=button`) from a fallback — a
    /// fallback can no longer masquerade as a "posted click that landed".
    func answerTrustFallbackForTesting(trusted: Bool) {
        trustPromptController.answerTrustFallbackForTesting(trusted: trusted)
    }

    /// Test-seam (wave1r4): red-light close WITHOUT answering (M1: no answer
    /// = do-not-trust = removal).
    func dismissTrustPromptForTesting() {
        trustPromptController.closeWithoutAnswerForTesting()
    }

    /// Renders the trust prompt to a PNG — test-harness only (the wave1r4 EN / zh-Hant
    /// acceptance renders).
    func renderTrustPromptSnapshot(to path: String) {
        trustPromptController.renderSnapshot(to: path)
    }

    /// wave1r4 — the prompt's rendered-string audit (LANGAUDIT trust …;
    /// the counterpart row of the acceptance renders).
    func trustPromptAudit() {
        trustPromptController.languageAudit()
    }

    /// wave1r10 — the prompt's window-state audit (level / no close button /
    /// collection behaviour / deactivate policy / modal state; see the controller).
    func trustPromptStateAudit() {
        trustPromptController.stateAudit()
    }

    /// wave1r10 — posts the REAL synthetic click on the prompt's trust
    /// button (the user-click recipe; the modal-blocking proof = this click reaches it while clicks
    /// on other app windows are dropped).
    func postTrustClickForTesting() {
        trustPromptController.postTrustClickForTesting()
    }

    /// wave1r10 — posts a REAL Escape keyDown to the prompt window
    /// (ESC = do-not-trust; the user-key recipe).
    func postTrustEscapeForTesting() {
        trustPromptController.postEscapeForTesting()
    }

    /// wave1r10 — raises the app so posted events route normally (macOS 14
    /// cooperative activation: `activate(from:)` citing the frontmost app — the
    /// non-deprecated `activate(ignoringOtherApps:)` equivalent;
    /// probe-verified=true activation). Returns whether the request reported
    /// success case (`NSApp.isActive` must be true for an instant; callers poll on this).
    @discardableResult
    func activateForEventsForTesting() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            NSApp.activate()
            return NSApp.isActive
        }
        return NSRunningApplication.current.activate(from: frontmost, options: [.activateAllWindows])
    }

    /// wave1r10 — posts the REAL synthetic click on the preferences window's
    /// Apply button (the target of the modal-blocking probe: the same click fired
    /// before/after the modal is dropped while the modal is up). `leg` names the probe leg in the
    /// evidence line.
    func postPreferencesApplyClickForTesting(leg: String) {
        preferencesController.postApplyClickForTesting(leg: leg)
    }

    /// Test-seam: the red-light close path for the preferences window
    /// (see UITestDriver).
    func closePreferences() {
        preferencesController.close()
    }

    /// Test-seam: the panel's PIN-protection toggle — the same path the
    /// user's panel switch takes (stage D wiring: an engine write + E1; see UITestDriver).
    func setPanelPinProtection(_ on: Bool) {
        panelController.setPinProtection(on)
    }

    /// Test-seam: the panel's regenerate button press — the exact action path the
    /// button takes (including the PIN-off guard; see UITestDriver).
    func pressPanelPinChange() {
        panelController.pressPinChangeButton()
    }

    /// stage D read-through refresh — re-reads the engine's PIN truth into the
    /// PIN surfaces (the panel code row / the regenerate button; the preferences window while
    /// open). Called by LifecycleCoordinator.receiverStartPrepared() right
    /// after every spawn preparation, because the P3 unset code regenerates
    /// at each start — the shown code must be the code being spawned with.
    func refreshPinDisplays() {
        panelController.refreshPinDisplay()
        preferencesController.refreshValuesIfVisible()
    }

    /// R4-Q2=A — routes a settled launch failure's short cause to the panel
    /// status row (called by LifecycleCoordinator; existing row, no new
    /// visual element). stage G: the reason is language-neutral; the panel
    /// composes the localized "Start failed: " prefix (§B a2).
    func showStatusFailure(reason: String) {
        panelController.showFailure(reason: reason)
    }

    /// R5 fallback delivery terminal (contract L396 "reserve two structural forms: fire a notification
    /// or only update the status-row subscriber") — the SessionNotifier subscriber under the
    /// still-undecided notification form (R5-Q1; no banner is built). This class owns
    /// the panel status row, so the fallback subscriber path terminates here.
    ///
    /// no visible difference in the fallback state (recorded as such): the row is maintained by the
    /// coordinator state chain (the state channel), never by this subscriber, so the
    /// panel renders independently of the notification path. What this
    /// method adds is the `NOTIFY …` trace that makes the delivery
    /// observable (D8: it is written for EVERY event — the retained B2 slot
    /// does not gate it; scripts/test-sleep-notify.sh asserts exactly that),
    /// and it is the exact slot where the R5 form (banner / panel event row)
    /// lands as a visual upgrade.
    func presentSessionNotification(_ notification: SessionNotifier.Notification) {
        let kind = notification.kind == .connected ? "connected" : "disconnected"
        UILog.line("NOTIFY \(kind) message=\(notification.message)")
    }

    // MARK: - Preferences-window test seams (stage C / wave1c)
    //
    // Each of these drives the exact commit path the corresponding control's
    // action takes (target/action → intent handler → engine + E1), so the
    // scripted wiring test exercises the real write-back chain without
    // synthetic NSEvents (Accessibility permission is unavailable in the
    // test environment) — same philosophy as performPrimaryAction().

    /// Device-name field commit (Enter / end-editing path).
    func commitPreferencesDeviceName(_ name: String) {
        preferencesController.commitDeviceNameForTesting(name)
    }

    /// Resolution slider settle commit (step index into the S-4 detents —
    /// wave1r3: the slider's driving path; it settles only on release).
    func selectPreferencesResolutionStep(_ step: Int) {
        preferencesController.selectResolutionForTesting(step: step)
    }

    /// Frame-rate slider settle commit (step index into the S-4 detents).
    func selectPreferencesFrameRateStep(_ step: Int) {
        preferencesController.selectFrameRateForTesting(step: step)
    }

    /// Mute switch toggle.
    func togglePreferencesMute(_ on: Bool) {
        preferencesController.toggleMuteForTesting(on)
    }

    /// prevent-sleep switch toggle (stage E — the same action path the switch takes;
    /// E1 exception: instant, receiver untouched).
    func togglePreferencesPreventSleep(_ on: Bool) {
        preferencesController.togglePreventSleepForTesting(on)
    }

    /// Retained B2 slot seam (stage E / D8 — no page control any more): stages
    /// the field so the harness can prove the NOTIFY record ignores it.
    func togglePreferencesNotifications(_ on: Bool) {
        preferencesController.toggleNotificationsForTesting(on)
    }

    /// Test-seam (stage G — language): the language dropdown selection path —
    /// the exact path a user pick takes. wave1r1: the selection is STAGED (it only
    /// flips on apply; see UITestDriver).
    func selectPreferencesLanguage(_ code: String) {
        preferencesController.selectLanguageForTesting(code: code)
    }

    /// Test-seam (wave1r3): the preferences window's footer About entry
    /// press — the exact action path the bottom-right button takes
    /// (the small button at bottom-right → onOpenAbout → performOpenAbout).
    func pressPreferencesAboutForTesting() {
        preferencesController.pressAboutForTesting()
    }

    /// Test-seam (wave1r1 — staged apply): the exact action path the
    /// window-bottom Apply button takes (everything takes effect at once; see UITestDriver).
    func applyPreferencesChanges() {
        preferencesController.applyForTesting()
    }

    /// Test-seam (wave1r1 R2): opens the trust editor through the exact
    /// "Edit Trust Devices…" button path (the sheet itself does not drive it).
    func presentTrustEditorForTesting() {
        preferencesController.presentTrustEditorForTesting()
    }

    /// Test-seam (wave1r1 R2): presses one-click Reset — an empty list → a no-op trace.
    func pressTrustResetForTesting() {
        preferencesController.pressTrustResetForTesting()
    }

    /// Test-seam (wave1r4): presses a row's ✕ (keyed by machine code) — the exact
    /// button action path (removal; it shares the same writer as the dialog's do-not-trust).
    func removeTrustRowForTesting(machineCode: String) {
        preferencesController.removeTrustRowForTesting(machineCode: machineCode)
    }

    /// Test-seam (wave1r6): logs the LIVE (on-screen) ✕ codes of the presented
    /// editor — the VIEW-layer counterpart of the model rows (wave1r4's blind spot = the
    /// assertions only probed the model layer; this seam walks the view tree of the presented sheet).
    func auditTrustEditorLiveRowsForTesting() {
        preferencesController.auditTrustEditorLiveRowsForTesting()
    }

    /// Test-seam (wave1r6): presses a row's ✕ BY ITS LIVE VIEW TREE — models
    /// the on-screen click. A removed row's button no longer exists → miss
    /// trace, and no second `remove requested` (YC's repeated-click regression).
    func pressLiveTrustRowForTesting(machineCode: String) {
        preferencesController.pressLiveTrustRowForTesting(machineCode: machineCode)
    }

    /// Test-seam (wave1r6): renders the editor sheet (on-screen renders before/after ✕;
    /// the wave1r6 §renders delivery).
    func renderTrustEditorSnapshotForTesting(to path: String) {
        preferencesController.renderTrustEditorSnapshotForTesting(to: path)
    }

    /// Test-seam (wave1r1 R2): ends the trust editor sheet.
    func dismissTrustEditorForTesting() {
        preferencesController.dismissTrustEditorForTesting()
    }

    /// stage G language audit — the RENDERED strings of the panel, read back
    /// from the actual controls (not re-derived from the dictionary — a
    /// control that failed to re-render would show up here). wave1r3: the
    /// The "about" row was retired (B2 ruling ③) — the about= field went with it.
    /// Written to ui.log; asserted by scripts/test-language.sh.
    func languageAuditPanel() {
        UILog.line(
            "LANGAUDIT panel lang=\(localization.language)"
                + " status=\(panelController.currentStatusText)"
                + " button=\(panelController.currentPrimaryTitle)"
                + " pin=\(panelController.currentPinLabel)"
                + " change=\(panelController.currentChangeTitle)"
                + " entry=\(panelController.currentEntryTitle)"
                + " quit=\(panelController.currentQuitTitle)"
                + " tooltip=\(localization.t("menu.tooltip"))"
        )
    }

    /// stage G language audit — the RENDERED strings of the preferences window
    /// (title / group caps / language row + picker selection).
    func languageAuditPrefs() {
        preferencesController.languageAudit()
    }

    /// stage G language audit — the RENDERED strings of the About mini-window
    /// (wave1r2: title / app name / copyright / license).
    func languageAuditAbout() {
        aboutController.languageAudit()
    }

    /// stage G evidence: the dictionary load line (path + term count / load
    /// error) — asserted by scripts/test-language.sh phase A/C.
    func logDictionaryState() {
        if let dictionary = localization.dictionary {
            UILog.line(
                "LANG dictionary loaded path=\(localization.dictionaryPath) terms=\(dictionary.termCount) languages=\(dictionary.languages.joined(separator: ","))"
            )
        } else {
            UILog.line(
                "LANG dictionary load failed path=\(localization.dictionaryPath) error=\(localization.loadErrorDescription ?? "unknown")"
            )
        }
    }

    /// Test-harness windows audit — the visible control-surface windows.
    /// Written to ui.log after each scripted step and asserted by
    /// scripts/test-ui-prefs.sh (while open = the panel + preferences window; nothing is left after closing).
    func windowsAudit() -> String {
        "WINDOWS panel=\(panelController.isVisible ? 1 : 0) prefs=\(preferencesController.isVisible ? 1 : 0) about=\(aboutController.isVisible ? 1 : 0)"
    }

    /// Renders the given receiver state on the icon (colour) and inside the
    /// panel (status row + main button). Called by LifecycleCoordinator on
    /// every state transition.
    func updateState(_ state: ReceiverState) {
        statusItem.button?.image = StatusIconFactory.image(for: state)
        panelController.update(with: state)
        UILog.line("STATE \(UILog.describe(state))")
    }

    /// Panel render to PNG — test-harness only (see UITestDriver).
    func renderPanelSnapshot(to path: String) {
        panelController.renderSnapshot(to: path)
    }

    /// Preferences-window render to PNG — test-harness only (see UITestDriver).
    func renderPreferencesSnapshot(to path: String) {
        preferencesController.renderSnapshot(to: path)
    }

    /// Preferences-window FOOTER close-up render to PNG — test-harness only
    /// (wave1r3: B2 §F evidence — About at bottom-right + the full-text R1 reminder).
    func renderPreferencesFooterSnapshot(to path: String) {
        preferencesController.renderFooterSnapshot(to: path)
    }

    /// About-window render to PNG — test-harness only (wave1r2; see
    /// UITestDriver).
    func renderAboutSnapshot(to path: String) {
        aboutController.renderSnapshot(to: path)
    }
}
