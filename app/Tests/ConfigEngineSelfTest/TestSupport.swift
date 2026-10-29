import Foundation
import ConfigEngine
import SharedTypes

/// Minimal check framework for the Stage2-B (2a) ConfigEngine self-test.
///
/// Harness choice (the 2a task card: "pick your own harness" → the scripts/ convention): this
/// toolchain is CommandLineTools-only, so neither XCTest nor swift-testing is
/// linkable from SwiftPM — the harness is therefore a plain executable target
/// (`swift run ConfigEngineSelfTest`, wrapped by `scripts/test-config-engine.sh`).
/// Re-runnable: every scratch file it creates lives under the per-user temp
/// directory (`<NSTemporaryDirectory()>/ConfigEngineSelfTest/wave1b-config-engine-tests/`,
/// one-shot scratch per P-2.2) — never inside the source checkout; per-suite
/// evidence dumps land in the system temp directory too, or in
/// `MIRAGE_EVIDENCE_DIR` when the caller sets it. Retention is not this file's
/// job: a path printed once and re-created on the next run is enough, and a
/// caller that wants the dumps keeps them by copying them out.
enum TestReporter {

    static var passed = 0
    static var failed = 0
    static var failures: [String] = []

    static func check(_ condition: Bool, _ label: String) {
        if condition {
            passed += 1
        } else {
            failed += 1
            failures.append(label)
            print("  FAIL — \(label)")
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        check(actual == expected, "\(label) — actual: \(actual), expected: \(expected)")
    }

    static func isNil<T>(_ value: T?, _ label: String) {
        check(value == nil, "\(label) — expected nil, got \(String(describing: value))")
    }

    static func notNil<T>(_ value: T?, _ label: String) {
        check(value != nil, "\(label) — expected non-nil")
    }

    /// Named-value requirement: records a failure and returns nil when absent.
    @discardableResult
    static func require<T>(_ value: T?, _ label: String) -> T? {
        guard let value else {
            check(false, "REQUIRED missing — \(label)")
            return nil
        }
        passed += 1
        return value
    }

    static func throwsError(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
            check(false, "\(label) — expected an error to be thrown")
        } catch {
            passed += 1
        }
    }
}

enum TestSupport {

    /// Repo root derived from THIS file's location
    /// (<repo>/app/Tests/ConfigEngineSelfTest/TestSupport.swift → up 4
    /// levels) — independent of any hardcoded path in the engine sources.
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ConfigEngineSelfTest/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // app/
        .deletingLastPathComponent()   // repo root

    /// Evidence dump directory (2a deliverables).
    ///
    /// `MIRAGE_EVIDENCE_DIR` wins when it is set (the caller's run directory);
    /// otherwise a fresh per-process directory under the system temp dir. Two
    /// properties matter and both are deliberate: the directory is never
    /// inside the checkout (a test run must not write into the worktree), and
    /// it is not a fixed path (each run gets its own; nothing accumulates in
    /// the repo, and nothing here decides how long evidence is kept — a caller
    /// that needs the dumps copies them out of the printed path).
    static let evidenceDir: URL = {
        let env = ProcessInfo.processInfo.environment["MIRAGE_EVIDENCE_DIR"] ?? ""
        if !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ConfigEngineSelfTest", isDirectory: true)
            .appendingPathComponent("evidence-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
    }()

    /// The real app-support location (independent derivation: home dir per
    /// FileManager, bundle id per BLUEPRINT O-3).
    static let appSupportParent: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)

    static let appSupportDir: URL = appSupportParent
        .appendingPathComponent("com.ycchung.mirageplay", isDirectory: true)

    // MARK: - Evidence

    @discardableResult
    static func writeEvidence(_ name: String, _ text: String) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
        let url = evidenceDir.appendingPathComponent(name)
        try? Data(text.utf8).write(to: url, options: .atomic)
        print("[evidence] \(url.path)")
        print("----- \(name) -----")
        print(text)
        print("----- end \(name) -----")
        return url
    }

    // MARK: - Isolated scratch locations

    /// Harness-private scratch root — one temp subtree per run, never inside
    /// the checkout.
    ///
    /// The rc directory used to be injected as `repoRoot`, which was harmless
    /// only while the product wrote into a subdirectory of the injected root.
    /// After P-2.2 the rc file name is flat (`<rcDirectory>/snapshot.rc`), so
    /// injecting the repo root would drop `snapshot.rc` straight into the
    /// worktree (P-2.3 red line). Scratch therefore lives under
    /// `NSTemporaryDirectory()`.
    static let testScratchRoot: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("ConfigEngineSelfTest", isDirectory: true)
        .appendingPathComponent("wave1b-config-engine-tests", isDirectory: true)

    /// A fresh, empty scratch directory (recreated if it already exists).
    static func freshScratch(_ name: String) throws -> URL {
        let dir = scratchPath(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The scratch path WITHOUT creating anything (for "no auto-creation"
    /// assertions).
    static func scratchPath(_ name: String) -> URL {
        testScratchRoot.appendingPathComponent(name, isDirectory: true)
    }

    static func removeScratch(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// An engine wired for isolation: profile store + key vault inside the
    /// given scratch dir, rc snapshot directory inside it as well (P-2.2: the
    /// rc root is an AppSupport-style directory, never a project root).
    static func isolatedEngine(scratch: URL) -> ConfigEngine {
        ConfigEngine(
            profileStore: ProfileStore(rootDirectory: scratch.appendingPathComponent("support")),
            keyVault: KeyVault(bundleID: "com.ycchung.mirageplay", homeDirectory: scratch),
            rcArgvSnap: RcArgvSnap(rcDirectory: scratch.appendingPathComponent("rc"))
        )
    }

    // MARK: - Rendering helpers

    static func render(argv: [String]) -> String {
        "[" + argv.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    static func renderLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "| " + $0 }
            .joined(separator: "\n")
    }

    /// Case-insensitive ASCII path comparison — the working-disk volume is
    /// case-insensitive (BLUEPRINT writes the root lowercase, `pwd` renders
    /// it as `Projects`), so byte equality is the unstable form.
    static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased() == rhs.lowercased()
    }

    /// All Swift files under a source directory (recursive).
    static func swiftFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Identity-material file patterns (red-line scan): the names uxplay's
    /// `-key`/`-reg`/`-dacp` family could drop, wherever they could land.
    static func isIdentityMaterialFile(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasSuffix(".pem")
            || lowered.hasSuffix(".key")
            || lowered.hasSuffix(".register")
            || lowered.hasSuffix(".dacp")
            || lowered.hasPrefix(".uxplay")
    }

    // MARK: - Red-line scan scope

    /// Directory names the red-line scan does not police, on top of every hidden
    /// directory (see `isUnscannedLocation`). Directory names only — a file is
    /// never excused by its own name.
    static let unscannedDirectoryNames: Set<String> = ["_build", "app.swiftpm"]

    /// One-line statement of the scan's exclusions, derived from the same two
    /// sources the scan uses so that a description written into evidence cannot
    /// drift away from what was actually skipped.
    static var unscannedLocationsDescription: String {
        "hidden directories (directory name starting with \".\"; files are never excused), "
            + unscannedDirectoryNames.sorted().map { "\($0)/" }.joined(separator: ", ")
    }

    /// True when `path` names a location outside the red-line scan's scope.
    ///
    /// The scan polices every FILE in the checkout, so these are DIRECTORY
    /// exclusions: a file inherits an exclusion from a directory it sits in,
    /// never from its own name. The three cases are a definition of "not
    /// source", not a list of names that happened to be inconvenient:
    ///   - the path is not under the checkout (the scan never sees it),
    ///   - a directory below the checkout root is hidden, i.e. its directory
    ///     name starts with a dot — `.git` (object store), `.build`/`.swiftpm`
    ///     (tool caches), an agent relay tree, and any other hidden working
    ///     layer,
    ///   - a directory is the build output root `_build` or SwiftPM's
    ///     per-build-directory cache `app.swiftpm`.
    ///
    /// The hidden test is on the DIRECTORY NAME, not on the path. Identity
    /// material is routinely a dotfile (`.uxplay.pem`, `.uxplay.register`,
    /// `.uxplay.dacp` — the flagship pattern of `isIdentityMaterialFile` is the
    /// `.uxplay` prefix), so excusing "any component starting with a dot"
    /// excused precisely the files this scan exists to catch. Files are never
    /// excused by name; only the directories around them can be.
    ///
    /// Everything else in the checkout IS policed, the checkout root included:
    /// that is the property the control assertions exercise, because a predicate
    /// that excused everything would make the scan pass while catching nothing.
    static func isUnscannedLocation(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        // A path that does not exist (and any regular file) resolves to
        // `false` here: an unprovable directory is treated as a file, so an
        // exclusion can never be granted on a guess.
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return isUnscannedLocation(url, isDirectory: isDirectory)
    }

    /// `URL` form of the same predicate, for callers that already know whether
    /// the URL is a directory (the scan enumerator reads that key anyway, so
    /// passing it in avoids a second stat per entry).
    static func isUnscannedLocation(_ url: URL, isDirectory: Bool) -> Bool {
        let root = repoRoot.path
        let path = url.path
        guard path.lowercased().hasPrefix(root.lowercased()) else { return false }
        let relative = String(path.dropFirst(root.count))
        guard relative.isEmpty || relative.hasPrefix("/") else { return false }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            // Every component above the leaf names a directory by position; the
            // leaf itself is a directory only when the caller says so. A leaf
            // that is a file can therefore never satisfy the checks below.
            let namesDirectory = index < components.count - 1 || isDirectory
            guard namesDirectory else { continue }
            if component.hasPrefix(".") { return true }
            if unscannedDirectoryNames.contains(String(component)) { return true }
        }
        return false
    }

    /// Walks the physical repo tree and returns identity-material file paths.
    /// Excluded (one definition, `isUnscannedLocation`): hidden directories and
    /// the build output root / SwiftPM cache — build outputs are not source, and
    /// a warm build tree holds a copy of the vendored upstream material. No file
    /// is excluded by name, so a dotfile such as `.uxplay.pem` landing in the
    /// checkout is still reported.
    static func scanRepoForIdentityFiles() -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: repoRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []) else { return [] }
        var offenders: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isUnscannedLocation(url, isDirectory: isDirectory) {
                enumerator.skipDescendants()
                continue
            }
            if isIdentityMaterialFile(url.lastPathComponent) {
                offenders.append(url.path)
            }
        }
        return offenders.sorted()
    }
}
