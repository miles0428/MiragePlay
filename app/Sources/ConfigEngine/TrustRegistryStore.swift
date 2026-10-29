import Foundation

/// TrustRegistryStore — wave1r4 (trust increment): the `registration.list` I/O unit.
///
/// The file IS the uxplay trust registry (`-reg <path>`; production path =
/// `KeyVault.regPath`, AppSupport only — the six-B group D red line). Upstream format
/// (uxplay.cpp:2625-2631, one line per registered client, `\n`-terminated):
///
///     <pk64>,<deviceID>,<name>
///
/// Upstream's own loader blind-cuts at `line[44]` (uxplay.cpp:3158-3159), so
/// every written line MUST be well-formed — no blank or short lines (the I3 line-format rule).
///
/// Read side (tolerant): empty/malformed lines are skipped; entries are
/// deduped by machine code — a re-paired device appends a second line and the
/// LAST occurrence wins (it carries the freshest name cache).
///
/// Write side (ONE mechanism, shared by the dialog's do-not-trust / the editor's ✕ / one-click Reset —
/// the I6 write-side seam; the settings/state semantics stay in the AppShell):
///   - `remove(deviceID:)`: drop every line of that device (all duplicates)
///     AND empty/malformed lines; every OTHER valid line is preserved
///     VERBATIM (split limit 2 — names may contain commas/blanks); the file
///     is rewritten atomically (temp→rename; the same `.atomic` precedent as
///     `RcArgvSnap.writeRcFile` / `ProfileStore.saveCurrent`);
///   - `reset()`: the file truncates to 0 bytes (an empty file is safe: the upstream
///     loader reads zero lines).
///
/// M2 timing note (it does not kick in this session): this type only writes the FILE — nothing here
/// restarts the receiver or touches E1. The new list takes effect at the next
/// touches a uxplay spawn (it takes effect on the next start or the next app launch).
public final class TrustRegistryStore {

    public enum StoreError: Error, Equatable {
        case writeFailed(path: String, reason: String)
    }

    /// One valid registry line.
    public struct Entry: Equatable {
        /// The machine code (deviceID) — the persisted key.
        public let machineCode: String
        /// The name cache (it may be empty in the raw file; tolerated).
        public let name: String
        /// The client public key (pk64 — field 0 of the raw line).
        public let pk: String

        public init(machineCode: String, name: String, pk: String) {
            self.machineCode = machineCode
            self.name = name
            self.pk = pk
        }
    }

    /// What one `remove(deviceID:)` did — evidence-line material.
    public struct RemovalReport: Equatable {
        /// Lines matched and dropped (ALL duplicates of the target).
        public let removed: Int
        /// Valid lines kept (verbatim).
        public let kept: Int
        /// Empty/malformed lines dropped while rewriting.
        public let dropped: Int

        public init(removed: Int, kept: Int, dropped: Int) {
            self.removed = removed
            self.kept = kept
            self.dropped = dropped
        }
    }

    /// The registry file path (production: `KeyVault.regPath`).
    public let regPath: URL

    public init(regPath: URL) {
        self.regPath = regPath
    }

    // MARK: - Read (tolerant)

    /// Parses the registry; tolerant of empty/short/corrupt lines. Deduped by
    /// machine code — the LAST line for a device wins.
    public func entries() -> [Entry] {
        guard let text = readText() else { return [] }
        var result: [Entry] = []
        var indexByCode: [String: Int] = [:]
        for line in Self.lines(of: text) {
            guard let entry = Self.parse(line) else { continue }
            if let index = indexByCode[entry.machineCode] {
                result[index] = entry
            } else {
                indexByCode[entry.machineCode] = result.count
                result.append(entry)
            }
        }
        return result
    }

    // MARK: - Write (single mechanism)

    /// Removes every line belonging to `deviceID` and rewrites the file
    /// atomically (see the type doc for the exact keep/drop rules).
    @discardableResult
    public func remove(deviceID: String) throws -> RemovalReport {
        let text = readText() ?? ""
        var kept: [String] = []
        var removed = 0
        var dropped = 0
        for line in Self.lines(of: text) {
            guard let entry = Self.parse(line) else {
                dropped += 1
                continue
            }
            if entry.machineCode == deviceID {
                removed += 1
                continue
            }
            kept.append(line)
        }
        let body = kept.map { $0 + "\n" }.joined()
        try writeAtomically(body)
        return RemovalReport(removed: removed, kept: kept.count, dropped: dropped)
    }

    /// Reset — truncates the registry to 0 bytes (I3; an empty file is safe).
    public func reset() throws {
        try writeAtomically("")
    }

    // MARK: - Line handling

    /// The lines of the file body — the trailing terminator does not count as
    /// a line; CR is stripped defensively (upstream writes LF).
    static func lines(of text: String) -> [String] {
        var raw = text.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        return raw.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Parses one line into an entry, or nil when it is empty/malformed.
    /// Split limit 2: the name (field 3) may itself contain commas.
    static func parse(_ line: String) -> Entry? {
        let parts = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let pk = String(parts[0])
        let machineCode = String(parts[1])
        let name = String(parts[2])
        // pk64 = 44 chars (32-byte key, base64; upstream blind-cuts at 44 —
        // anything shorter would corrupt the loader's key list).
        guard pk.count >= 44, !machineCode.isEmpty else { return nil }
        return Entry(machineCode: machineCode, name: name, pk: pk)
    }

    // MARK: - Private

    private func readText() -> String? {
        guard let data = try? Data(contentsOf: regPath) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Atomic rewrite (temp→rename; the same `.atomic` mechanism as
    /// `RcArgvSnap.writeRcFile` / `ProfileStore.saveCurrent`). Creates the
    /// support directory when missing (first write on a fresh install).
    private func writeAtomically(_ body: String) throws {
        let directory = regPath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: regPath, options: .atomic)
        } catch {
            throw StoreError.writeFailed(path: regPath.path, reason: error.localizedDescription)
        }
    }
}
