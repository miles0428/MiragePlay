import Foundation

/// ProfileStore — ⑫ persistence (BLUEPRINT arch-3 #5; R3-Q3 = A + a small rollback loop):
///
///   - Single active group: auto write-back on every settings change; the
///     last values come back after a restart. Stored as `settings.json` in the
///     app support directory (app-internal file; not a user-visible surface —
///     contract #10/#11).
///   - Save-as: saves a named snapshot into `<support>/configs/` — the file name =
///     the profile name, exactly (no extension; the body is JSON). Non-user
///     -visible; the dropdown lists whatever is in that directory.
///   - NO auto-created profiles ("the app does not bulk-create them"): only an explicit save-as
///     writes profile files; a fresh install lists an empty set.
public final class ProfileStore {

    public enum StoreError: Error, Equatable {
        case invalidProfileName(String)
        case profileNotFound(String)
    }

    /// Root = the app support directory (`<AppSupport>/<bundle-id>`); the
    /// named profiles live in `configs/` beneath it.
    public let rootDirectory: URL

    /// The single active settings group.
    public var currentSettingsURL: URL {
        rootDirectory.appendingPathComponent("settings.json")
    }

    /// The save-as target directory (`configs/`; the r3 rollback loop: `~/Library/Application
    /// Support/…/configs/`, keeping L64 and not amending the contract).
    public var profilesDirectory: URL {
        rootDirectory.appendingPathComponent("configs", isDirectory: true)
    }

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    // MARK: - Single active group (auto write-back)

    /// Loads the active settings; `nil` when nothing has been saved yet
    /// (fresh install). Does not create any file or directory.
    public func loadCurrent() throws -> SettingModel? {
        guard FileManager.default.fileExists(atPath: currentSettingsURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: currentSettingsURL)
        return try JSONDecoder().decode(SettingModel.self, from: data)
    }

    /// Write-back of the active settings (called on every change by the
    /// engine). Creates the support directory on first write.
    public func saveCurrent(_ model: SettingModel) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory, withIntermediateDirectories: true)
        try Self.encoder().encode(model).write(to: currentSettingsURL, options: .atomic)
    }

    // MARK: - Named profiles (save-as / the dropdown list)

    /// Saves a named snapshot into `configs/<name>` (file name = profile name).
    /// @return the written file URL.
    @discardableResult
    public func saveProfile(_ model: SettingModel, named name: String) throws -> URL {
        let url = try profileURL(for: name)
        try FileManager.default.createDirectory(
            at: profilesDirectory, withIntermediateDirectories: true)
        try Self.encoder().encode(model).write(to: url, options: .atomic)
        return url
    }

    /// Loads a named profile.
    public func loadProfile(named name: String) throws -> SettingModel {
        let url = try profileURL(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.profileNotFound(name)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SettingModel.self, from: data)
    }

    /// Lists the saved profile names (sorted; empty when none exist — never
    /// auto-creates anything).
    public func listProfiles() throws -> [String] {
        guard FileManager.default.fileExists(atPath: profilesDirectory.path) else {
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: profilesDirectory.path)
        return entries.sorted()
    }

    // MARK: - Helpers

    /// Validates the profile name and resolves the target file. The file name
    /// IS the profile name (the r3 rollback loop: file name = profile name), so path separators,
    /// "."/".." and empty names are rejected.
    private func profileURL(for name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains(":"),
              trimmed != ".",
              trimmed != ".."
        else {
            throw StoreError.invalidProfileName(name)
        }
        return profilesDirectory.appendingPathComponent(trimmed)
    }

    /// Stable, diff-friendly JSON (pretty-printed, sorted keys, unescaped
    /// slashes so paths stay readable).
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
