import AppKit
import Localization
import SharedTypes

/// S-2/S-4 building blocks for the preferences window — wave1r3 (the B2 slider batch)
/// SINGLE-PAGE form.
///
/// wave1r3 changes (YC's 2026-10-18 morning batch; draft `.task_state/ui_mockup_B2_slider.html`):
///
///   • SLIDER REBORN (ruling ① "for the UI I want a slider, not a text box with up/down arrows" —
///     the control is corrected; this overturns wave1r2's text box + stepper): the two numeric rows are
///     [slider 128 × 15 (draft value)] + [read-only value readout 48] (variant ①, the draft's
///     recommendation); zero steppers / zero value text boxes across the whole window. Detent snapping =
///     the existing 5×5 values (480p–2160p / 15–120 — do not invent your own); the slider is NOT
///     continuous — dragging = not yet committed, releasing = committed (the E5 style-coupling sentence is quoted again; the action
///     fires once on release);
///   • the whole Profiles section is withdrawn (ruling ② "profiles do not seem to be that useful"): the group hats 4→3
///     (Video & Audio / Connection & Session / Language); the profile dropdown
///     and "Save as…" are GONE from the window — the engine side (ConfigEngine /
///     ProfileStore) is retained and stays hidden;
///   • the ONE page, the centred 336-pt content column (margins 57/57) and the
///     the staged-apply model are UNCHANGED (ruling ⑥);
///   • The About entry (ruling ③ + the fix "about belongs bottom-right, not bottom-left") = a small button at the settings window's footer
///     bottom-right — owned by PreferencesWindowController (chrome), not here.
///
/// Sizes carried from the Mos measured values (window width 450 / label column 136 / gap 15 /
/// control height 22 / text field 180 / PIN 96 / dropdown 150 / button h20) — §H cites each value; the
/// slider 128×15 + read-only value 48 = the B2 draft's §E variant ① (the stated value ≠ AppKit — AppKit
/// flavour keeps the width exactly 128 and lets the control's intrinsic
/// height stand (18 pt with 5 tick marks, small size) because forcing 15 pt
/// clips the tick marks; the measured values are recorded in the delivery report).
enum PreferencesFormViews {

    enum Metrics {
        /// S-2 two-column form: the label column is 136 (Mos measured).
        static let labelWidth: CGFloat = 136
        /// S-2 the label→control gap is 15 (Mos measured).
        static let labelGap: CGFloat = 15
        /// B1 §A②: the control column — 185 = the widest control (text field 180) + 5 of slack.
        static let controlAreaWidth: CGFloat = 185
        /// B1 §A②: the content column 336 = 136 + 15 + 185; centred → margins 57/57.
        static let contentColumnWidth: CGFloat = labelWidth + labelGap + controlAreaWidth
        /// B1 §H: the row spacing is 8 (an approximate tidy-up for the implementation; revocable).
        static let rowSpacing: CGFloat = 8
        static let controlHeight: CGFloat = 22
        static let controlGap: CGFloat = 8
        /// B2 §E variant ①: the slider is 128 wide (the draft says 128×15; the width is per the value list, the height follows
        /// AppKit intrinsic — see the enum doc).
        static let sliderWidth: CGFloat = 128
        /// B2 §E variant ①: the read-only value readout is 48 wide (right-aligned).
        static let readoutWidth: CGFloat = 48
        static let textFieldWidth: CGFloat = 180
        static let pinFieldWidth: CGFloat = 96
        static let popupWidth: CGFloat = 150
        static let buttonHeight: CGFloat = 20
        /// wave1r1 — the window-bottom Apply control.
        static let applyButtonHeight: CGFloat = 24
        static let applyButtonMinWidth: CGFloat = 96
        /// B1: a group hat = an 11-pt tertiary label (6 pt of spacing to that group's first row).
        static let groupCapFontSize: CGFloat = 11
        static let groupCapBottomGap: CGFloat = 6
        /// B1: group separator = content column width (336).
        static let separatorWidth: CGFloat = contentColumnWidth
        /// B1 §H: the separator margins are 10/12 (an approximate tidy-up for the implementation).
        static let separatorTopGap: CGFloat = 10
        static let separatorBottomGap: CGFloat = 12
    }

    /// The numeric detent table — unchanged value domains (480p–2160p/
    /// 15–120; the P-7 precision-domain note; "detents = the existing values" — do not invent your own (B2 ruling ①).
    static let resolutionSteps = ["480p", "720p", "1080p", "1440p", "2160p"]
    /// Frame-rate detents (same provenance as `resolutionSteps`).
    static let frameRateSteps = ["15", "30", "45", "60", "120"]

    // MARK: - S-4 controls

    /// B2 §C–E variant ① — the numeric row control group: [slider 128] +
    /// [read-only value readout 48]. NO input field, NO stepper exists
    /// (ruling ① corrects the control; zero steppers / zero value text boxes across the whole window).
    ///
    /// E5 boundary (the §K#3 quote): the slider is NOT continuous — a drag
    /// while dragging = not yet committed (no callback, no staging); the action fires once on
    /// release (release = committed); tick-mark-only values give the discrete detent
    /// snap. The programmatic `apply(_:)` (the refresh path)
    /// never fires the callback, so read-through refreshes cannot masquerade
    /// as user edits.
    final class SliderControl: NSObject {

        /// The horizontal stack carrying [slider, readout].
        let view: NSStackView

        /// Settled-value callback (user paths only): the step INDEX into the
        /// detent table.
        var onValueChanged: ((Int) -> Void)?

        private let steps: [String]
        private let slider: NSSlider
        private let readout: NSTextField
        private var index: Int

        init(steps: [String], selectedStep: Int) {
            self.steps = steps
            let clamped = min(max(selectedStep, 0), max(steps.count - 1, 0))
            self.index = clamped
            self.slider = NSSlider(
                value: Double(clamped),
                minValue: 0,
                maxValue: Double(max(steps.count - 1, 0)),
                target: nil,
                action: nil
            )
            self.readout = PreferencesFormViews.readoutLabel(
                steps.isEmpty ? "" : steps[clamped])
            self.view = NSStackView()
            super.init()

            // Discrete detents: one tick per detent, and the values snap to the ticks.
            slider.numberOfTickMarks = steps.count
            slider.allowsTickMarkValuesOnly = true
            // E5: dragging does not count, only releasing commits — a non-continuous slider sends its
            // action exactly once, when the drag settles.
            slider.isContinuous = false
            slider.controlSize = .small
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: Metrics.sliderWidth).isActive = true

            view.orientation = .horizontal
            view.alignment = .centerY
            view.spacing = Metrics.controlGap
            view.setViews([slider, readout], in: .leading)

            apply(clamped)
        }

        /// Moves the group to a given step (silent refresh path).
        func apply(_ step: Int) {
            let clamped = min(max(step, 0), max(steps.count - 1, 0))
            index = clamped
            slider.doubleValue = steps.isEmpty ? 0 : Double(clamped)
            readout.stringValue = steps.isEmpty ? "" : steps[clamped]
        }

        /// Commit seam (UITestDriver / wiring tests): moves the group to
        /// `step` through the same path a settled slider action takes
        /// (self-sync + notify).
        func commit(step: Int) {
            let clamped = min(max(step, 0), max(steps.count - 1, 0))
            apply(clamped)
            onValueChanged?(clamped)
        }

        /// The settled slider action — the pointer left the knob (release) or a
        /// keyboard detent move landed. Snaps to the nearest detent and
        /// notifies; seeing this during a drag is impossible (isContinuous
        /// = false).
        @objc private func sliderChanged(_ sender: NSSlider) {
            let target = min(max(Int(sender.doubleValue.rounded()), 0), max(steps.count - 1, 0))
            apply(target)
            onValueChanged?(target)
        }
    }

    /// B2 §E variant ① — the read-only value readout: 48 pt, right-aligned, 12-pt
    /// secondary text. A LABEL (non-editable, non-selectable)— it can never
    /// can be typed; the "value text box" does not exist anywhere in this window
    /// (ruling ①).
    static func readoutLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Metrics.readoutWidth).isActive = true
        return label
    }

    /// S-4 switch (toggle) row control.
    static func switchControl(isOn: Bool) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        toggle.controlSize = .small
        return toggle
    }

    /// S-4 text input (device name 180 / PIN change 96).
    static func textInput(_ text: String, width: CGFloat) -> NSTextField {
        let field = NSTextField(string: text)
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    /// stage G — the language picker (English / Traditional Chinese / Simplified Chinese; contract L146
    /// pick one of three). The items come from the dictionary's declared language set; the
    /// DISPLAY name is each language's self-name (lang.option.*), the VALUE
    /// (BCP-47 code) rides `representedObject` so selection is by value.
    static func languagePopup(localization: LanguageService) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: Metrics.popupWidth).isActive = true
        for code in localization.supportedLanguages {
            popup.addItem(withTitle: localization.t("lang.option." + code))
            popup.lastItem?.representedObject = code
        }
        return popup
    }

    /// wave1r1 — the window-bottom Apply control: a system bezel button
    /// whose bezel takes the accent colour (the S-5 system blue), marking it as the
    /// one commit action of the staged-apply model. Disabled (clean) state
    /// greys out automatically (B1 §C: clean state = grey, changed state = bright).
    static func applyButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.bezelColor = .controlAccentColor
        button.font = .systemFont(ofSize: 12.5, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: Metrics.applyButtonHeight).isActive = true
        button.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Metrics.applyButtonMinWidth
        ).isActive = true
        return button
    }

    /// S-4 standard button (h20, quiet surface) — reused by "Edit Trust
    /// Devices…" and the footer About entry (the B2 §F small secondary button).
    static func smallButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor(white: 1, alpha: 0.20).cgColor
        button.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight).isActive = true
        button.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(button.intrinsicContentSize.width + 10, 44)
        ).isActive = true
        return button
    }

    /// The wave1r3 group hat — an 11-pt tertiary label (three hats: Video & Audio /
    /// Connection & Session / Language — the Profiles hat left with the whole section, ruling ②).
    static func groupCap(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: Metrics.groupCapFontSize)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// B1 group separator — the content column width (336; Mos's original value 410 = the full-width style
    /// left along with the centring).
    static func separatorRow() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalToConstant: Metrics.separatorWidth).isActive = true
        return line
    }

    /// One S-2 form row: right-aligned label (136) + 15 gap + controls.
    /// An empty label keeps the control column aligned (button rows, …).
    static func formRow(_ label: String, controls: [NSView]) -> NSView {
        formRowWithLabel(label, controls: controls).row
    }

    /// Same as `formRow`, but also hands back the label field — used where
    /// the rendered label itself is part of the UI evidence (the language
    /// row; the stage G audit). The layout is identical to `formRow`.
    ///
    /// The label WRAPS instead of clipping: the English
    /// "Connection Notifications" (144.8 pt) exceeds the 136-pt label column
    /// and EN must adapt by reflowing/wrapping, never truncating (zero truncation; a wrapped
    /// two-line label keeps the S-2 right-alignment baseline).
    static func formRowWithLabel(
        _ label: String, controls: [NSView]
    ) -> (row: NSView, label: NSTextField) {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12.5)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.usesSingleLineMode = false
        labelField.lineBreakMode = .byWordWrapping
        labelField.maximumNumberOfLines = 0
        labelField.preferredMaxLayoutWidth = Metrics.labelWidth
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: Metrics.labelWidth).isActive = true

        let controlStack = NSStackView(views: controls)
        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = Metrics.controlGap

        let row = NSStackView(views: [labelField, controlStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.labelGap
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.controlHeight).isActive = true
        return (row, labelField)
    }

    // MARK: - The single page (B1; Profiles withdrawn — wave1r3)

    /// The ONE settings page — every control reference the window controller
    /// keeps for staged refresh (row order: Video & Audio → Connection &
    /// Session → Language — wave1r3 ruling ②: the Profiles group is GONE).
    struct SinglePage {
        let view: NSView
        /// The centred 336-pt content column (the form STACK itself —
        /// geometry evidence target).
        let column: NSView
        /// The THREE group hats (render evidence — order: Video & Audio/
        /// Connection & Session/Language).
        let groupCaps: [NSTextField]
        let resolution: SliderControl
        let frameRate: SliderControl
        let mute: NSSwitch
        let deviceNameField: NSTextField
        let pinField: NSTextField
        let preventSleep: NSSwitch
        /// The trusted-devices section — the list is not embedded; the "Edit Trust Devices…" button opens the editor dialog.
        let editTrustButton: NSButton
        /// stage G: the language picker in the "Language" group.
        let languagePopup: NSPopUpButton
        /// The language row label (rendered value is part of the audit).
        let languageRowLabel: NSTextField
    }

    /// Builds the single page (every string is a dictionary lookup).
    /// Row order: [cap Video & Audio][Resolution][Frame Rate][Mute][sep]
    /// [cap Connection & Session][Device Name][PIN Code][Trust Devices]
    /// [Prevent Sleep][sep][cap Language][Language].
    /// D8: the connection-notification row is GONE from the page (YC ruling B "only remove the UI switch")
    /// — the B2 field lives on in the model/persistence only.
    static func buildSinglePage(
        snapshot: EffectiveSnapshot,
        localization: LanguageService
    ) -> SinglePage {
        let resolution = SliderControl(
            steps: resolutionSteps,
            selectedStep: resolutionSteps.firstIndex(of: snapshot.resolution) ?? 2
        )
        let frameRate = SliderControl(
            steps: frameRateSteps,
            selectedStep: frameRateSteps.firstIndex(of: String(snapshot.frameRate)) ?? 1
        )
        let mute = switchControl(isOn: snapshot.muted)

        let deviceNameField = textInput(snapshot.deviceName, width: Metrics.textFieldWidth)
        // stage D: the PIN field carries the engine's TRUE value; editing is
        // deferred to the row-1 increment — read-only here (selectable).
        let pinField = textInput(snapshot.pinCode ?? "", width: Metrics.pinFieldWidth)
        pinField.isEditable = false
        let preventSleep = switchControl(isOn: snapshot.preventSleep)
        // wave1r1 R2 (YC ruling ④): the trusted-device list is no longer embedded — it becomes an "Edit Trust
        // Devices…" button (the editor dialog = a device name + ✕ per row plus a one-click Reset; the underlying data source =
        // a later increment, for now an empty-list shell holds the position).
        let editTrustButton = smallButton(localization.t("prefs.trust.edit"))

        let languagePicker = languagePopup(localization: localization)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.rowSpacing

        // ① Video & Audio
        let capVideo = groupCap(localization.t("prefs.tab.videoAudio"))
        let resolutionRow = formRow(localization.t("prefs.row.resolution"), controls: [resolution.view])
        let frameRateRow = formRow(localization.t("prefs.row.frameRate"), controls: [frameRate.view])
        let muteRow = formRow(localization.t("prefs.row.mute"), controls: [mute])
        let separatorA = separatorRow()

        // ② Connection & Session
        let capConnection = groupCap(localization.t("prefs.tab.connection"))
        let deviceRow = formRow(localization.t("prefs.row.deviceName"), controls: [deviceNameField])
        let pinRow = formRow(localization.t("prefs.row.pinChange"), controls: [pinField])
        let trustRow = formRow(localization.t("prefs.row.trusted"), controls: [editTrustButton])
        let sleepRow = formRow(localization.t("prefs.row.preventSleep"), controls: [preventSleep])
        let separatorB = separatorRow()

        // ③ Language (wave1r3: the original Profiles group is withdrawn entirely — ruling ②)
        let capLanguage = groupCap(localization.t("prefs.tab.language"))
        let languageRow = formRowWithLabel(localization.t("prefs.row.language"), controls: [languagePicker])

        for view in [
            capVideo, resolutionRow, frameRateRow, muteRow, separatorA,
            capConnection, deviceRow, pinRow, trustRow, sleepRow, separatorB,
            capLanguage, languageRow.row,
        ] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(Metrics.groupCapBottomGap, after: capVideo)
        stack.setCustomSpacing(Metrics.separatorTopGap, after: muteRow)
        stack.setCustomSpacing(Metrics.separatorBottomGap, after: separatorA)
        stack.setCustomSpacing(Metrics.groupCapBottomGap, after: capConnection)
        stack.setCustomSpacing(Metrics.separatorTopGap, after: sleepRow)
        stack.setCustomSpacing(Metrics.separatorBottomGap, after: separatorB)
        stack.setCustomSpacing(Metrics.groupCapBottomGap, after: capLanguage)

        return SinglePage(
            view: wrapCentredColumn(stack),
            column: stack,
            groupCaps: [capVideo, capConnection, capLanguage],
            resolution: resolution,
            frameRate: frameRate,
            mute: mute,
            deviceNameField: deviceNameField,
            pinField: pinField,
            preventSleep: preventSleep,
            editTrustButton: editTrustButton,
            languagePopup: languagePicker,
            languageRowLabel: languageRow.label
        )
    }

    /// Wraps the form stack as the CENTRED content column: fixed 336 width,
    /// horizontal centre on the page centre, top/bottom pinned (the content is centred as a whole
    /// — ruling ①). The page's height follows the stack; the width is EXACTLY
    /// 336 regardless of label wrapping (the trailing edge is pinned, so a
    /// long label can never inflate the window's minimum width).
    private static func wrapCentredColumn(_ stack: NSStackView) -> NSView {
        let page = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: Metrics.contentColumnWidth),
            stack.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        return page
    }
}
