import Foundation
import IOKit.pwr_mgt

/// SleepAssertion — J3-5a ⑩ prevent-sleep (the smallest responsibility unit; BLUEPRINT arch-3 #6).
///
/// Holds one IOKit power assertion that keeps the display (and, with it, the
/// idle system-sleep path) awake while a receiver session runs. The
/// acquisition POLICY is deliberately NOT owned here — SRP-5: no config
/// state, no windows, no cross-imports. The AppShell drives it:
///   - `enable()` on the receiver entering a started state (scope = while the receiver runs
///     = the r6-K1 mechanical default);
///   - `disable()` whenever the receiver is stopped / not started (red line: the assertion
///     must already be released in the receiver's stopped state);
///   - prevent-sleep switch flips re-apply immediately WITHOUT touching the receiver
///     (E1 exception: shell-held, effective at once, receiver untouched).
///
/// Implementation choice (contract arch-3 #6 leaves it to coding): direct IOKit
/// `IOPMAssertion` — preferred over a `caffeinate` subprocess (survey L94
/// "macOS requires doing it all ourselves"; no extra process to manage, and `deinit` releases as a
/// safety net). Assertion type = `PreventUserIdleDisplaySleep`: the
/// projection session needs the display awake (r4-Q1 "the screen must not sleep during class = a hard requirement");
/// holding the display awake also keeps the machine from starting the idle
/// sleep sequence — one assertion covers display/system per the contract's
/// "one assertion, one pair of switches".
///
/// Observable effect (the testable anchor, scripts/test-sleep-notify.sh):
/// `pmset -g assertions` lists
/// `pid <app>(MiragePlay): … PreventUserIdleDisplaySleep named:
/// "MiragePlay SleepGuard (receiver session)"` while held; the line
/// disappears the moment the assertion is released.
public final class SleepAssertion {

    /// Reason string shown by `pmset -g assertions` — dev-facing OS
    /// identifier, NOT a UI string. Deliberately ASCII: measured on this
    /// machine, pmset's `named:` field renders non-ASCII names as ""
    /// (CJK probe → `named: ""`), so an ASCII name is what makes the
    /// held/released state actually readable in the power-assertion anchor.
    public static let assertionName = "MiragePlay SleepGuard (receiver session)"

    /// The held assertion id (0 = none held).
    private var assertionID: IOPMAssertionID = 0

    public init() {}

    /// Safety net: a `SleepAssertion` that goes away must never leave the
    /// assertion behind (the backstop for the "release in the stopped state" red line — the AppShell releases
    /// explicitly; the kernel would also reap it at process exit).
    deinit {
        disable()
    }

    /// Whether the power assertion is currently held.
    public var isActive: Bool { assertionID != 0 }

    /// Acquires the power assertion if it is not already held.
    ///
    /// - Returns: `true` when this call acquired it (off→on transition);
    ///   `false` when it was already held or the acquisition failed
    ///   (inspect `isActive` to distinguish).
    @discardableResult
    public func enable() -> Bool {
        guard assertionID == 0 else { return false }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return false }
        assertionID = id
        return true
    }

    /// Releases the power assertion if it is held (idempotent).
    ///
    /// - Returns: `true` when this call released it (on→off transition);
    ///   `false` when nothing was held.
    @discardableResult
    public func disable() -> Bool {
        guard assertionID != 0 else { return false }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        return true
    }
}
