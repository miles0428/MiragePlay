import AppKit
import Localization

/// About mini-window — wave1r2 (the B1 implementation unit; B1 §E-1 option A; YC ruling ② "the copyright
/// lives in the About mini-window (opened from some entry point, e.g. the panel menu)").
///
/// Entry point: the "About" SECONDARY small row at the bottom of the menu-bar
/// panel (B1 §E-1 left its entry point open → a secondary small row at the panel's bottom; flagged in the delivery report).
///
/// Content (static statements + one source-repository link; the distribution-surface link
/// set referenced by 0.4-3 is not bundled):
///   • the app name MiragePlay (YC decided on 2026-10-18; wave1r5 rewrote the line for the rename);
///   • the copyright line `© 2026 Yu-Cheng Chung and Contributors` (YC's verbatim ruling;
///     revocable in one line);
///   • the licence notice GPL-3.0-only (GPL-3 §6 requires pointing at the corresponding source);
///   • third-party components (per deps.lock): UxPlay v1.73.6 / OpenSSL 3 / libplist /
///
/// All strings are term-dictionary lookups through the injected
/// `LanguageService` (three languages; zero hard-coded UI strings). The window is
/// single-instance, owned and reused by StatusItemMenu (same pattern as the
/// preferences window); CLOSE ONLY traffic light (the S-6 convention).
public final class AboutWindowController: NSObject, NSWindowDelegate {

    enum Metrics {
        /// B1 §E-1 sketch: the About window is a compact 360-pt window.
        static let width: CGFloat = 360
        static let padding: CGFloat = 18
        static let lineSpacing: CGFloat = 8
        /// The text column (= width − 2 × padding); long lines WRAP here so
        /// the window's minimum width can never inflate.
        static let textWidth: CGFloat = width - padding * 2
    }

    /// The repository the About window links to (single source of truth: the visible
    /// caption is a term-dictionary lookup, the URL is not).
    static let sourceRepositoryURL = "https://github.com/miles0428/MiragePlay"

    /// Whether the window is currently on screen (used by the test's window-count assertion).
    public var isVisible: Bool { window.isVisible }

    private let window: NSWindow
    private let localization: LanguageService
    private let appNameLabel = NSTextField(labelWithString: "")
    private let copyrightLabel = NSTextField(labelWithString: "")
    private let licenseLabel = NSTextField(labelWithString: "")
    private let thirdPartyLabel = NSTextField(labelWithString: "")
    private let sourceButton = NSButton(title: "", target: nil, action: nil)
    private var hasBeenShown = false

    public init(localization: LanguageService) {
        self.localization = localization
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
        buildContent()
        applyLanguage()
        localization.observe { [weak self] in
            self?.applyLanguage()
        }
    }

    // MARK: - Visibility

    /// Shows the window (a singleton: the same instance is reused; brought to the front when already shown).
    public func show() {
        if hasBeenShown {
            UILog.line("ABOUT shown (reused)")
        } else {
            hasBeenShown = true
            UILog.line("ABOUT shown (created)")
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        UILog.line("ABOUT frame \(frameDescription)")
    }

    /// Red-light close (equivalent to the window's close button; the instance is kept and can be reopened).
    public func close() {
        guard window.isVisible else { return }
        window.close()
    }

    public func windowWillClose(_ notification: Notification) {
        UILog.line("ABOUT closed")
    }

    // MARK: - Language (stage G)

    /// Re-renders every string in the selected language (observer-driven;
    /// takes effect across the whole UI instantly).
    func applyLanguage() {
        window.title = localization.t("about.title")
        appNameLabel.stringValue = localization.t("about.appName")
        copyrightLabel.stringValue = localization.t("about.copyright")
        licenseLabel.stringValue = localization.t("about.license")
        thirdPartyLabel.stringValue = localization.t("about.thirdParty")
        applySourceLinkTitle()
    }

    /// Re-renders the source link caption as a hyperlink (link colour + underline) in the
    /// selected language; the URL itself never changes.
    private func applySourceLinkTitle() {
        sourceButton.attributedTitle = NSAttributedString(
            string: localization.t("about.source"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        )
    }

    /// stage G language audit — the RENDERED strings of this window, read back
    /// from the actual controls (evidence that it "takes effect across the whole UI instantly"). wave1r2-fix1:
    /// the third-party line is included so a missed flip is caught by the
    /// audit assertion, not only by the render (review N5).
    public func languageAudit() {
        UILog.line(
            "LANGAUDIT about lang=\(localization.language)"
                + " title=\(window.title)"
                + " appname=\(appNameLabel.stringValue)"
                + " copyright=\(copyrightLabel.stringValue)"
                + " license=\(licenseLabel.stringValue)"
                + " thirdParty=\(thirdPartyLabel.stringValue)"
                + " source=\(sourceButton.title)"
        )
    }

    // MARK: - Actions

    /// Opens the source repository in the default browser (this target's first external link).
    @objc private func openSourceRepository() {
        guard let url = URL(string: AboutWindowController.sourceRepositoryURL) else { return }
        UILog.line("ACTION about-source-open url=\(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Test-harness support

    /// Renders the window to a PNG (the app renders it itself — the same convention as the
    /// preferences window; Screen Recording permission is unavailable in the
    /// test environment).
    public func renderSnapshot(to path: String) {
        window.displayIfNeeded()
        let target: NSView = window.contentView?.superview ?? window.contentView ?? NSView()
        target.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            UILog.line("ABOUT snapshot failed (no bitmap rep)")
            return
        }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            UILog.line("ABOUT snapshot failed (no png data)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            UILog.line("ABOUT snapshot \(path)")
        } catch {
            UILog.line("ABOUT snapshot failed (\(error.localizedDescription))")
        }
    }

    // MARK: - Configuration & layout

    private func configureWindow() {
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.tabbingMode = .disallowed
        window.delegate = self
    }

    private func buildContent() {
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        window.contentView = effectView

        appNameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        appNameLabel.alignment = .center
        copyrightLabel.font = .systemFont(ofSize: 12)
        copyrightLabel.textColor = .secondaryLabelColor
        copyrightLabel.alignment = .center
        licenseLabel.font = .systemFont(ofSize: 12)
        licenseLabel.textColor = .secondaryLabelColor
        licenseLabel.alignment = .center
        // The third-party line WRAPS at the text column width (EN is the
        // longest string; a fixed wrap width keeps the minimum window width
        // deterministic — the 602-pt-window bug class).
        thirdPartyLabel.font = .systemFont(ofSize: 11)
        thirdPartyLabel.textColor = .tertiaryLabelColor
        thirdPartyLabel.alignment = .center
        thirdPartyLabel.usesSingleLineMode = false
        thirdPartyLabel.lineBreakMode = .byWordWrapping
        thirdPartyLabel.maximumNumberOfLines = 0
        thirdPartyLabel.preferredMaxLayoutWidth = Metrics.textWidth

        // The source-repository link: a borderless button rendered as a hyperlink. It is the
        // window's only control, and it opens the browser through NSWorkspace (AppKit only —
        // this target has no SwiftUI dependency).
        sourceButton.target = self
        sourceButton.action = #selector(openSourceRepository)
        sourceButton.isBordered = false
        sourceButton.bezelStyle = .inline
        sourceButton.alignment = .center
        sourceButton.toolTip = AboutWindowController.sourceRepositoryURL

        let stack = NSStackView(views: [appNameLabel, copyrightLabel, licenseLabel, thirdPartyLabel, sourceButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.lineSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effectView.topAnchor, constant: Metrics.padding),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -Metrics.padding),
            stack.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: effectView.leadingAnchor, constant: Metrics.padding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: effectView.trailingAnchor, constant: -Metrics.padding),
        ])
        for label in [appNameLabel, copyrightLabel, licenseLabel, thirdPartyLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: Metrics.textWidth).isActive = true
        }
    }

    private var frameDescription: String {
        String(
            format: "%dx%d",
            Int(window.frame.width.rounded()),
            Int(window.frame.height.rounded())
        )
    }
}
