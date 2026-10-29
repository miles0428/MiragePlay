import Foundation

/// SettingsUI intent surface — the preferences panel (the window body) produces intent only
/// (BLUEPRINT arch-3 #3: "produce 'intent', never perform the action"; SRP-5: the UI must not spawn/kill
/// processes, must not assemble argv, and must not decide the effect semantics by itself).
///
/// wave1r1 staged-apply refit (YC's 2026-10-17 rulings ①② "whole-window consistency: the edits do not
/// take effect first; the bottom Apply commits everything at once" + "preview before applying"): every controllable field
/// in the window (device name / resolution / framerate / mute / prevent-sleep / connection notification / language /
/// the selected profile) is STAGED — the window only mutates its local UI state; nothing happens until
/// engine write, no E1, no receiver touch happens until the user presses
/// Apply. The one apply intent carries the full staged payload across the
/// seam; the AppShell adapter diffs it against the engine truth, performs all
/// writes in one batch and arranges the E1 outcome (running + receiver-related
/// change → exactly one restart; shell-held-only → zero touch; not started →
/// pure write-back).
///
/// stage D (wave1d) scope unchanged: the panel PIN chain rides this same seam —
/// the PIN protection switch + the regenerate button (the PIN is not in the window; the panel side is untouched).
/// wave1r3 (B2 ruling ②): the whole ⑫ profile-section UI is GONE from the settings
/// window (the dropdown + "Save as…" are withdrawn) — the save-as intent method retired with it;
/// ProfileStore.listProfiles / saveProfile remain as the engine-level
/// surface (no UI face), and the engine tests live in ConfigEngineSelfTest
/// (config-engine).
public protocol PreferencesIntentHandling: AnyObject {

    // MARK: - Staged apply (wave1r1)

    /// Apply pressed — the ONE batch commit. The AppShell adapter writes
    /// every staged field that differs from the engine truth (an engine write + ⑫
    /// auto write-back), then arranges the E1 outcome:
    ///   - receiver running ∧ any receiver-related diff (name/resolution/framerate/
    ///     mute) → auto-restart exactly ONCE (E1; carried by the IF-1 restart);
    ///   - running ∧ a shell-held-only diff (prevent-sleep/notification/language/profile name) →
    ///     zero receiver touch (each takes effect through its own hook);
    ///   - not started → pure write-back, the next start uses the values.
    /// The window clears its dirty state by re-syncing from the engine truth
    /// right after this call returns.
    func preferencesApplyRequested(_ staged: StagedSettings)

    // MARK: - Panel PIN chain (stage D / wave1d — unchanged)

    /// The panel's PIN protection switch flipped (P4 write-back = E1: while running = restart and apply;
    /// not started = pure write-back, effective on the next start).
    func pinProtectionToggled(_ enabled: Bool)

    /// The panel's small regenerate button pressed (P6 / R3-Q1=A: produce a 4-digit random code → it becomes set;
    /// E1 takes effect). With the PIN off it has no effect (the button is greyed).
    func pinChangeRequested()
}

/// wave1r1 — the window's staged payload: the controllable values the preferences
/// window shows. Plain Foundation types only (SettingsUI does not import
/// ConfigEngine); the AppShell adapter maps it onto the engine. `profileName`
/// is the engine-current profile name (wave1r3: the Profiles UI is withdrawn — it rides as
/// read-through engine truth; selection/naming is no longer changed by the window).
public struct StagedSettings: Equatable {

    /// The device name (A1; the -n body).
    public var deviceName: String
    /// The resolution (A4; an S-4 detent label, e.g. "720p").
    public var resolution: String
    /// The framerate cap (A5).
    public var frameRate: Int
    /// Mute (A6).
    public var muted: Bool
    /// Prevent-sleep (B1; shell-held).
    public var preventSleep: Bool
    /// The connection notification (B2; shell-held). D8: the page control is gone, so this
    /// rides as read-through engine truth (same treatment as `profileName`
    /// after the Profiles UI was withdrawn) — on apply it is always the same-value no-op unless
    /// the engine side has drifted (e.g. after a profile load).
    public var notificationsEnabled: Bool
    /// The language (B3; BCP-47 — applies to the whole UI at Apply).
    public var language: String
    /// The selected profile name (B4; display/current-name semantics only).
    public var profileName: String

    public init(
        deviceName: String,
        resolution: String,
        frameRate: Int,
        muted: Bool,
        preventSleep: Bool,
        notificationsEnabled: Bool,
        language: String,
        profileName: String
    ) {
        self.deviceName = deviceName
        self.resolution = resolution
        self.frameRate = frameRate
        self.muted = muted
        self.preventSleep = preventSleep
        self.notificationsEnabled = notificationsEnabled
        self.language = language
        self.profileName = profileName
    }
}

/// wave1r1 R2 — one trust-device row for the editor shell (YC ruling ⑤: trust stores the
/// **machine code** and displays the **device name** (a name cache)). The underlying trust data source
/// is a LATER increment (the data wiring awaits that increment) — the editor currently renders an
/// empty list; this type is the seam the real source will land on.
public struct TrustDeviceEntry: Equatable {

    /// The stable machine identifier (the machine code) — the persisted key.
    public let machineCode: String

    /// The cached display name (the device name).
    public let name: String

    public init(machineCode: String, name: String) {
        self.machineCode = machineCode
        self.name = name
    }
}
