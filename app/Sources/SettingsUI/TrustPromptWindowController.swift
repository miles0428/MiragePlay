import AppKit
import Localization

/// The trust prompt dialog — wave1r4 (trust increment I2); wave1r10 (a new YC order: always
/// topmost + forced interaction); wave1r10d (YC ruled **route ①**: skip the system app-modal and lock the UI ourselves).
///
/// Trigger: the CoreBridge fourth parse mode "registered new client" (a PIN pairing succeeded,
/// at the moment projection begins, uxplay.cpp:2624) → the AppShell decision layer →
/// `present(deviceName:deviceID:)`. The semantics in one sentence (spec_trust_20261018-r2 §2):
/// "trust this name? = remembered, so no PIN next time" — NOT "may it connect or not"; both answers
/// **do not affect the current connection** (YC's framing: the point of trusting is that the next
/// connection can be a little easier, not whether it can connect at all).
///
/// Answer semantics (M1): trust = keep (zero action); do-not-trust = removal plus a file write;
/// close / no answer = treated as do-not-trust (removal). Every answer is thrown up
/// via `onAnswer(deviceID, trusted:)` — only the AppShell decision layer performs the write.
///
/// Wording discipline (§2.7): the copy always uses the "remember / do not remember" frame (the dictionary keys `trust.ask.*`);
/// literals like "block", "refuse the connection" or "let through" are forbidden.
///
/// **The wave1r10d presentation mechanism (YC ruled route ①: "skip the system app-modal and block the UI yourself")**:
///   - **Do not enter a system modal session**: an app-modal modal session overwrites a modal window's
///     `level` with `NSModalPanelWindowLevel` (8) during presentation, which breaks
///     "always topmost" (the r10 proof: `TRUSTPROMPTAUDIT level=8`; the reviewer marked
///     this required-1). This wave uses an **app-side lock** instead:
///       a) **The level is always 26** (`NSStatusWindowLevel + 1`) — set in `init`, and
///          **re-asserted on every `show()`** (with no modal session overwriting it ⇒ it stays
///          26 at runtime; it outranks the panel's 25).
///       b) **Blocking the rest of this app's UI**: while visible it installs a **local event monitor** (
///          `NSEvent.addLocalMonitorForEvents`) that swallows every mouse/key event **not for this
///          prompt window** (returning `nil` ⇒ not dispatched), and sets `ignoresMouseEvents = true`
///          on this app's other windows (restored when it closes). {trust} / {do-not-trust} remain
///          the only two exits (YC: "forcing the user to click" is kept).
///       c) On presentation it calls `activate(from:)` (the non-deprecated foregrounding under macOS 14
///          cooperative activation) plus `makeKeyAndOrderFront`; with no foreground app it falls back to `NSApp.activate()`.
///       d) **ESC = do-not-trust** (`distrustButton.keyEquivalent = "\u{1b}"`;
///          the keyDown path is kept — the prompt is the key window, so events dispatch normally).
///       e) **Still no close button** (`styleMask` is only `.titled`).
///       f) **Serialization kept**: a repeat event for the same device = coalesced (not re-shown); a different device = queued,
///          and it takes over after the previous one closes.
///       g) **Apply-on-disconnect / the file write are never blocked by the lock**: with no modal session the main queue
///          is never stuck; the lock only intercepts "event dispatch", not dispatch blocks (the apply / write
///          pipelines run as usual), and it leaves evidence with a main-queue liveness line.
///   - `canJoinAllSpaces` + `fullScreenAuxiliary` + `hidesOnDeactivate = false`:
/// visible across Spaces / over full-screen presentations; it does not hide when the user switches away from the app.
public final class TrustPromptWindowController: NSObject, NSWindowDelegate {

    enum Metrics {
        /// Compact window, same family as the About mini-window.
        static let width: CGFloat = 380
        static let padding: CGFloat = 18
        static let lineSpacing: CGFloat = 8
        static let buttonsTopGap: CGFloat = 6
        /// The text column (= width − 2 × padding); long lines WRAP here.
        static let textWidth: CGFloat = width - padding * 2
    }

    /// The app-lock level: above NSStatusWindowLevel (measured as 25 for the panel) = 26;
    /// higher than every existing window of this app (the panel 25 / the preferences and About windows 0).
    private static let lockLevel = NSWindow.Level(
        rawValue: NSWindow.Level.statusBar.rawValue + 1)

    /// Answer sink — wired by the AppShell to the (single) trust registry
    /// writer's decision path. `trusted == false` covers both the explicit
    /// the do-not-trust press and the unanswered/closed window (M1).
    public var onAnswer: ((_ deviceID: String, _ trusted: Bool) -> Void)?

    /// Whether the prompt is currently on screen (used by the test's window-count assertion).
    public var isVisible: Bool { window.isVisible }

    /// wave1r10d — the device currently being asked about (nil = no prompt in
    /// flight). This is the device-identity seam: the harness answers only the
    /// a prompt belonging to its target device (the discriminator when several interleave under serialization).
    public var currentDeviceID: String? { current?.deviceID }

    /// wave1r10d — true while the app-side lock (local event monitor +
    /// the other windows' ignoresMouseEvents) is holding the UI on this prompt.
    public var isLockActive: Bool { lockMonitor != nil }

    private let window: NSWindow
    private let localization: LanguageService
    private let messageLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private var trustButton: NSButton!
    private var distrustButton: NSButton!
    private var hasBeenShown = false

    /// The device currently being asked about (nil = no prompt in flight).
    private var current: (deviceName: String, deviceID: String)?
    /// Devices queued while a prompt is visible (events for a different device = queued).
    private var pending: [(deviceName: String, deviceID: String)] = []
    /// Set when the visible prompt was answered (distinguishes an answer from
    /// a close — the latter is the M1 "no answer" case.
    private var answered = false
    /// wave1r10d — set between `show()` and the close funnel; guards a second
    /// presentation while the cycle is still settling (never double-present).
    private var isPresenting = false
    /// wave1r10d — the local event monitor token while the app-side lock holds.
    private var lockMonitor: Any?
    /// wave1r10d — the other app windows we masked (+ their prior state), so
    /// the mask is restored exactly on release.
    private var ignoredWindows: [(window: NSWindow, wasIgnoring: Bool)] = []

    public init(localization: LanguageService) {
        self.localization = localization
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 170),
            // wave1r10 — TITLED ONLY: no `.closable` ⇒ no ✕ in the title bar —
            // trust / do-not-trust are the only two exits (forced interaction; YC's order).
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
        buildContent()
        applyLanguage()
        // A language flip repaints immediately (the stage G discipline; the same convention as About / the preferences window).
        localization.observe { [weak self] in
            self?.applyLanguage()
        }
    }

    // MARK: - Presentation

    /// Shows the ask for one device. If a prompt is already visible
    /// (or its cycle is settling) the event MERGES when it is the same
    /// device; a different device is queued (one at a time — serialization).
    public func present(deviceName: String, deviceID: String) {
        if let current, isPresenting || window.isVisible {
            if current.deviceID == deviceID {
                UILog.line("TRUST prompt merged (same device) deviceID=\(deviceID)")
                return
            }
            pending.append((deviceName: deviceName, deviceID: deviceID))
            UILog.line("TRUST prompt queued deviceID=\(deviceID) (a prompt is visible)")
            return
        }
        if isPresenting {
            // A close is in flight (`current` already cleared, the cycle still
            // settling): queue — never double-show.
            pending.append((deviceName: deviceName, deviceID: deviceID))
            UILog.line("TRUST prompt queued deviceID=\(deviceID) (prompt cycle settling)")
            return
        }
        show(deviceName: deviceName, deviceID: deviceID)
    }

    private func show(deviceName: String, deviceID: String) {
        current = (deviceName: deviceName, deviceID: deviceID)
        answered = false
        applyLanguage()
        if hasBeenShown {
            UILog.line("TRUST prompt shown (reused)")
        } else {
            hasBeenShown = true
            UILog.line("TRUST prompt shown (created)")
            window.center()
        }
        // wave1r10d — the level is re-asserted on EVERY presentation (no modal session
        // ⇒ AppKit never overwrites it to 8; this is the runtime guarantee of "always topmost").
        window.level = Self.lockLevel
        raiseForPresentation()
        window.makeKeyAndOrderFront(nil)
        UILog.line("TRUST prompt presented name=\(deviceName) deviceID=\(deviceID)")
        isPresenting = true
        installLock()
    }

    /// Raises the app for the prompt. LSUIElement apps are not active by
    /// default, and macOS 14+ activation is cooperative (plain `activate()`
    /// may not be granted for a CLI-launched process): `activate(from:)`
    /// citing the current frontmost app is the non-deprecated
    /// `activate(ignoringOtherApps:)` equivalent (probe-verified: the app
    /// actually becomes active). No front app ⇒ fall back to `activate()`.
    private func raiseForPresentation() {
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            _ = NSRunningApplication.current.activate(from: frontmost, options: [.activateAllWindows])
        } else {
            NSApp.activate()
        }
    }

    /// wave1r10d — engages the app-side lock (route ①): a local event monitor
    /// swallows every mouse/key event that is NOT destined for the prompt
    /// window (returning nil ⇒ never dispatched), and every OTHER app window
    /// is masked with `ignoresMouseEvents = true`. The prompt stays fully
    /// interactive (its own events pass through); there is **no system modal
    /// session**, so `NSApp.modalWindow` stays nil and the main queue is never
    /// blocked (the apply / write pipelines run as usual).
    private func installLock() {
        guard lockMonitor == nil else { return }
        for other in NSApp.windows where other !== window {
            if !other.ignoresMouseEvents {
                ignoredWindows.append((window: other, wasIgnoring: false))
                other.ignoresMouseEvents = true
            } else {
                ignoredWindows.append((window: other, wasIgnoring: true))
            }
        }
        lockMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                       .otherMouseDown, .otherMouseUp, .scrollWheel,
                       .keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            guard let self, self.window.isVisible else { return event }
            // Only events belonging to the prompt window are dispatched;
            // every other app window's event is swallowed (the app-side lock).
            if event.window === self.window { return event }
            UILog.line("TRUST prompt lock swallowed event type=\(event.type.rawValue)")
            return nil
        }
        UILog.line(
            "TRUST prompt lock engaged (app-side lock; 信任／不信任 the only exits;"
                + " level=\(window.level.rawValue) maskedWindows=\(ignoredWindows.count))"
        )
        // In-lock liveness probe: a main-queue hop that still lands while the
        // lock holds = proof the dispatch pipeline (log-watcher hops, apply
        // chain, apply-on-disconnect / the file write) is NOT blocked.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lockMonitor != nil else { return }
            UILog.line(
                "TRUST prompt lock liveness (locked=1 key=\(self.window.isKeyWindow ? 1 : 0) main-q=alive)"
            )
        }
    }

    /// wave1r10d — releases the lock (window close funnel): unhook the event
    /// monitor and restore every masked window's exact prior state.
    private func releaseLock() {
        if let monitor = lockMonitor {
            NSEvent.removeMonitor(monitor)
            lockMonitor = nil
        }
        for masked in ignoredWindows where !masked.wasIgnoring {
            masked.window.ignoresMouseEvents = false
        }
        ignoredWindows.removeAll()
        UILog.line("TRUST prompt lock released")
    }

    /// Presents the next queued device once the single window is free
    /// (the previous one has already closed; async so it never re-enters a close notification).
    private func advanceQueueIfIdle() {
        guard !isPresenting, !window.isVisible, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        DispatchQueue.main.async { [weak self] in
            self?.present(deviceName: next.deviceName, deviceID: next.deviceID)
        }
    }

    /// Settles the visible ask: logs, hands the answer up, closes the window
    /// (close → `windowWillClose` → lock release).
    private func settle(trusted: Bool, via: String) {
        guard !answered, let current else { return }
        answered = true
        UILog.line("TRUST prompt answered \(trusted ? "trust" : "distrust") deviceID=\(current.deviceID) via=\(via)")
        onAnswer?(current.deviceID, trusted)
        window.close()
    }

    @objc private func trustClicked(_ sender: NSButton) {
        settle(trusted: true, via: "button")
    }

    @objc private func distrustClicked(_ sender: NSButton) {
        settle(trusted: false, via: "button")
    }

    /// NSWindowDelegate — the close funnel (M1 "no answer" = do-not-trust: without a prior
    /// answer the close settles as a distrust answer (removal); it is reached only via
    /// programmatic close — the window has NO close button (wave1r10))
    public func windowWillClose(_ notification: Notification) {
        if !answered, let openAsk = current {
            answered = true
            UILog.line("TRUST prompt dismissed unanswered (→ distrust) deviceID=\(openAsk.deviceID)")
            onAnswer?(openAsk.deviceID, false)
        }
        UILog.line("TRUST prompt closed")
        current = nil
        answered = false
        releaseLock()
        // Hold `isPresenting` until the next run-loop pass so a register event
        // landing during the close cannot double-show; then advance the queue
        // (by then the window reports hidden).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPresenting = false
            self.advanceQueueIfIdle()
        }
    }

    // MARK: - Language (the stage G discipline)

    /// Re-renders every string in the selected language (observer-driven).
    func applyLanguage() {
        window.title = localization.t("trust.ask.windowTitle")
        trustButton.title = localization.t("trust.ask.accept")
        distrustButton.title = localization.t("trust.ask.decline")
        if let current {
            messageLabel.stringValue = localization.t("trust.ask.title", current.deviceName)
        }
        infoLabel.stringValue = localization.t("trust.ask.message")
    }

    /// The rendered-string audit (the counterpart row for the EN / zh-Hant render acceptance).
    public func languageAudit() {
        UILog.line(
            "LANGAUDIT trust lang=\(localization.language) title=\(window.title)"
                + " message=\(messageLabel.stringValue)"
                + " accept=\(trustButton.title) decline=\(distrustButton.title)"
                + " visible=\(isVisible ? 1 : 0)"
        )
    }

    /// wave1r10d — the window-state audit (level / no close button / collection behaviour /
    /// deactivate policy / app-lock state) — the machine-checked evidence line for the
    /// "always topmost (26) + app-side lock" contract (asserted by scripts/test-trust.sh).
    public func stateAudit() {
        let closeButton = window.standardWindowButton(.closeButton) == nil ? "absent" : "present"
        UILog.line(
            "TRUSTPROMPTAUDIT level=\(window.level.rawValue) styleMask=\(window.styleMask.rawValue)"
                + " closable=\(window.styleMask.contains(.closable) ? 1 : 0) closeButton=\(closeButton)"
                + " canJoinAllSpaces=\(window.collectionBehavior.contains(.canJoinAllSpaces) ? 1 : 0)"
                + " fullScreenAuxiliary=\(window.collectionBehavior.contains(.fullScreenAuxiliary) ? 1 : 0)"
                + " hidesOnDeactivate=\(window.hidesOnDeactivate ? 1 : 0)"
                + " key=\(window.isKeyWindow ? 1 : 0) visible=\(window.isVisible ? 1 : 0)"
                + " locked=\(isLockActive ? 1 : 0)"
        )
    }

    // MARK: - Test-harness support

    /// Test seam: the exact action path the trust button takes.
    public func pressTrustForTesting() {
        trustClicked(trustButton)
    }

    /// Test seam: the exact action path the do-not-trust button takes.
    public func pressDistrustForTesting() {
        distrustClicked(distrustButton)
    }

    /// wave1r10e test seam — the DIAGNOSTIC silent-fallback exit (anti-fake-green).
    /// Lands the SAME answer funnel (settle: log → onAnswer → close) but tags the
    /// audit line `via=fallback`, whereas the real posted-click/posted-key paths
    /// keep `via=button`. The harness reaches this ONLY when a posted event failed
    /// to land within the grace window; the distinguishing tag stops a fallback
    /// from masquerading as a real event landing in the test evidence.
    public func answerTrustFallbackForTesting(trusted: Bool) {
        settle(trusted: trusted, via: "fallback")
    }

    /// Test seam: the red-light close WITHOUT answering (M1 → do-not-trust).
    public func closeWithoutAnswerForTesting() {
        guard window.isVisible else { return }
        window.close()
    }

    /// wave1r10 test seam — posts a REAL synthetic click on the trust
    /// button (the user-click recipe: window coordinates + the target
    /// window's number, verified against live AppKit event routing).
    public func postTrustClickForTesting() {
        postClick(on: trustButton)
    }

    /// wave1r10 test seam — posts a REAL Escape keyDown to the prompt window
    /// (ESC = do-not-trust; the user-key recipe — keyDown + the window number).
    public func postEscapeForTesting() {
        guard window.isVisible else { return }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ) else { return }
        #if DEBUG
        UILog.line(
            "UITEST trust-esc posted (window=\(window.windowNumber) key=\(window.isKeyWindow ? 1 : 0) locked=\(isLockActive ? 1 : 0))"
        )
        #endif
        NSApp.postEvent(event, atStart: false)
    }

    /// Posts a synthetic down/up pair on `control` through the app event
    /// queue (the same queue a real user click lands in).
    ///
    /// The evidence line is wrapped in `#if DEBUG`: posting IS the seam's
    /// behaviour and always runs, but the marker text must never reach a
    /// release binary (only the DEBUG-only harness reads it).
    private func postClick(on control: NSControl) {
        guard window.isVisible else { return }
        let rectInWindow = control.convert(control.bounds, to: nil)
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
            " UITEST trust-click posted (window=\(window.windowNumber) key=\(window.isKeyWindow ? 1 : 0) locked=\(isLockActive ? 1 : 0))"
        )
        #endif
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
    }

    /// Renders the prompt to a PNG (the app renders it itself — the same convention as About /
    /// preferences windows; Screen Recording permission is unavailable in
    /// the test environment).
    public func renderSnapshot(to path: String) {
        window.displayIfNeeded()
        let target: NSView = window.contentView?.superview ?? window.contentView ?? NSView()
        target.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            UILog.line("TRUST prompt snapshot failed (no bitmap rep)")
            return
        }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            UILog.line("TRUST prompt snapshot failed (no png data)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            UILog.line("TRUST prompt snapshot \(path)")
        } catch {
            UILog.line("TRUST prompt snapshot failed (\(error.localizedDescription))")
        }
    }

    // MARK: - Configuration & layout

    private func configureWindow() {
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.tabbingMode = .disallowed
        // wave1r10d — always topmost (YC's order): above NSStatusWindowLevel (measured as 25 for the panel)
        // = 26; higher than every existing window of this app. `show()` re-asserts it every time.
        window.level = Self.lockLevel
        // visible across Spaces + it can assist the full screen (another process's projection window keeps playing).
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // it does not hide when the user switches away from this app (part of the forced interaction).
        window.hidesOnDeactivate = false
        window.delegate = self
    }

    private func buildContent() {
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        window.contentView = effectView

        messageLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.usesSingleLineMode = false
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = Metrics.textWidth

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.alignment = .center
        infoLabel.lineBreakMode = .byWordWrapping
        infoLabel.usesSingleLineMode = false
        infoLabel.maximumNumberOfLines = 0
        infoLabel.preferredMaxLayoutWidth = Metrics.textWidth

        trustButton = NSButton(title: "", target: self, action: #selector(trustClicked(_:)))
        trustButton.bezelStyle = .rounded
        // the default button = trust (spec §2.4 fallback value).
        trustButton.keyEquivalent = "\r"
        distrustButton = NSButton(title: "", target: self, action: #selector(distrustClicked(_:)))
        distrustButton.bezelStyle = .rounded
        // ESC = do-not-trust (M1: "no answer = do-not-trust" — the outcome is identical, so
        // ESC maps onto the explicit distrust action; wave1r10d keeps it as a
        // keyDown exit of the app-side lock).
        distrustButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [distrustButton, trustButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [messageLabel, infoLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.lineSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(Metrics.buttonsTopGap + Metrics.lineSpacing, after: infoLabel)
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effectView.topAnchor, constant: Metrics.padding),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -Metrics.padding),
            stack.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: effectView.leadingAnchor, constant: Metrics.padding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: effectView.trailingAnchor, constant: -Metrics.padding),
        ])
        for label in [messageLabel, infoLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: Metrics.textWidth).isActive = true
        }
    }
}
