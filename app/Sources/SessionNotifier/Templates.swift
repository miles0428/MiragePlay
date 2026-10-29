import Foundation
import Localization

/// Templates — ⑪ the notification text templates (BLUEPRINT arch-3 #7 "Templates.swift = the text templates").
///
/// stage G (wave1g) language: the texts are dictionary lookups
/// (the §B j fallback values: ["notify.connected"/"notify.disconnected"] —
/// "Connected to <device name>"/"Disconnected" [EN], "Connected: <device name>"/
/// "Disconnected" [zh-Hant]) rendered in the language selected at dispatch time, so a
/// notification always carries the language in force when it fires
/// (instant switchover; the panel status row keeps the same phrasing per the §B table).
///
/// These are still fallback values, NOT the final strings: the notification FORM
/// (banner vs the panel's dropdown list) is R5-Q1, still undecided — the texts are
/// finalised together with that ruling ("the copy is finalised with R5").
///
/// A `nil` service (an unwired composition; production always wires one) renders
/// the term key — the same honest convention as a missing dictionary in
/// `LanguageService`, never a second hard-coded text source.
enum SessionNotificationTemplates {

    /// The connected-notification text ("Connected: <device name>" / "Connected to <device>").
    public static func connected(device: String, localization: LanguageService?) -> String {
        guard let localization else { return "notify.connected" }
        return localization.t("notify.connected", device)
    }

    /// The disconnected-notification text ("Disconnected").
    public static func disconnected(localization: LanguageService?) -> String {
        guard let localization else { return "notify.disconnected" }
        return localization.t("notify.disconnected")
    }
}
