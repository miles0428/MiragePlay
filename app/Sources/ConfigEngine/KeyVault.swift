import Foundation

/// KeyVault — where identity material lives (BLUEPRINT arch-3 #5; the six-B group D
/// red line: identity material must never enter the repo).
///
/// Both files reach the receiver only through `-key` (server keypair) and
/// `-reg` (pin-registered clients list), and both live EXCLUSIVELY under
/// `~/Library/Application Support/<bundle-id>/` (com.ycchung.mirageplay).
/// This type provides the paths plus the writability guarantee; it never
/// copies, reads or generates key material itself.
///
/// Upstream generation/reuse semantics (verified in core/uxplay source; the
/// 2a report carries the same evidence):
///   - `-key <fn>` → lib/crypto.c:351 `ed25519_key_generate`: if <fn> parses
///     as a PEM private key it is REUSED; if missing/unreadable a NEW Ed25519
///     keypair is generated and written to <fn> (uxplay.cpp:672 logs
///     "*** A new Public Key has been created and stored in <fn>").
///   - `-reg <fn>` → parse-time `file_has_write_access` (uxplay.cpp:327-346)
///     probes by create+remove; a non-writable path exits 1
///     (uxplay.cpp:1661-1668). So the app-side duty is exactly: the parent
///     directory must exist and be writable.
public struct KeyVault: Sendable {

    /// O-3 (contract): the app bundle id is the support-directory name.
    public static let defaultBundleID = "com.ycchung.mirageplay"

    /// File names inside the support directory (PM-adoptable minor naming).
    public static let keyFileName = "server.pem"
    public static let registrationFileName = "registration.list"

    public enum VaultError: Error, Equatable {
        case supportDirectoryUnwritable(path: String)
    }

    /// `~/Library/Application Support/<bundle-id>`.
    public let supportDirectory: URL

    /// `-key` target: the server keypair (Ed25519, PIN/trust root).
    public var keyPath: URL {
        supportDirectory.appendingPathComponent(Self.keyFileName)
    }

    /// `-reg` target: the pin-registered clients list.
    public var regPath: URL {
        supportDirectory.appendingPathComponent(Self.registrationFileName)
    }

    /// Builds the vault.
    /// - Parameters:
    ///   - bundleID: overrides the bundle id (nil → `Bundle.main.bundleIdentifier`,
    ///     falling back to `defaultBundleID` for unbundled binaries/tests).
    ///   - homeDirectory: overrides the home directory (nil → the user's home).
    public init(bundleID: String? = nil, homeDirectory: URL? = nil) {
        let bundle = bundleID ?? Bundle.main.bundleIdentifier ?? Self.defaultBundleID
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        self.supportDirectory = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundle, isDirectory: true)
    }

    /// Creates the support directory if needed and verifies writability with a
    /// create+remove probe (the same shape upstream uses to validate `-reg`).
    /// Throws `VaultError.supportDirectoryUnwritable` when the directory
    /// cannot be created or written to — in that case `-key`/`-reg` MUST NOT
    /// be passed to uxplay (upstream would exit 1 on an unwritable path).
    public func ensureWritable(fileManager: FileManager = .default) throws {
        do {
            try fileManager.createDirectory(
                at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            throw VaultError.supportDirectoryUnwritable(path: supportDirectory.path)
        }
        let probe = supportDirectory.appendingPathComponent(".mb-write-probe-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: probe.path, contents: Data()) else {
            throw VaultError.supportDirectoryUnwritable(path: supportDirectory.path)
        }
        try? fileManager.removeItem(at: probe)
    }
}
