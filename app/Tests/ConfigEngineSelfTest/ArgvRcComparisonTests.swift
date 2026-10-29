import Foundation
import ConfigEngine
import SharedTypes

/// Test ① — argv/rc two serialized forms: per-field comparison on the two
/// spec examples (the factory default / all on) with independently derived expected values.
///
/// Expected values are literal transcriptions of
/// `.task_state/spec_if2-fields_20261017.md` §2.1 (the complete-example arrays) plus
/// the PM-adopted tail increments that postdate the draft examples:
///   - S-4: `-rc <snapshot.rc path>` appended at the argv tail;
///   - S-9=B: `-key`/`-reg` appear only while PIN is on.
/// The rc expectations add the S-3 full-mirror body (§2.2 line shape).
enum ArgvRcComparisonSuite {

    /// §2.2 header line, verbatim.
    static let rcHeader = "# MiragePlay snapshot（自動生成；v1 欄位與命令列同值——命令列恆優先）"

    /// §2.1 the factory-default complete example, verbatim.
    static let factoryArgvSpecExample = ["-n", "MiragePlay", "-s", "1920x1080", "-fps", "30", "-vsync", "no"]

    /// §2.1 the all-on complete example, verbatim.
    static let fullArgvSpecExample = ["-n", "YC 的 Mac", "-s", "1280x720", "-fps", "60", "-vsync", "no", "-a", "-pin", "4827"]

    /// S-4 + P-2.2: the rc snapshot directory is INJECTED (harness-private temp
    /// directory). The engine's rc root is no longer a project root — after
    /// P-2.2 the default is AppSupport and the file name is flat, so injecting
    /// the repo root would write `snapshot.rc` into the checkout.
    static var rcTestDirectory: URL {
        TestSupport.testScratchRoot.appendingPathComponent("argv-rc", isDirectory: true)
    }

    /// S-4: expected rc snapshot path (`<rcDirectory>/snapshot.rc`).
    static var expectedRcPath: String {
        rcTestDirectory.appendingPathComponent(RcArgvSnap.rcFileName).path
    }

    /// S-9=B: expected identity paths (AppSupport per BLUEPRINT O-3; file
    /// names are the KeyVault constants — PM-adoptable minor naming).
    static var expectedKeyPath: String {
        TestSupport.appSupportDir.appendingPathComponent("server.pem").path
    }
    static var expectedRegPath: String {
        TestSupport.appSupportDir.appendingPathComponent("registration.list").path
    }

    static func runAll() {
        runCase("①a factory default: both forms") { try factoryDefaultBothForms() }
        runCase("①b fully open: both forms") { try fullyOpenBothForms() }
        runCase("①c S-9 gate: PIN off drops identity paths") { try identityPathsDroppedWhenPINOff() }
        runCase("①d C2 channel: rc-only verbatim injection") { try passThroughChannelInjectsRcOnly() }
        runCase("①e rc file: location + per-start rewrite") { try rcFileWriteAndOverwrite() }
    }

    // MARK: - Case A: factory default (PIN off; rc transport on)

    static func factoryDefaultBothForms() throws {
        let snapBuilder = RcArgvSnap(rcDirectory: rcTestDirectory)
        let snapshot = snapBuilder.makeSnapshot(
            from: Presets.factoryModel, effectivePinCode: nil, identityPaths: nil)

        // Snapshot payload: factory values everywhere, no identity paths.
        TestReporter.equal(snapshot.deviceName, "MiragePlay", "A1 deviceName")
        TestReporter.check(!snapshot.pinEnabled, "A2 pinEnabled off at factory")
        TestReporter.isNil(snapshot.pinCode, "A3 pinCode nil")
        TestReporter.equal(snapshot.resolution, "1080p", "A4 resolution")
        TestReporter.equal(snapshot.frameRate, 30, "A5 frameRate")
        TestReporter.check(!snapshot.muted, "A6 muted off")
        TestReporter.check(snapshot.vsyncDisabled, "C1 vsync baseline on")
        TestReporter.isNil(snapshot.keyPath, "C3 keyPath nil (PIN off)")
        TestReporter.isNil(snapshot.regPath, "C3 regPath nil (PIN off)")
        TestReporter.check(snapshot.preventSleep, "B1 preventSleep")
        TestReporter.check(snapshot.notificationsEnabled, "B2 notificationsEnabled")
        TestReporter.equal(snapshot.language, "en", "B3 language")
        TestReporter.equal(snapshot.profileName, "預設", "B4 profileName")
        TestReporter.equal(snapshot.rcPassThrough, [String](), "C2 channel empty (S-6(a))")

        // argv = §2.1 example + S-4 tail.
        let expectedArgv = factoryArgvSpecExample + ["-rc", expectedRcPath]
        TestReporter.equal(snapshot.argv(), expectedArgv, "factory argv = spec example + -rc tail")

        // The `.default` snapshot (no rc transport) equals the §2.1 example
        // EXACTLY — the strongest spec-literal anchor.
        TestReporter.equal(EffectiveSnapshot.default.argv(), factoryArgvSpecExample,
                           "EffectiveSnapshot.default argv == §2.1 example verbatim")

        // rc = header + full mirror of the fields present.
        let expectedRc = [
            rcHeader,
            "n MiragePlay",
            "s 1920x1080",
            "fps 30",
            "vsync no",
        ].joined(separator: "\n") + "\n"
        TestReporter.equal(snapshot.rcText(), expectedRc, "factory rcText verbatim")

        // Per-field comparison (dump as evidence).
        let fields: [(String, String, String)] = [
            ("A1 deviceName", "-n MiragePlay", "n MiragePlay"),
            ("A4 resolution (table D: 1080p→1920x1080)", "-s 1920x1080", "s 1920x1080"),
            ("A5 frameRate", "-fps 30", "fps 30"),
            ("C1 vsync baseline (S-5 dual form)", "-vsync no", "vsync no"),
            ("S-4 rc transport (argv tail only)", "-rc " + expectedRcPath, "(never in the rc body — pass-through only)"),
        ]
        TestSupport.writeEvidence("01-factory-argv-rc-field-comparison.txt",
                                  renderFieldTable(fields, snapshot: snapshot))
        for (label, argvFragment, rcFragment) in fields {
            if label.hasPrefix("S-4") { continue }
            TestReporter.check(snapshot.argv().joined(separator: " ").contains(argvFragment),
                               "argv missing \(label): \(argvFragment)")
            TestReporter.check(snapshot.rcText().contains(rcFragment + "\n") || snapshot.rcText().hasSuffix(rcFragment),
                               "rc missing \(label): \(rcFragment)")
        }

        // Shell group (B1-B4) never serializes; coverArt is gone entirely.
        for leak in ["preventSleep", "notificationsEnabled", "language", "profileName", "coverArt", "-nh"] {
            TestReporter.check(!snapshot.argv().joined(separator: " ").contains(leak), "argv leaks \(leak)")
            TestReporter.check(!snapshot.rcText().contains(leak), "rc leaks \(leak)")
        }
    }

    // MARK: - Case B: all on (a name with blanks / 720p / 60 / muted / PIN on 4827)

    static func fullyOpenBothForms() throws {
        let model = SettingModel(
            deviceName: "YC 的 Mac",
            pinEnabled: true,
            pinCode: "4827",
            resolution: "720p",
            frameRate: 60,
            muted: true,
            preventSleep: true,
            notificationsEnabled: true,
            language: "en",
            profileName: "預設",
            rcPassThrough: []
        )
        let identity = RcArgvSnap.IdentityPaths(key: expectedKeyPath, reg: expectedRegPath)
        let snapBuilder = RcArgvSnap(rcDirectory: rcTestDirectory)
        let snapshot = snapBuilder.makeSnapshot(
            from: model, effectivePinCode: "4827", identityPaths: identity)

        TestReporter.equal(snapshot.deviceName, "YC 的 Mac", "deviceName")
        TestReporter.equal(snapshot.pinCode, "4827", "pinCode")
        TestReporter.equal(snapshot.keyPath, expectedKeyPath, "keyPath")
        TestReporter.equal(snapshot.regPath, expectedRegPath, "regPath")
        TestReporter.equal(snapshot.rcPath, expectedRcPath, "rcPath")

        // argv = §2.1 example + S-9 tail (only while PIN on) + S-4 tail.
        let expectedArgv = fullArgvSpecExample
            + ["-key", expectedKeyPath, "-reg", expectedRegPath]
            + ["-rc", expectedRcPath]
        TestReporter.equal(snapshot.argv(), expectedArgv, "full-open argv = spec example + key/reg + -rc")

        // rc = header + full mirror; blank-carrying values are quoted; the
        // AppSupport path carries "Application Support" → quoted too.
        let expectedRc = [
            rcHeader,
            "n \"YC 的 Mac\"",
            "s 1280x720",
            "fps 60",
            "vsync no",
            "a",
            "pin 4827",
            "key \"\(expectedKeyPath)\"",
            "reg \"\(expectedRegPath)\"",
        ].joined(separator: "\n") + "\n"
        TestReporter.equal(snapshot.rcText(), expectedRc, "full-open rcText verbatim")

        let fields: [(String, String, String)] = [
            ("A1 deviceName（含空白→引號）", "-n YC 的 Mac", "n \"YC 的 Mac\""),
            ("A4 resolution（720p→1280x720）", "-s 1280x720", "s 1280x720"),
            ("A5 frameRate", "-fps 60", "fps 60"),
            ("C1 vsync baseline", "-vsync no", "vsync no"),
            ("A6 muted (S-8: -a short form)", "-a", "a"),
            ("A2/A3 PIN (fixed form -pin <xxxx>)", "-pin 4827", "pin 4827"),
            ("C3 -key (S-9=B: only while PIN is on)", "-key " + expectedKeyPath, "key \"\(expectedKeyPath)\""),
            ("C3 -reg (S-9=B: only while PIN is on)", "-reg " + expectedRegPath, "reg \"\(expectedRegPath)\""),
        ]
        TestSupport.writeEvidence("02-full-open-argv-rc-field-comparison.txt",
                                  renderFieldTable(fields, snapshot: snapshot))
        for (label, argvFragment, rcFragment) in fields {
            TestReporter.check(snapshot.argv().joined(separator: " ").contains(argvFragment),
                               "argv missing \(label): \(argvFragment)")
            TestReporter.check(snapshot.rcText().contains(rcFragment + "\n") || snapshot.rcText().hasSuffix(rcFragment),
                               "rc missing \(label): \(rcFragment)")
        }
    }

    // MARK: - S-9 gate: PIN off drops identity even when paths are supplied

    static func identityPathsDroppedWhenPINOff() throws {
        let model = Presets.factoryModel  // pinEnabled == false
        let identity = RcArgvSnap.IdentityPaths(key: expectedKeyPath, reg: expectedRegPath)
        let snapshot = RcArgvSnap(rcDirectory: rcTestDirectory)
            .makeSnapshot(from: model, effectivePinCode: "4827", identityPaths: identity)

        TestReporter.isNil(snapshot.keyPath, "S-9=B: PIN off → zero identity-file artifacts (key)")
        TestReporter.isNil(snapshot.regPath, "S-9=B: PIN off → zero identity-file artifacts (reg)")
        TestReporter.isNil(snapshot.pinCode, "PIN off → -pin never emitted")
        TestReporter.check(!snapshot.argv().contains("-key"), "argv has no -key")
        TestReporter.check(!snapshot.argv().contains("-reg"), "argv has no -reg")
        TestReporter.check(!snapshot.argv().contains("-pin"), "argv has no -pin")
        TestReporter.check(!snapshot.rcText().contains("key "), "rc has no key line")
        TestReporter.check(!snapshot.rcText().contains("reg "), "rc has no reg line")
        TestReporter.check(!snapshot.rcText().contains("pin "), "rc has no pin line")
    }

    // MARK: - Channel (C2 / S-6(a)): rc-only verbatim injection

    static func passThroughChannelInjectsRcOnly() throws {
        var model = Presets.factoryModel
        model.rcPassThrough = ["p 7100", "pw hunter2"]   // structure demo; v1 default is []
        let snapshot = RcArgvSnap(rcDirectory: rcTestDirectory)
            .makeSnapshot(from: model, effectivePinCode: nil, identityPaths: nil)

        let rc = snapshot.rcText()
        TestReporter.check(rc.contains("p 7100\n"), "rc carries channel line 1 verbatim")
        TestReporter.check(rc.contains("pw hunter2\n"), "rc carries channel line 2 verbatim")
        TestReporter.check(rc.hasSuffix("pw hunter2\n"), "channel lines are injected last")

        // Never in argv — the channel is rc-exclusive.
        let argv = snapshot.argv()
        TestReporter.check(!argv.joined(separator: " ").contains("7100"), "channel line 1 not in argv")
        TestReporter.check(!argv.joined(separator: " ").contains("hunter2"), "channel line 2 not in argv")
    }

    // MARK: - rc file write (S-4): location + per-start rewrite

    static func rcFileWriteAndOverwrite() throws {
        let snapBuilder = RcArgvSnap(rcDirectory: rcTestDirectory)
        let snapshotA = snapBuilder.makeSnapshot(
            from: Presets.factoryModel, effectivePinCode: nil, identityPaths: nil)

        let writtenURL = try snapBuilder.writeRcFile(snapshotA)
        TestReporter.check(TestSupport.pathsEqual(writtenURL.path, expectedRcPath),
                           "rc file location = <rcDirectory>/\(RcArgvSnap.rcFileName) (P-2.2) — actual: \(writtenURL.path)")
        TestReporter.check(!writtenURL.path.lowercased()
                            .hasPrefix(TestSupport.repoRoot.path.lowercased()),
                           "rc file is NOT written inside the repo (P-2.3) — actual: \(writtenURL.path)")
        TestReporter.equal(try String(contentsOf: writtenURL, encoding: .utf8), snapshotA.rcText(),
                           "rc file body == rcText()")

        // Second start: muted flipped on → the file is fully rewritten.
        var modelB = Presets.factoryModel
        modelB.muted = true
        let snapshotB = snapBuilder.makeSnapshot(from: modelB, effectivePinCode: nil, identityPaths: nil)
        try snapBuilder.writeRcFile(snapshotB)
        let onDisk = try String(contentsOf: writtenURL, encoding: .utf8)
        TestReporter.equal(onDisk, snapshotB.rcText(), "rc file rewritten on second start")
        TestReporter.check(onDisk.contains("a\n"), "rewritten rc has -a")
        TestReporter.check(onDisk != snapshotA.rcText(), "rewritten rc differs from first body")

        // O-5: the user rc files are never written.
        let home = FileManager.default.homeDirectoryForCurrentUser
        TestReporter.check(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".uxplayrc").path),
                           "no ~/.uxplayrc written")
        TestReporter.check(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/uxplayrc").path),
                           "no ~/.config/uxplayrc written")

        // P-2.2 / P-2.3: the DEFAULT rc directory is the per-bundle AppSupport
        // directory — NOT this repo. The old assertions here ("default project
        // root == repo root", "that path exists") encoded the retired
        // behaviour; they are replaced (not dropped, not loosened) by the new
        // contract, which also pins the alias and the "created on demand"
        // property that the old existence check was proxying for.
        let defaultRcRoot = RcArgvSnap.rcDirectoryDefault
        TestReporter.check(!TestSupport.pathsEqual(RcArgvSnap.projectRootDefault.path,
                                                   TestSupport.repoRoot.path),
                           "RcArgvSnap default rc root is NOT the repo root (P-2.3) — actual: \(defaultRcRoot.path)")
        TestReporter.check(TestSupport.pathsEqual(defaultRcRoot.deletingLastPathComponent().path,
                                                  TestSupport.appSupportParent.path),
                           "RcArgvSnap.rcDirectoryDefault sits directly under ~/Library/Application Support (P-2.2) — actual: \(defaultRcRoot.path)")
        TestReporter.equal(defaultRcRoot.lastPathComponent,
                           Bundle.main.bundleIdentifier ?? "com.ycchung.mirageplay",
                           "RcArgvSnap.rcDirectoryDefault is keyed by the running bundle id")
        // F-4: this used to assert `rcPath.lastPathComponent == rcFileName`,
        // which is true by construction (rcPath IS rcDirectory/rcFileName) and
        // could therefore never fail. The label's real claim — "the rc file
        // lands in a flat directory that is not part of the source checkout" —
        // was never asserted at all. It is now asserted through the SAME
        // predicate the red-line scan uses (TestSupport.isUnscannedLocation),
        // so the assertion and the scan cannot drift apart, and it is pinned by
        // two controls that keep it falsifiable in both directions:
        //   - an rcPath at the checkout root must NOT be excused: the scan has
        //     to catch it, so "excused" cannot mean "everything is excused";
        //   - an rcPath under the build output root MUST be excused: without
        //     that, a constant-false predicate would pass the first assertion
        //     for the wrong reason.
        let defaultRcPath = RcArgvSnap().rcPath
        TestReporter.check(!TestSupport.isUnscannedLocation(defaultRcPath.path),
                           "default rcPath is not in a non-source location (P-2.2) — actual: \(defaultRcPath.path)")
        TestReporter.check(TestSupport.pathsEqual(defaultRcPath.deletingLastPathComponent().path,
                                                  defaultRcRoot.path),
                           "default rcPath sits directly in the default rc directory — actual: \(defaultRcPath.path)")
        let repoRootRcPath = RcArgvSnap(rcDirectory: TestSupport.repoRoot).rcPath
        TestReporter.check(!TestSupport.isUnscannedLocation(repoRootRcPath.path),
                           "control: an rcPath at the checkout root is NOT excused by the predicate — actual: \(repoRootRcPath.path)")
        let buildRootRcPath = RcArgvSnap(
            rcDirectory: TestSupport.repoRoot.appendingPathComponent("_build/scratch")).rcPath
        TestReporter.check(TestSupport.isUnscannedLocation(buildRootRcPath.path),
                           "control: an rcPath under the build output root IS excused by the predicate — actual: \(buildRootRcPath.path)")
        TestReporter.check(!defaultRcRoot.path.lowercased()
                            .hasPrefix(TestSupport.repoRoot.path.lowercased()),
                           "RcArgvSnap default rc directory is outside the repo — actual: \(defaultRcRoot.path)")
        // AppSupport itself always exists on macOS; the per-bundle directory is
        // created by writeRcFile (proved above on the injected directory), so
        // the default location is reachable on a clean machine without the
        // test pre-creating the real one.
        TestReporter.check(FileManager.default.fileExists(atPath: TestSupport.appSupportParent.path),
                           "AppSupport parent of the default rc directory exists on disk — actual: \(TestSupport.appSupportParent.path)")
    }

    // MARK: - Helpers

    static func renderFieldTable(_ fields: [(String, String, String)], snapshot: EffectiveSnapshot) -> String {
        var lines: [String] = []
        lines.append("argv/rc field-by-field comparison (expected values = spec_if2-fields §2.1/§2.2 verbatim + PM-adopted S-4/S-9 tail attachments)")
        lines.append("argv() = \(TestSupport.render(argv: snapshot.argv()))")
        lines.append("rcText() =")
        lines.append(TestSupport.renderLines(snapshot.rcText()))
        lines.append("")
        lines.append("field | argv fragment | rc line | argv hit | rc hit")
        for (label, argvFragment, rcFragment) in fields {
            let argvHit = snapshot.argv().joined(separator: " ").contains(argvFragment) ? "YES" : "n/a"
            let rcHit = snapshot.rcText().contains(rcFragment) ? "YES" : "n/a"
            lines.append("\(label) | \(argvFragment) | \(rcFragment) | \(argvHit) | \(rcHit)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
