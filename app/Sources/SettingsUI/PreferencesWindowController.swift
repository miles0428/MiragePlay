import AppKit
import Localization
import ReceiverKit
import SharedTypes

/// The preferences panel (the window body) — wave1r3 (the B2 slider batch) SINGLE-PAGE refit.
///
/// Per B2 (`.task_state/ui_mockup_B2_slider.html`) + YC's 2026-10-18 morning batch
/// rulings (PROGRESS_20261016.md L318/319/325):
///
///   • Slider (ruling ① corrects the control "for the UI I want a slider, not a text box with up/down arrows"):
///     resolution / framerate = [slider 128] + [read-only value 48] (variant ①); zero
///     steppers / zero value text boxes; discrete detent snapping, dragging does not count, only releasing commits (per E5);
///   • Profiles withdrawn (ruling ②): the profile group (dropdown + "Save as…") is GONE;
///     the group hats 4→3 (Video & Audio / Connection & Session / Language); the engine side
///     (ConfigEngine / ProfileStore) is retained and stays hidden;
///   • About moves into the window (ruling ③ + the fix "about belongs bottom-right, not bottom-left"): the About
///     entry is a quiet small button at the footer's BOTTOM-RIGHT (bottom-right, flush to the bottom;
///     the B2 draft's bottom-left is wrong); the panel's bottom "about" row is withdrawn (the panel = PIN code → start → settings → leave);
///     the About mini-window itself is unchanged;
///   • The content is centred as a whole (ruling ①): the 336-pt content column is centred in the
///     450-pt window (margins 57/57; `PREFS layout` evidence line);
///   • The changed-state reminder + the two apply states (ruling ⑤/R1): the window-bottom band carries the
///     Apply button (centred, never moves between states) and, to its LEFT,
///     the R1 reminder "Unsaved changes" with an orange dot.
///     R1 full text takes priority (YC's consequential correction): the FULL text is restored because the
///     About entry moved right — the `PREFS footer` evidence line measures
///     slot vs the reminder width (it only shrinks if it will not fit; currently it fits in every language). R1 does not add height: the
///     reminder lives inside the same fixed footer band, so the window height
///     never changes between the two states;
///   • window 450 wide — FIXED in every language; traffic light: CLOSE ONLY
///     (S-6); single instance, owned and reused by StatusItemMenu.
///
/// The wave1r1 staged-apply model (KEPT — ruling ⑥):
///   • EVERY controllable field (device name / resolution / framerate / mute / prevent-sleep /
///     connection notification / language) mutates LOCAL staged state only — no engine write, no
///     E1, no receiver touch happens on edit;
///   • the window-bottom Apply bar commits ALL staged fields in one batch
///     (`preferencesApplyRequested`); DISABLED while nothing changed and the
///     dirty state clears by re-syncing from the engine truth afterwards;
///   • close without applying DISCARDS the staged values (PM micro-decision 1).
///
/// All user-visible strings are term-dictionary lookups through the injected
/// `LanguageService` (contract L146) — zero hard-coded UI strings. A language
/// flip rebuilds the page in place (the UI switches language on apply).
public final class PreferencesWindowController: NSObject, NSTextFieldDelegate, NSWindowDelegate {

    enum Metrics {
        /// B1: window width 450 (fixed for all three languages).
        static let width: CGFloat = 450
        /// B1: body top padding 14 (.wbody padding-top).
        static let contentTopGap: CGFloat = 14
        /// B1: the footer separator margins (the apply row's separator spans the full window width).
        static let footerSeparatorTopGap: CGFloat = 10
        static let footerButtonTopGap: CGFloat = 10
        static let footerBottomPadding: CGFloat = 14
        /// B1 §C: the R1 reminder sits LEFT of the Apply button (gap ~10pt).
        static let reminderGap: CGFloat = 10
        static let reminderMinLeading: CGFloat = 18
        static let reminderDotSize: CGFloat = 6
        /// B2 §F + YC's correction: the About entry — a small secondary button at the footer's
        /// right edge (bottom-right, flush to the bottom; symmetric to the mock-up's left 19).
        static let aboutEntryTrailingGap: CGFloat = 18
    }

    /// Whether the window is currently on screen (used by the test's window-count assertion).
    public var isVisible: Bool { window.isVisible }

    /// Intent sink — set by AppShell (StatusItemMenu); the wired controls
    /// forward their commits here. Weak: the AppShell adapter owns the
    /// lifetime.
    public weak var intentHandler: (any PreferencesIntentHandling)?

    /// wave1r3 — the About entry callback (the footer's bottom-right button). Wired by
    /// StatusItemMenu to the About mini-window opener; the window itself never
    /// owns that window (SRP; SettingsUI does not know AppShell).
    public var onOpenAbout: (() -> Void)?

    private let window: NSWindow
    private let snapshotProvider: () -> EffectiveSnapshot

    /// wave1r1 R2 — trust-device rows for the "Edit Trust Devices…" editor
    /// (wave1r4: the real provider lands here — wired by the AppShell to the
    /// `registration.list` read side (TrustRegistryStore.entries()); the
    /// default stays an empty list for an unwired construction).
    private let trustDevicesProvider: () -> [TrustDeviceEntry]

    /// wave1r4 — the trust WRITE side (✕ / Reset share the same writer with the dialog's do-not-trust
    /// — the I6 write-side seam). SettingsUI only emits intent — the AppShell adapter
    /// performs the file write and owns the M2 timing semantics (it does not kick in this session).
    /// `onTrustDeviceRemove` carries the machine code; `onTrustReset` carries the
    /// row count the editor showed (evidence).
    public var onTrustDeviceRemove: ((String) -> Void)?
    public var onTrustReset: ((Int) -> Void)?

    /// stage G — the term lookup behind every string in this window.
    private let localization: LanguageService

    // MARK: - wave1r1 staged state

    /// The values the CONTROLS show (window-local; engine writes only at
    /// Apply). It is rebuilt from the truth on every fresh show and after every
    /// apply; an unapplied edit is discarded at close (PM micro-decision 1).
    private var staged: StagedSettings

    /// The engine truth the staged values are compared against (dirty =
    /// `staged != base`; Apply is disabled while clean — PM micro-decision 3).
    private var base: StagedSettings

    /// Evidence dedupe for the `PREFS apply enabled=` line (state changes only).
    private var lastApplyEnabledLogged: Bool?

    private let effectView = NSVisualEffectView()
    private let pageContainer = NSView()
    private let footerSeparator = NSView()
    /// The bottom Apply control (the apply row).
    private var applyButton: NSButton!
    /// wave1r3 — the footer's BOTTOM-RIGHT About entry (a small secondary button; B2 §F).
    private var aboutButton: NSButton!
    /// B1 §C/§D R1 — the reminder text to the left of the Apply button (two states: in the clean state
    /// it is hidden, in the changed state it is visible; the button itself never moves).
    private let reminderStack = NSStackView()
    private let reminderDot = NSView()
    private let reminderLabel = NSTextField(labelWithString: "")

    /// The single settings page (B1; Profiles withdrawn — wave1r3).
    private var form: PreferencesFormViews.SinglePage?
    private var hasBeenShown = false

    /// wave1r1 R2 — the providers feeding the trust editor; stage G adds the
    /// dictionary service.
    public init(
        snapshotProvider: @escaping () -> EffectiveSnapshot,
        trustDevicesProvider: @escaping () -> [TrustDeviceEntry] = { [] },
        localization: LanguageService
    ) {
        self.snapshotProvider = snapshotProvider
        self.trustDevicesProvider = trustDevicesProvider
        self.localization = localization
        let initial = StagedSettings(from: snapshotProvider())
        self.staged = initial
        self.base = initial
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 560),
            // S-6: only the close button is available — closable only; no miniaturize/zoom.
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
        buildContent()
        // stage G: instant effect across the whole UI — a language flip re-renders this window in
        // place (the observer lives for the app's lifetime; it fires at Apply when
        // the staged language value is committed).
        localization.observe { [weak self] in
            self?.applyLanguage()
        }
    }

    // MARK: - Visibility

    /// Shows the window (a singleton: the same instance is reused; brought to the front when already shown).
    ///
    /// A FRESH show (window was hidden) re-syncs every control from the engine
    /// truth — unapplied staged edits are discarded (PM micro-decision 1). A re-show
    /// while already visible only re-fronts the window and NEVER clobbers
    /// staged edits.
    public func show() {
        let wasVisible = window.isVisible
        if !wasVisible {
            syncFromTruth()
        }
        if hasBeenShown {
            UILog.line("PREFS shown (reused)")
        } else {
            hasBeenShown = true
            UILog.line("PREFS shown (created)")
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Settled-frame evidence (the cleanfails-diag fix direction ②): run a layout
        // pass BEFORE reading the frame so the logged value is the steady
        // one (AppKit content-fitting rewrites the window frame on layout;
        // a pre-layout read records a transient value).
        window.contentView?.layoutSubtreeIfNeeded()
        UILog.line("PREFS frame \(frameDescription)")
        logGeometry()
    }

    /// Red-light close (equivalent to the window's close button; the instance is kept and can be reopened).
    public func close() {
        guard window.isVisible else { return }
        window.close()
    }

    /// NSWindowDelegate — the single close funnel (real red light AND the
    /// seam path): unapplied staged edits are discarded here (PM micro-decision 1).
    public func windowWillClose(_ notification: Notification) {
        if staged != base {
            UILog.line("PREFS staged discarded (unapplied)")
            staged = base
        }
        UILog.line("PREFS closed")
    }

    // MARK: - Language (stage G)

    /// Re-renders every string in the selected language (rebuilt in place so
    /// the rendered values stay the engine truth). Fired by the
    /// LanguageService observer when the staged language value is committed
    /// at Apply (the UI switches language on apply) — the receiver is never touched.
    /// The staged/base state is re-synced by the apply handler that triggered
    /// this rebuild (see `applyClicked`).
    func applyLanguage() {
        window.title = localization.t("prefs.window.title")
        reminderLabel.stringValue = localization.t("prefs.apply.reminder")
        // wave1r2-fix1 (the R1 review required it): the footer Apply button is
        // CHROME owned by this controller — NOT rebuilt by rebuildForm — so
        // its title must be refreshed here on every flip (the original gap: it was only
        // assigned at construction, so the zh-Hant window's bottom button still said "Apply"). wave1r3: the footer About entry is
        // chrome too — same refresh duty.
        applyButton?.title = localization.t("prefs.button.apply")
        aboutButton?.title = localization.t("prefs.button.about")
        rebuildForm()
        updateApplyState()
    }

    /// stage G language audit — the RENDERED strings of this window, read back
    /// from the actual controls (evidence that it "takes effect across the whole UI instantly") — the window
    /// title, the THREE group caps, the language row, the picked item AND the
    /// footer Apply / About button titles (chrome; wave1r2-fix1: that button's string joins
    /// the audit; wave1r3: the About button joins the audit too, and missing a translation turns this assertion red).
    /// Written to ui.log by StatusItemMenu.languageAuditPrefs().
    public func languageAudit() {
        let caps = form?.groupCaps.map { $0.stringValue } ?? []
        func cap(_ index: Int) -> String {
            caps.count > index ? caps[index] : "-"
        }
        UILog.line(
            "LANGAUDIT prefs lang=\(localization.language)"
                + " title=\(window.title)"
                + " cap0=\(cap(0))"
                + " cap1=\(cap(1))"
                + " cap2=\(cap(2))"
                + " langrow=\(form?.languageRowLabel.stringValue ?? "-")"
                + " language=\(form?.languagePopup.titleOfSelectedItem ?? "-")"
                + " apply=\(applyButton.title)"
                + " about=\(aboutButton.title)"
                + " frame=\(frameDescription)"
        )
    }

    /// Test seam (stage G — see UITestDriver): the exact path the language
    /// picker's action takes. wave1r1: the selection is STAGED (it does not flip instantly).
    public func selectLanguageForTesting(code: String) {
        guard let popup = form?.languagePopup else { return }
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == code }) {
            popup.select(item)
        }
        languageSelected(popup)
    }

    // MARK: - Test-harness support

    /// Renders the window to a PNG (the app renders it itself — Screen Recording permission
    /// is unavailable in the test environment). Prefers the full window frame
    /// (theme frame, includes the title bar) and falls back to the content
    /// view. Failures are logged, never thrown.
    public func renderSnapshot(to path: String) {
        window.displayIfNeeded()
        let target: NSView = window.contentView?.superview ?? window.contentView ?? effectView
        target.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            UILog.line("PREFS snapshot failed (no bitmap rep)")
            return
        }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            UILog.line("PREFS snapshot failed (no png data)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            UILog.line("PREFS snapshot \(path)")
        } catch {
            UILog.line("PREFS snapshot failed (\(error.localizedDescription))")
        }
    }

    /// Renders ONLY the footer band (footer separator → window bottom) as a
    /// close-up PNG — the B2 §F evidence frame: About at the bottom-right
    /// (bottom-right) + the FULL-TEXT R1 reminder (the orange dot as before). The same self-render
    /// convention as `renderSnapshot` (no Screen Recording permission).
    ///
    /// Coordinate note: the content view is NOT flipped (y=0 at the window's
    /// BOTTOM)— the band is [0 … separator.maxY], so the crop is the strip
    /// BELOW the separator (the separator + the apply row; height ≈ 50 pt).
    public func renderFooterSnapshot(to path: String) {
        window.displayIfNeeded()
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let separatorFrame = footerSeparator.convert(footerSeparator.bounds, to: content)
        let band = NSRect(
            x: 0,
            y: 0,
            width: content.bounds.width,
            height: min(separatorFrame.maxY + 2, content.bounds.height)
        )
        guard band.height > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: band) else {
            UILog.line("PREFS footer snapshot failed (no bitmap rep)")
            return
        }
        content.cacheDisplay(in: band, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            UILog.line("PREFS footer snapshot failed (no png data)")
            return
        }
        logFooterGeometry(tag: "render")
        do {
            try data.write(to: URL(fileURLWithPath: path))
            UILog.line("PREFS footer snapshot \(path) band=\(Int(band.height.rounded()))")
        } catch {
            UILog.line("PREFS footer snapshot failed (\(error.localizedDescription))")
        }
    }

    // MARK: - Window configuration & layout

    private func configureWindow() {
        window.title = localization.t("prefs.window.title")
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.tabbingMode = .disallowed
        window.delegate = self
    }

    /// Builds the structural chrome once: effect view, the centred single
    /// page container, the window-bottom Apply bar (the apply row with the R1
    /// reminder) and the footer BOTTOM-RIGHT About entry. The page itself is
    /// built by `rebuildForm()` (re-runnable — a language flip calls it again
    /// with the new strings).
    private func buildContent() {
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        window.contentView = effectView

        pageContainer.translatesAutoresizingMaskIntoConstraints = false

        // wave1r1: the window-bottom Apply bar — the single batch commit of
        // the staged-apply model. The separator is FULL window width (B1 §A②:
        // the bottom apply-row separator spans the full window width); the button is centred and never moves.
        footerSeparator.wantsLayer = true
        footerSeparator.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false

        applyButton = PreferencesFormViews.applyButton(localization.t("prefs.button.apply"))
        applyButton.target = self
        applyButton.action = #selector(applyClicked(_:))
        applyButton.isEnabled = false

        // wave1r3 — the About entry (B2 §F + YC's correction "about belongs bottom-right,
        // not bottom-left"): a quiet small button at the footer's RIGHT edge, on the
        // Apply row (bottom-right, flush to the bottom). Clicking opens the About mini-window
        // through `onOpenAbout` (wired by StatusItemMenu).
        aboutButton = PreferencesFormViews.smallButton(localization.t("prefs.button.about"))
        aboutButton.target = self
        aboutButton.action = #selector(aboutClicked(_:))

        // B1 §C/§D R1 — "Unsaved changes" + the orange dot, aligned to the left of the button; in the clean state it is
        // hidden (no reminder), in the changed state it is visible (the reminder shows). The same fixed band → the
        // window height never changes between the two states (R1 does not add height).
        // wave1r3: the FULL text is restored (YC's consequential correction — moving About to the right made the
        // reminder slot wider; if it fits, the full text comes back; see the `PREFS footer` evidence line for the measurement).
        reminderDot.wantsLayer = true
        reminderDot.layer?.cornerRadius = Metrics.reminderDotSize / 2
        reminderDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        reminderDot.translatesAutoresizingMaskIntoConstraints = false
        reminderLabel.font = .systemFont(ofSize: 11)
        reminderLabel.textColor = .secondaryLabelColor
        reminderLabel.stringValue = localization.t("prefs.apply.reminder")
        reminderStack.orientation = .horizontal
        reminderStack.alignment = .centerY
        reminderStack.spacing = 6
        reminderStack.translatesAutoresizingMaskIntoConstraints = false
        reminderStack.setViews([reminderDot, reminderLabel], in: .leading)
        reminderStack.isHidden = true

        effectView.addSubview(pageContainer)
        effectView.addSubview(footerSeparator)
        effectView.addSubview(applyButton)
        effectView.addSubview(reminderStack)
        effectView.addSubview(aboutButton)

        NSLayoutConstraint.activate([
            pageContainer.topAnchor.constraint(equalTo: effectView.topAnchor, constant: Metrics.contentTopGap),
            pageContainer.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),

            footerSeparator.topAnchor.constraint(
                equalTo: pageContainer.bottomAnchor, constant: Metrics.footerSeparatorTopGap),
            footerSeparator.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),

            applyButton.topAnchor.constraint(
                equalTo: footerSeparator.bottomAnchor, constant: Metrics.footerButtonTopGap),
            applyButton.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            applyButton.bottomAnchor.constraint(
                equalTo: effectView.bottomAnchor, constant: -Metrics.footerBottomPadding),

            // bottom-right, flush to the bottom: the same footer band as Apply, with the right edge 18 from
            // the window's right edge (symmetric to the mock-up's left 19).
            aboutButton.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            aboutButton.trailingAnchor.constraint(
                equalTo: effectView.trailingAnchor, constant: -Metrics.aboutEntryTrailingGap),

            reminderDot.widthAnchor.constraint(equalToConstant: Metrics.reminderDotSize),
            reminderDot.heightAnchor.constraint(equalToConstant: Metrics.reminderDotSize),

            reminderStack.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            reminderStack.trailingAnchor.constraint(
                equalTo: applyButton.leadingAnchor, constant: -Metrics.reminderGap),
            reminderStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: effectView.leadingAnchor, constant: Metrics.reminderMinLeading),
        ])

        rebuildForm()
    }

    /// (Re)builds the single page with the current strings and wires every
    /// control. Re-runnable by design (language flip): the old page is torn
    /// down and rebuilt from the engine truth; the staged state lives HERE
    /// and is re-rendered via `renderControls()`.
    private func rebuildForm() {
        form?.view.removeFromSuperview()

        let snapshot = snapshotProvider()
        let page = PreferencesFormViews.buildSinglePage(
            snapshot: snapshot, localization: localization)
        self.form = page

        wireControls(page)

        page.view.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(page.view)
        NSLayoutConstraint.activate([
            page.view.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            page.view.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            page.view.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])

        renderControls()
        fitWindowToContent()
    }

    /// Sizes the window to the single page's content (B1: the height follows the content dynamically;
    /// the measured value ≠ AppKit — the browser mock-up measured 595 px, while AppKit
    /// layout follows the actual form metrics). Width stays 450.
    private func fitWindowToContent() {
        effectView.layoutSubtreeIfNeeded()
        let height = effectView.fittingSize.height
        guard height > 0 else { return }
        window.setContentSize(NSSize(width: Metrics.width, height: height.rounded()))
    }

    /// Wires the page controls to the window's STAGED state (wave1r1:
    /// nothing here writes the engine — every commit mutates `staged` and the
    /// Apply button becomes the single commit point). The two sliders report
    /// their SETTLED detent only (release only; wave1r3 carries E5). The device-name
    /// field keeps its commit-once semantics (E5: on Enter / end-editing).
    private func wireControls(_ page: PreferencesFormViews.SinglePage) {
        page.resolution.onValueChanged = { [weak self] step in
            guard let self = self else { return }
            let steps = PreferencesFormViews.resolutionSteps
            guard steps.indices.contains(step) else { return }
            self.stage { $0.resolution = steps[step] }
        }
        page.frameRate.onValueChanged = { [weak self] step in
            guard let self = self else { return }
            let steps = PreferencesFormViews.frameRateSteps
            guard steps.indices.contains(step), let value = Int(steps[step]) else { return }
            self.stage { $0.frameRate = value }
        }
        page.mute.target = self
        page.mute.action = #selector(muteToggled(_:))
        page.preventSleep.target = self
        page.preventSleep.action = #selector(preventSleepToggled(_:))
        page.deviceNameField.delegate = self
        // wave1r1 R2: the trusted-devices section — "Edit Trust Devices…" opens the editor
        // popup (the list is not embedded; wave1r4: the rows = the registry truth, and ✕ / Reset go through the write-side
        // seam).
        page.editTrustButton.target = self
        page.editTrustButton.action = #selector(editTrustDevicesClicked(_:))
        // stage G: the language picker stages its selection — the UI flips at
        // Apply.
        page.languagePopup.target = self
        page.languagePopup.action = #selector(languageSelected(_:))
    }

    // MARK: - Truth sync & staged rendering

    /// stage D read-through for the READ-ONLY PIN field only. Called from the
    /// panel PIN surfaces and every spawn preparation. wave1r1: this must
    /// NEVER touch the staged fields (staged edits survive side-channel truth
    /// updates).
    public func refreshValuesIfVisible() {
        guard window.isVisible else { return }
        form?.pinField.stringValue = snapshotProvider().pinCode ?? ""
    }

    /// Fresh-show / post-apply sync: re-read the engine truth into
    /// base + staged, re-render every control and emit the evidence lines
    /// (PREFS values / PREFS staged / PREFS apply enabled).
    private func syncFromTruth() {
        let snapshot = snapshotProvider()
        base = StagedSettings(from: snapshot)
        staged = base
        renderControls()
        form?.deviceNameField.stringValue = staged.deviceName
        form?.pinField.stringValue = snapshot.pinCode ?? ""
        logTruthLines(snapshot: snapshot)
        logStaged()
        updateApplyState()
    }

    /// Pushes the staged values into the controls (staged → views; never the
    /// other way). Programmatic control updates never fire actions, so this
    /// cannot masquerade as a user edit.
    private func renderControls() {
        form?.resolution.apply(
            PreferencesFormViews.resolutionSteps.firstIndex(of: staged.resolution) ?? 2)
        form?.frameRate.apply(
            PreferencesFormViews.frameRateSteps.firstIndex(of: String(staged.frameRate)) ?? 1)
        form?.mute.state = staged.muted ? .on : .off
        form?.deviceNameField.stringValue = staged.deviceName
        form?.preventSleep.state = staged.preventSleep ? .on : .off
        if let popup = form?.languagePopup,
           let item = popup.itemArray.first(where: { ($0.representedObject as? String) == staged.language }) {
            popup.select(item)
        }
    }

    /// `PREFS values …` — the ENGINE truth rendered from the snapshot
    /// (read-through evidence; the format unchanged since stages C/D/E; the
    /// `profile=` field is engine truth — the Profiles UI is gone, the
    /// engine value rides along).
    private func logTruthLines(snapshot: EffectiveSnapshot) {
        UILog.line(
            "PREFS values res=\(snapshot.resolution) fps=\(snapshot.frameRate) mute=\(snapshot.muted ? "on" : "off") name=\(snapshot.deviceName) pin=\(snapshot.pinCode ?? "-") sleep=\(snapshot.preventSleep ? "on" : "off") notify=\(snapshot.notificationsEnabled ? "on" : "off") profile=\(snapshot.profileName)"
        )
    }

    /// `PREFS staged …` — the window-local staged payload (wave1r1 evidence:
    /// shows what the CONTROLS carry, applied or not).
    private func logStaged() {
        UILog.line(
            "PREFS staged name=\(staged.deviceName) res=\(staged.resolution) fps=\(staged.frameRate) mute=\(staged.muted ? "on" : "off") sleep=\(staged.preventSleep ? "on" : "off") notify=\(staged.notificationsEnabled ? "on" : "off") lang=\(staged.language) profile=\(staged.profileName) dirty=\(staged != base ? 1 : 0)"
        )
    }

    /// `PREFS layout …` — the CENTRING evidence (rulings ①/②): the rendered
    /// content column's position in window coordinates (expected x=57,
    /// w=336 in the 450-pt window) + the window width.
    private func logGeometry() {
        guard let column = form?.column, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let inWindow = column.convert(column.bounds, to: nil)
        UILog.line(
            "PREFS layout formx=\(Int(inWindow.minX.rounded())) formw=\(Int(inWindow.width.rounded())) winw=\(Int(window.frame.width.rounded()))"
        )
        logFooterGeometry(tag: "show")
    }

    /// `PREFS footer …` — the B2 §F footer measurement (YC's consequential correction of the R1
    /// full-text-first judgement): the About entry's rendered frame (bottom-right), the R1
    /// reminder's rendered width and the REMINDER SLOT (available width
    /// between the leading margin and the Apply button); `full=1` proves the
    /// full-text "Unsaved changes" fits (it only shrinks if it will not fit).
    private func logFooterGeometry(tag: String) {
        guard let about = aboutButton, let apply = applyButton else { return }
        let aboutFrame = about.convert(about.bounds, to: nil)
        let applyFrame = apply.convert(apply.bounds, to: nil)
        let reminderWidth = Metrics.reminderDotSize + reminderStack.spacing + reminderLabel.fittingSize.width
        let slot = applyFrame.minX - Metrics.reminderGap - Metrics.reminderMinLeading
        UILog.line(
            "PREFS footer \(tag) aboutx=\(Int(aboutFrame.minX.rounded())) aboutw=\(Int(aboutFrame.width.rounded()))"
                + " reminderw=\(Int(reminderWidth.rounded())) slot=\(Int(slot.rounded()))"
                + " full=\(reminderWidth <= slot ? 1 : 0)"
        )
    }

    /// The Apply button state (+ the R1 reminder): ENABLED only while the
    /// staged payload differs from the engine truth (PM micro-decision 3). In the clean state = no
    /// reminder + a grey button; in the changed state = the reminder shows + a bright button (ruling ⑤/R1). It is logged on every
    /// change (evidence line).
    private func updateApplyState() {
        let enabled = staged != base
        applyButton?.isEnabled = enabled
        reminderStack.isHidden = !enabled
        if lastApplyEnabledLogged != enabled {
            lastApplyEnabledLogged = enabled
            UILog.line("PREFS apply enabled=\(enabled ? 1 : 0) reminder=\(enabled ? 1 : 0)")
        }
    }

    /// A user edit landed on a staged field: mutate the local payload only
    /// (zero engine write / zero E1 / zero receiver touch — rulings ①/⑤), then
    /// refresh the dirty state (+ the R1 reminder).
    private func stage(_ mutate: (inout StagedSettings) -> Void) {
        mutate(&staged)
        logStaged()
        updateApplyState()
    }

    // MARK: - Control actions (wave1r1: all staged)

    /// the device-name commit path — E5 commit-once (the delegate `controlTextDidEndEditing`:
    /// Enter or focus loss; the test seam drives the same method). The value
    /// is STAGED; applying it to the engine is the Apply button's business.
    private func deviceNameCommitted(_ field: NSTextField) {
        stage { $0.deviceName = field.stringValue }
    }

    /// E5: the device-name field's editing session ended (Enter / focus
    /// loss) — stage the committed value once.
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field === form?.deviceNameField else { return }
        deviceNameCommitted(field)
    }

    /// The mute switch action — staged.
    @objc private func muteToggled(_ sender: NSSwitch) {
        stage { $0.muted = sender.state == .on }
    }

    /// The prevent-sleep switch action — staged (it only takes effect on apply; the shell-held semantics are unchanged).
    @objc private func preventSleepToggled(_ sender: NSSwitch) {
        stage { $0.preventSleep = sender.state == .on }
    }

    /// The language picker action — staged: the selection is kept in the window-local
    /// payload only; the whole UI flips when Apply commits it (the UI switches
    /// language on apply; the adapter writes the engine + flips the service).
    @objc private func languageSelected(_ sender: NSPopUpButton) {
        guard let code = sender.selectedItem?.representedObject as? String else { return }
        stage { $0.language = code }
    }

    /// wave1r3 — the footer About entry action: hands the open request to the
    /// AppShell wiring (`onOpenAbout` → StatusItemMenu → About mini-window).
    @objc private func aboutClicked(_ sender: NSButton) {
        UILog.line("PREFS about entry clicked")
        onOpenAbout?()
    }

    // MARK: - Apply (wave1r1)

    /// The ONE batch commit. The adapter performs every engine write and the
    /// E1 arrangement (running + receiver-related diff → exactly one restart;
    /// shell-held only → zero touch; not started → pure write-back); this
    /// method then re-syncs the controls from the engine truth, which clears
    /// the dirty state (after applying, dirty clears to zero + the reminder disappears).
    @objc private func applyClicked(_ sender: NSButton) {
        guard staged != base else { return }
        UILog.line("PREFS apply requested")
        intentHandler?.preferencesApplyRequested(staged)
        syncFromTruth()
    }

    /// Test seam (UITestDriver): the exact action path the Apply button
    /// takes (see UITestDriver).
    public func applyForTesting() {
        applyClicked(applyButton)
    }

    /// wave1r10 test seam — posts a REAL synthetic click on the Apply
    /// button (the user-click recipe: window coordinates + the target
    /// window's number, probe-verified against live AppKit event routing).
    /// Used by the lock-blocking probe in scripts/test-trust.sh: the same
    /// posted click fires while no trust lock is up and is DROPPED while the
    /// trust prompt's app-side lock (route ①) runs (the lock swallows events not
    /// destined for the prompt window). The enabled/key state rides the
    /// evidence line so the script can correlate legs.
    public func postApplyClickForTesting(leg: String) {
        guard window.isVisible, let apply = applyButton else { return }
        let rectInWindow = apply.convert(apply.bounds, to: nil)
        let center = NSPoint(x: rectInWindow.midX, y: rectInWindow.midY)
        func make(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: center, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0
            )
        }
        guard let down = make(.leftMouseDown), let up = make(.leftMouseUp) else { return }
        #if DEBUG
        UILog.line(
            "UITEST prefs-apply-click posted leg=\(leg) enabled=\(apply.isEnabled ? 1 : 0) key=\(window.isKeyWindow ? 1 : 0)"
        )
        #endif
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
    }

    // MARK: - The trusted-device editor dialog (wave1r1 R2; the wave1r4 implementation)

    /// The "Edit Trust Devices…" action — opens the trust editor (YC ruling ④).
    @objc private func editTrustDevicesClicked(_ sender: NSButton) {
        presentTrustEditor()
    }

    /// The live trust editor sheet, if presented (for the dismissal seam).
    private var trustEditor: NSAlert?

    /// wave1r6 (rebuilding ✕ on screen) — the LIVE accessory container + stack of the
    /// presented editor (weak: the alert window hierarchy owns them). A
    /// refresh REBUILDS the stack IN PLACE: swapping `NSAlert.accessoryView`
    /// on an already-presented sheet never re-lays-out (NSAlert lays out
    /// lazily at display time — the old view, including its ✕ buttons, stays
    /// on screen and keeps receiving clicks; observed by YC as "after clicking x it should
    /// disappear, not just sit there"). The in-place rebuild removes the old buttons from
    /// the window hierarchy → a repeat click at the old position cannot fire
    /// the view again (regression: in YC's session six consecutive ✕ clicks, with the last five landing on the stale old buttons).
    private weak var trustAccessoryContainer: NSView?
    private weak var trustAccessoryStack: NSStackView?

    /// The trust editor POPUP (YC rulings ④/⑤): each row = a device name + ✕ (pressing ✕ removes it),
    /// and the dialog contains a one-click Reset. Trust stores the machine code and displays the device name (a name cache).
    /// wave1r4: rows come from the REAL registry source (`trustDevicesProvider`
    /// → TrustRegistryStore.entries(), tolerant read + dedupe); ✕ and Reset
    /// emit intent through the write-side seam (it shares the same writer with the dialog's do-not-trust)
    /// and the rows re-render from the source. All strings ride the
    /// dictionary (three languages).
    private func presentTrustEditor() {
        guard window.isVisible else { return }
        let entries = trustDevicesProvider()
        UILog.line("PREFS trust editor presented (rows=\(entries.count))")
        let alert = NSAlert()
        alert.messageText = localization.t("prefs.trust.editorTitle")
        alert.addButton(withTitle: localization.t("prefs.trust.done"))
        alert.accessoryView = makeTrustAccessory(entries: entries)
        trustEditor = alert
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.trustEditor = nil
            UILog.line("PREFS trust editor dismissed")
        }
    }

    /// Builds the editor's accessory view from the given rows (each row = a device name
    /// + ✕; a one-click Reset at the bottom). Re-runnable — but a LIVE sheet re-renders
    /// through `rebuildTrustAccessoryInPlace` instead (wave1r6: swapping is ineffective on an already-presented
    /// sheet). The container + stack are cached for the in-place path.
    private func makeTrustAccessory(entries: [TrustDeviceEntry]) -> NSView {
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 10))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 260),
        ])
        populateTrustStack(stack, entries: entries)
        trustAccessoryContainer = accessory
        trustAccessoryStack = stack
        sizeTrustAccessory(accessory, stack: stack)
        return accessory
    }

    /// (Re)fills the editor stack — each row = a device name (the display = the name cache; an empty
    /// name falls back to the machine code) + ✕ (pressing ✕ removes it; the machine code is the key); the empty state = an empty text row; a one-click Reset at the bottom.
    /// Re-runnable: the wave1r6 refresh path calls it on the LIVE stack (views
    /// already inside the window hierarchy → takes effect immediately).
    private func populateTrustStack(_ stack: NSStackView, entries: [TrustDeviceEntry]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if entries.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: localization.t("prefs.trust.empty")))
        } else {
            for entry in entries {
                let displayName = entry.name.isEmpty ? entry.machineCode : entry.name
                let name = NSTextField(labelWithString: displayName)
                let remove = NSButton(
                    title: "✕",
                    target: self,
                    action: #selector(trustRowRemoveClicked(_:))
                )
                remove.isBordered = false
                remove.identifier = NSUserInterfaceItemIdentifier(entry.machineCode)
                let row = NSStackView(views: [name, remove])
                row.orientation = .horizontal
                row.spacing = 8
                stack.addArrangedSubview(row)
            }
        }
        let reset = NSButton(
            title: localization.t("prefs.trust.reset"),
            target: self,
            action: #selector(trustResetClicked)
        )
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)
        stack.layoutSubtreeIfNeeded()
    }

    /// Sizes the accessory container from the stack's fitted content
    /// (top/leading/width pins only — no conflicting bottom pin).
    private func sizeTrustAccessory(_ accessory: NSView, stack: NSStackView) {
        accessory.frame = NSRect(
            x: 0,
            y: 0,
            width: 260,
            height: max(stack.fittingSize.height, 10)
        )
    }

    /// Re-renders the editor rows from the (now-updated) registry source —
    /// called after every ✕/Reset write so the list never shows a stale row.
    /// wave1r6: on a LIVE sheet the stack is rebuilt IN PLACE (a swapped
    /// `accessoryView` is never re-laid-out by the presented NSAlert).
    private func refreshTrustEditorRows() {
        guard let alert = trustEditor else { return }
        let entries = trustDevicesProvider()
        UILog.line("PREFS trust editor refreshed (rows=\(entries.count))")
        if let stack = trustAccessoryStack, let container = trustAccessoryContainer,
           stack.window != nil {
            populateTrustStack(stack, entries: entries)
            sizeTrustAccessory(container, stack: stack)
            container.layoutSubtreeIfNeeded()
            stack.window?.displayIfNeeded()
            UILog.line("PREFS trust editor views rebuilt in place (rows=\(entries.count))")
        } else {
            alert.accessoryView = makeTrustAccessory(entries: entries)
        }
    }

    /// One-click Reset — removes everything (= the registry truncates to 0; the same file-write mechanism
    /// and the same timing semantics as do-not-trust (wave1r6: apply on disconnect — the decision lives in AppShell's pending gate).
    /// Intent through the write-side seam; rows re-render from the source
    /// afterwards (wave1r6: the LIVE stack rebuilds in place).
    @objc private func trustResetClicked() {
        let count = trustDevicesProvider().count
        UILog.line("PREFS trust reset requested (rows=\(count))")
        onTrustReset?(count)
        refreshTrustEditorRows()
    }

    /// Per-row ✕ — removes ONE trusted device (pressing ✕ deletes it; keyed by the machine code).
    /// It shares the dialog's do-not-trust file-write mechanism and timing semantics (wave1r6: apply on disconnect).
    @objc private func trustRowRemoveClicked(_ sender: NSButton) {
        let code = sender.identifier?.rawValue ?? "-"
        UILog.line("PREFS trust remove requested code=\(code)")
        onTrustDeviceRemove?(code)
        refreshTrustEditorRows()
    }

    // MARK: - Test seams (UITestDriver)

    /// Test seam: the same commit path the device-name field's action takes.
    public func commitDeviceNameForTesting(_ name: String) {
        guard let field = form?.deviceNameField else { return }
        field.stringValue = name
        deviceNameCommitted(field)
    }

    /// Test seam: the same settle path the resolution slider's commit takes
    /// (release only; the scripted B2 rewrites / the harness).
    public func selectResolutionForTesting(step: Int) {
        form?.resolution.commit(step: step)
    }

    /// Test seam: the same settle path the frame-rate slider's commit takes.
    public func selectFrameRateForTesting(step: Int) {
        form?.frameRate.commit(step: step)
    }

    /// Test seam: the same action path the mute switch takes.
    public func toggleMuteForTesting(_ on: Bool) {
        guard let mute = form?.mute else { return }
        mute.state = on ? .on : .off
        muteToggled(mute)
    }

    /// Test seam: the same action path the prevent-sleep switch takes.
    public func togglePreventSleepForTesting(_ on: Bool) {
        guard let toggle = form?.preventSleep else { return }
        toggle.state = on ? .on : .off
        preventSleepToggled(toggle)
    }

    /// Test seam (D8): stages the retained B2 slot DIRECTLY — the settings
    /// page no longer carries a connection-notification control, so there is no switch to
    /// drive (`toggle` as a control name is historical). The harness uses it
    /// to put a FALSE value through the real apply path and prove that the
    /// NOTIFY record is not gated by it (recording is unconditional), and that the value
    /// still persists.
    public func toggleNotificationsForTesting(_ on: Bool) {
        stage { $0.notificationsEnabled = on }
    }

    /// Test seam (wave1r3): presses the footer About entry through the exact
    /// button action path ("PERFS about entry clicked"→ onOpenAbout).
    public func pressAboutForTesting() {
        aboutClicked(aboutButton)
    }

    /// Test seam (wave1r1 R2): opens the trust editor through the exact
    /// button path ("Edit Trust Devices…").
    public func presentTrustEditorForTesting() {
        presentTrustEditor()
    }

    /// Test seam (wave1r1 R2): ends the trust editor sheet.
    public func dismissTrustEditorForTesting() {
        guard let alert = trustEditor else { return }
        window.endSheet(alert.window)
    }

    /// Test seam (wave1r1 R2; the wave1r4 implementation): presses one-click Reset through the
    /// exact button action path (remove all = truncate; the evidence line
    /// "PREFS trust reset requested (rows=N)" + "TRUST reset …").
    public func pressTrustResetForTesting() {
        trustResetClicked()
    }

    /// Test seam (wave1r4; wave1r6 → LIVE-VIEW backed): presses a row's ✕.
    /// wave1r6 rewrote the lookup: the button is found in the PRESENTED
    /// sheet's view tree (the old model-table lookup was exactly the blind
    /// spot the YC ✕ incident exposed — model-layer green, view-layer stale).
    public func removeTrustRowForTesting(machineCode: String) {
        pressLiveTrustRowForTesting(machineCode: machineCode)
    }

    // MARK: - wave1r6 test seams (the on-screen view layer; not the model layer)

    /// Test seam (wave1r6): the machine codes of the ✕ buttons ACTUALLY in
    /// the presented sheet's view tree — walks the alert WINDOW (the
    /// on-screen layer). Empty list = no editor on screen (or no rows).
    func liveTrustRowCodesForTesting() -> [String] {
        guard let alert = trustEditor else { return [] }
        return Self.descendantButtons(of: alert.window.contentView ?? NSView())
            .filter { $0.action == #selector(trustRowRemoveClicked(_:)) }
            .compactMap { $0.identifier?.rawValue }
    }

    /// Test seam (wave1r6): logs the LIVE row codes — the view-layer evidence
    /// line (`PREFS trust editor live-rows=…`). Sorted so scripts can match
    /// the exact code list deterministically.
    public func auditTrustEditorLiveRowsForTesting() {
        let codes = liveTrustRowCodesForTesting().sorted()
        UILog.line("PREFS trust editor live-rows=\(codes.count) codes=[\(codes.joined(separator: ","))]")
    }

    /// Test seam (wave1r6): presses the ✕ of `machineCode` through the LIVE
    /// view tree — models a user pressing the on-screen button. A row that
    /// was already removed has no live button: the seam records a miss and —
    /// crucially — NO `remove requested` line (YC's repeated-click regression: after six clicks, five of them
    /// landed on the stale old buttons; the in-place rebuild removes the button).
    public func pressLiveTrustRowForTesting(machineCode: String) {
        guard let alert = trustEditor, let root = alert.window.contentView else {
            UILog.line("PREFS trust live-press miss code=\(machineCode) (no sheet)")
            return
        }
        guard let button = Self.descendantButtons(of: root).first(where: {
            $0.action == #selector(trustRowRemoveClicked(_:))
                && $0.identifier?.rawValue == machineCode
        }) else {
            UILog.line("PREFS trust live-press miss code=\(machineCode) (row not on screen)")
            return
        }
        trustRowRemoveClicked(button)
    }

    /// Renders the presented trust editor sheet to a PNG — test-harness only
    /// (wave1r6: the on-screen renders before/after ✕). The same AppKit render convention as the
    /// other surfaces (Screen Recording TCC unavailable in the test env).
    ///
    /// wave1r6 render fix: an NSAlert SHEET's background is composited by the
    /// window server — no offscreen capture route (cacheDisplay /
    /// displayIgnoringOpacity / layer.render / PDF raster, all probed) draws
    /// it, so a bare capture is white-on-black text (first delivery: three
    /// identical 3.1KB 2-colour PNGs). Captures are therefore rendered onto
    /// a bitmap PREFILLED with the window background colour — the probe with
    /// prefill yields a faithful 87-colour dark-mode dialog. Candidates are
    /// tried in order; the first capture with actual content variation wins;
    /// a vector-PDF raster is the last resort.
    public func renderTrustEditorSnapshotForTesting(to path: String) {
        guard let alert = trustEditor, alert.window.isVisible else {
            UILog.line("PREFS trust editor snapshot failed (no live sheet)")
            return
        }
        let sheetWindow = alert.window
        sheetWindow.displayIfNeeded()
        var candidates: [(label: String, view: NSView)] = []
        if let content = sheetWindow.contentView { candidates.append(("content", content)) }
        if let frame = sheetWindow.contentView?.superview { candidates.append(("frame", frame)) }
        if let accessory = trustAccessoryContainer { candidates.append(("accessory", accessory)) }
        for (label, view) in candidates {
            view.layoutSubtreeIfNeeded()
            guard let rep = Self.prefilledCapture(of: view),
                  Self.repHasContentVariation(rep),
                  let data = rep.representation(using: .png, properties: [:]) else { continue }
            writeTrustEditorSnapshot(data, path: path, label: label)
            return
        }
        // Last resort: PDF rasterization of the sheet content.
        if let content = sheetWindow.contentView {
            let pdf = content.dataWithPDF(inside: content.bounds)
            if let image = NSImage(data: pdf),
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               Self.repHasContentVariation(rep),
               let data = rep.representation(using: .png, properties: [:]) {
                writeTrustEditorSnapshot(data, path: path, label: "pdf")
                return
            }
        }
        UILog.line("PREFS trust editor snapshot failed (all capture targets blank)")
    }

    /// Writes one editor-sheet capture + the evidence line.
    private func writeTrustEditorSnapshot(_ data: Data, path: String, label: String) {
        do {
            try data.write(to: URL(fileURLWithPath: path))
            UILog.line("PREFS trust editor snapshot \(path) target=\(label)")
        } catch {
            UILog.line("PREFS trust editor snapshot failed (\(error.localizedDescription))")
        }
    }

    /// Captures one view onto a 2× bitmap rep PREFILLED with the window
    /// background colour (the sheet background is otherwise absent from any
    /// offscreen capture — see `renderTrustEditorSnapshotForTesting`).
    private static func prefilledCapture(of view: NSView) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        let scale = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width) * scale,
            pixelsHigh: Int(bounds.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            NSColor.windowBackgroundColor.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: bounds.size))
            view.cacheDisplay(in: bounds, to: rep)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// True when a capture carries actual content — samples a pixel grid and
    /// looks for ≥ 2 distinct colours (a blank sheet frame is uniform).
    private static func repHasContentVariation(_ rep: NSBitmapImageRep) -> Bool {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 8, height > 8 else { return false }
        var first: NSColor?
        for xi in stride(from: 1, to: width, by: max(1, width / 16)) {
            for yi in stride(from: 1, to: height, by: max(1, height / 16)) {
                guard let color = rep.colorAt(x: xi, y: yi) else { continue }
                if let reference = first {
                    if abs(color.redComponent - reference.redComponent) > 0.02
                        || abs(color.greenComponent - reference.greenComponent) > 0.02
                        || abs(color.blueComponent - reference.blueComponent) > 0.02 {
                        return true
                    }
                } else {
                    first = color
                }
            }
        }
        return false
    }

    /// Recursive button collector — the view-tree walk behind the wave1r6
    /// live seams (identification = the row action selector + machine code).
    private static func descendantButtons(of view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        func walk(_ current: NSView) {
            if let button = current as? NSButton { result.append(button) }
            current.subviews.forEach(walk)
        }
        walk(view)
        return result
    }

    private var frameDescription: String {
        String(
            format: "%dx%d",
            Int(window.frame.width.rounded()),
            Int(window.frame.height.rounded())
        )
    }
}

/// wave1r1 — EffectiveSnapshot → staged payload (fresh-show / post-apply
/// sync). Both types live behind the SettingsUI ↔ SharedTypes seam; no
/// ConfigEngine import needed. `profileName` rides through as ENGINE truth
/// (wave1r3: the Profiles UI is withdrawn — the value is no longer changed by the window, and on apply it is always the same-value no-op).
private extension StagedSettings {
    init(from snapshot: EffectiveSnapshot) {
        self.init(
            deviceName: snapshot.deviceName,
            resolution: snapshot.resolution,
            frameRate: snapshot.frameRate,
            muted: snapshot.muted,
            preventSleep: snapshot.preventSleep,
            notificationsEnabled: snapshot.notificationsEnabled,
            language: snapshot.language,
            profileName: snapshot.profileName
        )
    }
}
