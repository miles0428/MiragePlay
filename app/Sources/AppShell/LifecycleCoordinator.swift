import AppKit
import Localization
import ReceiverKit
import ConfigEngine
import ContainerKit
import SessionNotifier
import SleepGuard
import SettingsUI
import core_bridge

/// S1-S5 state machine orchestrator.
///
/// CP-2 / increment ① (2026-10-16): receiver start/stop is UI-driven — the
/// only entry points are the panel's start/stop button (via StatusItemMenu)
/// plus the quit path. Nothing is started at app launch. Every transition is
/// pushed to the menu bar UI (icon colour + panel) via `refreshStatusItem()`.
final class LifecycleCoordinator {

    enum CoordinatorState: Equatable {
        case idle
        case waiting
        case connected(deviceName: String)
        case stopping

        static func == (lhs: CoordinatorState, rhs: CoordinatorState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.waiting, .waiting): return true
            case (.connected(let a), .connected(let b)): return a == b
            case (.stopping, .stopping): return true
            default: return false
            }
        }
    }

    private(set) var currentState: CoordinatorState = .idle

    var receiverController: ReceiverController?
    var configEngine: ConfigEngineProtocol?
    var containerKit: RootContainerView?
    /// J3-5a ⑩ — injected by CompositionRoot; driven by `applySleepGuard()`.
    var sleepGuard: SleepAssertion?
    /// J3-5b ⑪ — injected by CompositionRoot; fed from `onReceiverEvent`.
    var sessionNotifier: SessionNotifier?
    var statusItemMenu: StatusItemMenu?
    /// wave1r4 (trust increment) — the single trust-registry writer (✕ / Reset / the
    /// dialog's do-not-trust all share it; the I6 write-side seam). Injected by CompositionRoot. All three
    /// removal paths decide HERE.
    /// wave1r6 (trust timing fix; three YC rulings overturned M2) — the writer still only
    /// writes the file; the TIMING decision moved to the pending-apply gate
    /// below (after the file write it sets pending → an E1 restart once that session's last live connection drops).
    var trustRegistry: TrustRegistryHandler?

    /// wave1r6 (trust timing fix) — pending-apply flag: an effective trust removal
    /// (do-not-trust / ✕ / Reset; removed ≥ 1) wrote the registry, and uxplay only
    /// ever reads that file at spawn (its trust decision consults the in-memory
    /// `registered_keys` and never re-reads — debug_trust-timing §1.1 fact B), so the
    /// change must be made effective at the session boundary:
    ///
    ///   - set on every effective removal write;
    ///   - APPLIED (E1 restart, the same carrier as settingsChanged) when the
    ///     LAST live connection drops (socket census gate — another device online must not
    ///     or immediately when the removal lands with zero live connections
    ///     be kicked); the "answer do-not-trust only after disconnect" corner; the dirty flag);
    ///   - NEVER force-applied mid-projection (.connected)— red line: no
    ///     kicking of the ongoing session;
    ///   - cleared at the next spawn (`receiverStartPrepared` — the registry
    ///     reload evidence);
    ///   - the apply event also ROTATES the PIN (`changePin` — a hard block: the iOS
    ///     client auto-enters its last PIN, so only a code it has never seen
    ///     actually blocks it; the one-line reversal note is in the wave1r6 report "do not rotate automatically").
    private(set) var trustRegistryDirty = false

    /// wave1r6 (trust timing fix) — the PIN-rotation leg of the trust apply
    /// (rotate the PIN on apply). Injected by CompositionRoot as
    /// `ConfigEngine.changePin()` — the very same mechanism the panel's
    /// the panel's regenerate button uses (lifecycle ownership stays in the shell wiring; the
    /// coordinator keeps the decision + the evidence).
    var trustPinRotator: (() -> Void)?

    /// User-initiated start — the panel's start button (2026-10-16 ruling:
    /// the receiver opens only when the user clicks start in the panel). This is the ONLY regular start path; the old
    /// self-start at launch was Stage1 scaffolding and has been removed.
    func start() {
        guard currentState == .idle || currentState == .stopping else { return }
        currentState = .waiting
        refreshStatusItem()
        // stage E (wave1e) ⑩: scope = while the receiver runs — the sleep assertion is
        // derived from (receiver started ∧ prevent-sleep on) on every transition.
        applySleepGuard()
        let snapshot = configEngine?.effectiveSnapshot() ?? .default
        receiverController?.start(snapshot: snapshot)
    }

    /// Stops the receiver (menu "Stop"). Doubles as the cleanup entry point
    /// from `applicationWillTerminate`: it never calls NSApplication.terminate,
    /// so it is safe to run while AppKit is already tearing the app down.
    func stop() {
        currentState = .stopping
        refreshStatusItem()
        // ReceiverController.stop() is where the user intent lands
        // (CoreBridgeReceiverController.stop() sets wantsRunning = false), so
        // the crash guard treats this termination as user-initiated and never
        // respawns it — S4/D5: the panel's stop button is the ONLY regular shutdown path.
        receiverController?.stop()
        // The Stage1 leg stops promptly: settle straight back to idle so the
        // panel shows not-started / start again ("stopping" is a transition marker only).
        currentState = .idle
        refreshStatusItem()
        // ⑩ red line: the assertion must already be released in the receiver's stopped state.
        applySleepGuard()
    }

    /// User-initiated quit (menu "Quit MiragePlay" / Cmd+Q): stop the
    /// receiver, then ask AppKit to begin the termination sequence. This is the
    /// ONLY place allowed to call terminate() — `applicationWillTerminate`
    /// must call `stop()` instead, because terminate() re-enters that
    /// notification and turns the quit into an infinite recursion (the app
    /// becomes unquittable).
    func quit() {
        receiverController?.stop()
        // S5 collects everything: drop the power assertion now — the terminate
        // sequence re-enters via applicationWillTerminate → stop() (also
        // releases; idempotent), this just makes the intent explicit and
        // independent of that re-entry.
        currentState = .idle
        applySleepGuard()
        NSApplication.shared.terminate(nil)
    }

    func onReceiverEvent(_ event: ReceiverEvent) {
        switch event {
        case .connected(let deviceName):
            currentState = .connected(deviceName: deviceName)
            containerKit?.showMirrorWindow()
            // ⑪ (stage E): feed the SessionNotifier from the single event source
            // (IF-1 events; the notifier translates + dispatches
            // unconditionally — D8: the retained B2 slot gates nothing).
            sessionNotifier?.handle(event)
        case .disconnected:
            currentState = .waiting
            containerKit?.hideMirrorWindow()
            sessionNotifier?.handle(event)
            // wave1r6 — T1 (YC's main scenario): the last connection dropped while a
            // trust removal was pending → restart now so uxplay reloads the
            // registry (the removal takes effect). The socket census gate answers "no other
            // effective connection" — another device still projecting keeps it held.
            // wave1r6b N-1 (race guard) — a `.disconnected` that LAGS behind
            // stop()/quit() (the close line was already read/dispatched, the
            // buffered event gets consumed after the receiver settled) must
            // NOT run the apply gate: with a pending removal it would
            // restart() the very receiver the user just closed (a false revival, which
            // user-intent). A live T1 arrives here with the CoreBridge state
            // already `.waiting` (`handleDisconnected` sets it before
            // yielding)— the stale case is the only one that reads `.idle`.
            if receiverController?.state != .idle {
                applyTrustRegistryIfGated(origin: "disconnect", viaDisconnect: true)
            } else {
                UILog.line("TRUST apply skipped (stale disconnect after stop; receiver idle)")
            }
        case .trustPairingRegistered(let deviceName, let deviceID):
            // wave1r4 (trust increment I1/I2) — a PIN pairing completed and uxplay
            // registered the client. This is the ONE trigger for the trust
            // ask (T1'': at the moment pairing succeeds and projection begins):
            //   - log the parsed event (UILog keeps the trace);
            //   - PIN on → present the ask "trust <name>? = remembered, no code next
            //     time" (semantics = convenience; neither answer affects the current connection);
            //   - PIN off → never shown, no effect (the trust semantics exist only while the PIN
            //     is on; and with the PIN off uxplay never triggers register at all — this gate is redundant defence).
            // No state transition: registration is not a connection event.
            UILog.line("TRUST event registered new client name=\(deviceName) deviceID=\(deviceID)")
            guard configEngine?.effectiveSnapshot().pinEnabled ?? false else {
                UILog.line("TRUST event ignored (pin off) deviceID=\(deviceID)")
                return
            }
            statusItemMenu?.presentTrustPrompt(deviceName: deviceName, deviceID: deviceID)
            return
        case .error(let message):
            // A crash the guard will respawn from keeps the receiver
            // non-idle → keep showing waiting (ruling ④: a crash-recovery respawn maps
            // straight to waiting — no extra case, no fourth visual). A launch failure or a
            // guard give-up leaves the receiver idle → show not-started.
            let receiverState = receiverController?.state ?? .idle
            currentState = (receiverState == .idle) ? .idle : .waiting
            refreshStatusItem()
            // ⑩: a settled give-up (receiver now idle) must not leave the
            // sleep assertion behind; error is NOT a ⑪ notification.
            applySleepGuard()
            // R4-Q2=A: a settled launch failure shows its short cause on the
            // panel status row ("Start failed: <short reason>"). Reuses the existing
            // status row — no new visual element; the next transition
            // renders the standard strings again.
            // stage G: the core bridge flags launch failures with the
            // language-neutral "SPAWN-FAILED" marker; the panel composes the
            // localized prefix from the term dictionary (§B a2) so the row
            // follows the selected language (EN default = "Start failed: …").
            if receiverState == .idle, let reason = Self.launchFailureReason(from: message) {
                statusItemMenu?.showStatusFailure(reason: reason)
            }
            return
        }
        refreshStatusItem()
        applySleepGuard()
    }

    /// E1 (S3) — a committed settings write landed (the engine already
    /// persisted it; ⑫ auto write-back).
    ///
    ///   - Running (waiting/connected): auto-restart the receiver so the change
    ///     takes effect immediately — IF-1 `restart(snapshot:)` is the
    ///     E1 carrier. E4: the panel keeps its start-button presentation — the
    ///     existing "Waiting for connection…" string reflects the re-apply; no new visual
    ///     element, no flip back to not-started.
    ///   - Not started (not-started/transition): pure write-back — nothing to
    ///     restart; the next start picks the values up.
    ///
    /// The restart's snapshot is re-prepared inside the receiver right
    /// before each spawn (P3 code rules + rc rewrite), so it always carries
    /// the latest values even if several changes land back-to-back.
    func settingsChanged() {
        switch currentState {
        case .idle, .stopping:
            UILog.line("ACTION settings-changed (write-back only)")
            return
        case .waiting, .connected:
            UILog.line("ACTION settings-changed (restart)")
            // E4: stay in the "started" presentation while the receiver
            // re-applies; the status row uses the existing waiting string.
            currentState = .waiting
            refreshStatusItem()
            let snapshot = configEngine?.effectiveSnapshot() ?? .default
            receiverController?.restart(snapshot: snapshot)
        }
    }

    /// E1 exception (prevent-sleep = shell-held; contract L742) — the prevent-sleep switch
    /// changed. Re-applies the ⑩ sleep assertion IMMEDIATELY and does NOT
    /// touch the receiver: no restart, no spawn (instant effect, receiver untouched).
    /// While not running the value is a pure write-back and the assertion
    /// stays released; the next start picks the value up.
    func preventSleepChanged() {
        let on = configEngine?.effectiveSnapshot().preventSleep ?? true
        UILog.line("ACTION prevent-sleep \(on ? "on" : "off") (shell-held, no restart)")
        applySleepGuard()
    }

    /// E1 exception (connection notification = shell-held; contract L742) — the retained B2 slot
    /// changed. D8: nothing in the delivery path reads this value any more
    /// (NOTIFY is unconditional), so there is nothing to re-arrange and the receiver
    /// is NOT touched: no restart, no spawn. The hook stays as the
    /// shell-held trace of the slot's own value.
    func notificationsChanged() {
        let on = configEngine?.effectiveSnapshot().notificationsEnabled ?? true
        UILog.line("ACTION notifications \(on ? "on" : "off") (shell-held, no restart)")
    }

    /// E1 exception (language = shell-held; contract L742 row 12 "language = shell-held,
    /// instant effect, receiver untouched") — the language picker changed. The UI re-renders
    /// through the LanguageService observers (the adapter already flipped
    /// them); this hook only traces the change so scripts can assert the
    /// receiver was NOT touched (zero restart / zero spawn; running or not).
    func languageChanged() {
        let code = configEngine?.effectiveSnapshot().language ?? LanguageService.fallbackLanguage
        UILog.line("ACTION language \(code) (shell-held, no restart)")
    }

    // MARK: - Trust (wave1r4 / wave1r6) — the decision layer; all three removal entries share one writer (I6)

    /// dialog answer (M1/T2''): trust = keep the registry (zero action — registration is already
    /// a fact); do-not-trust = removal plus file write. wave1r6: an EFFECTIVE removal (removed ≥ 1) raises the
    /// pending-apply flag and runs the apply gate (apply on disconnect).
    func trustPromptAnswered(deviceID: String, trusted: Bool) {
        guard let trustRegistry else { return }
        if trusted {
            trustRegistry.keep(deviceID: deviceID, origin: "prompt")
        } else if trustRegistry.removeDevice(machineCode: deviceID, origin: "prompt") {
            markTrustRegistryDirty(origin: "prompt")
        }
    }

    /// the editor's per-row ✕ (the same removal mechanism; origin=editor).
    func trustDeviceRemoved(machineCode: String) {
        guard let trustRegistry else { return }
        if trustRegistry.removeDevice(machineCode: machineCode, origin: "editor") {
            markTrustRegistryDirty(origin: "editor")
        }
    }

    /// the editor's one-click Reset (registry truncate to 0; the same mechanism).
    func trustResetRequested(rows: Int) {
        guard let trustRegistry else { return }
        if trustRegistry.resetAll(origin: "editor", rows: rows) {
            markTrustRegistryDirty(origin: "editor")
        }
    }

    // MARK: - wave1r6 trust apply gate (apply on disconnect)

    /// An effective removal landed. First removal of a cycle marks the flag
    /// and evaluates the gate immediately; a second removal inside the same
    /// cycle only refreshes the trace (the file write itself is already
    /// covered — the in-flight/next spawn loads the whole file).
    private func markTrustRegistryDirty(origin: String) {
        guard !trustRegistryDirty else {
            UILog.line("TRUST pending updated origin=\(origin) (cycle already pending)")
            return
        }
        trustRegistryDirty = true
        UILog.line("TRUST pending set origin=\(origin)")
        applyTrustRegistryIfGated(origin: origin, viaDisconnect: false)
    }

    /// The one apply gate. Entry points: every effective removal write
    /// (viaDisconnect=false) and every `.disconnected` event
    /// (viaDisconnect=true). Rules (see the `trustRegistryDirty` doc):
    ///   - receiver not running → defer to the next start (that spawn loads
    ///     the new file anyway); rotate the PIN now so the next session
    ///     cannot be entered through the client's remembered code;
    ///   - `.connected` → HELD (red line: never force an apply while a projection is running);
    ///   - `.waiting` + live connections → HELD (another device online must not be kicked);
    ///   - `.waiting` + zero live connections → APPLY (restart + PIN rotate).
    private func applyTrustRegistryIfGated(origin: String, viaDisconnect: Bool) {
        guard trustRegistryDirty else { return }
        guard configEngine?.effectiveSnapshot().pinEnabled ?? false else {
            // PIN off = no trust semantics (-reg is not passed, the registry is never read) — skip the cycle.
            trustRegistryDirty = false
            UILog.line("TRUST apply dropped origin=\(origin) (pin off — no trust semantics)")
            return
        }
        let live = receiverController?.liveConnectionCount ?? 0
        switch currentState {
        case .idle, .stopping:
            _ = rotateTrustPin(context: "deferred")
            UILog.line("TRUST apply deferred origin=\(origin) (receiver not running; next start loads registry)")
        case .waiting:
            if live == 0 {
                performTrustApply(gate: viaDisconnect ? "disconnect" : "immediate")
            } else if viaDisconnect {
                UILog.line("TRUST apply held live=\(live) (disconnect gate)")
            } else {
                UILog.line("TRUST apply held origin=\(origin) live=\(live) (clients still connected)")
            }
        case .connected:
            UILog.line("TRUST apply held origin=\(origin) live=\(live) (connected; awaits disconnect)")
        }
    }

    /// Performs the boundary apply: rotate the PIN, then E1-restart the
    /// receiver (same carrier as `settingsChanged`) so the next spawn reloads
    /// the registry. The pending flag is cleared by the spawn hook
    /// (`receiverStartPrepared`), not here — a removal landing inside the
    /// 0.5s restart gap folds into the approaching spawn instead of
    /// scheduling a second restart.
    private func performTrustApply(gate: String) {
        guard trustRegistryDirty, currentState == .waiting else { return }
        // red line: never reached while a connection is projecting — the gate
        // only calls this from the `.waiting` + live==0 corner.
        let rotated = rotateTrustPin(context: gate)
        UILog.line("TRUST apply gate=\(gate) restart=1 pin-rotated=\(rotated ? 1 : 0)")
        currentState = .waiting
        refreshStatusItem()
        let snapshot = configEngine?.effectiveSnapshot() ?? .default
        receiverController?.restart(snapshot: snapshot)
    }

    /// rotate the PIN on apply (wave1r6) — regenerates the stored code through
    /// the same mechanism as the panel's regenerate button (`ConfigEngine.changePin`) so
    /// the client's auto-entered last PIN no longer matches (a hard block).
    /// The panel + preferences window are re-read immediately (the panel shows it in sync;
    /// the spawn-time `receiverStartPrepared` refresh follows).
    /// the one-line reversal note (YC): "do not rotate automatically" → remove this call, keep the restart.
    @discardableResult
    private func rotateTrustPin(context: String) -> Bool {
        guard let engine = configEngine, engine.effectiveSnapshot().pinEnabled,
              let rotator = trustPinRotator else { return false }
        rotator()
        UILog.line("TRUST pin-rotate applied (\(context)) — stored code regenerated (breaks client PIN auto-entry)")
        statusItemMenu?.refreshPinDisplays()
        return true
    }

    /// Test seam (UITestDriver / scripts/test-sleep-notify.sh): injects a
    /// receiver event through the exact path a real CoreBridge event takes
    /// (`.connected`/`.disconnected` feed the state chain AND the
    /// SessionNotifier). The real-connect leg still needs a device (⑪ marked as a YC
    /// hands-on item) — this drives the same code path for the notification flow.
    func injectReceiverEvent(_ event: ReceiverEvent) {
        onReceiverEvent(event)
    }

    /// ⑩ (stage E) — re-derives the SleepGuard assertion from
    /// "the receiver is running ∧ prevent-sleep is on" and applies it. Called by AppShell on
    /// every ReceiverState transition (contract arch-3 #6: AppShell calls this on every
    /// ReceiverState transition) and by `preventSleepChanged()`. Logs only
    /// actual transitions (held / released)— the pmset red line itself is
    /// asserted by scripts/test-sleep-notify.sh.
    private func applySleepGuard() {
        guard let sleepGuard else { return }
        let receiverRunning: Bool
        switch currentState {
        case .waiting, .connected:
            receiverRunning = true
        case .idle, .stopping:
            receiverRunning = false
        }
        let preventSleep = configEngine?.effectiveSnapshot().preventSleep ?? true
        if receiverRunning && preventSleep {
            if sleepGuard.enable() {
                UILog.line("SLEEPGUARD assertion held")
            }
        } else {
            if sleepGuard.disable() {
                UILog.line("SLEEPGUARD assertion released")
            }
        }
    }

    /// stage D spawn-prepare hook — called from CompositionRoot's
    /// `snapshotPreparer` right after the engine prepared a receiver start
    /// (the P3 unset mode regenerates the code at every receiver start). Re-reads
    /// the PIN truth into the PIN surfaces so the displayed code is always
    /// the code the receiver is actually spawning with (panel code row +
    /// preferences window while open).
    /// wave1r6: every spawn also reloads the trust registry — the pending
    /// apply flag is consumed here (`TRUST pending cleared at spawn`,
    /// the automated "a disconnect-triggered restart really does load the new file" evidence).
    func receiverStartPrepared() {
        statusItemMenu?.refreshPinDisplays()
        if trustRegistryDirty {
            trustRegistryDirty = false
            UILog.line("TRUST pending cleared at spawn (registry reloaded)")
        }
    }

    /// stage G: strips the language-neutral launch-failure marker off an
    /// `.error` message (the R4-Q2=A carry-over channel; `nil` = not a settled launch
    /// failure). The user-visible prefix is composed by the panel from the
    /// term dictionary (§B a2), so the row follows the selected language.
    private static func launchFailureReason(from message: String) -> String? {
        guard message.hasPrefix(CoreBridgeReceiverController.launchFailureMarker) else {
            return nil
        }
        return String(message.dropFirst(CoreBridgeReceiverController.launchFailureMarker.count))
    }

    /// Pushes the coordinator state to the menu bar UI (icon colour + panel
    /// status row/button). Single funnel so no transition can forget the UI.
    private func refreshStatusItem() {
        switch currentState {
        case .idle:
            statusItemMenu?.updateState(.idle)
        case .waiting:
            statusItemMenu?.updateState(.waiting)
        case .connected(let deviceName):
            statusItemMenu?.updateState(.connected(deviceName: deviceName))
        case .stopping:
            statusItemMenu?.updateState(.stopping)
        }
    }
}
