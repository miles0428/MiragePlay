import ConfigEngine
import SettingsUI

/// TrustRegistryHandler — wave1r4 (trust increment I6): the ONE trust-registry
/// write side (the write-side seam, new).
///
/// Every removal path funnels through this single writer instance:
///   ① the trust prompt's do-not-trust answer (origin=prompt),
///   ② the editor's per-row ✕ (origin=editor),
///   ③ the editor's one-click Reset (origin=editor).
/// Trust (remember) is the KEEP path — zero action (registration is already a fact;
///
/// wave1r6 (trust timing fix; YC ruling overturned M2) — this type still only writes the
/// FILE (no receiver/E1 side effects here — the decision layer is LifecycleCoordinator),
/// but every removal now REPORTS whether it actually changed the registry
/// (removed ≥ 1); the AppShell turns that into the pending-apply flag whose
/// boundary semantics are "apply on disconnect" (T1) plus the "answer only after
/// Evidence: one `TRUST …` line per decision on the UILog channel
/// (`<NSTemporaryDirectory()>/com.ycchung.mirageplay/ui.log`, or the file named
/// by `MIRAGE_PLAY_UI_LOG`) — parseable by scripts/tests/test-trust.sh.
final class TrustRegistryHandler {

    private let store: TrustRegistryStore

    init(store: TrustRegistryStore) {
        self.store = store
    }

    /// Answering "trust" = remember = keep the registry: zero action (registration is
    func keep(deviceID: String, origin: String) {
        UILog.line("TRUST keep origin=\(origin) deviceID=\(deviceID) (remember — registry untouched)")
    }

    /// removal (file write) — shared by the dialog's do-not-trust / ✕.
    /// Returns `true` when the write actually removed ≥ 1 registry line
    /// (the AppShell decision layer raises the pending-apply flag on it;
    /// a repeat click on an already-removed device returns `false`).
    @discardableResult
    func removeDevice(machineCode: String, origin: String) -> Bool {
        do {
            let report = try store.remove(deviceID: machineCode)
            UILog.line(
                "TRUST remove origin=\(origin) deviceID=\(machineCode)"
                    + " removed=\(report.removed) kept=\(report.kept) dropped=\(report.dropped)"
            )
            return report.removed > 0
        } catch {
            UILog.line(
                "TRUST remove failed origin=\(origin) deviceID=\(machineCode)"
                    + " error=\(error.localizedDescription)"
            )
            return false
        }
    }

    /// Reset (truncate 0) — shared by the editor's one-click Reset.
    /// `rows` = the row count the editor showed (evidence only).
    /// Returns `true` when ≥ 1 valid entry was actually removed.
    @discardableResult
    func resetAll(origin: String, rows: Int) -> Bool {
        do {
            let removed = store.entries().count
            try store.reset()
            UILog.line("TRUST reset origin=\(origin) rows=\(rows) removed=\(removed) (file truncated to 0)")
            return removed > 0
        } catch {
            UILog.line(
                "TRUST reset failed origin=\(origin) rows=\(rows)"
                    + " error=\(error.localizedDescription)"
            )
            return false
        }
    }
}
