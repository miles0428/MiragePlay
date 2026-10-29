import ConfigEngine
import Localization
import SettingsUI

/// wave1r1 — the preferences-window intent adapter (stage C base, staged refit).
///
/// SettingsUI produces intent only (arch-3 #3 "produce 'intent', never perform
/// SRP-5). Under the staged-apply model the window's ONE apply intent
/// (`preferencesApplyRequested`) carries the full staged payload; this
/// AppShell adapter diffs it against the engine truth, performs ALL engine
/// writes in one batch (each setter auto write-backs — ⑫), then arranges the
/// E1 outcome in the coordinator (IF-3: the restart arrangement itself never
/// lives in this adapter or the UI):
///
///   - receiver running ∧ any RECEIVER-RELATED diff (device name/resolution/framerate/
///     mute — the E1 vocabulary) → `settingsChanged()` → auto-restart exactly
///     ONCE for the whole batch (restart exactly once — PM micro-decision 4);
///   - shell-held diffs (prevent-sleep/connection notification/language) → their own hooks, zero
///     receiver touch (E1 exception: shell-held);
///   - profileName diff (the selected profile) → engine name only — never receiver
///     related (B4 is shell-group data, never serialized into argv/rc);
///   - not started → any receiver-related batch is a pure write-back
///     (the coordinator logs `write-back only`; it takes effect on the next start).
///
/// stage D (wave1d) — the panel PIN chain rides the same adapter: the panel's
/// PIN protection switch and regenerate button emit intent (`pinProtectionToggled` /
/// `pinChangeRequested`); the engine write + E1 signal happen here. PIN is
/// NOT part of the window's staged payload (the PIN is not in the window; the panel side is untouched).
///
/// wave1r3 (B2 ruling ②) — the whole ⑫ profile-section UI (dropdown + save-as) is GONE
/// from the settings window (the ProfileStore engine side is retained and stays hidden): the save-as
/// intent method retired with the UI face; ProfileStore stays untouched and
/// the ⑫ auto write-back path below is unchanged.
final class PreferencesIntentHandler: PreferencesIntentHandling {

    private let engine: ConfigEngine
    private weak var coordinator: LifecycleCoordinator?
    /// stage G: the live term-lookup service — flipped in step with the engine
    /// truth so every surface re-renders (the UI switches language on apply).
    private let localization: LanguageService

    init(engine: ConfigEngine, coordinator: LifecycleCoordinator, localization: LanguageService) {
        self.engine = engine
        self.coordinator = coordinator
        self.localization = localization
    }

    // MARK: - Staged apply (wave1r1)

    /// Apply — the one batch commit. Every staged field that differs from
    /// the engine truth is written (⑫ auto write-back); the E1 / shell-held
    /// signals fire exactly once per changed class (see the type doc).
    /// Dropped values (hand-edited corrupt profile content) leave a trace and
    /// keep the previous truth — the window re-syncs afterwards and shows it.
    func preferencesApplyRequested(_ staged: StagedSettings) {
        let model = engine.currentModel

        var receiverRelated = false
        let name = staged.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.deviceName != name {
            engine.setDeviceName(name)
            receiverRelated = true
        }
        if model.resolution != staged.resolution {
            do {
                try engine.setResolution(staged.resolution)
                receiverRelated = true
            } catch {
                UILog.line("PREFS apply dropped (resolution \(staged.resolution)): \(error.localizedDescription)")
            }
        }
        if model.frameRate != staged.frameRate {
            do {
                try engine.setFrameRate(staged.frameRate)
                receiverRelated = true
            } catch {
                UILog.line("PREFS apply dropped (frame rate \(staged.frameRate)): \(error.localizedDescription)")
            }
        }
        if model.muted != staged.muted {
            engine.setMuted(staged.muted)
            receiverRelated = true
        }

        var sleepChanged = false
        if model.preventSleep != staged.preventSleep {
            engine.setPreventSleep(staged.preventSleep)
            sleepChanged = true
        }
        var notificationsChanged = false
        if model.notificationsEnabled != staged.notificationsEnabled {
            engine.setNotificationsEnabled(staged.notificationsEnabled)
            notificationsChanged = true
        }
        var languageFlipped = false
        if model.language != staged.language {
            do {
                try engine.setLanguage(staged.language)
                // Service flip — the whole UI re-renders synchronously through
                // the LanguageService observers (the UI switches language on apply).
                localization.setLanguage(staged.language)
                languageFlipped = true
            } catch {
                UILog.line("PREFS apply dropped (language \(staged.language)): \(error.localizedDescription)")
            }
        }
        if model.profileName != staged.profileName {
            // the selected profile = Apply = in effect (current is updated). Shell-group data —
            // never serialized into argv/rc (IF-2), zero receiver relevance.
            engine.setProfileName(staged.profileName)
        }

        // E1 arrangement (exactly one restart / no touch / pure write-back; see the type doc).
        if receiverRelated {
            coordinator?.settingsChanged()
        }
        if sleepChanged {
            coordinator?.preventSleepChanged()
        }
        if notificationsChanged {
            coordinator?.notificationsChanged()
        }
        if languageFlipped {
            coordinator?.languageChanged()
        }
        let shellHeld = sleepChanged || notificationsChanged || languageFlipped
        UILog.line(
            "ACTION apply-staged receiver-related=\(receiverRelated ? "1" : "0") shell-held=\(shellHeld ? "1" : "0")"
        )
    }

    // MARK: - Panel PIN chain (stage D)

    /// P4 (E1 write-back) / P1-P3: the panel PIN switch flipped on/off.
    /// Engine write (setPinEnabled ensures a displayable code when turning
    /// on, P2) + E1 signal — running → auto-restart applies `-pin` now;
    /// not started → pure write-back, the next start uses it.
    func pinProtectionToggled(_ enabled: Bool) {
        guard engine.currentModel.pinEnabled != enabled else { return }
        engine.setPinEnabled(enabled)
        coordinator?.settingsChanged()
    }

    /// P6 (R3-Q1=A): the panel's regenerate button — produce a fresh random
    /// code (it becomes set → reused from now on) + E1 signal. With the PIN off the button is greyed
    /// (no effect): enforced here as defence in depth even though the panel
    /// disables the button itself.
    func pinChangeRequested() {
        guard engine.currentModel.pinEnabled else { return }
        engine.changePin()
        coordinator?.settingsChanged()
    }
}
