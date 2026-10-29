import Foundation
import ConfigEngine
import SharedTypes

/// A tiny deterministic generator for the PinCode seam.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Test ④ — PinCode P1-P3 / P6 semantics: unset vs set, and the changePin API.
enum PinCodeSuite {

    static func runAll() {
        runCase("④a P1: factory default off") { try factoryDefaultIsP1Off() }
        runCase("④b unset: per-start regeneration (session-only)") { try neverSetModeRegeneratesEachStart() }
        runCase("④c user-set: reuse across starts and restarts; changePin") { try userSetModeReusesAcrossStartsAndRestarts() }
        runCase("④d toggle off clears wire, on shows a code") { try toggleOffClearsWireAndOnAgainShowsCode() }
        runCase("④e generator domain + validity") { generatorDomainAndValidity() }
    }

    // MARK: - P1: default off

    static func factoryDefaultIsP1Off() throws {
        TestReporter.check(!Presets.factoryModel.pinEnabled, "P1: pinEnabled off at factory")
        TestReporter.isNil(Presets.factoryModel.pinCode, "P3: no code at factory (unset)")

        let dir = try TestSupport.freshScratch("pin-default")
        defer { TestSupport.removeScratch(dir) }
        let engine = TestSupport.isolatedEngine(scratch: dir)
        let snap = engine.effectiveSnapshot()
        TestReporter.check(!snap.pinEnabled, "snap pinEnabled off")
        TestReporter.isNil(snap.pinCode, "snap pinCode nil")
        TestReporter.check(!snap.argv().contains("-pin"), "no -pin in argv")
        TestReporter.check(snap.argv().joined(separator: " ").contains("-vsync no"), "baseline present")
    }

    // MARK: - The unset mode: per-start regeneration (session-only)

    static func neverSetModeRegeneratesEachStart() throws {
        let dir = try TestSupport.freshScratch("pin-unset")
        defer { TestSupport.removeScratch(dir) }
        let engine = TestSupport.isolatedEngine(scratch: dir)

        engine.setPinEnabled(true)
        // P2: flipping PIN on yields a displayable random 4-digit code.
        guard let displayCode = TestReporter.require(engine.effectiveSnapshot().pinCode, "display code after toggle-on") else { return }
        TestReporter.check(PinCode.isValidCode(displayCode), "display code is a valid 0001-9999 form")

        // unset → every receiver start generates a fresh code; the code is
        // stable within a session (P3 "the code does not change while the receiver runs").
        var codes: [String] = []
        for _ in 0..<6 {
            let snapshot = try engine.prepareForReceiverStart()
            guard let code = TestReporter.require(snapshot.pinCode, "start code") else { return }
            TestReporter.check(PinCode.isValidCode(code), "start code is valid")
            TestReporter.equal(engine.effectiveSnapshot().pinCode, code, "code stable within session")
            TestReporter.check(snapshot.argv().joined(separator: " ").contains("-pin \(code)"), "-pin carries the code")
            TestReporter.check(snapshot.rcText().contains("pin \(code)\n"), "rc pin carries the code")
            codes.append(code)
        }
        TestReporter.check(Set(codes).count > 1, "unset mode regenerates across starts")

        // Unset codes are never persisted — the model stays unset.
        TestReporter.isNil(engine.currentModel.pinCode, "model stays unset")
        TestReporter.isNil(try ProfileStore(rootDirectory: dir.appendingPathComponent("support")).loadCurrent()?.pinCode,
                           "persisted file stays unset (pinCode null)")

        let evidence = [
            "mode: unset (never changed)",
            "display code after toggle-on: \(displayCode)",
            "codes across 6 starts: \(codes)",
            "distinct: \(Set(codes).count)",
            "model.pinCode persisted: null",
        ].joined(separator: "\n") + "\n"
        TestSupport.writeEvidence("05-pin-unset-states.txt", evidence)
    }

    // MARK: - The set mode: reused across starts and restarts; the changePin API

    static func userSetModeReusesAcrossStartsAndRestarts() throws {
        let dir = try TestSupport.freshScratch("pin-set")
        defer { TestSupport.removeScratch(dir) }
        let engine = TestSupport.isolatedEngine(scratch: dir)

        engine.setPinEnabled(true)
        let code0 = engine.changePin()                 // P6 regenerate button
        TestReporter.check(PinCode.isValidCode(code0), "changePin returns a valid code")
        TestReporter.equal(engine.currentModel.pinCode, code0, "changed → persisted user-set")

        // set → reused on every start.
        for _ in 0..<3 {
            TestReporter.equal(try engine.prepareForReceiverStart().pinCode, code0, "user-set reused on start")
        }

        // Restart (fresh engine over the same support dir) reuses the code.
        let engine2 = TestSupport.isolatedEngine(scratch: dir)
        TestReporter.equal(engine2.currentModel.pinCode, code0, "user-set survives restart (model)")
        TestReporter.equal(engine2.effectiveSnapshot().pinCode, code0, "user-set survives restart (snapshot)")
        TestReporter.equal(try engine2.prepareForReceiverStart().pinCode, code0, "user-set reused after restart")

        // regenerate again → a new code (the retry guards the 1/9999 collision), still reused.
        var code1 = engine2.changePin()
        var attempts = 0
        while code1 == code0 && attempts < 20 {
            code1 = engine2.changePin()
            attempts += 1
        }
        TestReporter.check(code1 != code0, "second change yields a different code")
        TestReporter.equal(engine2.currentModel.pinCode, code1, "new code persisted")
        TestReporter.equal(try engine2.prepareForReceiverStart().pinCode, code1, "new code reused on next start")

        TestSupport.writeEvidence("06-pin-set-states.txt", [
            "mode: user-set (changed)",
            "changePin() code0: \(code0) — reused across 3 starts + restart",
            "changePin() code1: \(code1) — reused on next start",
            "persisted pinCode: \(engine2.currentModel.pinCode ?? "nil")",
        ].joined(separator: "\n") + "\n")
    }

    // MARK: - toggle semantics (P2) + switch-side clearing

    static func toggleOffClearsWireAndOnAgainShowsCode() throws {
        let dir = try TestSupport.freshScratch("pin-toggle")
        defer { TestSupport.removeScratch(dir) }
        let engine = TestSupport.isolatedEngine(scratch: dir)

        engine.setPinEnabled(true)
        TestReporter.notNil(engine.effectiveSnapshot().pinCode, "PIN on → code exists")
        TestReporter.check(engine.effectiveSnapshot().argv().contains("-pin"), "PIN on → -pin present")

        engine.setPinEnabled(false)
        TestReporter.isNil(engine.effectiveSnapshot().pinCode, "PIN off → code nil")
        TestReporter.check(!engine.effectiveSnapshot().argv().contains("-pin"), "PIN off → no -pin")

        engine.setPinEnabled(true)
        TestReporter.notNil(engine.effectiveSnapshot().pinCode, "PIN back on → code exists")
    }

    // MARK: - Generator domain (S-7) + validity

    static func generatorDomainAndValidity() {
        // "0000" is rejected by upstream (uxplay.cpp:1093-1102) — excluded.
        TestReporter.check(!PinCode.isValidCode("0000"), "\"0000\" invalid")
        TestReporter.check(PinCode.isValidCode("0001"), "\"0001\" valid")
        TestReporter.check(PinCode.isValidCode("9999"), "\"9999\" valid")
        TestReporter.check(!PinCode.isValidCode("10000"), "5 digits invalid")
        TestReporter.check(!PinCode.isValidCode("12a4"), "non-digit invalid")
        TestReporter.check(!PinCode.isValidCode(""), "empty invalid")

        for _ in 0..<500 {
            let code = PinCode.randomCode()
            TestReporter.check(code.count == 4 && PinCode.isValidCode(code), "random code in domain: \(code)")
        }

        // The generator seam is deterministic for a fixed seed.
        var seededA = SeededGenerator(seed: 42)
        var seededB = SeededGenerator(seed: 42)
        TestReporter.equal(PinCode.randomCode(using: &seededA), PinCode.randomCode(using: &seededB),
                           "seeded generator is deterministic")

        // P3 decision seam: stored → reused, nil → fresh valid code.
        TestReporter.equal(PinCode.codeForReceiverStart(storedCode: "0001"), "0001", "stored code reused")
        var seeded = SeededGenerator(seed: 7)
        let fresh = PinCode.codeForReceiverStart(storedCode: nil, using: &seeded)
        TestReporter.check(PinCode.isValidCode(fresh), "fresh code valid")
    }
}
