import AppKit

/// Main application delegate managing the app lifecycle.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var lifecycleCoordinator: LifecycleCoordinator!
    private var compositionRoot: CompositionRoot!

    func applicationDidFinishLaunching(_ notification: Notification) {
        compositionRoot = CompositionRoot()
        lifecycleCoordinator = compositionRoot.build()

        // CP-2 / increment ① (2026-10-16): NO auto-start. The receiver is
        // opened/closed only from the panel (Start opens / Stop closes) —
        // the previous `lifecycleCoordinator.start()` here was Stage1
        // scaffolding (app-launch ⇒ receiver-on) and has been removed by the
        // 2026-10-16 lifecycle ruling. S5 quit semantics are unchanged.
        // P-2.5: the scripted-UI harness is a DEBUG-only channel. In a release
        // build neither the environment lookups nor the driver exist, so no
        // MIRRORBOARD_UITEST* literal can reach the shipped binary.
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["MIRRORBOARD_UITEST_LANGUAGE"] == "1" {
            // Scripted harness for scripts/test-language.sh (stage G, phase A):
            // default-English first run → zh-Hant/zh-Hans flips with immediate
            // all-UI re-render → language flip while the receiver runs
            // (E1 row 12: zero restart). Inert on normal launches.
            UITestDriver.runLanguage(coordinator: lifecycleCoordinator)
        } else if environment["MIRRORBOARD_UITEST_LANGUAGE"] == "2" {
            // Same script, phase B (relaunch): the persisted language must
            // be in force on the first render — passive read only.
            UITestDriver.runLanguageRestart(coordinator: lifecycleCoordinator)
        } else if environment["MIRRORBOARD_UITEST_LANGUAGE"] == "3" {
            // Same script, phase C (dictionary fixture via
            // MIRRORBOARD_STRINGS_PATH): the missing-key fallback chain
            // (selected → en → key) drives the rendered status row.
            UITestDriver.runLanguageFixture(coordinator: lifecycleCoordinator)
        } else if environment["MIRRORBOARD_UITEST_WIRING"] == "1" {
            // Scripted harness for scripts/test-wiring-e1.sh (stage C): receiver
            // start → four settings commits through the real preferences
            // commit paths (E1 auto-restarts) → stop → pure write-back →
            // quit. Inert on normal launches.
            UITestDriver.runWiringE1(coordinator: lifecycleCoordinator)
        } else if environment["MIRRORBOARD_UITEST_PIN"] == "1" {
            // Scripted harness for scripts/test-pin-chain.sh (stage D): the PIN
            // chain — panel switch → engine, code row truth (unset = a fresh code
            // on every start / changed = reused), the regenerate button (regen + E1),
            // preferences field truth; P4 flips while running auto-restart. Inert on
            // normal launches.
            UITestDriver.runPinChain(coordinator: lifecycleCoordinator)
        } else if environment["MIRRORBOARD_UITEST_SLEEPNOTIFY"] == "1" {
            // Scripted harness for scripts/test-sleep-notify.sh (stage E): ⑩
            // SleepGuard (prevent-sleep on/off → assertion held/released via pmset)
            // + ⑪ SessionNotifier (injected connection events — recorded
            // unconditionally, D8) + prevent-sleep write-back round-trip + the
            // retained B2 slot's persistence round-trip. Inert on normal
            // launches.
            UITestDriver.runSleepNotify(coordinator: lifecycleCoordinator)
        } else if environment["MIRRORBOARD_UITEST_TRUST"] == "1" {
            // Scripted harness for scripts/test-trust.sh (wave1r4): the trust
            // chain — raw `registered new client` records appended to
            // launch.log (the exact CoreBridge parse path) → trust ask
            // (trust / do-not-trust / no answer) → registry file assertions → editor
            // rows/✕/Reset. Phase A runs in EN; the flip to zh-Hant is
            // persisted for phase B. Inert on normal launches.
            UITestDriver.runTrust(coordinator: lifecycleCoordinator)
        } else if environment["MIRRORBOARD_UITEST_TRUST"] == "2" {
            // Same script, phase B (relaunch): the persisted zh-Hant renders
            // the trust ask; the render + audit carry the zh-Hant acceptance shot.
            UITestDriver.runTrustHant(coordinator: lifecycleCoordinator)
        } else if environment["MIRRORBOARD_UITEST_PREFS"] == "1" {
            // Scripted harness for scripts/test-ui-prefs.sh (increment ②) —
            // panel → preferences window → tab switch → singleton/close
            // audits; receiver stays untouched. Inert on normal launches.
            UITestDriver.runPreferences(coordinator: lifecycleCoordinator)
        } else if environment["MIRRORBOARD_UITEST"] == "1" {
            // Scripted harness for scripts/test-ui-cp2.sh — drives the same
            // entry points the panel buttons use; inert on normal launches.
            UITestDriver.run(coordinator: lifecycleCoordinator)
        }
        #endif
    }

    /// Termination cleanup — a NOTIFICATION from AppKit, not a command.
    ///
    /// As soon as this runs, termination is already approved: the only job
    /// left is to stop the receiver so uxplay cannot outlive the app. This
    /// method must NEVER call `lifecycleCoordinator.quit()`: quit() calls
    /// `NSApplication.shared.terminate(_:)`, which re-enters this method and
    /// recurses forever — that is the "app cannot quit" bug (fixed
    /// 2026-10-16). Same shape as Mos: its quit menu item only ever calls
    /// terminate(), while termination cleanup lives in the delegate's own
    /// willTerminate path.
    func applicationWillTerminate(_ notification: Notification) {
        lifecycleCoordinator.stop()
    }
}
