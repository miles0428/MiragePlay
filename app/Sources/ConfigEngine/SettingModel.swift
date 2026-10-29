import Foundation

/// SettingModel — the ⑫ single model: every v1 fine-grained item in one value type
/// (BLUEPRINT arch-3 #5 "⑫ a single model of fine-grained per-feature items").
///
/// Field list = the full IF-2 11-column set (spec §1 tables A/B + the C2 channel
/// structure; the C1 `vsync no` baseline lives in `Presets`, not here):
///
///   A1 deviceName            — broadcast-name body (suffix appended upstream)
///   A2 pinEnabled            — PIN switch (P1: default off)
///   A3 pinCode               — the set code; nil = unset (P3)
///   A4 resolution            — "480p"…"2160p" (table D is mapped at serialization)
///   A5 frameRate             — 15/30/45/60/120
///   A6 muted                 — `-a`
///   B1 preventSleep          — shell-held (never serialized; E1 exception)
///   B2 notificationsEnabled  — shell-held
///   B3 language              — BCP-47 ("en"/"zh-Hant"/"zh-Hans"; S-10)
///   B4 profileName           — currently active profile name
///   C2 rcPassThrough         — K2 channel structure (v1 kept empty; S-6(a))
///
/// P3 / R3-Q1 semantics carried by `pinCode`: nil means unset (never changed) — a
/// fresh random session code is generated at every receiver start and never
/// persisted; non-nil means set (changed) — the code is reused across starts and
/// survives restarts (auto write-back). The per-start regeneration rule itself
/// lives in `PinCode` + the engine, not in the stored value.
public struct SettingModel: Codable, Equatable, Sendable {

    /// A1 — broadcast-name body (never carries the `@hostname` suffix).
    public var deviceName: String

    /// A2 — PIN verification switch (P1 default: off).
    public var pinEnabled: Bool

    /// A3 — the set code ("0001"…"9999"); nil = unset (P3).
    public var pinCode: String?

    /// A4 — resolution label; domain = `Presets.resolutionLabels`.
    public var resolution: String

    /// A5 — frame-rate cap; domain = `Presets.frameRates`.
    public var frameRate: Int

    /// A6 — mute.
    public var muted: Bool

    /// B1 — prevent sleep while the receiver runs.
    public var preventSleep: Bool

    /// B2 — connection notifications.
    public var notificationsEnabled: Bool

    /// B3 — UI language, BCP-47 (S-10).
    public var language: String

    /// B4 — name of the currently active settings profile.
    public var profileName: String

    /// C2 — rc pass-through channel (verbatim rc lines). v1: structure only.
    public var rcPassThrough: [String]

    public init(
        deviceName: String,
        pinEnabled: Bool,
        pinCode: String?,
        resolution: String,
        frameRate: Int,
        muted: Bool,
        preventSleep: Bool,
        notificationsEnabled: Bool,
        language: String,
        profileName: String,
        rcPassThrough: [String]
    ) {
        self.deviceName = deviceName
        self.pinEnabled = pinEnabled
        self.pinCode = pinCode
        self.resolution = resolution
        self.frameRate = frameRate
        self.muted = muted
        self.preventSleep = preventSleep
        self.notificationsEnabled = notificationsEnabled
        self.language = language
        self.profileName = profileName
        self.rcPassThrough = rcPassThrough
    }
}
