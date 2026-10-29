import Foundation

/// Presets — the factory baseline (⑫ out-of-the-box defaults; BLUEPRINT arch-3 #5).
///
/// Defaults per the IF-2 fields draft §1 + the PM-adopted values; each field's
/// provenance (spec line / contract line / stub value / PM proposal pending
/// YC's one-line revert) is tabulated in the 2a coding report
/// (the default-value proposal table).
///
/// The `vsync no` baseline (C1) is fixed HERE and deliberately not a
/// SettingModel field: K2 puts it in the baseline permanently, it is never a
/// panel item and never user-editable (contract L394/L786; survey L90).
public enum Presets {

    // MARK: - Factory values (mirrored into `factoryModel`)

    /// A1 — the default broadcast-name body (spec §1 group A note; matches the Stage1
    /// hardcoded `-n MiragePlay`).
    public static let deviceName = "MiragePlay"

    /// A2 — P1: PIN verification defaults OFF.
    public static let pinEnabled = false

    /// A3 — P3: never set at the factory (unset → a per-start random session code).
    public static let pinCode: String? = nil

    /// A4 — table D: 1080p (the upstream default 1920x1080@60; the current stub value).
    public static let resolution = "1080p"

    /// A5 — survey L134 (upstream default 30; the current stub value).
    public static let frameRate = 30

    /// A6 — the stub value false (a PM proposal pending withdrawal).
    public static let muted = false

    /// B1 — ⑩ usable out of the box: on (the stub value true; a PM proposal pending withdrawal).
    public static let preventSleep = true

    /// B2 — ⑪: on (default). D8: the settings-page control was withdrawn,
    /// so this value is a reserved, inert default — it no longer gates the
    /// the NOTIFY record (recording is unconditional). Kept for schema/persistence stability.
    public static let notificationsEnabled = true

    /// B3 — R4-Q1: English by default; S-10 BCP-47 form.
    public static let language = "en"

    /// B4 — the current value in the settings UI (the profile popup's factory name;
    /// PreferencesFormViews.swift:442).
    public static let profileName = "預設"

    /// C2 — S-6(a): structure reserved, always empty in v1.
    public static let rcPassThrough: [String] = []

    /// C1 — fixed `vsync no` baseline (S-5=A dual form).
    public static let vsyncDisabled = true

    // MARK: - Value domains (S-16③ / P-7 implementation domains)

    /// A4 domain (PreferencesFormViews.resolutionSteps).
    public static let resolutionLabels = ["480p", "720p", "1080p", "1440p", "2160p"]

    /// A5 domain (PreferencesFormViews.frameRateSteps).
    public static let frameRates = [15, 30, 45, 60, 120]

    /// The B3 domain (contract L136: pick one of three; the S-10 BCP-47 candidate form).
    public static let languages = ["en", "zh-Hant", "zh-Hans"]

    // MARK: - Factory model

    /// The factory seed model (fresh install / no persisted settings yet).
    public static let factoryModel = SettingModel(
        deviceName: deviceName,
        pinEnabled: pinEnabled,
        pinCode: pinCode,
        resolution: resolution,
        frameRate: frameRate,
        muted: muted,
        preventSleep: preventSleep,
        notificationsEnabled: notificationsEnabled,
        language: language,
        profileName: profileName,
        rcPassThrough: rcPassThrough
    )
}
