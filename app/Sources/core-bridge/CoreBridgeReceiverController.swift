import Foundation
import SharedTypes
import ReceiverKit

/// CoreBridgeReceiverController — J2-① embedded leg implementation (spawn-backed).
///
/// Stage1 projection-resilience fix (ruling 20261016-10-16) + respawn-loop fix
/// (incident 2026-10-16 17:35, engineering-grade ruling):
///   1. Crash guard — respawn (bounded exponential backoff 1s / 2s / 4s / 8s,
///      capped at 8s) is reserved for CRASH-SHAPED deaths: `.uncaughtSignal`,
///      or `.exit` with a non-zero status. A termination caused by `stop()` /
///      `quit()` / `restart()` is explicitly flagged as user-initiated and
///      must NOT respawn, otherwise stop() would loop forever. A `.exit` with
///      status 0 and no app-side intent is ALSO never respawned: uxplay only
///      exits 0 on its own through its own window/UI quit paths (X-close / Q /
///      ⌘Q → SIGTERM to itself; Dock Quit → silent NSApp exit(0)), and both
///      are user intent. Incident 2026-10-16 17:35: the old "status-0 exit is
///      unexpected → respawn" doctrine fought the user — 13 respawn loops on
///      window closes the user performed; see `handleTermination` for the
///      reversal.
///      Contract note (PM ruling 2026-10-16, implementation-comment route):
///      uxplay window terminating itself (X/Q/⌘Q/Dock) = an already-formed termination intent; this guard promises not to respawn.
///   2. stdout buffering — uxplay's `log()` (core/uxplay/uxplay.cpp:235) uses bare
///      `printf` with no `fflush`. Redirecting stdout to a regular file leaves
///      libc in full-buffered mode (4096 bytes), so `launch.log` stays 0 bytes
///      for as long as the process is silent. Measured facts (D2 report):
///        - file redirect  → 0 bytes live, 808 bytes only after the process exits
///        - pipe redirect  → 0 bytes live (pipe is block-buffered too)
///        - pty (this design) → line arrives in 0.03–0.08s, live
///      The earlier wave wrapped uxplay in `/usr/bin/stdbuf` to force line
///      buffering. That made behaviour depend on whether the host HAD stdbuf
///      (macOS does not ship it; some OS installs happen to carry it), and on a
///      host without it the receiver silently degraded to full buffering: the
///      `Accepted …` line was pushed out by the burst of frames that follows a
///      connection (→ turns green), while `Connection closed …` sat in the
///      buffer forever because uxplay falls silent right after it (→ stays
///      green). That asymmetry was YC's bug report.
///      The wrapper is GONE. Every host now takes the same path: the child's
///      stdout/stderr are attached to a pseudo-terminal (`openpty`), a tty
///      makes libc line-buffered with no external tool and no OS dependency,
///      and a pump thread copies the master side into `launch.log` (the log
///      watcher keeps polling that file, so its semantics are unchanged).
///      No `DYLD_*`/`GST_*` stripping exec hop remains in between either.
///   3. Snapshot-driven spawn (stage C / wave1c) — the uxplay argv now comes from
///      `EffectiveSnapshot.argv()` (IF-2 §2.1; the Stage1 hardcoded name
///      argument is retired), and the injected `snapshotPreparer` runs before
///      EVERY spawn (rc-file rewrite + P3 code rules). Each successful spawn
///      appends one `MIRRORBOARD SPAWN` argv line to launch.log (the
///      re-runnable wiring-test evidence).
///   4. Event stream — string matching aligned against uxplay's real stdout.
///      Verified by connecting a synthetic TCP client to a live uxplay and
///      reading its log:
///        "Accepted IPv4 client on socket 15, port 1131"
///        "Accepted IPv6 client on socket 15, port 1131"
///        "Connection closed on socket 15"
///      Device name now comes from uxplay.cpp:2334
///      ("connection request from <name> (<model>) with deviceID = <id>")
///      instead of the hard-coded "iPhone".
public final class CoreBridgeReceiverController: ReceiverController {

    /// stage G (wave1g) — the language-neutral marker prefixing a settled launch
    /// failure on the `.error` event channel (the R4-Q2=A carry-over channel). The AppShell
    /// strips it and composes the localized prefix from the term dictionary
    /// (§B a2), so a launch failure is surfaced in the selected language and
    /// this module stays language-free.
    public static let launchFailureMarker = "SPAWN-FAILED: "

    public private(set) var state: ReceiverState = .idle

    /// Injected snapshot preparation (stage C / wave1c) — called before EVERY
    /// spawn (user start, E1 auto-restart, crash-guard respawn). Wired by
    /// CompositionRoot to `ConfigEngine.prepareForReceiverStart()`, which
    /// rewrites the AppSupport rc snapshot and applies the P3 code rules.
    /// The rc file must exist before every spawn: a `-rc <path>` whose file
    /// is missing makes uxplay exit(0) at startup (uxplay.cpp:2986-2991) —
    /// indistinguishable from a graceful user quit to the crash guard.
    /// `nil` (no engine wired) → spawn the snapshot argument as-is.
    public var snapshotPreparer: (() throws -> EffectiveSnapshot)?

    private var eventContinuation: AsyncStream<ReceiverEvent>.Continuation?

    public var events: AsyncStream<ReceiverEvent> {
        let (stream, continuation) = AsyncStream<ReceiverEvent>.makeStream()
        self.eventContinuation = continuation
        return stream
    }

    private var logWatcherTask: Task<Void, Never>?

    private let logQueue = DispatchQueue(label: "com.mirrorboard.launchlog")

    /// uxplay binary path — the packaged projection helper inside MiragePlay.app.
    ///
    /// dock-branding (task 20261018): the projection process must appear in the
    /// Dock as "MiragePlay" (helper bundle display name + AppIcon.icns), never
    /// as the bare `uxplay` executable with the generic exec icon. The core
    /// executable is therefore spawned from the nested helper bundle
    /// `MiragePlay.app/Contents/Helpers/MiragePlay Projection.app/Contents/MacOS/uxplay`
    /// (packaging only — core/uxplay sources are untouched; build-app.sh packs
    /// the byte-identical copy together with the helper Info.plist + icon).
    ///
    /// Resolution order:
    ///   1. `<Bundle.main>/Contents/Helpers/…` — the shipping layout
    ///      (`open MiragePlay.app`); Bundle.main stays the .app even though
    ///      Contents/MacOS/MiragePlay is a symlink into the swiftpm build dir.
    ///      This is the ONLY production resolution (P-2.2: paths derive from
    ///      the bundle — never from a source checkout).
    ///   2. DEBUG-only `MIRAGE_PLAY_HELPER_PATH` — test seam for a raw
    ///      `swift build` binary, whose Bundle.main is just the build
    ///      directory and therefore hides no `.app` at all. The harness
    ///      supplies the assembled helper executable path explicitly; nothing
    ///      is baked into the source (P-2.1) and no work-directory path is ever
    ///      consulted at runtime (P-2.3).
    ///
    /// When neither resolves, the bundled path is returned unchanged: the
    /// spawn then fails through the P-7.4 readable-error path instead of
    /// silently pointing somewhere plausible.
    private static let uxplayPath: String = {
        let helperRelative = "Contents/Helpers/MiragePlay Projection.app/Contents/MacOS/uxplay"
        let bundled = Bundle.main.bundleURL.appendingPathComponent(helperRelative).path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        #if DEBUG
        if let override = Foundation.ProcessInfo.processInfo.environment[debugHelperPathEnvironmentKey],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        #endif
        return bundled
    }()

    /// DEBUG-only seam name for `uxplayPath` (see the resolution order above).
    /// Compiled out of release builds together with the probe.
    static let debugHelperPathEnvironmentKey = "MIRAGE_PLAY_HELPER_PATH"

    /// Projection helper bundle (`…/Contents/Helpers/MiragePlay Projection.app`),
    /// derived from the SAME resolution as `uxplayPath`: the executable lives at
    /// `<helper>/Contents/MacOS/uxplay`, so dropping three path components walks
    /// back to the bundle root (P-7.2 / P-1.2 bundle layout).
    ///
    /// Derived rather than resolved a second time on purpose — the helper bundle
    /// is the only owner of `Contents/Frameworks/`, `Contents/plugins/` and
    /// `Contents/bin/`, so a single derivation keeps the executable and the
    /// GStreamer search paths from ever disagreeing (interface I-1/I-2).
    private static var helperBundleURL: URL {
        URL(fileURLWithPath: uxplayPath)
            .deletingLastPathComponent()   // Contents/MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // MiragePlay Projection.app
    }

    /// GStreamer plugin directory shipped inside the helper bundle
    /// (`<helper>/Contents/plugins` — 14 plugins).
    ///
    /// Deliberately NOT `Frameworks/`: on macOS `GST_MODULE_SUFFIX` is `.dylib`,
    /// so every file in a scanned directory counts as a plugin candidate and the
    /// plain shared libraries would be registered as broken plugins (blacklist
    /// pollution) instead of being ignored.
    private static var gstPluginDirectory: URL {
        helperBundleURL.appendingPathComponent("Contents/plugins", isDirectory: true)
    }

    /// Relocated plugin scanner shipped inside the helper bundle
    /// (`<helper>/Contents/bin/gst-plugin-scanner`). GStreamer looks for it
    /// relative to the libgstreamer install prefix by default, which a bundle
    /// does not reproduce — hence the explicit path.
    private static var gstPluginScanner: URL {
        helperBundleURL.appendingPathComponent("Contents/bin/gst-plugin-scanner")
    }

    /// Per-user writable GStreamer registry (`…/Application Support/<bundle id>/
    /// gst-registry.bin`).
    ///
    /// Never the shared default (`~/.cache/gstreamer-1.0/registry.*.bin`): a
    /// development machine's Homebrew GStreamer writes that same file, so
    /// sharing it mixes plugin sets across machines and versions.
    ///
    /// - Returns: the registry URL, or nil when the support directory cannot be
    ///   created (the caller then leaves the variable unset and GStreamer uses
    ///   its own default rather than failing the spawn).
    private static func gstRegistryURL() -> URL? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ycchung.mirageplay"
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let directory = support.appendingPathComponent(bundleID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                   withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return directory.appendingPathComponent("gst-registry.bin")
    }

    /// One temp subtree per bundle id (P-2.2: one-shot scratch, no cross-launch
    /// retention). Holds ONLY the spawn CWD (and `ui.log`, written by
    /// `UILog`); `launch.log` moved to Application Support — see
    /// `launchLogDirectory`.
    static let scratchDirectoryName = "com.ycchung.mirageplay"

    /// File name of the receiver log inside `launchLogDirectory`.
    ///
    /// `public` only so the DEBUG UI-test injector
    /// (`UITestDriver.injectLaunchLogLine`) can name the file the watcher
    /// actually polls instead of restating the name; it has no other consumer
    /// outside this module.
    public static let launchLogFileName = "launch.log"

    /// Why a spawn prerequisite could not be prepared. Carries a
    /// human-readable description so the panel can show it verbatim (P-7.4:
    /// the launch failure must be legible, never a "clicked and nothing happened").
    enum SpawnEnvironmentError: LocalizedError {
        case scratchDirectoryUnavailable(path: String, reason: String)
        case launchLogDirectoryUnavailable(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case let .scratchDirectoryUnavailable(path, reason):
                return "Cannot prepare the receiver scratch directory at \(path): \(reason)"
            case let .launchLogDirectoryUnavailable(path, reason):
                return "Cannot write the receiver log directory at \(path): \(reason)"
            }
        }
    }

    /// Creates and write-probes the scratch directory used as the child's CWD.
    ///
    /// This MUST run before `Process` is built: `Process.run()` throws
    /// (`NSCocoaErrorDomain` 4) when `currentDirectoryURL` does not exist, and
    /// on a clean machine nobody has created this subtree yet. The probe is the
    /// same shape as `KeyVault.ensureWritable` — creation alone does not prove
    /// the child can write its log there.
    ///
    /// - Parameter fileManager: injectable for tests.
    /// - Returns: the directory URL, ready to be used.
    /// - Throws: `SpawnEnvironmentError.scratchDirectoryUnavailable` when the
    ///   directory cannot be created or written to (the caller must surface it,
    ///   never swallow it).
    static func ensureScratchDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(scratchDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SpawnEnvironmentError.scratchDirectoryUnavailable(
                path: directory.path, reason: error.localizedDescription)
        }
        let probe = directory.appendingPathComponent(".spawn-probe-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: probe.path, contents: Data()) else {
            throw SpawnEnvironmentError.scratchDirectoryUnavailable(
                path: directory.path, reason: "directory is not writable")
        }
        try? fileManager.removeItem(at: probe)
        return directory
    }

    /// `~/Library/Application Support/<CFBundleIdentifier>` — the location P-2.2
    /// reserves for artefacts that must survive a relaunch (rc snapshot,
    /// identity material, and now `launch.log`).
    ///
    /// Built the way `KeyVault.supportDirectory` is built (home-relative
    /// `Library/Application Support`, never a hardcoded home path: P-2.1), so
    /// the log sits next to `snapshot.rc`/`server.pem` and is still there after
    /// a reboot — which is exactly the evidence a stuck-green report needs.
    ///
    /// - Parameter fileManager: injectable for tests.
    /// - Returns: the directory URL (not created here).
    ///
    /// `public` only for the DEBUG UI-test injector: the trust suite appends
    /// synthetic uxplay records and must append them to the very directory the
    /// spawn and the watcher resolve, never to a re-derived copy of it.
    public static func launchLogDirectory(fileManager: FileManager = .default) -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? scratchDirectoryName
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    /// Creates and write-probes the log directory (`launchLogDirectory`).
    ///
    /// Same create+probe shape as `ensureScratchDirectory`/`KeyVault`: a
    /// directory that exists but refuses writes would otherwise swallow every
    /// log line and resurface as "the receiver log is empty" (P-7.4 forbids
    /// that silent outcome).
    ///
    /// - Parameter fileManager: injectable for tests.
    /// - Returns: the directory URL, ready to be used.
    /// - Throws: `SpawnEnvironmentError.launchLogDirectoryUnavailable`.
    static func ensureLaunchLogDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = launchLogDirectory(fileManager: fileManager)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SpawnEnvironmentError.launchLogDirectoryUnavailable(
                path: directory.path, reason: error.localizedDescription)
        }
        let probe = directory.appendingPathComponent(".launch-log-probe-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: probe.path, contents: Data()) else {
            throw SpawnEnvironmentError.launchLogDirectoryUnavailable(
                path: directory.path, reason: "directory is not writable")
        }
        try? fileManager.removeItem(at: probe)
        return directory
    }

    /// Launch log URL for the CURRENT generation.
    /// (`~/Library/Application Support/<bundle-id>/launch.log` — P-2.2: a log
    /// must survive a relaunch, unlike the temp scratch CWD.)
    /// Resolved at spawn time, after the directory was created and write-probed,
    /// so the log can never point into a directory the receiver cannot write.
    /// `nil` before the first spawn and after a directory failure.
    private var launchLogURL: URL?

    private var uxplayProcess: Process?

    // MARK: - Crash guard state

    /// Set to `true` immediately before we terminate uxplay ourselves (stop() /
    /// restart() / quit()). Read and reset by the termination handler: when it
    /// is true the termination was user-initiated and must NOT trigger a
    /// respawn. It is never cleared while a kill is in flight (stop() runs
    /// twice on the quit() path) and is reset fresh at every spawn.
    private var userInitiatedTermination = false

    /// Sticky "the user wants this receiver running" intent — set by start();
    /// cleared by stop(), and by a graceful uxplay-UI close (see
    /// `handleTermination`); never flipped back by the quit() sequence.
    ///
    /// Respawn decisions consult this (with the flag above): a status-0 exit
    /// caused by our own stop/quit must never be resurrected, and neither
    /// must a graceful status-0 exit caused by uxplay's own window/UI quit.
    /// Only crash-shaped deaths (signals / non-zero exits) are respawned.
    private var wantsRunning = false

    /// Consecutive failed respawn attempts, drives the backoff ladder.
    private var restartAttempt = 0

    /// Set by start() to request a log truncate on the next spawn. A crash-guard
    /// respawn leaves this false so the CRASH trail survives.
    private var truncateLaunchLog = false

    /// Byte offset in launch.log at the moment of the current spawn. The log
    /// watcher begins here so a respawn does not re-dispatch lines it already
    /// processed (which would emit duplicate CONNECTION events).
    private var logSpawnOffset: UInt64 = 0

    /// wave1r4 (trust increment I1) — set when the "registered new client" prefix
    /// line was seen: uxplay's LOGI emits TWO lines per registration
    /// (`PK = \n%s`; uxplay.cpp:2624), so the very next line is expected to be
    /// the pk64 continuation. It is consumed silently when it looks like a
    /// pk64; anything else is processed normally (never swallowed).
    /// Watcher-thread only (same thread as `processLogLine`).
    private var expectPkContinuation = false

    /// wave1r6 (trust timing fix) — the socket census for the apply-on-disconnect gate.
    ///
    /// `Accepted IPv4/IPv6 client on socket N` (httpd.c:312) inserts the
    /// socket, `Connection closed on socket N` (httpd.c:238) removes it — one
    /// TCP client connection = one accept/close pair, so the set's emptiness
    /// is the honest "no connection for this case any more" fact the coverage gate needs (a restart
    /// while another device is still projecting would kick it).
    ///
    /// logQueue-confined (mutated inside the dispatched handlers);
    /// `liveConnectionCount` reads it synchronously from the main thread.
    /// Cleared at every spawn: a new uxplay generation starts with zero
    /// connections — sockets that died with the old generation never emit
    /// their close line, so a stale entry is impossible by construction.
    ///
    /// Two consumers, one fact: the trust gate asks "is anybody still
    /// connected" (`liveConnectionCount`) and the close handler asks "was that
    /// the last connection" — one device holds several TCP connections, so
    /// only an empty set is a device-level disconnect.
    ///
    /// What this census CANNOT do (documented on purpose — review R3): upstream
    /// prints the close line only when `close()` actually succeeds
    /// (`_build/uxplay/lib/httpd.c:233-238`, materialized by
    /// scripts/build/vendor-uxplay.sh), so a lost close line
    /// leaves its socket counted FOREVER: the device never reads as offline and
    /// the trust apply stays held, because both consumers read this one set.
    /// There is deliberately no timer and no second bookkeeper; the reset point
    /// is `removeAll()` at the next spawn. The stuck state is not silent — every
    /// branch writes a `SOCKET …` trace, so a census that will not drain is
    /// greppable in launch.log.
    ///
    /// Counted per SOCKET, not per device: it answers "is this session still
    /// alive", which is exactly what the restart gate needs (restarting kicks
    /// every connected client).
    private var activeSockets: Set<Int> = []

    /// The identity the accept path carries before uxplay reveals the real name
    /// (`connection request from <name>` arrives later, on the setup line). It
    /// is a "not known yet" marker, NOT an identity — see `handleConnected`.
    private static let placeholderDeviceName = "Unknown Device"

    /// True once this generation accepted a connection whose socket number we
    /// could not parse. An unparsable accept makes the census incomplete, and an
    /// incomplete census must not be read as "empty ⇒ the device left" (review
    /// R3, direction A: a single unparsed accept would otherwise let the NEXT
    /// close of any already-dead socket flip the device offline early).
    /// logQueue-confined; cleared by the spawn reset together with `activeSockets`.
    private var censusIncomplete = false

    /// wave1r6 — live client-connection count (IF-1 addition; see the
    /// `activeSockets` doc). `logQueue.sync` gives an ordered read: every
    /// accept/close handler completes its set mutation before it yields its
    /// event, so a consumer that already received `.disconnected` can never
    /// observe the closing socket still counted.
    public var liveConnectionCount: Int {
        logQueue.sync { activeSockets.count }
    }

    /// Single writer handle for launch.log.
    ///
    /// Two writers use it: `writeStructuredLog` (our CONNECTION/CRASH markers)
    /// and the pty pump (everything the child wrote to its tty). Both go through
    /// the SAME descriptor opened with O_APPEND (see
    /// `openLaunchLogForAppend`), which is what keeps their output from
    /// shredding each other: the kernel places every `write` at the current EOF,
    /// so neither a stale file offset nor a PREVIOUS generation's late output can
    /// land on top of a marker we just appended. The child no longer holds this
    /// descriptor — it writes to the pty slave, and the pump relays it here.
    private var launchLogHandle: FileHandle?

    // MARK: - PTY state (stdout/stderr line buffering)

    /// Serialises the three pty fields below. They are touched from the main
    /// thread (spawn / stop / termination) and from the pump thread (exit), so
    /// every read AND write goes through `ptyLock`.
    private let ptyLock = NSLock()

    /// Master side of the current generation's pty — the app's read end. `-1`
    /// when no pty is open. Owned by the pump thread: it is the only writer
    /// that closes it (`retireMasterFD`), so no thread ever `close`es a
    /// descriptor another thread is blocked in `poll()` on.
    private var ptyMasterFD: Int32 = -1

    /// Slave side — attached to the child's stdout AND stderr. The parent keeps
    /// its own copy only until `Process.run()` returns and then closes it: while
    /// ANY slave descriptor stays open the master never reports EOF/EIO, so a
    /// held copy would leave the pump waiting on a child that is long dead.
    private var ptySlaveFD: Int32 = -1

    /// Retires the current pump. The pump re-reads it after every 100 ms poll
    /// timeout and exits on a mismatch, which is what makes `stop()` /
    /// `handleTermination` / a new spawn able to shut a pump down without
    /// racing its blocking read.
    private var ptyGeneration: UInt64 = 0

    /// Cached backoff work item so a stop() during the backoff window cancels
    /// the pending respawn instead of spawning an orphan uxplay.
    private var pendingRestartWorkItem: DispatchWorkItem?

    /// Pending E1 auto-restart re-start (the hand-off gap after restart()'s
    /// stop). Cancelled by stop()/start() so a quick stop during the gap can
    /// never spawn a zombie receiver.
    private var pendingRestartStartWorkItem: DispatchWorkItem?

    /// Max consecutive restart attempts before we stop trying and surface an
    /// error. 8 attempts with the 1/2/4/8 ladder ≈ 29s of retrying; enough to
    /// ride out a port still held in TIME_WAIT by the dead socket, without
    /// looping forever if uxplay is genuinely unusable (e.g. missing dylib).
    private static let maxRestartAttempts = 8

    /// A respawned uxplay that stays up this long is considered healthy and the
    /// backoff ladder resets. Comfortably longer than the 8s ceiling so a
    /// still-crashing process cannot reset the ladder early.
    private static let healthyAfterSeconds: TimeInterval = 15.0

    /// Signals we trap to guarantee "child dies with parent" (BLUEPRINT arch-3 #11
    /// orphan prevention). NSApplication does not run applicationWillTerminate
    /// on SIGTERM, so without this an abrupt quit leaves uxplay orphaned —
    /// still holding the AirPlay ports and the Bonjour advertisement, which is
    /// exactly the "cannot reconnect" symptom this fix set out to remove.
    private static let trappedSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    /// Installed signal sources, kept alive for the lifetime of the controller.
    private var signalSources: [DispatchSourceSignal] = []

    public init() {
        installOrphanPrevention()
    }

    /// SIGTERM/SIGINT/SIGHUP → terminate the uxplay child, then let the default
    /// disposition kill us, so the child never outlives the app.
    private func installOrphanPrevention() {
        for sig in Self.trappedSignals {
            // Ignore first so the default action is deferred while we clean up.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.terminateChildAndExit(bySignal: sig)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Terminates the uxplay child (if any), then restores the default handler
    /// and re-raises the signal so the app really dies.
    private func terminateChildAndExit(bySignal sig: Int32) {
        if let proc = uxplayProcess, proc.isRunning {
            userInitiatedTermination = true
            cancelPendingRestart()
            proc.terminate()
            // Give the child a brief window to exit cleanly before we die.
            let deadline = Date().addingTimeInterval(1.0)
            while proc.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        uxplayProcess = nil
        // Restore default disposition and re-raise: the signal now kills us.
        signal(sig, SIG_DFL)
        kill(getpid(), sig)
    }

    // MARK: - ReceiverController

    /// Starts (or restarts after an explicit stop) the uxplay receiver and
    /// (re)arms the user intent that allows the crash guard to respawn.
    public func start(snapshot: EffectiveSnapshot) {
        beginStart(snapshot: snapshot, truncateLog: true)
    }

    /// Shared start body. `truncateLog` separates a fresh user start (new
    /// session → truncate) from the E1 auto-restart (append, so the
    /// pre-restart trail survives next to the new generation's output).
    private func beginStart(snapshot: EffectiveSnapshot, truncateLog: Bool) {
        // Refuse on the FACT that a live child exists — never on the derived
        // `state`. `.connected` can be stale: a lost `Connection closed` line
        // leaves the state green while uxplay sits idle waiting for the next
        // client, and the old `state == .idle || state == .stopping` guard then
        // swallowed the start with no feedback at all (P-7.4: never a silent
        // no-op). A dead/absent child is always startable, whatever the state
        // says.
        //
        // A child we have already asked to die (`userInitiatedTermination`) is
        // not a reason to refuse either: that is the stop()→start() hand-off,
        // where the state guard used to let the start through immediately and
        // waiting for the async termination callback here would make a fast
        // restart fail instead. The single-path guarantee (never two uxplay
        // generations) is unchanged — a genuinely running child, i.e. one we
        // did not ask to stop, is still rejected.
        if let proc = uxplayProcess, proc.isRunning, !userInitiatedTermination {
            writeStructuredLog("START ignored — uxplay pid=\(proc.processIdentifier) is still running \(timestamp())")
            return
        }
        wantsRunning = true

        // Any respawn scheduled by the crash guard is now redundant — an
        // explicit start supersedes it. Same for a pending E1 restart-start.
        cancelPendingRestart()
        cancelPendingRestartStart()

        // A fresh user-initiated start begins a new session: truncate the log.
        self.truncateLaunchLog = truncateLog
        restartAttempt = 0
        spawnUxplay(snapshot: snapshot)
    }

    // MARK: - Spawn

    /// Creates and launches the uxplay child process.
    /// - Parameters:
    ///   - snapshot: EffectiveSnapshot from ConfigEngine (IF-2).
    ///   - truncateLog: true only for a fresh session start; a crash-guard
    ///     respawn must APPEND, otherwise each respawn would wipe the CRASH
    ///     trail and the pre-crash log — destroying exactly the evidence this
    ///     fix exists to produce.
    private func spawnUxplay(snapshot: EffectiveSnapshot, truncateLog: Bool = false) {
        // Each generation gets a clean deliberate-kill mark: a stale `true`
        // leaking from a previous generation's stop() would suppress the
        // respawn of a genuine crash of this one.
        userInitiatedTermination = false

        // Spawn prerequisites (P-2.2) — resolved BEFORE anything else, because
        // `Process.run()` throws when `currentDirectoryURL` is missing and that
        // throw used to be the clean-machine symptom (press Start, nothing
        // happens). TWO locations, because they have different lifetimes:
        //   - the temp scratch directory = the child's CWD (a one-shot temporary);
        //   - `~/Library/Application Support/<bundle-id>/` = `launch.log`
        //     (kept across starts, so a stuck-green report still has its evidence
        //     after a relaunch and after the OS prunes /var/folders).
        // A failure in either is surfaced through the P-7.4 readable-error
        // path, never swallowed.
        let scratchDirectory: URL
        let logDirectory: URL
        do {
            scratchDirectory = try Self.ensureScratchDirectory()
            logDirectory = try Self.ensureLaunchLogDirectory()
        } catch {
            state = .idle
            let reason = error.localizedDescription
            eventContinuation?.yield(.error(message: Self.launchFailureMarker + reason))
            return
        }
        let logURL = logDirectory.appendingPathComponent(Self.launchLogFileName)
        launchLogURL = logURL

        // Pre-flight the helper (P-7.4). Without this a missing or non-executable
        // helper is only discovered when `Process.run()` fails, and a launch
        // failure that looks like a crash costs the user the whole backoff
        // ladder (~29s) before any legible reason appears. The failure is a
        // packaging fact, not a crash, so it is settled here — once, with the
        // path in the message.
        guard FileManager.default.isExecutableFile(atPath: Self.uxplayPath) else {
            state = .idle
            let reason = "projection helper is missing or not executable at \(Self.uxplayPath)"
            writeStructuredLog("MIRRORBOARD SPAWN-FAILED \(reason) \(timestamp())")
            eventContinuation?.yield(.error(message: Self.launchFailureMarker + reason))
            return
        }

        // stage C (wave1c): resolve the snapshot to actually spawn with through
        // the injected preparer — it rewrites the rc file and applies the P3
        // code rules before every spawn. A failure here must NOT spawn: the
        // short cause lands on the panel status row (R4-Q2=A) and the
        // receiver settles back to idle.
        let effectiveSnapshot: EffectiveSnapshot
        if let prepare = snapshotPreparer {
            do {
                effectiveSnapshot = try prepare()
            } catch {
                truncateLaunchLog = false
                state = .idle
                let reason = error.localizedDescription
                writeStructuredLog("MIRRORBOARD SPAWN-FAILED \(reason) \(timestamp())")
                eventContinuation?.yield(.error(message: Self.launchFailureMarker + reason))
                return
            }
        } else {
            effectiveSnapshot = snapshot
        }

        let process = Process()
        // The uxplay arguments come from the snapshot's argv() form (IF-2
        // §2.1) and are passed through UNCHANGED: line buffering is no longer
        // arranged by wrapping the executable in a helper tool, it is arranged
        // by the tty we hand the child (see the pty block below). One spawn
        // path for every host — no "has stdbuf / has not" fork, which is what
        // made this bug machine-dependent. It also means `process` IS uxplay:
        // the termination handler, `isRunning` and terminate() all address the
        // real PID with no exec hop in between.
        let snapshotArguments = effectiveSnapshot.argv()
        let spawnedArguments = snapshotArguments
        process.executableURL = URL(fileURLWithPath: Self.uxplayPath)
        process.arguments = spawnedArguments
        // CWD per BLUEPRINT arch-3 #11 — the scratch directory created above.
        process.currentDirectoryURL = scratchDirectory

        // Spawn environment.
        //
        // NO `DYLD_LIBRARY_PATH` here — deliberately removed (P-7.2):
        //   1. packaging rewrites the load commands inside the Mach-O headers to
        //      `@loader_path/…`, so dyld resolves the bundled dylibs with no
        //      environment help. A stale variable would now WIN over those
        //      rewritten paths (there is no exec hop to strip it any more).
        //   2. it was never effective on the old path either: uxplay used to be
        //      launched THROUGH `/usr/bin/stdbuf`, and that extra exec stripped
        //      every `DYLD_*` variable. Measured: with `DYLD_PRINT_LIBRARIES=1`
        //      a direct spawn printed 843 dyld lines, the stdbuf-wrapped spawn
        //      printed 0 — the old assignment only produced a false sense of
        //      safety.
        //
        // GStreamer still needs environment help (`gst_init` reads the child's
        // environment): the bundle places plugins, scanner and registry outside
        // GStreamer's compiled-in search paths.
        //
        // NOTE: Process.environment returns nil for a new Process instance on macOS,
        // so we must use Foundation.ProcessInfo.processInfo.environment (the parent
        // environment, a class property — no parentheses) as the base and merge
        // our overrides on top.
        var env = Foundation.ProcessInfo.processInfo.environment

        // Every value below is derived from Bundle.main (through `uxplayPath`);
        // no absolute development path is baked in.
        let pluginDirectory = Self.gstPluginDirectory.path
        // An empty string (NOT an unset variable) is what disables the
        // compiled-in system plugin directories: GStreamer treats a non-NULL
        // empty value as an empty path list, while an unset variable falls back
        // to the defaults. Without it a development machine's Homebrew plugins
        // would be scanned next to the bundled ones — and be missing entirely on
        // a clean machine.
        let pluginSystemPath = ""
        let registryPath = Self.gstRegistryURL()?.path
        let scannerPath: String? = {
            let path = Self.gstPluginScanner.path
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }()

        // The `_1_0` variants take precedence over their unsuffixed
        // counterparts in GStreamer's versioned env lookup, so a value inherited
        // from the user's shell could bypass every guard below. Both forms are
        // therefore pinned to the same bundle-owned values.
        env["GST_PLUGIN_PATH"] = pluginDirectory
        env["GST_PLUGIN_PATH_1_0"] = pluginDirectory
        env["GST_PLUGIN_SYSTEM_PATH"] = pluginSystemPath
        env["GST_PLUGIN_SYSTEM_PATH_1_0"] = pluginSystemPath
        if let scannerPath {
            env["GST_PLUGIN_SCANNER"] = scannerPath
            env["GST_PLUGIN_SCANNER_1_0"] = scannerPath
        } else {
            // Layout without the packaged scanner (raw `swift build` binary next
            // to a bundle assembled without the plugin closure): drop any
            // inherited value instead of letting it point at a development
            // install. An empty string is NOT a valid substitute — GStreamer
            // treats it as "unset" and falls back to the system scanner, which
            // is exactly the inherited-default behaviour we want here.
            env.removeValue(forKey: "GST_PLUGIN_SCANNER")
            env.removeValue(forKey: "GST_PLUGIN_SCANNER_1_0")
        }
        if let registryPath {
            env["GST_REGISTRY"] = registryPath
            env["GST_REGISTRY_1_0"] = registryPath
        }
        process.environment = env

        // Log destination + truncate policy.
        //
        // A fresh user start truncates; a crash-guard respawn appends, so the
        // CRASH trail and the pre-crash log survive the respawn.
        let shouldTruncate = truncateLog || truncateLaunchLog
        truncateLaunchLog = false
        if shouldTruncate {
            try? launchLogHandle?.close()
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        } else if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        // One handle, opened in append mode, shared by our markers and the pty
        // pump (see the launchLogHandle doc comment); O_APPEND makes every
        // write — ours and the pump's — land atomically at the current EOF.
        // Without it the handle and a dying generation's late output keep
        // independent file offsets, and those writes can be scribbled on top
        // of a marker we just appended (observed in an earlier wiring-test run).
        try? launchLogHandle?.close()
        guard let logHandle = openLaunchLogForAppend() else {
            state = .idle
            let reason = "cannot open the receiver log for appending at \(logURL.path)"
            eventContinuation?.yield(.error(message: Self.launchFailureMarker + reason))
            return
        }
        launchLogHandle = logHandle
        // Remember where this generation's output begins, so the watcher below
        // does not replay lines emitted by a previous (crashed) generation.
        // Taken from the SAME URL the watcher will poll (the AppSupport log),
        // after truncation/creation and before the spawn marker is appended —
        // so the offset is generation-correct across the P-2.2 move as well.
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        logSpawnOffset = (attrs?[.size] as? UInt64) ?? 0

        // Line buffering — the actual fix. libc picks its stdio buffering from
        // the TYPE of stdout: a regular file or a pipe gets full buffering
        // (4096 bytes), a tty gets line buffering. uxplay's `log()` is a bare
        // `printf` with no `fflush`, so on a file the last quiet stretch of
        // output never reaches `launch.log` — and the quiet stretch is exactly
        // what follows `Connection closed on socket N`. Handing the child a
        // pseudo-terminal makes every line readable immediately, with no
        // external tool (`stdbuf`) and therefore no host-dependent spawn path.
        //
        // Measured on the real helper (D2 report): with a file redirect the
        // `UxPlay 1.73.6` banner was still absent after 4s of live process; on
        // a pty it appeared at 0.076s.
        //
        // The pump thread copies the master side into launch.log, so the log
        // watcher keeps its file-polling semantics unchanged.
        let pty: (master: Int32, slave: Int32)
        do {
            pty = try Self.openPTY()
        } catch {
            state = .idle
            let reason = error.localizedDescription
            writeStructuredLog("MIRRORBOARD SPAWN-FAILED \(reason) \(timestamp())")
            eventContinuation?.yield(.error(message: Self.launchFailureMarker + reason))
            return
        }
        let generation = adoptPTY(master: pty.master, slave: pty.slave)
        let slaveHandle = FileHandle(fileDescriptor: pty.slave, closeOnDealloc: false)
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        // wave1r6 — a new generation starts with zero client connections:
        // any socket of the previous generation died with it (its close line
        // never reaches this process's census), so the stale count must not
        // survive into the new generation's apply-on-disconnect gate.
        //
        // This is the ONLY census reset point (review R3): a close line that
        // never arrived leaves a socket counted for the whole lifetime of its
        // generation — the device then reads as connected (and a pending trust
        // apply stays held) until this line runs. Traced so the reset is
        // visible next to the `SOCKET closed … live=N` lines it clears.
        logQueue.sync {
            activeSockets.removeAll()
            censusIncomplete = false
        }
        writeStructuredLog("SOCKET census reset (spawn; the only reset point — a lost close line holds a generation)")

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleTermination(of: proc)
            }
        }

        do {
            try process.run()
            uxplayProcess = process
            state = .waiting
            // The parent's slave copy has done its job (the child holds its own
            // dup): closing it is what lets the master report EOF once the
            // child exits.
            retireSlaveFD()
            // Drain the master into launch.log from here on. Started before the
            // spawn marker merely so no early child output can be missed; both
            // writers use O_APPEND so their order does not matter.
            startPTYPump(master: pty.master, generation: generation, logHandle: logHandle)
            // Spawn evidence (the stage C test ①): the exact process argv, one line
            // per spawn. Every element is `"`-quoted so values containing
            // blanks (device names, AppSupport paths) stay unambiguous.
            writeStructuredLog(Self.spawnMarker(arguments: spawnedArguments, pid: process.processIdentifier))
            startLogWatcher()
            // A generation that survived past the backoff ladder counts as
            // healthy: clear the attempt counter so an unrelated crash much
            // later in the session does not inherit a long 8s backoff.
            if restartAttempt > 0 {
                let pid = process.processIdentifier
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.healthyAfterSeconds) { [weak self] in
                    guard let self = self, let live = self.uxplayProcess, live.processIdentifier == pid else { return }
                    if self.restartAttempt > 0 {
                        self.writeStructuredLog("CRASH respawn healthy after \(Self.healthyAfterSeconds)s; backoff ladder reset \(self.timestamp())")
                        self.restartAttempt = 0
                    }
                }
            }
        } catch {
            // No pump owns the master yet — both descriptors are ours to close.
            abandonPTY()
            state = .idle
            let reason = error.localizedDescription
            writeStructuredLog("MIRRORBOARD SPAWN-FAILED \(reason) \(timestamp())")
            eventContinuation?.yield(.error(message: Self.launchFailureMarker + reason))
        }
    }

    /// One-line spawn record for the re-runnable wiring tests: the exact argv
    /// the child was started with (`MIRRORBOARD SPAWN pid=… argv="…" "…"`).
    private static func spawnMarker(arguments: [String], pid: Int32) -> String {
        let quoted = arguments.map { argument -> String in
            let escaped = argument
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: " ")
        return "MIRRORBOARD SPAWN pid=\(pid) argv=\(quoted)"
    }

    // MARK: - PTY (child stdout/stderr)

    /// Why a pseudo-terminal could not be allocated.
    enum PTYError: LocalizedError {
        case allocationFailed(code: Int32)

        var errorDescription: String? {
            switch self {
            case let .allocationFailed(code):
                let text = String(cString: strerror(code))
                return "cannot allocate a pseudo-terminal for the projection helper (errno \(code): \(text))"
            }
        }
    }

    /// Allocates a master/slave pseudo-terminal pair for the child's
    /// stdout+stderr.
    ///
    /// The pair is created with `openpty(3)`, which also gives us a sane
    /// initial `termios`; two flags are then cleared on the SLAVE so the log
    /// stays byte-identical to what a plain redirect used to produce:
    ///   - `ECHO`  — the terminal must not echo anything back;
    ///   - `OPOST` — disables `ONLCR`, so `\n` is NOT rewritten to `\r\n`.
    /// Everything else (line discipline, `ICANON`, signal chars) is left at the
    /// system default: uxplay only writes, and line buffering — the whole point
    /// — comes from `isatty(stdout)`, not from these flags.
    ///
    /// - Returns: the master (app reads) and slave (child writes) descriptors.
    /// - Throws: `PTYError.allocationFailed` (surfaced through P-7.4).
    static func openPTY() throws -> (master: Int32, slave: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            let code = errno
            if master >= 0 { _ = close(master) }
            if slave >= 0 { _ = close(slave) }
            throw PTYError.allocationFailed(code: code)
        }
        var term = termios()
        if tcgetattr(slave, &term) == 0 {
            term.c_lflag &= ~tcflag_t(ECHO)
            term.c_oflag &= ~tcflag_t(OPOST)
            _ = tcsetattr(slave, TCSANOW, &term)
        }
        return (master: master, slave: slave)
    }

    /// Publishes a freshly opened pty as the current generation and retires the
    /// previous one.
    ///
    /// Bumping the generation FIRST is what stops a previous pump: it re-checks
    /// the counter on every poll tick and exits on its own, so a new spawn never
    /// has to close a descriptor the old pump is blocked on.
    ///
    /// - Returns: the generation token the new pump must carry.
    @discardableResult
    private func adoptPTY(master: Int32, slave: Int32) -> UInt64 {
        ptyLock.lock()
        ptyGeneration &+= 1
        let generation = ptyGeneration
        ptyMasterFD = master
        ptySlaveFD = slave
        ptyLock.unlock()
        return generation
    }

    /// Closes the parent's own copy of the slave descriptor (idempotent).
    ///
    /// Must run right after `Process.run()` returns: while ANY slave descriptor
    /// is open the master never reports EOF, which would leave the pump waiting
    /// on a child that is long dead.
    private func retireSlaveFD() {
        ptyLock.lock()
        let slave = ptySlaveFD
        ptySlaveFD = -1
        ptyLock.unlock()
        if slave >= 0 { _ = close(slave) }
    }

    /// Closes a master descriptor owned by a pump that has already exited.
    ///
    /// The field is cleared only when it still refers to THIS descriptor, so a
    /// pump exiting late can never close the descriptor a newer generation has
    /// already installed.
    private func retireMasterFD(_ fd: Int32) {
        ptyLock.lock()
        if ptyMasterFD == fd { ptyMasterFD = -1 }
        ptyLock.unlock()
        _ = close(fd)
    }

    /// Releases both descriptors on the spawn-failure path, where no pump was
    /// started and therefore no other thread owns the master.
    private func abandonPTY() {
        ptyLock.lock()
        ptyGeneration &+= 1
        let master = ptyMasterFD
        let slave = ptySlaveFD
        ptyMasterFD = -1
        ptySlaveFD = -1
        ptyLock.unlock()
        if slave >= 0 { _ = close(slave) }
        if master >= 0 { _ = close(master) }
    }

    /// Retires the current pump without touching its descriptor: the pump closes
    /// the master itself as it exits (at most one 100 ms poll tick later). Used
    /// while the child may still be dying — closing the master here could race a
    /// blocking `poll()`.
    ///
    /// - Parameter generation: when given, the retirement only happens if that
    ///   generation is still current. A late timer from a finished generation
    ///   must never retire the pump a newer spawn has already installed.
    private func retirePTYPump(generation: UInt64? = nil) {
        ptyLock.lock()
        if let generation, ptyGeneration != generation {
            ptyLock.unlock()
            return
        }
        ptyGeneration &+= 1
        let slave = ptySlaveFD
        ptySlaveFD = -1
        ptyLock.unlock()
        if slave >= 0 { _ = close(slave) }
    }

    /// Retires the current pump after a short grace period.
    ///
    /// The grace exists so the pump can drain what the child wrote just before
    /// it died (a pty holds that data until it is read; retiring instantly would
    /// throw the tail of the log away — exactly the evidence a crash report
    /// needs). The generation guard makes the delayed call a no-op if the
    /// receiver was restarted in the meantime.
    private func schedulePTYRetire() {
        ptyLock.lock()
        let generation = ptyGeneration
        ptyLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.retirePTYPump(generation: generation)
        }
    }

    /// True while `generation` is still the current one.
    private func isPTYGenerationAlive(_ generation: UInt64) -> Bool {
        ptyLock.lock()
        defer { ptyLock.unlock() }
        return ptyGeneration == generation
    }

    /// Starts the master-side pump on its own thread (it blocks in `poll`).
    private func startPTYPump(master: Int32, generation: UInt64, logHandle: FileHandle) {
        let thread = Thread { [weak self] in
            self?.pumpPTY(master: master, generation: generation, logHandle: logHandle)
        }
        thread.name = "com.mirrorboard.uxplay.pty"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Copies everything the child writes to its tty into `launch.log`.
    ///
    /// Non-blocking-plus-`poll` rather than a plain blocking `read`: the 100 ms
    /// timeout is where the generation check happens, so `stop()` / a respawn
    /// shut the pump down without anyone having to close a descriptor it is
    /// blocked on.
    ///
    /// End of stream is NORMAL here and never an error:
    ///   - `read` → 0 is what macOS reports when the last slave descriptor
    ///     closes (verified against the real helper);
    ///   - `read` → -1 / `EIO` is the same event on Linux and on some Darwin
    ///     configurations.
    /// Both exit the loop and close the master. Only an unexpected `errno`
    /// breaks out the same way, silently — the receiver's state machine does not
    /// depend on this thread.
    ///
    /// - Parameters:
    ///   - fd: the pty master descriptor.
    ///   - generation: token from `adoptPTY`; a mismatch means "retired".
    ///   - logHandle: O_APPEND handle shared with `writeStructuredLog`.
    private func pumpPTY(master fd: Int32, generation: UInt64, logHandle: FileHandle) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while isPTYGenerationAlive(generation) {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[0..<count])
                try? logHandle.write(contentsOf: data)
                continue
            }
            if count == 0 { break }          // macOS: last slave copy closed
            if errno == EIO { break }        // pty close signal, not an error
            if errno == EINTR || errno == EAGAIN { continue }
            break
        }
        retireMasterFD(fd)
    }

    /// Decides whether a terminated uxplay process should be respawned.
    ///
    /// The user's intent is the authority — never the exit code:
    ///   - user-initiated (`stop()` / `quit()` / `restart()` / signal exit)
    ///     → no respawn, state → .idle, whatever the exit code (0 included)
    ///   - `.exit` / status 0 with no app-side intent → uxplay answered a
    ///     quit request made through its OWN window/UI (X / Q / ⌘Q / Dock
    ///     Quit) = user intent → no respawn, `STOP` marker, state → .idle
    ///     (incident 2026-10-16 17:35 fix)
    ///   - crash-shaped (any signal, or a non-zero exit) → bounded-backoff
    ///     respawn
    private func handleTermination(of proc: Process) {
        // Only react to the process we are currently tracking; a late callback
        // from an already-replaced process must not clobber the live one.
        guard proc === uxplayProcess else { return }

        logWatcherTask?.cancel()
        logWatcherTask = nil
        uxplayProcess = nil
        // The child is gone; let the pump drain its tty and hit EOF itself.
        schedulePTYRetire()

        // Two sources of user intent: the flag armed by the terminate() we
        // just sent, or the sticky wantsRunning cleared by stop()/quit().
        // Either one means "the user asked for this" → no respawn, exit code
        // irrelevant (our own SIGTERM makes uxplay exit 0 gracefully).
        let wasUserInitiated = userInitiatedTermination || !wantsRunning
        // Reset the flag; spawnUxplay re-arms it fresh for each generation.
        userInitiatedTermination = false

        let status = proc.terminationStatus
        let reason = proc.terminationReason

        if wasUserInitiated {
            state = .idle
            return
        }

        // Clean exit with no app-side intent = uxplay answered a quit request
        // made through its OWN window (X-close / Q / ⌘Q / Dock Quit). That is
        // user intent: stop the receiver, never respawn (incident 2026-10-16
        // 17:35). Only crash-shaped deaths (signal / non-zero exit) fall
        // through to the respawn below.
        if reason == .exit && status == 0 {
            cancelPendingRestart()
            restartAttempt = 0
            wantsRunning = false
            state = .idle
            writeStructuredLog("STOP uxplay exited with status 0 (graceful — quit via uxplay UI) — not respawning \(timestamp())")
            eventContinuation?.yield(.error(message: "uxplay was closed — receiver stopped, not respawning"))
            return
        }

        // Crash-shaped death (signal / non-zero exit) — describe it, then
        // respawn with backoff.
        let description: String
        switch reason {
        case .uncaughtSignal:
            description = "uxplay terminated by signal \(status) — respawning"
        case .exit:
            description = "uxplay exited with status \(status) — respawning"
        @unknown default:
            description = "uxplay terminated (reason \(reason.rawValue), status \(status)) — respawning"
        }
        writeStructuredLog("CRASH \(description) \(timestamp())")
        eventContinuation?.yield(.error(message: description))

        scheduleRestart()
    }

    /// Schedules an automatic respawn using the 1s/2s/4s/8s backoff ladder.
    private func scheduleRestart() {
        guard restartAttempt < Self.maxRestartAttempts else {
            writeStructuredLog("CRASH giving up after \(restartAttempt) restart attempts \(timestamp())")
            eventContinuation?.yield(.error(message: "uxplay could not be restarted after \(restartAttempt) attempts"))
            state = .idle
            return
        }

        let delay = Self.backoffDelay(for: restartAttempt)
        restartAttempt += 1
        writeStructuredLog("CRASH respawn attempt \(restartAttempt) in \(String(format: "%.0f", delay))s \(timestamp())")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // A stop() (or an explicit start()) that landed while we were
            // waiting must cancel the respawn — otherwise stop() would
            // resurrect uxplay. Dispatch may still run an item that was
            // cancelled after scheduling, so the intent is re-checked here at
            // fire time, not only at schedule time.
            guard self.wantsRunning, self.state != .idle else { return }
            // `.default` is only the no-engine fallback — an injected
            // snapshotPreparer supplies the current prepared snapshot (so a
            // crash respawn applies the latest settings and re-writes the rc
            // file before the next spawn).
            self.spawnUxplay(snapshot: .default)
        }
        pendingRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Backoff ladder: 1s, 2s, 4s, then a flat 8s ceiling.
    private static func backoffDelay(for attempt: Int) -> TimeInterval {
        switch attempt {
        case 0: return 1.0
        case 1: return 2.0
        case 2: return 4.0
        default: return 8.0
        }
    }

    /// Cancels a scheduled respawn, if any.
    private func cancelPendingRestart() {
        pendingRestartWorkItem?.cancel()
        pendingRestartWorkItem = nil
    }

    /// Cancels a pending E1 auto-restart re-start, if any.
    private func cancelPendingRestartStart() {
        pendingRestartStartWorkItem?.cancel()
        pendingRestartStartWorkItem = nil
    }

    // MARK: - Log Watcher

    private func startLogWatcher() {
        logWatcherTask?.cancel()
        logWatcherTask = Task { [weak self] in
            self?.watchLaunchLog()
        }
    }

    private func watchLaunchLog() {
        // The log location is fixed for this generation (resolved at spawn).
        guard let logPath = launchLogURL?.path else { return }
        // Re-open the handle per poll cycle: the file is rewritten/truncated on
        // a fresh start, which detaches any previously held descriptor.
        // Start at the current generation's spawn offset so a respawn does not
        // replay lines from a crashed generation.
        var offset = logSpawnOffset
        var pendingBuffer = ""

        while !Task.isCancelled {
            guard let fileHandle = FileHandle(forReadingAtPath: logPath) else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            defer { try? fileHandle.close() }

            do {
                try fileHandle.seek(toOffset: offset)
            } catch {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            let lineData = fileHandle.availableData
            if lineData.isEmpty {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            offset += UInt64(lineData.count)

            guard let chunk = String(data: lineData, encoding: .utf8) ?? String(data: lineData, encoding: .ascii) else {
                continue
            }
            pendingBuffer += chunk
            // Only complete lines (terminated by \n) are dispatched; a partial
            // tail is held until the rest arrives.
            while let newlineIndex = pendingBuffer.firstIndex(of: "\n") {
                let line = String(pendingBuffer[pendingBuffer.startIndex..<newlineIndex])
                pendingBuffer = String(pendingBuffer[pendingBuffer.index(after: newlineIndex)...])
                processLogLine(line)
            }
        }
    }

    /// Maps uxplay stdout lines to ReceiverEvent transitions.
    /// Strings verified against live uxplay stdout (see class doc comment).
    /// wave1r4 (trust increment I1): a fourth mode — the `registered new client`
    /// record — was added; it is the ONLY trust-relevant event (pairing succeeded,
    /// at the moment projection begins; a code-free reconnect does not trigger it).
    private func processLogLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // wave1r4 (trust increment I1) — the pk64 CONTINUATION of the record below.
        // uxplay's LOGI is a TWO-LINE record (`PK = \n%s`; uxplay.cpp:2624):
        //     registered new client: <name> DeviceID = <id> PK = 
        //     <pk64 (44 chars)>
        // The continuation is consumed (silently ignored — the client key is
        // not needed by the trust semantics); anything that does not look
        // like a pk64 line falls through to normal processing.
        if expectPkContinuation {
            expectPkContinuation = false
            if Self.isPk64Line(trimmed) { return }
        }

        // wave1r4 (trust increment I1) — the trust record prefix line: extract name AND
        // deviceID explicitly (the connection-request mode below never took
        // deviceID — r1b's note was a line-number miss; see spec r2 §4 I1).
        if let range = trimmed.range(of: "registered new client: ") {
            let tail = String(trimmed[range.upperBound...])
            if let idRange = tail.range(of: " DeviceID = ") {
                let name = String(tail[tail.startIndex..<idRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let idTail = String(tail[idRange.upperBound...])
                let deviceID: String
                // The line is TRIMMED before parsing, so the record's trailing
                // " " after `PK =` is gone — match the space-free tail.
                if let pkRange = idTail.range(of: " PK =") {
                    deviceID = String(idTail[idTail.startIndex..<pkRange.lowerBound])
                } else {
                    deviceID = idTail
                }
                let cleanID = deviceID.trimmingCharacters(in: .whitespaces)
                if !cleanID.isEmpty {
                    expectPkContinuation = true
                    logQueue.async { [weak self] in
                        self?.handleTrustPairingRegistered(deviceName: name, deviceID: cleanID)
                    }
                }
            }
            return
        }

        // "Accepted IPv4 client on socket 15, port 1131"
        // "Accepted IPv6 client on socket 15, port 1131"
        if trimmed.contains("Accepted IPv4 client") || trimmed.contains("Accepted IPv6 client") {
            let socket = Self.socketNumber(in: trimmed)
            logQueue.async { [weak self] in
                guard let self else { return }
                if let socket {
                    self.activeSockets.insert(socket)
                } else {
                    // Recording and judging must be symmetric (review R3): this
                    // accept cannot be attributed, so the set is no longer a
                    // complete account of this generation and must not later be
                    // read as "empty ⇒ the device is gone".
                    self.censusIncomplete = true
                    self.writeStructuredLog(
                        "SOCKET accept socket=? (unattributable; the census cannot prove an empty set this generation)")
                }
                self.handleConnected(deviceName: Self.placeholderDeviceName)
            }
            return
        }

        // "connection request from <name> (<model>) with deviceID = <id>"
        // (uxplay.cpp:2334) — this is where the real device name appears.
        if let range = trimmed.range(of: "connection request from ") {
            let tail = String(trimmed[range.upperBound...])
            if let parenIndex = tail.firstIndex(of: "(") {
                let name = String(tail[tail.startIndex..<parenIndex]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    logQueue.async { [weak self] in
                        self?.handleConnected(deviceName: name)
                    }
                }
            }
            return
        }

        // "Connection closed on socket 15"
        //
        // A close is a SOCKET event, not a device event: one client holds
        // several TCP connections (video / audio / control), so the device is
        // only offline once the LAST of them is gone. The census above is the
        // same set the trust gate reads through `liveConnectionCount`; here it
        // is consulted at the moment the connection is removed.
        //
        // Review R3 — both directions of the earlier version are closed here:
        //   A) an unparsable line (or a close for a socket this generation
        //      never accepted) used to reach an unconditional `isEmpty` test and
        //      could flip the device offline early. No number ⇒ no decision.
        //   B) a close line that never arrives keeps its socket counted, and the
        //      set then never empties (see the `activeSockets` note: the next
        //      spawn is the only reset point). That state is traced, not silent.
        if trimmed.contains("Connection closed") {
            let socket = Self.socketNumber(in: trimmed)
            logQueue.async { [weak self] in
                guard let self else { return }
                guard let socket else {
                    // We cannot say WHICH connection ended, so we cannot say the
                    // device is gone: no flip, no `.disconnected`, trace only.
                    self.writeStructuredLog(
                        "SOCKET closed socket=? live=\(self.activeSockets.count) (unattributable; no device-level decision)")
                    return
                }
                let wasTracked = self.activeSockets.remove(socket) != nil
                guard self.activeSockets.isEmpty else {
                    // Another connection of the same session is still up: no
                    // state flip and no `.disconnected` (the panel stays on
                    // the connected presentation and the session notifier
                    // stays quiet). The trace keeps the socket-level fact
                    // greppable, including the surviving count.
                    self.writeStructuredLog(
                        "SOCKET closed socket=\(socket) live=\(self.activeSockets.count) (device still connected)")
                    return
                }
                // The set is empty — but that is a DEVICE-level fact only when
                // the socket we just removed was one we recorded, and every
                // accept of this generation could be attributed.
                guard wasTracked else {
                    self.writeStructuredLog(
                        "SOCKET closed socket=\(socket) live=0 (untracked socket; no device-level decision)")
                    return
                }
                guard !self.censusIncomplete else {
                    self.writeStructuredLog(
                        "SOCKET closed socket=\(socket) live=0 (census incomplete this generation; no device-level decision)")
                    return
                }
                self.handleDisconnected()
            }
        }
    }

    /// Extracts the socket number from an uxplay log line (`… on socket 15…`)
    /// — the raw material of the wave1r6 socket census. `nil` when the line
    /// carries no number (defensive; both known formats do).
    private static func socketNumber(in line: String) -> Int? {
        guard let range = line.range(of: "socket ") else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// A client connection was accepted.
    ///
    /// uxplay emits TWO records per device (`Accepted … client on socket N`,
    /// which carries no name, then `connection request from <name>`), and a
    /// second connection of the same session repeats an accept.
    ///
    /// The two suppressions below are NOT the same rule (review R2):
    ///   - the SAME name again = the same identity re-stated by a second socket
    ///     of one session → no state write, no second `.connected` (every event
    ///     reaches the session notifier, so a repeat would send a "connected"
    ///     notification for a session that never went away);
    ///   - the PLACEHOLDER (`Unknown Device`, what the accept path carries
    ///     before the name is revealed) is "no identity yet", not an identity:
    ///     it must never overwrite a name already known for this session, or
    ///     the panel would fall back to `Unknown Device` and uxplay would never
    ///     correct it (the name comes once, on the setup line).
    /// A DIFFERENT real name is still the reveal / a new device and re-yields,
    /// because the panel has to pick that name up.
    private func handleConnected(deviceName: String) {
        if case .connected(let currentName) = state {
            if currentName == deviceName { return }
            if deviceName == Self.placeholderDeviceName { return }
        }
        state = .connected(deviceName: deviceName)
        eventContinuation?.yield(.connected(deviceName: deviceName))
        writeStructuredLog("CONNECTION \(deviceName) \(timestamp())")
    }

    /// wave1r4 (trust increment I1) — one PIN pairing completed and uxplay wrote the
    /// client into its registry. The event carries the explicitly-extracted
    /// name + deviceID up to the AppShell decision layer (UILog evidence is
    /// written there — this module stays log-file free of UI concerns).
    /// No state transition: registration is not a connection event.
    private func handleTrustPairingRegistered(deviceName: String, deviceID: String) {
        eventContinuation?.yield(.trustPairingRegistered(deviceName: deviceName, deviceID: deviceID))
    }

    /// True when the line looks exactly like the pk64 continuation — base64
    /// (44 chars, ending in the single `=` pad of a 32-byte key). Anything
    /// else is NOT swallowed by the continuation consumer.
    private static func isPk64Line(_ line: String) -> Bool {
        guard line.count == 44, line.hasSuffix("=") else { return false }
        let base64 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        return line.dropLast().unicodeScalars.allSatisfy { base64.contains($0) }
    }

    private func handleDisconnected() {
        state = .waiting
        eventContinuation?.yield(.disconnected)
        writeStructuredLog("DISCONNECTION \(timestamp())")
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// Appends a structured marker to launch.log.
    ///
    /// Writes through the SAME handle that was handed to the uxplay child, so
    /// markers and child output share one append position; the O_APPEND
    /// open additionally makes every write land atomically at the current
    /// EOF (no stale-offset overwrites). Falls back to a fresh append handle
    /// if the cached one is gone (e.g. the file was truncated by a fresh
    /// start).
    private func writeStructuredLog(_ message: String) {
        let line = message + "\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = launchLogHandle {
            if (try? handle.write(contentsOf: data)) != nil { return }
        }
        // Fallback: reopen and append.
        if let handle = openLaunchLogForAppend() {
            try? handle.write(contentsOf: data)
            launchLogHandle = handle
        }
    }

    /// Opens launch.log for appending with O_APPEND — every write (ours and
    /// the child's) is placed by the kernel at the current EOF. Closing is
    /// explicit (`launchLogHandle?.close()` at the next spawn).
    private func openLaunchLogForAppend() -> FileHandle? {
        guard let path = launchLogURL?.path else { return nil }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    /// Stops the receiver (menu "Stop" / quit() / termination cleanup).
    ///
    /// Any uxplay termination caused by this call — including uxplay's own
    /// graceful `exit(0)` after our SIGTERM is delivered — must never be
    /// respawned.
    public func stop() {
        // Sticky intent: nothing about this receiver may respawn from now on.
        wantsRunning = false

        // Arm the deliberate-kill flag BEFORE terminate(). It is SET, never
        // cleared, while a kill is in flight: on the quit() path stop() runs
        // twice (quit() itself, then the AppKit termination sequence) and the
        // second call must not erase the first call's user intent.
        if uxplayProcess != nil {
            userInitiatedTermination = true
        }
        cancelPendingRestart()
        cancelPendingRestartStart()

        logWatcherTask?.cancel()
        logWatcherTask = nil
        // Same grace as handleTermination: the pump drains the tty, then exits
        // and closes the master on its own.
        schedulePTYRetire()
        if let proc = uxplayProcess, proc.isRunning {
            proc.terminate()
            // Deliberately KEEP uxplayProcess set until the termination
            // handler runs. The handler is asynchronous; nil-ing the pointer
            // here would make it take the stale-callback early return instead
            // of the explicit user-initiated branch — i.e. suppression would
            // be an accident of ordering rather than the documented rule.
            // Keeping the pointer lets handleTermination see
            // proc === uxplayProcess, consume the flag, and take the no-respawn
            // path (the handler clears the pointer itself).
        } else {
            // Nothing running (or already reaped): clear immediately.
            uxplayProcess = nil
        }
        restartAttempt = 0
        state = .idle
    }

    /// E1 (IF-1: the auto-restart carrier) — stop, then re-spawn with the
    /// given snapshot after a short hand-off gap.
    ///
    /// Distinct from `start()` in two contract-relevant ways:
    ///   - the log APPENDS (the pre-restart trail survives next to the new
    ///     generation's output; only a fresh user start truncates);
    ///   - the "wants running" intent is re-armed across the gap, so the
    ///     internal stop() is not mistaken for a user stop by the crash
    ///     guard. A genuine user stop landing in the gap clears the intent
    ///     again, and this pending re-start is cancelled (no zombie spawn).
    public func restart(snapshot: EffectiveSnapshot) {
        stop()
        wantsRunning = true
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Fire-time re-check: Dispatch may still run an item that was
            // cancelled after scheduling — a user stop during the gap must
            // win over this auto-restart.
            guard self.wantsRunning else { return }
            self.beginStart(snapshot: snapshot, truncateLog: false)
        }
        pendingRestartStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    public func attachSurface(to host: any SurfaceHost) {
        // J2-① embedded leg: surface attachment handled by native renderer bridge
    }
}