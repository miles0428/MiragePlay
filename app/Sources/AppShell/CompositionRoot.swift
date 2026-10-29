import Foundation
import ReceiverKit
import ConfigEngine
import SleepGuard
import SessionNotifier
import Localization
import SettingsUI
import core_bridge

/// Composition root — injects the J2 enabled leg and wires every protocol
/// into a car (BLUEPRINT arch-3 #1: only AppShell may import all modules).
///
/// CP-2 / increment ① (2026-10-16) wiring added:
///   1. StatusItemMenu is now actually INSTANTIATED and injected into the
///      coordinator (previously the item had zero instantiation points, so
///      the menu bar icon never appeared — the CP-2 acceptance gap).
///   2. The receiver's event stream is subscribed ONCE here and forwarded to
///      the coordinator state machine — the panel's status row
///      (not started / waiting for a connection / connected: device name) is fed from
///      stdout events (ReceiverEvent).
final class CompositionRoot {

    /// Retains the single event-stream consumer task.
    private var eventTask: Task<Void, Never>?

    /// Retains the preferences-window intent adapter (stage C): the status-item
    /// menu holds it too, while the preferences window holds it weakly.
    private var preferencesIntent: PreferencesIntentHandler?

    /// Builds the fully wired coordinator.
    func build() -> LifecycleCoordinator {
        let coordinator = LifecycleCoordinator()

        // Stage2-B (2a): the real ConfigEngine — model/presets/profiles/key
        // vault/rc-argv snap/PIN (IF-2). Read side wired below; the stage C
        // wires the write side (preferences intent + spawn preparation).
        let configEngine = ConfigEngine()

        // stage G (wave1g): the language landing — the term dictionary is
        // written in config (contract L146/L147; fill-in point
        // `app/Resources/Strings/terms.json`; an env override lets the test
        // harness point at a fixture) and every surface looks terms up in
        // the selected language. The initial language is the PERSISTED
        // engine truth — a fresh install defaults to English (R4-Q1).
        let localization = LanguageService(
            dictionaryURL: LanguageService.dictionaryURL(
                environment: ProcessInfo.processInfo.environment),
            language: configEngine.currentModel.language
        )
        // Missing-term evidence (a missing key is never silent): one line per
        // that needed a fallback — asserted by scripts/test-language.sh.
        localization.onMissingTerm = { term, language, fallback in
            UILog.line("LANG missing term=\(term) lang=\(language) fallback=\(fallback)")
        }

        // J2-①: embedded (native-macos-renderer) — Stage2: full C bridge
        let receiver = CoreBridgeReceiverController()

        // stage C (wave1c): every spawn prepares through the engine — rc-file
        // rewrite + P3 code rules. A `-rc <path>` whose file is missing
        // makes uxplay exit(0) at startup (uxplay.cpp:2986-2991), which the
        // crash guard cannot distinguish from a graceful quit, so this
        // closure must run before EVERY spawn (see the controller).
        // stage D (wave1d): after preparation the PIN truth is re-read into the
        // PIN displays — the P3 unset code regenerates at every receiver
        // start, so the shown code must follow the freshly prepared one.
        receiver.snapshotPreparer = { [weak coordinator] in
            let snapshot = try configEngine.prepareForReceiverStart()
            coordinator?.receiverStartPrepared()
            return snapshot
        }

        coordinator.configEngine = configEngine
        coordinator.receiverController = receiver

        // wave1r4 (trust increment) — the trust registry: `registration.list` I/O
        // (read = the editor rows are the truth; write = ✕ / Reset / the dialog's
        // do-not-trust answer all share one writer — the I6 write-side seam).
        // (`regPath`; AppSupport only). The handler only writes the file;
        // wave1r6: the TIMING/apply decisions live in the coordinator's
        // pending gate (apply on disconnect).
        let trustRegistryStore = TrustRegistryStore(regPath: KeyVault().regPath)
        let trustRegistry = TrustRegistryHandler(store: trustRegistryStore)
        coordinator.trustRegistry = trustRegistry

        // wave1r6 (trust timing fix) — the PIN-rotation leg of the trust apply
        // (rotate the PIN on apply): the SAME engine write the panel's regenerate
        // performs (`changePin` — stored code regenerated), so the iOS
        // client's auto-entered last PIN no longer matches (hard block).
        coordinator.trustPinRotator = {
            _ = configEngine.changePin()
        }

        // stage E (wave1e) ⑩ SleepGuard: the two-state unit is injected here and
        // driven by the coordinator on every ReceiverState transition /
        // prevent-sleep switch flip (scope = while the receiver runs; the receiver's
        let sleepGuard = SleepAssertion()
        coordinator.sleepGuard = sleepGuard

        // stage E (wave1e) ⑪ SessionNotifier: the event container — fed from
        // the coordinator's event funnel, delivering to subscribers. D8: the
        // settings-page switch was withdrawn and the B2 slot no longer gates
        // delivery, so nothing is injected here — dispatch is unconditional
        // (SRP-5: the notifier still holds no configuration state).
        let sessionNotifier = SessionNotifier()
        // stage G: notification texts render in the selected language at
        // dispatch time (instant switchover).
        sessionNotifier.localization = localization
        coordinator.sessionNotifier = sessionNotifier

        // Receiver events → coordinator state machine (feeds the panel's
        // status row). Access `events` exactly once: the getter installs the
        // single continuation that CoreBridge yields into.
        let events = receiver.events
        eventTask = Task { [weak coordinator] in
            for await event in events {
                guard let coordinator = coordinator else { return }
                await MainActor.run {
                    coordinator.onReceiverEvent(event)
                }
            }
        }

        // stage C (wave1c): the preferences-window intent adapter — engine
        // write + E1 signal (the coordinator owns the restart arrangement).
        // stage G: it also flips the language service in step with the engine.
        let intentHandler = PreferencesIntentHandler(
            engine: configEngine, coordinator: coordinator, localization: localization)
        preferencesIntent = intentHandler

        // J1: menu bar shell — status item + anchored panel (CP-2 ①).
        // wave1r3 (B2 ruling ②): the ⑫ profile provider plumbing was the dropdown's
        // truth channel — the dropdown UI is GONE from the settings window, so
        // it retires with it; the ENGINE surface (listProfiles/previewProfile/
        // saveProfile) stays untouched and stays hidden.
        // stage G (wave1g): the language service rides the dictionary lookups in every
        // surface.
        // wave1r4: the trust editor's row source — a READ of the registry
        // (tolerant + deduped); the WRITE side rides `coordinator.trustRegistry`.
        let statusItemMenu = StatusItemMenu(
            lifecycleCoordinator: coordinator,
            localization: localization,
            preferencesIntent: intentHandler,
            trustDevicesProvider: {
                trustRegistryStore.entries().map { entry in
                    TrustDeviceEntry(
                        machineCode: entry.machineCode,
                        name: entry.name.isEmpty ? entry.machineCode : entry.name
                    )
                }
            }
        )
        // stage G evidence: the dictionary load line (path/term count or the
        // load failure) goes to the UI log at startup.
        statusItemMenu.logDictionaryState()
        coordinator.statusItemMenu = statusItemMenu

        // stage E (wave1e): R5 fallback delivery path — the panel-status-row
        // subscriber (contract L396 "only update the status-row subscriber"; PM fallback). The
        // StatusItemMenu owns the status row and emits the NOTIFY trace;
        // when R5 settles, the banner/panel form slots in beside it here.
        sessionNotifier.subscribe { [weak statusItemMenu] notification in
            statusItemMenu?.presentSessionNotification(notification)
        }

        return coordinator
    }
}
