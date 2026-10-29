import Foundation
import ReceiverKit

/// UI-side evidence log for the CP-2 test harness (scripts/test-ui-cp2.sh).
///
/// Appends one timestamped line per entry to
/// `<NSTemporaryDirectory()>/com.ycchung.mirageplay/ui.log` (P-2.2: one-shot
/// scratch, no cross-launch retention) — a UI-side channel deliberately
/// separate from `launch.log`, which is the uxplay stdout channel whose three
/// frozen match strings (and the CONNECTION / DISCONNECTION / CRASH markers)
/// are part of the core⇄app contract and must stay byte-identical. Nothing
/// here ever writes to launch.log.
///
/// Called from the main thread only; failures are swallowed on purpose —
/// logging must never affect the UI path it is instrumenting.
public enum UILog {

    /// Scratch directory shared with the spawn leg
    /// (`CoreBridgeReceiverController`): one temp subtree per bundle id.
    static let scratchDirectoryName = "com.ycchung.mirageplay"

    /// `ui.log` location.
    ///
    /// `MIRAGE_PLAY_UI_LOG` (absolute path of the log FILE) wins over the
    /// default. The test harness sets it so every run writes — and every
    /// assertion reads — its own per-run file: the shared temp location let a
    /// line left behind by a previous run satisfy the next run's assertion.
    /// Unset or empty keeps the historical location byte for byte.
    ///
    /// Default: the temp scratch directory, falling back to the bare temp
    /// directory when that subdirectory cannot be created. A log line is never
    /// worth failing a UI path over, and both fallbacks still land outside any
    /// source checkout (P-2.3).
    private static let logPath: String = {
        let override = ProcessInfo.processInfo.environment["MIRAGE_PLAY_UI_LOG"] ?? ""
        if !override.isEmpty {
            let file = URL(fileURLWithPath: override)
            // Caller names a file inside a directory it may not have created
            // yet; failures are swallowed (the first write then fails and is
            // dropped, exactly like any other unwritable path here).
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            return file.path
        }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = temp.appendingPathComponent(scratchDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                   withIntermediateDirectories: true)
            return directory.appendingPathComponent("ui.log").path
        } catch {
            return temp.appendingPathComponent("ui.log").path
        }
    }()

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Appends one timestamped line (creating the file on first use).
    ///
    /// O_APPEND: the log file is SHARED between processes (the app and a
    /// second launch that trips the singleton guard; the harness reads it
    /// concurrently), so every write must land atomically at EOF — a
    /// `seekToEnd` + `write` pair can interleave across processes and
    /// misplace a line (same lesson as the launch.log O_APPEND fix).
    public static func line(_ message: String) {
        let entry = "[\(formatter.string(from: Date()))] [pid \(getpid())] \(message)\n"
        guard let data = entry.data(using: .utf8) else { return }

        let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
    }

    /// Stable single-token description of a receiver state, for log lines.
    public static func describe(_ state: ReceiverState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .waiting:
            return "waiting"
        case .connected(let deviceName):
            return "connected(\(deviceName))"
        case .stopping:
            return "stopping"
        }
    }
}
