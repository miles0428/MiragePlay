import Foundation
import ConfigEngine
import SharedTypes

/// Tests ⑤⑥ — the two red lines of the 2a card:
///   ⑤ identity material (server keypair `-key` / register `-reg` family)
///      lands ONLY in `~/Library/Application Support/com.ycchung.mirageplay/`
///      — never inside the repo (the first line of defence for the six-B group D);
///   ⑥ zero classroom wording (and the "teaching mode" synonym ban) in the
///      ConfigEngine/SharedTypes sources and in every serialized artifact.
enum RedLineSuite {

    static func runAll() {
        runCase("⑤a KeyVault paths land in AppSupport only") { try keyVaultPathsLandInAppSupport() }
        runCase("⑤b engine gates identity paths by PIN") { try engineGatesIdentityPathsByPIN() }
        runCase("⑤c repo has zero identity-material files") { try repoHasNoIdentityMaterialFiles() }
        runCase("⑥ zero classroom wording (sources + artifacts)") { try zeroClassroomWordingInSourcesAndArtifacts() }
    }

    // MARK: - ⑤ identity material: AppSupport only

    static func keyVaultPathsLandInAppSupport() throws {
        let vault = KeyVault(bundleID: "com.ycchung.mirageplay")

        // Independent derivation of the expected location.
        TestReporter.check(TestSupport.pathsEqual(vault.supportDirectory.path, TestSupport.appSupportDir.path),
                           "support dir = ~/Library/Application Support/com.ycchung.mirageplay")
        TestReporter.check(TestSupport.pathsEqual(
            vault.keyPath.path,
            TestSupport.appSupportDir.appendingPathComponent("server.pem").path), "keyPath under AppSupport")
        TestReporter.check(TestSupport.pathsEqual(
            vault.regPath.path,
            TestSupport.appSupportDir.appendingPathComponent("registration.list").path), "regPath under AppSupport")

        // Red line: identity paths never live inside the repo.
        TestReporter.check(!vault.keyPath.path.lowercased().hasPrefix(TestSupport.repoRoot.path.lowercased()),
                           "keyPath outside repo")
        TestReporter.check(!vault.regPath.path.lowercased().hasPrefix(TestSupport.repoRoot.path.lowercased()),
                           "regPath outside repo")

        // ensureWritable: creates the support directory (create+remove probe,
        // the same shape upstream uses for -reg) and creates NO key material —
        // generation/reuse belongs to upstream (ed25519_key_generate).
        let keyBefore = FileManager.default.fileExists(atPath: vault.keyPath.path)
        let regBefore = FileManager.default.fileExists(atPath: vault.regPath.path)
        try vault.ensureWritable()
        TestReporter.check(FileManager.default.fileExists(atPath: vault.supportDirectory.path),
                           "ensureWritable creates the support dir")
        TestReporter.equal(FileManager.default.fileExists(atPath: vault.keyPath.path), keyBefore,
                           "ensureWritable does not create the key file")
        TestReporter.equal(FileManager.default.fileExists(atPath: vault.regPath.path), regBefore,
                           "ensureWritable does not create the reg file")
    }

    static func engineGatesIdentityPathsByPIN() throws {
        let dir = try TestSupport.freshScratch("redline-engine")
        defer { TestSupport.removeScratch(dir) }
        let engine = ConfigEngine(
            profileStore: ProfileStore(rootDirectory: dir.appendingPathComponent("support")),
            keyVault: KeyVault(bundleID: "com.ycchung.mirageplay"),   // the real AppSupport
            rcArgvSnap: RcArgvSnap(rcDirectory: dir.appendingPathComponent("rc")))

        // PIN off → zero identity-material products (S-9=B).
        let off = engine.effectiveSnapshot()
        TestReporter.isNil(off.keyPath, "PIN off: keyPath nil")
        TestReporter.isNil(off.regPath, "PIN off: regPath nil")
        TestReporter.check(!off.argv().contains("-key"), "PIN off: no -key")
        TestReporter.check(!off.argv().contains("-reg"), "PIN off: no -reg")

        // PIN on → paths appear, and they are AppSupport paths, not repo paths.
        engine.setPinEnabled(true)
        let on = try engine.prepareForReceiverStart()
        guard let key = TestReporter.require(on.keyPath, "keyPath while PIN on"),
              let reg = TestReporter.require(on.regPath, "regPath while PIN on") else { return }
        TestReporter.check(key.hasPrefix(TestSupport.appSupportDir.path), "keyPath is an AppSupport path")
        TestReporter.check(reg.hasPrefix(TestSupport.appSupportDir.path), "regPath is an AppSupport path")
        TestReporter.check(!key.lowercased().hasPrefix(TestSupport.repoRoot.path.lowercased()), "keyPath outside repo")
        TestReporter.check(!reg.lowercased().hasPrefix(TestSupport.repoRoot.path.lowercased()), "regPath outside repo")

        // Both serialized forms carry the pair only in this (PIN-on) state.
        TestReporter.check(on.argv().joined(separator: " ").contains("-key \(key)"), "argv carries -key")
        TestReporter.check(on.argv().joined(separator: " ").contains("-reg \(reg)"), "argv carries -reg")
        TestReporter.check(on.rcText().contains("key \"\(key)\""), "rc carries quoted key path")
        TestReporter.check(on.rcText().contains("reg \"\(reg)\""), "rc carries quoted reg path")
    }

    static func repoHasNoIdentityMaterialFiles() throws {
        // Run representative operations first, INCLUDING the production rc
        // write path, then prove nothing identity-shaped landed in the repo.
        var model = Presets.factoryModel
        model.pinEnabled = true
        model.pinCode = "4827"
        // The rc directory is a harness-private temp directory: the production
        // rc root is AppSupport (P-2.2) and the rc file name is flat, so
        // injecting the repo root here would write `snapshot.rc` into the
        // checkout (P-2.3 red line).
        let rcDirectory = try TestSupport.freshScratch("redline-identity-rc")
        defer { TestSupport.removeScratch(rcDirectory) }
        let snapBuilder = RcArgvSnap(rcDirectory: rcDirectory)
        let snapshot = snapBuilder.makeSnapshot(
            from: model,
            effectivePinCode: "4827",
            identityPaths: RcArgvSnap.IdentityPaths(
                key: TestSupport.appSupportDir.appendingPathComponent("server.pem").path,
                reg: TestSupport.appSupportDir.appendingPathComponent("registration.list").path))
        try snapBuilder.writeRcFile(snapshot)

        let offenders = TestSupport.scanRepoForIdentityFiles()
        TestReporter.equal(offenders, [String](), "identity material must never land in the repo (red line)")
        // Control for the scan scope: the build output root must be excused
        // (a warm build tree carries vendored material, not product output),
        // and the checkout root must not be. Both are asserted on the same
        // predicate the scan uses, so a predicate that excused everything —
        // which would make the assertion above pass while catching nothing —
        // turns these two red instead.
        TestReporter.check(TestSupport.isUnscannedLocation(
            TestSupport.repoRoot.appendingPathComponent("_build/core/CMakeCache.txt").path),
                           "control: the build output root is outside the red-line scan")
        TestReporter.check(!TestSupport.isUnscannedLocation(
            TestSupport.repoRoot.appendingPathComponent("snapshot.rc").path),
                           "control: a file at the checkout root is inside the red-line scan")

        TestSupport.writeEvidence("07-identity-landing-scan.txt", [
            "expected AppSupport dir: \(TestSupport.appSupportDir.path)",
            "key path (never repo): \(TestSupport.appSupportDir.appendingPathComponent("server.pem").path)",
            "reg path (never repo): \(TestSupport.appSupportDir.appendingPathComponent("registration.list").path)",
            "repo scan (*.pem/*.key/*.register/*.dacp/.uxplay*; excludes "
                + TestSupport.unscannedLocationsDescription + "):",
            "  offenders = \(offenders)",
            "rc file written to: \(snapBuilder.rcPath.path)",
        ].joined(separator: "\n") + "\n")
    }

    // MARK: - ⑥ zero classroom wording

    static func zeroClassroomWordingInSourcesAndArtifacts() throws {
        let scanDirs = [
            TestSupport.repoRoot.appendingPathComponent("app/Sources/ConfigEngine"),
            TestSupport.repoRoot.appendingPathComponent("app/Sources/SharedTypes"),
        ]
        let banned = ["上課", "教學"]
        var scannedFiles: [String] = []
        var hits: [String] = []
        for dir in scanDirs {
            for file in TestSupport.swiftFiles(in: dir) {
                scannedFiles.append(file.path.replacingOccurrences(of: TestSupport.repoRoot.path + "/", with: ""))
                let text = try String(contentsOf: file, encoding: .utf8)
                for word in banned where text.contains(word) {
                    hits.append("\(file.path): \(word)")
                }
            }
        }

        // Serialized artifacts (both forms + the rc file on disk).
        var model = Presets.factoryModel
        model.pinEnabled = true
        model.pinCode = "4827"
        model.muted = true
        // The rc artifact is produced by the write path and read back from the
        // location the snapshot itself carries. The old code read
        // `<repo>/scratch/snapshot.rc` (a subdirectory of the injected root),
        // which only existed if an
        // earlier suite had left it there — a hidden ordering dependency, and a
        // path P-2.2 retired (reading it now throws or scans stale bytes).
        let rcDirectory = try TestSupport.freshScratch("redline-wording-rc")
        defer { TestSupport.removeScratch(rcDirectory) }
        let wordingSnapBuilder = RcArgvSnap(rcDirectory: rcDirectory)
        let snapshot = wordingSnapBuilder.makeSnapshot(
            from: model, effectivePinCode: "4827", identityPaths: nil)
        let rcWrittenURL = try wordingSnapBuilder.writeRcFile(snapshot)
        let rcOnDisk = try String(contentsOf: rcWrittenURL, encoding: .utf8)
        TestReporter.check(!rcWrittenURL.path.lowercased()
                            .hasPrefix(TestSupport.repoRoot.path.lowercased()),
                           "rc artifact is not inside the repo (P-2.3) — actual: \(rcWrittenURL.path)")
        TestReporter.equal(rcWrittenURL.path, snapshot.rcPath ?? "<nil>",
                           "rc artifact is written at the snapshot's own rcPath")
        for (artifact, text) in [
            ("argv()", snapshot.argv().joined(separator: " ")),
            ("rcText()", snapshot.rcText()),
            ("snapshot.rc (disk)", rcOnDisk),
        ] {
            for word in banned where text.contains(word) {
                hits.append("\(artifact): \(word)")
            }
        }

        TestReporter.equal(hits, [String](), "zero classroom-wording hits in sources + artifacts")
        TestSupport.writeEvidence("08-classroom-wording-scan.txt", [
            "scanned source files (\(scannedFiles.count)):",
            scannedFiles.map { "  " + $0 }.joined(separator: "\n"),
            "banned words: \(banned)",
            "hits: \(hits.count)",
        ].joined(separator: "\n") + "\n")
    }
}
