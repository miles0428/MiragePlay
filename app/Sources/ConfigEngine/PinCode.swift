import Foundation

/// PinCode — the P1-P3 / P6 / R3-Q1 rule engine for the PIN code itself
/// (the BLUEPRINT appendix P table; IF-2 draft §1 A3 + S-7).
///
/// Division of duties with `SettingModel.pinCode`:
///   - set (changed): the user-set code is stored in the model (non-nil) and
///     reused on every receiver start; it persists across app restarts.
///   - unset (never changed): `model.pinCode == nil`; every receiver start generates
///     a fresh random code. That code is SESSION-ONLY (kept in the engine's
///     `sessionPinCode`, never written back to the model, never persisted).
///   - The regenerate button (P6) calls `changePin()`: a fresh random code → becomes
///     set → reused thereafter.
///
/// Code domain (S-7): 0001–9999 displayed zero-padded to 4 digits; "0000" is
/// rejected by upstream (`get_value` refuses 0 — uxplay.cpp:1093-1102) and is
/// excluded by construction.
public enum PinCode {

    /// S-7: the code range is 0001–9999 (avoiding "0000", which upstream rejects).
    public static let codeRange: ClosedRange<Int> = 1...9999

    /// Generates a random 4-digit code string ("0001"…"9999", zero-padded).
    /// Generic over the generator so tests can drive it deterministically.
    public static func randomCode<G: RandomNumberGenerator>(using generator: inout G) -> String {
        String(format: "%04d", Int.random(in: codeRange, using: &generator))
    }

    /// Generates a random 4-digit code string using the system generator.
    public static func randomCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return randomCode(using: &generator)
    }

    /// P3: the code to use for a receiver start.
    /// set (changed) → the stored code is reused; unset → a fresh random code.
    public static func codeForReceiverStart<G: RandomNumberGenerator>(
        storedCode: String?,
        using generator: inout G
    ) -> String {
        if let stored = storedCode { return stored }
        return randomCode(using: &generator)
    }

    /// P3: the code to use for a receiver start (system generator).
    public static func codeForReceiverStart(storedCode: String?) -> String {
        var generator = SystemRandomNumberGenerator()
        return codeForReceiverStart(storedCode: storedCode, using: &generator)
    }

    /// True when `code` is a 4-digit string inside 0001–9999 (display form).
    public static func isValidCode(_ code: String) -> Bool {
        guard code.count == 4, code.allSatisfy(\.isNumber), let value = Int(code) else {
            return false
        }
        return codeRange.contains(value)
    }
}
