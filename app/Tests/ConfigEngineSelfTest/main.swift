import Foundation

/// Stage2-B (2a) ConfigEngine self-test runner entry point.
///
/// Harness note: the toolchain on this machine is CommandLineTools-only (no
/// XCTest.framework, no swift-testing wiring), so this is a plain SwiftPM
/// executable target instead of a test target. Run either:
///   - `cd app && swift run ConfigEngineSelfTest`   (then: `swift build` also
///     compiles it, so the harness can never silently rot), or
///   - `scripts/tests/test-config-engine.sh` (wraps the above + logs into the
///     run's evidence directory: `MIRAGE_EVIDENCE_DIR` when set, else a fresh
///     directory under the system temp dir).
///
/// Evidence is not retained by this harness: the dumps are printed with their
/// paths and live in the system temp dir (or the caller's MIRAGE_EVIDENCE_DIR).
/// A caller that wants to keep them copies them out.
///
/// Exit code 0 = all checks passed; 1 = failures (listed at the end).

func runCase(_ label: String, _ body: () throws -> Void) {
    print("-- \(label)")
    do {
        try body()
    } catch {
        TestReporter.check(false, "\(label) threw — \(error)")
    }
}

let started = Date()

print("MiragePlay Stage2-B (2a) ConfigEngine self-test")
print("repo root: \(TestSupport.repoRoot.path)")
print("run at: \(ISO8601DateFormatter().string(from: started))")
print("")

ArgvRcComparisonSuite.runAll()
PersistenceSuite.runAll()
PinCodeSuite.runAll()
TrustRegistrySuite.runAll()
RedLineSuite.runAll()

let failuresBlock = TestReporter.failures.isEmpty
    ? "    (none)"
    : TestReporter.failures.map { "    - " + $0 }.joined(separator: "\n")

let summary = """
self-test summary
  passed: \(TestReporter.passed)
  failed: \(TestReporter.failed)
  failures:
\(failuresBlock)
"""
print(summary)

TestSupport.writeEvidence("00-self-test-summary.txt", summary + "\nelapsed: \(String(format: "%.1f", Date().timeIntervalSince(started)))s\n")

if TestReporter.failed > 0 {
    print("RESULT: FAIL (\(TestReporter.failed) failures)")
    exit(1)
} else {
    print("RESULT: PASS (\(TestReporter.passed) checks)")
    exit(0)
}
