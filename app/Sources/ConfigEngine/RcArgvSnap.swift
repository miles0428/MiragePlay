import Foundation
import SharedTypes

/// RcArgvSnap — model → EffectiveSnapshot (IF-2) plus the rc snapshot file
/// (BLUEPRINT arch-3 #5: "model → EffectiveSnapshot (an argv + rc snapshot,
/// command line over rc in precedence order)").
///
/// rc file facts (contract L399 / O-5 + upstream evidence):
///   - Location: `<rcDirectory>/snapshot.rc`, i.e. `~/Library/Application
///     Support/<CFBundleIdentifier>/snapshot.rc` (P-2.2: cross-launch
///     retention → AppSupport, the same convention KeyVault established for
///     identity material). The user files `~/.uxplayrc` /
///     `~/.config/uxplayrc` are NEVER written, and no path inside a source
///     checkout is ever used (P-2.3).
///   - Rewritten on every receiver start (S-4). A missing `-rc <file>` makes
///     uxplay exit(0) at startup (uxplay.cpp:2986-2991), so the spawn leg
///     (stage C) must call `writeRcFile` before every spawn; a bad path is NOT a
///     crash the crash-guard can distinguish.
///   - Passing `-rc` replaces the `$UXPLAYRC/~/.uxplayrc/~/.config/uxplayrc`
///     lookup entirely (uxplay.cpp:2974-2982) — intended side effect.
public struct RcArgvSnap: Sendable {

    public static let rcFileName = "snapshot.rc"

    /// Per-user rc snapshot directory (the P-2.2 landing point: `~/Library/Application
    /// Support/<CFBundleIdentifier>/`), derived from the running bundle id so
    /// a relocated or renamed bundle keeps its own directory.
    ///
    /// - Returns: the directory URL (not created here; `writeRcFile` creates
    ///   it before every write).
    public static var rcDirectoryDefault: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ycchung.mirageplay"
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent(bundleID, isDirectory: true)
    }

    /// Historical name of `rcDirectoryDefault`, kept so existing call sites and
    /// harnesses keep compiling. The value is the AppSupport directory — never
    /// a source checkout (P-2.3).
    public static var projectRootDefault: URL { rcDirectoryDefault }

    /// Identity paths for the `-key`/`-reg` pair (S-9=B).
    public struct IdentityPaths: Sendable, Equatable {
        public let key: String
        public let reg: String

        public init(key: String, reg: String) {
            self.key = key
            self.reg = reg
        }
    }

    /// Directory the rc snapshot is written into (AppSupport, P-2.2).
    public let rcDirectory: URL

    /// Historical alias for `rcDirectory` (the label callers were written
    /// against); it holds an AppSupport directory, not a project root.
    public var projectRoot: URL { rcDirectory }

    /// The rc file location this builder hands to argv (`-rc` tail).
    public var rcPath: URL {
        rcDirectory.appendingPathComponent(Self.rcFileName)
    }

    public init(rcDirectory: URL = RcArgvSnap.rcDirectoryDefault) {
        self.rcDirectory = rcDirectory
    }

    /// Historical initializer label (`projectRoot:`) — forwards to
    /// `init(rcDirectory:)` so existing call sites keep compiling.
    public init(projectRoot: URL) {
        self.init(rcDirectory: projectRoot)
    }

    /// Builds the IF-2 shipment from the model.
    ///
    /// Gating applied here (last gate before the spawn leg):
    ///   - `pinEnabled == false` → pinCode/key/reg are all forced nil
    ///     (A2; S-9=B: PIN off = zero identity-file artefacts).
    ///   - identity paths are honored only while PIN is on.
    ///   - empty/whitespace deviceName falls back to the Presets default
    ///     (the broadcast name = <the binary or the default MiragePlay> + @hostname, contract L778).
    ///
    /// - Parameters:
    ///   - model: the ⑫ settings snapshot.
    ///   - effectivePinCode: the code in force for this snapshot (P3 decides
    ///     stored-vs-fresh; this builder only gates it).
    ///   - identityPaths: AppSupport key/reg paths, already ensured writable
    ///     by the caller (KeyVault.ensureWritable); nil = omit `-key`/`-reg`.
    public func makeSnapshot(
        from model: SettingModel,
        effectivePinCode: String?,
        identityPaths: IdentityPaths?
    ) -> EffectiveSnapshot {
        let trimmedName = model.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? Presets.deviceName : trimmedName

        let pinEnabled = model.pinEnabled
        let identity = pinEnabled ? identityPaths : nil

        return EffectiveSnapshot(
            deviceName: name,
            pinEnabled: pinEnabled,
            pinCode: pinEnabled ? effectivePinCode : nil,
            resolution: model.resolution,
            frameRate: model.frameRate,
            muted: model.muted,
            vsyncDisabled: Presets.vsyncDisabled,
            keyPath: identity?.key,
            regPath: identity?.reg,
            rcPath: rcPath.path,
            preventSleep: model.preventSleep,
            notificationsEnabled: model.notificationsEnabled,
            language: model.language,
            profileName: model.profileName,
            rcPassThrough: model.rcPassThrough
        )
    }

    /// Writes the rc body to disk (overwriting on every call — S-4 "rewrite on
    /// every start"), creating the AppSupport rc directory when missing. Uses the
    /// snapshot's own rcPath when present so the file always matches the `-rc`
    /// value the argv form carries.
    /// @return the URL written.
    @discardableResult
    public func writeRcFile(_ snapshot: EffectiveSnapshot) throws -> URL {
        let url = snapshot.rcPath.map { URL(fileURLWithPath: $0) } ?? rcPath
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(snapshot.rcText().utf8).write(to: url, options: .atomic)
        return url
    }
}
