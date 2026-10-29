import Foundation
import ConfigEngine

/// Tests ④ (wave1r4) — trust registry (`registration.list`) I/O:
/// tolerant read + dedupe, the shared remove mechanism (drop ALL duplicates,
/// keep other lines VERBATIM, atomic write), reset (truncate 0), and the
/// line-format discipline (no empty/short lines ever written — the upstream
/// loader blind-cuts at `line[44]`, uxplay.cpp:3158-3159).
enum TrustRegistrySuite {

    static func runAll() {
        runCase("④a tolerant read + dedupe (last wins)") { try tolerantReadAndDedupe() }
        runCase("④b remove: all duplicates out, others byte-verbatim") { try removeKeepsOthersVerbatim() }
        runCase("④c reset: truncate to 0 bytes (absent file included)") { try resetTruncatesToZero() }
        runCase("④d line-format discipline: output carries no empty/short lines") { try lineFormatDiscipline() }
    }

    static let fm = FileManager.default

    /// pk64 = 44 chars (base64 of a 32-byte key). Distinct per fixture line
    /// so verbatim-keeping can be asserted byte-for-byte.
    static func pk(_ seed: Character) -> String {
        String(repeating: seed, count: 43) + "="
    }

    // MARK: - ④a tolerant read + dedupe

    static func tolerantReadAndDedupe() throws {
        let dir = try TestSupport.freshScratch("trust-registry-read")
        defer { TestSupport.removeScratch(dir) }
        let reg = dir.appendingPathComponent("registration.list")

        let fixture = """
        \(pk("A")),AA:BB:CC:00:00:01,測試機甲
        \(pk("B")),AA:BB:CC:00:00:02,測試機乙

        short-line
        \(pk("C")),AA:BB:CC:00:00:03,測試機丙

        \(pk("D")),AA:BB:CC:00:00:01,測試機甲（更新名）
        \(pk("E")),AA:BB:CC:00:00:04,名字,含逗號
        """
        try Data(fixture.utf8).write(to: reg)

        let store = TrustRegistryStore(regPath: reg)
        let entries = store.entries()
        TestReporter.equal(entries.count, 4,
                           "read: malformed/short/empty lines skipped; duplicate device deduped")
        TestReporter.equal(entries.map { $0.machineCode },
                           ["AA:BB:CC:00:00:01", "AA:BB:CC:00:00:02", "AA:BB:CC:00:00:03", "AA:BB:CC:00:00:04"],
                           "read: dedupe keeps first-seen order")
        TestReporter.equal(entries[0].name, "測試機甲（更新名）",
                           "read: the LAST duplicate wins (freshest name cache)")
        TestReporter.equal(entries[3].name, "名字,含逗號",
                           "read: the name field may contain commas (split limit 2)")

        // Missing file → empty list, no side effects.
        let absent = TrustRegistryStore(regPath: dir.appendingPathComponent("nope.list"))
        TestReporter.equal(absent.entries().count, 0, "read: absent file → empty list")
        TestReporter.check(!fm.fileExists(atPath: dir.appendingPathComponent("nope.list").path),
                           "read: must not create the file")

        TestSupport.writeEvidence("05-trust-registry-read.txt", [
            "fixture:", TestSupport.renderLines(fixture),
            "entries: \(entries.map { "\($0.machineCode)=\($0.name)" })",
        ].joined(separator: "\n") + "\n")
    }

    // MARK: - ④b remove

    static func removeKeepsOthersVerbatim() throws {
        let dir = try TestSupport.freshScratch("trust-registry-remove")
        defer { TestSupport.removeScratch(dir) }
        let reg = dir.appendingPathComponent("registration.list")

        let lineA = "\(pk("A")),AA:BB:CC:00:00:01,測試機甲"
        let lineB1 = "\(pk("B")),AA:BB:CC:00:00:02,測試機乙"
        let lineB2 = "\(pk("C")),AA:BB:CC:00:00:02,測試機乙（重配對）"
        let lineD = "\(pk("D")),AA:BB:CC:00:00:04,名字,含逗號"
        let fixture = "\(lineA)\n\(lineB1)\nbroken\n\(lineB2)\n\n\(lineD)\n"
        try Data(fixture.utf8).write(to: reg)

        let store = TrustRegistryStore(regPath: reg)
        let report = try store.remove(deviceID: "AA:BB:CC:00:00:02")
        TestReporter.equal(report.removed, 2, "remove: ALL duplicates of the target dropped")
        TestReporter.equal(report.kept, 2, "remove: other valid lines kept")
        TestReporter.equal(report.dropped, 2, "remove: malformed + empty lines dropped with evidence")

        let after = try String(contentsOf: reg, encoding: .utf8)
        TestReporter.equal(after, "\(lineA)\n\(lineD)\n",
                           "remove: kept lines are byte-verbatim (names with commas survive; no dup leftovers)")

        // No temp leftovers — the atomic write cleans up after itself.
        TestReporter.equal(try fm.contentsOfDirectory(atPath: dir.path).sorted(),
                           ["registration.list"], "remove: atomic write leaves no temp files")

        // Removing an unknown device: report 0 removed; file still normalized.
        let second = try store.remove(deviceID: "AA:BB:CC:00:00:99")
        TestReporter.equal(second.removed, 0, "remove: unknown device → removed=0")
        TestReporter.equal(try String(contentsOf: reg, encoding: .utf8), "\(lineA)\n\(lineD)\n",
                           "remove: unknown device → other lines untouched")

        // Removing every device → 0-byte file (still a valid registry).
        try store.remove(deviceID: "AA:BB:CC:00:00:01")
        try store.remove(deviceID: "AA:BB:CC:00:00:04")
        let size = (try fm.attributesOfItem(atPath: reg.path)[.size] as? NSNumber)?.intValue ?? -1
        TestReporter.equal(size, 0, "remove: emptying the registry yields a 0-byte file")

        TestSupport.writeEvidence("06-trust-registry-remove.txt", [
            "fixture:", TestSupport.renderLines(fixture),
            "report: removed=\(report.removed) kept=\(report.kept) dropped=\(report.dropped)",
            "after:", TestSupport.renderLines("\(lineA)\n\(lineD)\n"),
        ].joined(separator: "\n") + "\n")
    }

    // MARK: - ④c reset

    static func resetTruncatesToZero() throws {
        let dir = try TestSupport.freshScratch("trust-registry-reset")
        defer { TestSupport.removeScratch(dir) }
        let reg = dir.appendingPathComponent("registration.list")

        try Data("\(pk("A")),AA:BB:CC:00:00:01,測試機甲\n".utf8).write(to: reg)
        let store = TrustRegistryStore(regPath: reg)
        try store.reset()
        let size = (try fm.attributesOfItem(atPath: reg.path)[.size] as? NSNumber)?.intValue ?? -1
        TestReporter.equal(size, 0, "reset: existing file truncated to 0 bytes")
        TestReporter.equal(store.entries().count, 0, "reset: reads back empty")

        // Absent file → reset still yields a 0-byte registry (idempotent).
        let absent = TrustRegistryStore(regPath: dir.appendingPathComponent("new.list"))
        try absent.reset()
        let newSize = (try fm.attributesOfItem(atPath: dir.appendingPathComponent("new.list").path)[.size] as? NSNumber)?.intValue ?? -1
        TestReporter.equal(newSize, 0, "reset: absent file → created empty (0 bytes)")
    }

    // MARK: - ④d line-format discipline

    static func lineFormatDiscipline() throws {
        let dir = try TestSupport.freshScratch("trust-registry-format")
        defer { TestSupport.removeScratch(dir) }
        let reg = dir.appendingPathComponent("registration.list")

        // A file with every kind of corruption the tolerant reader must handle.
        let fixture = "\(pk("A")),AA:BB:CC:00:00:01,測試機甲\nx\n\n\(pk("B")),AA:BB:CC:00:00:02,測試機乙\r\n"
        try Data(fixture.utf8).write(to: reg)

        let store = TrustRegistryStore(regPath: reg)
        _ = try store.remove(deviceID: "AA:BB:CC:00:00:01")
        let after = try String(contentsOf: reg, encoding: .utf8)
        TestReporter.equal(after, "\(pk("B")),AA:BB:CC:00:00:02,測試機乙\n",
                           "format: CR stripped, no empty/short lines remain")

        // Every written line must satisfy the upstream loader's structure:
        // at least 44 chars of pk before the first comma (blind cut at 44).
        for line in after.split(separator: "\n") {
            let pkField = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            TestReporter.check(pkField.count >= 44, "format: pk field ≥ 44 chars (line: \(line.prefix(12))…)")
        }
    }
}
