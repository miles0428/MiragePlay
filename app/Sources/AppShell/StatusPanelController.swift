import AppKit
import Localization
import ReceiverKit
import SettingsUI

/// Borderless floating panel that may become key so its controls accept
/// clicks while the (LSUIElement) app never activates.
final class AnchoredPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Anchored control panel (MenuBarExtra-style) — CP-2, increment ①.
///
/// Form: clicking the status item opens a panel-style control surface
/// anchored below the item (right edges aligned, 6 px gap) — NOT the old
/// NSMenu dropdown. AppKit route (NSStatusItem + NSPanel) per the
/// 2026-10-16 ruling: "MenuBarExtra" = a description of the form (an anchored panel opened
/// from the top-right corner); the implementation framework = AppKit.
/// Clicking anywhere outside the panel dismisses it.
///
/// Content (increment ②, 2026-10-17; YC added "the name and the PIN can be shown in the main menu";
/// wave1r1 R2 item-order/icon ruling; wave1r3: the About entry moves into the window — the panel's order returns to four items):
/// the status row (same-colour status dot + three-state text; the connected state = "Connected: <device>" with an A3 ellipsis;
/// an existing element, kept in place and outside the ordering) /
/// the PIN protection toggle + PIN code row (item order ①; stage D wiring: the code value = the engine truth
/// [P2/P3; zero-padded to 4 digits] + the small regenerate button [P6; greyed out when the PIN is off]) /
/// the start·stop main button (item order ②) / the settings row (formerly "preferences…"; item order ③,
/// which opens the preferences window) / leave (item order ④; S5: quit everything, never
/// ask). **Icons removed throughout** (YC 2026-10-17 R2: "icons do not help the reading verdict"):
/// the row glyphs (settings/escape) were removed — text-only rows; the status
/// the dot stays (functional semantics: the three-state colour).
/// wave1r3 (B2 ruling ③ "put the about button in preferences, not in the menu bar"):
/// the panel-bottom "About" secondary row is REMOVED — the panel = PIN code →
/// start → settings → leave; the About entry now lives in the preferences window's
/// footer (a small bottom-right button → AboutWindowController).
///
/// stage G (wave1g) language: every user-visible string in this view is looked
/// up per term in the selected language through the injected
/// up through `LanguageService` (contract L146 "the term dictionary is written in config and read
/// term by term in the selected language"; the values are in the supplementary pack §B). `applyLanguage()` re-renders every string on
/// a language flip — immediate (E1 row 12: language = shell-held, effective at once, receiver
/// untouched), with no receiver involvement. Zero Chinese literals remain here.
///
/// stage D (wave1d) PIN chain: the switch and the regenerate button emit intent
/// through the `onPinProtectionToggled` / `onPinChangeRequested` callbacks
/// (wired by StatusItemMenu to the AppShell adapter — engine write + E1 in
/// the coordinator; this view never touches the engine). The displayed code
/// is read back from the engine through `pinStateProvider` on panel show,
/// after each intent, and after every receiver-start preparation (the P3
/// the unset mode regenerates the code at each start — CompositionRoot's prepare
/// hook calls `refreshPinDisplay()` so the shown code is always the code the
/// receiver actually spawns with).
///
/// The design values below = the A3 §G/§I proposal values (the P-7/PM precision domain — YC accepts them
/// as measured, revocable in one line): width 300 / padding 12 / corner radius 12 / row height 24 /
/// main button height 26 / anchor gap 6 px; panel height follows
/// `Metrics.contentHeight(pinOn:)` (the A3 draft's 204/184 are proposal values; see the report for the differences).
final class StatusPanelController {

    /// A3 §G/§I proposal metrics — single source for layout AND panel size
    /// (no magic numbers duplicated in the sizing math).
    enum Metrics {
        static let width: CGFloat = 300
        static let padding: CGFloat = 12
        static let cornerRadius: CGFloat = 12
        static let rowHeight: CGFloat = 24
        static let statusRowHeight: CGFloat = 20
        static let statusDotSize: CGFloat = 9
        static let mainButtonHeight: CGFloat = 26
        static let rowGap: CGFloat = 8
        static let separatorHeight: CGFloat = 1
        static let anchorGap: CGFloat = 6
        /// PIN code row height (A3 .prow.sub) — present only when the PIN is on.
        static let pinCodeRowHeight: CGFloat = 20

        /// Total panel height derived from the metrics above for the given
        /// The PIN-protection visual state. wave1r1 R2 (YC item-order ruling): the order
        /// is status row → PIN section → start button → settings → leave; wave1r3 (About moves into the window)
        /// removes the former bottom "about" row — the panel = PIN code → start → settings → leave:
        /// PIN on:  12+20+8+24+20+8+1+8+26+8+1+8+24+8+24+12 = 212.
        /// PIN off: same minus the 20-pt code row = 192.
        static func contentHeight(pinOn: Bool) -> CGFloat {
            padding * 2
                + statusRowHeight + rowGap
                + rowHeight                        // PIN protection row (item order ①: PIN block on top)
                + (pinOn ? pinCodeRowHeight : 0)   // PIN code row (flush against it; appears when PIN is on)
                + rowGap
                + separatorHeight                  // separator after the PIN block
                + rowGap
                + mainButtonHeight + rowGap        // start/stop main button (item order ②)
                + separatorHeight + rowGap         // separator after the main button
                + rowHeight                        // settings row (formerly the preferences entry; item order ③)
                + rowGap
                + rowHeight                        // leave row (item order ④)
        }
    }

    /// Invoked when the start/stop main button is clicked.
    var onPrimaryAction: (() -> Void)?
    /// Invoked when the preferences… row is clicked (increment ②).
    var onOpenPreferences: (() -> Void)?
    /// Invoked when the leave row is clicked (S5 quit).
    var onQuit: (() -> Void)?

    /// Engine-truth provider for the PIN row — (enabled, code-in-force).
    /// Wired by StatusItemMenu to ConfigEngine's snapshot. `nil` (no engine
    /// wired) → the PIN display keeps its last local state.
    var pinStateProvider: (() -> (enabled: Bool, code: String?))?

    /// Invoked when the user flips the PIN protection switch (intent: an engine write + E1).
    var onPinProtectionToggled: ((Bool) -> Void)?

    /// Invoked when the user clicks the regenerate button (intent: regenerate the code + E1).
    var onPinChangeRequested: (() -> Void)?

    /// Whether the panel is currently on screen (used by the test's window-count assertion).
    var isVisible: Bool { panel.isVisible }

    /// The currently rendered status-row text (language audit evidence).
    var currentStatusText: String { statusLabel.stringValue }
    /// The currently rendered main-button title (language audit evidence).
    var currentPrimaryTitle: String { primaryButton.title }
    /// The currently rendered PIN-row label (language audit evidence).
    var currentPinLabel: String { pinProtectionLabel.stringValue }
    /// The currently rendered regenerate button title (language audit evidence).
    var currentChangeTitle: String { pinChangeButton.title }
    /// The currently rendered preferences… entry title (language audit evidence).
    var currentEntryTitle: String { preferencesButton.title }
    /// The currently rendered leave entry title (language audit evidence).
    var currentQuitTitle: String { quitButton.title }

    /// stage G: the term lookup for every user-visible string in this view.
    private let localization: LanguageService

    private let panel: AnchoredPanel
    private let effectView = NSVisualEffectView()
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton()
    private let separator = NSView()
    private let pinProtectionSwitch = NSSwitch()
    private let pinProtectionRow = NSStackView()
    private let pinProtectionLabel = NSTextField(labelWithString: "")
    private let pinCodeRow = NSView()
    private var pinCodeRowHeightConstraint: NSLayoutConstraint!
    private let pinCodeTitleLabel = NSTextField(labelWithString: "")
    private let pinCodeLabel = NSTextField(labelWithString: "")
    private let pinChangeButton = NSButton()
    private let pinSeparator = NSView()
    private let preferencesButton = NSButton()
    private let quitButton = NSButton()

    /// Global mouse monitor installed while the panel is visible — its calls
    /// never arrive for events inside our own app (status item click toggles
    /// separately), which is exactly the click-outside dismissal boundary.
    /// wave1r10b — the dismissal is additionally gated (app must be inactive
    /// AND the event must not originate from this process) so that a click
    /// landing while one of OUR windows owns the focus — e.g. the preferences
    /// window, behind which the panel deliberately stays open — never
    /// self-closes the panel.
    private var outsideClickMonitor: Any?

    /// Last rendered state, re-applied whenever the panel is shown.
    private var lastState: ReceiverState = .idle

    init(localization: LanguageService) {
        self.localization = localization
        panel = AnchoredPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.contentHeight(pinOn: false)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        buildContent()
        applyLanguage()
        applyPinLayout(pinOn: false, logged: false)
        // stage G: instant all-UI effect — the panel re-renders itself whenever
        // the selected language flips (observer lives for the app lifetime).
        localization.observe { [weak self] in
            self?.applyLanguage()
        }
    }

    // MARK: - Language (stage G)

    /// Re-renders every user-visible string in the selected language: the
    /// static labels, the entries, and the state row/button (via
    /// `update(with:)` — the same path a state transition takes). A settled
    /// failure text is intentionally not re-composed: the next transition
    /// renders the standard strings again (same convention as showFailure).
    func applyLanguage() {
        pinProtectionLabel.stringValue = localization.t("panel.pin.protection")
        pinCodeTitleLabel.stringValue = localization.t("panel.pin.code")
        pinChangeButton.title = localization.t("panel.pin.change")
        preferencesButton.title = localization.t("panel.entry.preferences")
        quitButton.title = localization.t("panel.entry.quit")
        update(with: lastState)
    }

    // MARK: - Visibility

    /// Toggles panel visibility — the status-item click entry point.
    func toggle(relativeTo button: NSStatusBarButton?) {
        if panel.isVisible {
            hide()
        } else {
            show(relativeTo: button)
        }
    }

    /// Shows the panel anchored below the status item, right edges aligned.
    func show(relativeTo button: NSStatusBarButton?) {
        update(with: lastState)
        // stage D: re-read the PIN truth before sizing/positioning — a persisted
        // PIN-on state must render its code row (and the 212 height) on the
        // very first open.
        refreshPinDisplay()
        position(relativeTo: button)
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
        UILog.line("PANEL shown")
    }

    /// Hides the panel (no-op when already hidden — and logs only real hides).
    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeOutsideClickMonitor()
        UILog.line("PANEL hidden")
    }

    // MARK: - State rendering

    /// Renders a receiver state on the status row and the main button.
    /// Called by StatusItemMenu.updateState on every coordinator transition.
    func update(with state: ReceiverState) {
        lastState = state
        let presentation = presentation(for: state)
        statusDot.layer?.backgroundColor = presentation.dotColor.cgColor
        statusLabel.stringValue = presentation.statusText
        primaryButton.title = presentation.buttonTitle
        primaryButton.isEnabled = presentation.buttonEnabled
        primaryButton.bezelColor = presentation.buttonAccent ? NSColor.controlAccentColor : nil
    }

    private func presentation(for state: ReceiverState) -> (
        dotColor: NSColor,
        statusText: String,
        buttonTitle: String,
        buttonEnabled: Bool,
        buttonAccent: Bool
    ) {
        // Strings = §B term dictionary lookups (stage G; the selected language).
        switch state {
        case .idle:
            return (.systemGray, localization.t("panel.status.idle"), localization.t("panel.button.start"), true, true)
        case .waiting:
            return (.systemOrange, localization.t("panel.status.waiting"), localization.t("panel.button.stop"), true, false)
        case .connected(let deviceName):
            return (.systemGreen, localization.t("panel.status.connected", deviceName), localization.t("panel.button.stop"), true, false)
        case .stopping:
            // Transient; the stopping-form text (§B a; visible only in the transition state).
            return (.systemGray, localization.t("panel.status.stopping"), localization.t("panel.button.stop"), false, false)
        }
    }

    // MARK: - Failure surfacing (R4-Q2=A)

    /// A settled launch failure shows its short cause on the status row
    /// ("Start failed: <short reason>" — the R4-Q2=A carry-over channel). Reuses the existing
    /// status row and the standard not-running presentation; no new visual
    /// element. The next state transition renders the standard strings again.
    ///
    /// stage G: `reason` is the language-neutral short cause (the core bridge
    /// yields it; see the "SPAWN-FAILED" marker); the prefix is composed
    /// here from the dictionary (§B a2) so the row follows the selected
    /// language (the EN default = "Start failed: <reason>").
    func showFailure(reason: String) {
        update(with: .idle)
        statusLabel.stringValue = localization.t("panel.status.startFailed") + reason
    }

    // MARK: - Window configuration & layout

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = Metrics.cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effectView
    }

    /// Builds the increment-① content: status row / main button / separator /
    /// leave. All heights and gaps derive from `Metrics`.
    private func buildContent() {
        let statusRow = NSView()
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = Metrics.statusDotSize / 2
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        statusRow.addSubview(statusDot)
        statusRow.addSubview(statusLabel)

        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.bezelStyle = .rounded
        primaryButton.translatesAutoresizingMaskIntoConstraints = false

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        // The PIN protection row + the PIN code row (YC added "the PIN can be shown in the main menu"; the A3 §B
        // cut-A layout). stage D wiring: the switch reflects the engine's pinEnabled
        // (read-through on show/refresh) and flipping it emits intent
        // (`onPinProtectionToggled`) — the engine write + E1 arrangement live
        // in the AppShell adapter/coordinator, never in this view.
        pinProtectionLabel.font = .systemFont(ofSize: 13)
        pinProtectionSwitch.controlSize = .small
        pinProtectionSwitch.state = .off
        pinProtectionSwitch.target = self
        pinProtectionSwitch.action = #selector(pinToggled)
        pinProtectionRow.setViews([pinProtectionLabel, pinProtectionSwitch], in: .leading)
        pinProtectionRow.orientation = .horizontal
        pinProtectionRow.alignment = .centerY
        pinProtectionRow.spacing = 7
        pinProtectionRow.translatesAutoresizingMaskIntoConstraints = false

        pinCodeRow.wantsLayer = true
        pinCodeRow.translatesAutoresizingMaskIntoConstraints = false
        pinCodeTitleLabel.font = .systemFont(ofSize: 13)
        // Code value = the engine truth (P2/P3; zero-padded to 4 digits — leading zeros must show). Initially empty;
        // it is read back for display by refreshPinDisplay() when the panel opens, after a PIN
        // intent, and before every spawn preparation (the unset P3 = generate a new code).
        pinCodeLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        pinCodeLabel.textColor = .secondaryLabelColor
        // The small regenerate button (P6 / R3-Q1=A): pressing it = generate a fresh 4-digit random
        // code + update the display + E1; when the PIN is off the button is greyed (no effect). Initially the PIN is off (P1) → disabled.
        pinChangeButton.target = self
        pinChangeButton.action = #selector(pinChangeClicked)
        pinChangeButton.bezelStyle = .rounded
        pinChangeButton.controlSize = .small
        pinChangeButton.font = .systemFont(ofSize: 11)
        pinChangeButton.isEnabled = false
        pinChangeButton.translatesAutoresizingMaskIntoConstraints = false
        let pinCodeStack = NSStackView(views: [pinCodeTitleLabel, pinCodeLabel, pinChangeButton])
        pinCodeStack.orientation = .horizontal
        pinCodeStack.alignment = .centerY
        pinCodeStack.spacing = 6
        pinCodeStack.translatesAutoresizingMaskIntoConstraints = false
        pinCodeRow.addSubview(pinCodeStack)

        pinSeparator.wantsLayer = true
        pinSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        pinSeparator.translatesAutoresizingMaskIntoConstraints = false

        // The settings row (formerly "preferences…"; the A3 §B bottom entry; item order ③) — wave1r1 R2
        // (YC icon ruling): text-only — the vector glyph was removed (no
        // icons; icons are removed throughout).
        preferencesButton.target = self
        preferencesButton.action = #selector(preferencesClicked)
        preferencesButton.isBordered = false
        preferencesButton.alignment = .left
        preferencesButton.font = .systemFont(ofSize: 13)
        preferencesButton.translatesAutoresizingMaskIntoConstraints = false

        // The leave row (item order ④) — wave1r1 R2: text-only (the escape SF Symbol was
        // removed with the same icon ruling).
        quitButton.target = self
        quitButton.action = #selector(quitClicked)
        quitButton.isBordered = false
        quitButton.alignment = .left
        quitButton.font = .systemFont(ofSize: 13)
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(statusRow)
        effectView.addSubview(primaryButton)
        effectView.addSubview(separator)
        effectView.addSubview(pinProtectionRow)
        effectView.addSubview(pinCodeRow)
        effectView.addSubview(pinSeparator)
        effectView.addSubview(preferencesButton)
        effectView.addSubview(quitButton)

        let padding = Metrics.padding
        pinCodeRowHeightConstraint = pinCodeRow.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            pinCodeStack.leadingAnchor.constraint(equalTo: pinCodeRow.leadingAnchor),
            pinCodeStack.centerYAnchor.constraint(equalTo: pinCodeRow.centerYAnchor),
            pinCodeRowHeightConstraint,
        ])
        // wave1r1 R2 (YC item-order ruling): status row (in place) → ① PIN section → ② start button →
        // ③ settings → ④ leave. The status row and other existing elements stay in place; separators fall with their sections.
        NSLayoutConstraint.activate([
            statusRow.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: padding),
            statusRow.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -padding),
            statusRow.topAnchor.constraint(equalTo: effectView.topAnchor, constant: padding),
            statusRow.heightAnchor.constraint(equalToConstant: Metrics.statusRowHeight),

            statusDot.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor),
            statusDot.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: Metrics.statusDotSize),
            statusDot.heightAnchor.constraint(equalToConstant: Metrics.statusDotSize),

            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 7),
            statusLabel.trailingAnchor.constraint(equalTo: statusRow.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),

            // ① PIN protection row — left-aligned (A3: the switch follows the label).
            pinProtectionRow.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: padding),
            pinProtectionRow.trailingAnchor.constraint(lessThanOrEqualTo: effectView.trailingAnchor, constant: -padding),
            pinProtectionRow.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: Metrics.rowGap),
            pinProtectionRow.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),

            // PIN code row — indented by 16 (A3 .prow.sub padding-left) and flush
            // under the toggle row; height 0 while PIN is off.
            pinCodeRow.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: padding + 16),
            pinCodeRow.trailingAnchor.constraint(lessThanOrEqualTo: effectView.trailingAnchor, constant: -padding),
            pinCodeRow.topAnchor.constraint(equalTo: pinProtectionRow.bottomAnchor),

            // the separator after the PIN section.
            pinSeparator.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: padding),
            pinSeparator.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -padding),
            pinSeparator.topAnchor.constraint(equalTo: pinCodeRow.bottomAnchor, constant: Metrics.rowGap),
            pinSeparator.heightAnchor.constraint(equalToConstant: Metrics.separatorHeight),

            // ② the start/stop main button.
            primaryButton.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: padding),
            primaryButton.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -padding),
            primaryButton.topAnchor.constraint(equalTo: pinSeparator.bottomAnchor, constant: Metrics.rowGap),
            primaryButton.heightAnchor.constraint(equalToConstant: Metrics.mainButtonHeight),

            // the separator after the main button.
            separator.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: padding),
            separator.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -padding),
            separator.topAnchor.constraint(equalTo: primaryButton.bottomAnchor, constant: Metrics.rowGap),
            separator.heightAnchor.constraint(equalToConstant: Metrics.separatorHeight),

            // ③ the settings row (formerly "preferences…").
            preferencesButton.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: padding),
            preferencesButton.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -padding),
            preferencesButton.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: Metrics.rowGap),
            preferencesButton.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),

            // ④ the leave row.
            quitButton.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: padding),
            quitButton.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -padding),
            quitButton.topAnchor.constraint(equalTo: preferencesButton.bottomAnchor, constant: Metrics.rowGap),
            quitButton.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),
            quitButton.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -padding),
        ])
    }

    // MARK: - Positioning

    /// Places the panel below the status item: right edges aligned, 6 px gap,
    /// clamped into the screen's visible frame.
    private func position(relativeTo button: NSStatusBarButton?) {
        guard let button = button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size

        var origin = NSPoint(
            x: buttonRect.maxX - size.width,
            y: buttonRect.minY - Metrics.anchorGap - size.height
        )
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
            origin.y = max(origin.y, visibleFrame.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Click-outside dismissal

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return }
            // The dismissal fires only for a genuine OUTSIDE click
            // (the out-of-panel contract: the panel deliberately stays open while our own
            // windows — panel / preferences / about — own the focus):
            //   1. only monitor OTHER-app clicks — an event whose source
            //      process is us (synthetic / loopback events reach the
            //      global monitor too) must never dismiss the panel;
            //   2. require the app to be INACTIVE — a click landing while we
            //      are the frontmost app is inside-app interaction, not a
            //      click outside the panel.
            let source = event.cgEvent?
                .getIntegerValueField(.eventSourceUnixProcessID)
            let fromSelf = source == Int64(ProcessInfo.processInfo.processIdentifier)
            if fromSelf || NSApp.isActive {
                return
            }
            UILog.line(
                "PANEL monitors last closed (outside click source-pid=\(source.map(String.init) ?? "unknown") app-active=\(NSApp.isActive ? 1 : 0))"
            )
            self.hide()
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Actions

    @objc private func primaryClicked() {
        onPrimaryAction?()
    }

    @objc private func preferencesClicked() {
        onOpenPreferences?()
    }

    @objc private func quitClicked() {
        onQuit?()
    }

    // MARK: - PIN chain (stage D wiring: the switch / the code row / the regenerate button)

    /// Programmatic setter for the PIN-protection toggle — the exact path the
    /// user's switch click takes (switch state → pinToggled: intent + E1 +
    /// read back for display; the test seam used by UITestDriver).
    func setPinProtection(_ on: Bool) {
        pinProtectionSwitch.state = on ? .on : .off
        pinToggled()
    }

    @objc private func pinToggled() {
        let on = pinProtectionSwitch.state == .on
        applyPinLayout(pinOn: on, logged: true)
        // Intent → AppShell adapter: engine write + E1 signal. Then re-read
        // the engine truth into the code row / button state (when the PIN is on
        // setPinEnabled guarantees there is a code to display — P2; when the PIN is off the code area hides and the button greys out).
        onPinProtectionToggled?(on)
        refreshPinDisplay()
    }

    /// P6 (R3-Q1=A): a click on the regenerate button — a fresh random code via the
    /// intent path (engine changePin + E1), then re-read the display.
    /// With the PIN off the button is greyed (no effect): real clicks cannot land on a disabled
    /// button; this guard also covers the programmatic seam.
    @objc private func pinChangeClicked() {
        guard pinProtectionSwitch.state == .on else {
            UILog.line("ACTION pin-change ignored (PIN off)")
            return
        }
        UILog.line("ACTION pin-change")
        onPinChangeRequested?()
        refreshPinDisplay()
    }

    /// Test-seam (UITestDriver): the exact action path the regenerate button
    /// takes — including the PIN-off guard.
    func pressPinChangeButton() {
        pinChangeClicked()
    }

    /// Re-reads the engine's PIN state into the switch, the code row and the
    /// regenerate button — the stage D truth channel (read-through, never an engine
    /// write). Called on panel show, after both PIN intents, and from the
    /// CompositionRoot prepare hook before every receiver spawn (the P3 unset
    /// code regenerates at each start). Emits the read-through evidence line
    /// used by scripts/test-pin-chain.sh (`PANEL pin display …`); the user
    /// toggle line stays `applyPinLayout(logged:)`'s.
    func refreshPinDisplay() {
        guard let state = pinStateProvider?() else { return }
        pinProtectionSwitch.state = state.enabled ? .on : .off
        applyPinLayout(pinOn: state.enabled, logged: false)
        pinCodeLabel.stringValue = state.code ?? ""
        pinChangeButton.isEnabled = state.enabled
        UILog.line(
            "PANEL pin display \(state.enabled ? "on" : "off") code=\(state.code ?? "-") change=\(state.enabled ? "enabled" : "disabled")"
        )
    }

    /// Applies the PIN visual state: the code row appears (PIN on) / hides
    /// (PIN off), the panel re-sizes to exactly the derived content height,
    /// and — when on screen — the panel keeps its top edge pinned below the
    /// status item.
    private func applyPinLayout(pinOn: Bool, logged: Bool) {
        pinCodeRow.isHidden = !pinOn
        pinCodeRowHeightConstraint.constant = pinOn ? Metrics.pinCodeRowHeight : 0
        let topEdge = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(
            NSSize(width: Metrics.width, height: Metrics.contentHeight(pinOn: pinOn))
        )
        if panel.isVisible {
            panel.setFrameTopLeftPoint(topEdge)
        }
        if logged {
            UILog.line(
                "PIN toggled \(pinOn ? "on" : "off") (panel \(Int(panel.frame.width))x\(Int(panel.frame.height)))"
            )
        }
    }

    // MARK: - Test-harness support

    /// Renders the panel content to a PNG (test harness only — see
    /// UITestDriver). Used instead of screen capture, which needs Screen
    /// Recording permission the test environment does not have. Failures are
    /// logged, never thrown.
    func renderSnapshot(to path: String) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            UILog.line("PANEL snapshot failed (no bitmap rep)")
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            UILog.line("PANEL snapshot failed (no png data)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            UILog.line("PANEL snapshot \(path)")
        } catch {
            UILog.line("PANEL snapshot failed (\(error.localizedDescription))")
        }
    }
}
