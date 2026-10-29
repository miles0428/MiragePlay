import AppKit
import ConfigEngine
import Foundation
import SettingsUI

/// Launch-time singleton guard — wave1r2 (YC ruling: "add: detect an existing
/// instance at launch → focus it and exit yourself (standard practice;
///
/// Mechanism: an exclusive `flock(2)` on
/// `~/Library/Application Support/com.ycchung.mirageplay/singleton.lock`.
/// The kernel releases the lock automatically when the owning process dies
/// (crash included), so a stale lock cannot block a fresh launch. The first
/// instance publishes its pid into the lock file; a second launch fails the
/// non-blocking lock, reads the pid, makes a BEST-EFFORT focus attempt on the
/// existing instance (`NSRunningApplication.activate()`) and exits 0 before
/// any UI, engine or receiver setup runs.
///
/// Zero instances (the normal test situation)→ the lock is simply acquired;
/// behaviour is otherwise untouched.
enum SingletonGuard {

    /// The lock file name inside the app-support directory.
    static let lockFileName = "singleton.lock"

    /// Held for the whole process lifetime once acquired (flock semantics:
    /// released by the kernel at exit; the fd must stay open).
    private static var lockFileDescriptor: Int32 = -1

    /// Claims the singleton lock or exits.
    ///
    /// Call this BEFORE building any UI. When another instance holds the
    /// lock: log an evidence line, best-effort focus the existing instance,
    /// then `exit(0)`.
    static func claimOrExit() {
        let supportDirectory = KeyVault().supportDirectory
        try? FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true)
        let lockPath = supportDirectory.appendingPathComponent(lockFileName).path

        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            // Cannot even open the lock file — behave as if no instance
            // exists (never block the app on a locking error; honest trace).
            UILog.line("SINGLETON lock unavailable path=\(lockPath)")
            return
        }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            // We are the sole instance: publish our pid for the next caller.
            _ = ftruncate(fd, 0)
            let pidLine = "\(getpid())\n"
            _ = pidLine.withCString { pointer in
                write(fd, pointer, strlen(pointer))
            }
            lockFileDescriptor = fd
            return
        }

        // Another instance holds the lock: read its pid, focus it, exit 0.
        var buffer = [CChar](repeating: 0, count: 32)
        _ = lseek(fd, 0, SEEK_SET)
        let bytesRead = read(fd, &buffer, buffer.count - 1)
        close(fd)
        var existingPid: pid_t = 0
        if bytesRead > 0 {
            let text = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            existingPid = pid_t(text) ?? 0
        }

        var focus = "skip"
        if existingPid > 0, let app = NSRunningApplication(processIdentifier: existingPid) {
            focus = app.activate() ? "ok" : "failed"
        }
        UILog.line(
            "SINGLETON detected existing instance pid=\(existingPid) focus=\(focus); exiting"
        )
        exit(0)
    }
}
