import Foundation
import SharedTypes

/// ConfigEngine — the 2a real engine (carrying IF-2; BLUEPRINT arch-3 #5).
///
/// Composition: `SettingModel` (⑫ single model) + `ProfileStore` (single-group
/// persistence + auto write-back + named profiles) + `KeyVault` (identity
/// material home; red line: AppSupport only) + `RcArgvSnap` (model →
/// EffectiveSnapshot + rc file) + `PinCode` (P1-P3 rules).
///
/// The IF-2 protocol (`ConfigEngineProtocol.effectiveSnapshot()`) is a pure
/// read in spirit — it never persists — but it does maintain the P2/A3
/// invariant that a live code exists whenever PIN is on (lazy session-code
/// generation; see `effectiveSnapshot()`).
///
/// Write-side API (setters, profile load/save, changePin, start preparation)
/// is 2a scope; wiring it to the UI/panel is stage C's business. All writes
/// auto write-back to the single active group (⑫: any settings change writes
/// back, and a restart brings the last value). Not thread-safe by design — menu-bar app, main thread only.
public final class ConfigEngine: ConfigEngineProtocol {

    public enum EngineError: Error, Equatable {
        case invalidResolution(String)
        case invalidFrameRate(Int)
        case invalidLanguage(String)
    }

    private var model: SettingModel

    /// P3 session-only code (the unset mode): generated per receiver start, never
    /// persisted, never part of `model`.
    private var sessionPinCode: String?

    private let profileStore: ProfileStore
    private let keyVault: KeyVault
    private let rcArgvSnap: RcArgvSnap

    /// Cached outcome of the KeyVault writability guarantee (success sticks;
    /// failure is retried on the next call in case the environment heals).
    private var vaultReady = false

    /// Last auto write-back failure, if any (no logger exists in this target;
    /// surfaced here so the UI layer can report it).
    public private(set) var lastPersistenceError: Error?

    // MARK: - Init

    public init(profileStore: ProfileStore, keyVault: KeyVault, rcArgvSnap: RcArgvSnap) {
        self.profileStore = profileStore
        self.keyVault = keyVault
        self.rcArgvSnap = rcArgvSnap
        // a restart brings the last value; a corrupt or missing file → the factory baseline.
        self.model = (try? profileStore.loadCurrent()) ?? Presets.factoryModel
    }

    /// Production wiring: AppSupport identity/config home + the working-disk
    /// project root for the rc scratch file.
    public convenience init() {
        let vault = KeyVault()
        self.init(
            profileStore: ProfileStore(rootDirectory: vault.supportDirectory),
            keyVault: vault,
            rcArgvSnap: RcArgvSnap()
        )
    }

    // MARK: - Read side (IF-2 protocol — 7-line protocol unchanged)

    /// IF-2: the effective snapshot for the current model.
    ///
    /// Maintains the A3 invariant "while on there is always a value": while the PIN is on, a code
    /// always exists — the set case uses the stored code; the unset case lazily materialises a
    /// session code (then kept stable until the next receiver start, P3
    /// "the code does not change while the receiver runs").
    public func effectiveSnapshot() -> EffectiveSnapshot {
        let pin: String? = model.pinEnabled ? ensuredSessionCode() : nil
        return rcArgvSnap.makeSnapshot(
            from: model,
            effectivePinCode: pin,
            identityPaths: ensuredIdentityPaths()
        )
    }

    /// Read-only view of the current settings (UI refresh / tests).
    public var currentModel: SettingModel { model }

    // MARK: - Receiver-start preparation (the stage C entry point)

    /// Called immediately before spawning the receiver (on every start).
    ///
    ///   - P3: unset → a fresh random code for this start (session-only);
    ///     set (changed) → the stored code is reused.
    ///   - S-4: (re)writes `<rcDirectory>/snapshot.rc`, i.e.
    ///     `~/Library/Application Support/<CFBundleIdentifier>/snapshot.rc`
    ///     (P-2.2). The spawn leg MUST call this before every spawn — a missing
    ///     `-rc` file makes uxplay exit(0) at startup (uxplay.cpp:2986-2991).
    ///
    /// - Throws: rc-file write errors (surfaced as "Start failed: <short reason>").
    @discardableResult
    public func prepareForReceiverStart() throws -> EffectiveSnapshot {
        if model.pinEnabled {
            if let stored = model.pinCode {
                sessionPinCode = stored          // already set → reuse
            } else {
                sessionPinCode = PinCode.randomCode()   // not set → generate a new code on every launch
            }
        }
        let snapshot = effectiveSnapshot()
        try rcArgvSnap.writeRcFile(snapshot)
        return snapshot
    }

    // MARK: - PIN (P1-P3 / P6 / R3-Q1)

    /// P2: toggling the PIN switch on guarantees a displayable random code.
    public func setPinEnabled(_ enabled: Bool) {
        guard model.pinEnabled != enabled else { return }
        model.pinEnabled = enabled
        if enabled { _ = ensuredSessionCode() }
        persistCurrent()
    }

    /// P6 / R3-Q1: the regenerate button — produces a fresh random code and marks
    /// it as set (reused across starts and restarts from now on).
    @discardableResult
    public func changePin() -> String {
        let code = PinCode.randomCode()
        model.pinCode = code
        sessionPinCode = code
        persistCurrent()
        return code
    }

    // MARK: - Settings writes (⑫ auto write-back; UI wiring = stage C)

    public func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.deviceName != trimmed else { return }
        model.deviceName = trimmed
        persistCurrent()
    }

    public func setResolution(_ label: String) throws {
        guard Presets.resolutionLabels.contains(label) else {
            throw EngineError.invalidResolution(label)
        }
        guard model.resolution != label else { return }
        model.resolution = label
        persistCurrent()
    }

    public func setFrameRate(_ value: Int) throws {
        guard Presets.frameRates.contains(value) else {
            throw EngineError.invalidFrameRate(value)
        }
        guard model.frameRate != value else { return }
        model.frameRate = value
        persistCurrent()
    }

    public func setMuted(_ muted: Bool) {
        guard model.muted != muted else { return }
        model.muted = muted
        persistCurrent()
    }

    public func setPreventSleep(_ enabled: Bool) {
        guard model.preventSleep != enabled else { return }
        model.preventSleep = enabled
        persistCurrent()
    }

    public func setNotificationsEnabled(_ enabled: Bool) {
        guard model.notificationsEnabled != enabled else { return }
        model.notificationsEnabled = enabled
        persistCurrent()
    }

    public func setLanguage(_ language: String) throws {
        guard Presets.languages.contains(language) else {
            throw EngineError.invalidLanguage(language)
        }
        guard model.language != language else { return }
        model.language = language
        persistCurrent()
    }

    public func setProfileName(_ name: String) {
        guard model.profileName != name else { return }
        model.profileName = name
        persistCurrent()
    }

    // MARK: - Named profiles (save-as / the dropdown list; R3-Q3 = A + a small rollback loop)

    /// Save-as: saves the current settings as a named snapshot
    /// (`<AppSupport>/configs/<name>`; file name = profile name) and makes the
    /// name for the current profile. Does not touch the receiver (an E1 exception).
    ///
    /// The snapshot carries its own name (B4 = the profile name it is saved
    /// under) — loadProfile enforces the same either way, so the stored file
    /// is self-consistent instead of carrying a stale previous name.
    @discardableResult
    public func saveProfileAs(named name: String) throws -> URL {
        var snapshot = model
        snapshot.profileName = name
        let url = try profileStore.saveProfile(snapshot, named: name)
        if model.profileName != name {
            model.profileName = name
            persistCurrent()
        }
        return url
    }

    /// Dropdown selection: loads a named profile, marks it current, and
    /// persists it as the active group (E1: selecting = load/switch takes effect at once — the
    /// receiver restart itself is wired in stage C).
    public func loadProfile(named name: String) throws {
        var loaded = try profileStore.loadProfile(named: name)
        loaded.profileName = name
        model = loaded
        // A profile switch invalidates the session-only PIN (P3 state belongs
        // to the profile); it regenerates lazily from the loaded model.
        sessionPinCode = nil
        persistCurrent()
    }

    // MARK: - Private

    /// A3/P2 invariant helper: set → the stored code; unset → the current session code,
    /// materialized (and kept) on first demand.
    private func ensuredSessionCode() -> String {
        if let stored = model.pinCode { return stored }
        if let session = sessionPinCode { return session }
        let fresh = PinCode.randomCode()
        sessionPinCode = fresh
        return fresh
    }

    /// S-9=B: identity paths only while PIN is on, and only after the vault
    /// writability guarantee. On failure returns nil (omit `-key`/`-reg`) —
    /// passing an unwritable path would make uxplay exit 1 at parse time.
    private func ensuredIdentityPaths() -> RcArgvSnap.IdentityPaths? {
        guard model.pinEnabled else { return nil }
        if !vaultReady {
            do {
                try keyVault.ensureWritable()
                vaultReady = true
            } catch {
                return nil
            }
        }
        return RcArgvSnap.IdentityPaths(
            key: keyVault.keyPath.path,
            reg: keyVault.regPath.path
        )
    }

    /// ⑫ auto write-back — every settings change lands immediately; the last
    /// values come back after a restart.
    private func persistCurrent() {
        do {
            try profileStore.saveCurrent(model)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error
        }
    }
}
