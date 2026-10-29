import Foundation

/// EffectiveSnapshot — IF-2: the only output ConfigEngine ships to the
/// receiver/spawn leg (BLUEPRINT arch-4 IF-2; arch-3 #5).
///
/// Field set per the IF-2 fields freeze draft
/// (`.task_state/spec_if2-fields_20261017.md` §1; the PM-adopted values in §5):
///
///   Mirror group — serialized into BOTH forms (argv + rc):
///     A1 deviceName / A2 pinEnabled / A3 pinCode / A4 resolution /
///     A5 frameRate / A6 muted / C1 vsyncDisabled (fixed baseline) /
///     C3 keyPath + regPath (S-9=B: present only while PIN is on) /
///     rcPath (C2 transport; S-4: `-rc <path>` argv tail).
///   Shell group — NEVER serialized (E1 exception; S-10=A full projection):
///     B1 preventSleep / B2 notificationsEnabled / B3 language / B4 profileName.
///   Channel — rc-only pass-through (C2 / K2 / S-6(a)):
///     rcPassThrough (v1: reserved structure, kept empty).
///
/// Two serialized forms (the 2a acceptance artifacts, BLUEPRINT L637):
///   - `argv()`   — command-line form, order §2.1 (S-2).
///   - `rcText()` — full-mirror rc-file body (S-3). rc syntax: one option per
///     line, leading `-` omitted, values quoted when they contain blanks
///     (upstream tokenizer: core/uxplay/uxplay.cpp:2841-2905 read_config_file).
///
/// Precedence (upstream evidence, uxplay.cpp:2974-3000): the `-rc` file is
/// applied BEFORE the command line, so command-line options win on collision —
/// the mirrored rc copy is therefore non-overriding by construction. `-nh` is
/// never emitted (no field can carry it — the broadcast-name suffix is hard-coded to "never off").
public struct EffectiveSnapshot: Sendable, Equatable {

    // MARK: - Mirror group (serialized: argv + rc)

    /// A1 — broadcast-name BODY only; the `@<hostname>` suffix is appended by
    /// upstream (never `-nh`; BLUEPRINT L394). Serialized as `-n <name>`.
    public let deviceName: String

    /// A2 — PIN verification switch (P1: default off). `-pin` appears only
    /// when true (A2: presence and value mean the same).
    public let pinEnabled: Bool

    /// A3 — effective 4-digit PIN code (`"0001"`…`"9999"`). Non-nil whenever
    /// `pinEnabled` (A3 draft semantics). Serialized in the FIXED form
    /// `-pin <xxxx>` — never bare `-pin` (bare form would let upstream pick a
    /// fresh random code per connection request; uxplay.cpp:1648-1655).
    public let pinCode: String?

    /// A4 — resolution label (`"480p"`…`"2160p"`); mapped to the `-s WxH`
    /// value through `pixelValue(forResolution:)` (table D, S-7).
    public let resolution: String

    /// A5 — frame-rate cap (`15/30/45/60/120`) → `-fps <n>`.
    public let frameRate: Int

    /// A6 — mute; serialized as the short form `-a` (S-8).
    public let muted: Bool

    /// C1 — the fixed `vsync no` baseline (K2: enters the baseline permanently,
    /// never a panel item; survey L90 macOS recommendation). Serialized in
    /// BOTH forms (S-5=A). Fixed `true` by Presets.
    public let vsyncDisabled: Bool

    /// C3 — `-key` path (server keypair, PIN/trust root — AppSupport only,
    /// the six-B group D red line). S-9=B: set and serialized only while the PIN is on;
    /// nil otherwise.
    public let keyPath: String?

    /// C3 — `-reg` path (pin-registered clients list; AppSupport only).
    /// Same gating as `keyPath`.
    public let regPath: String?

    /// C2 transport — absolute path of the rc snapshot file (S-4:
    /// `<rcDirectory>/snapshot.rc`, i.e. `~/Library/Application Support/
    /// <CFBundleIdentifier>/snapshot.rc` — P-2.2 cross-launch retention).
    /// When non-nil, argv gains the `-rc <path>` tail (item 8). Not mirrored
    /// inside the rc file itself (it is the transport, not a field).
    public let rcPath: String?

    // MARK: - Shell group (NEVER serialized; E1 exception — shell-held)

    /// B1 — prevent display/system sleep while the receiver runs (SleepGuard).
    public let preventSleep: Bool

    /// B2 — connection notifications (SessionNotifier).
    public let notificationsEnabled: Bool

    /// B3 — UI language in BCP-47 form (S-10: `"en"` default, `"zh-Hant"`,
    /// `"zh-Hans"`).
    public let language: String

    /// B4 — name of the currently active settings profile.
    public let profileName: String

    // MARK: - Channel (rc-only pass-through; K2 / S-6(a))

    /// C2 — rc pass-through lines, verbatim rc form (e.g. `"pw hunter2"`,
    /// `"p 7100"`). Injected into the rc file one line each; NEVER in argv.
    /// v1 default: empty (no operation entry; structure reserved for G2).
    public let rcPassThrough: [String]

    // MARK: - Init

    public init(
        deviceName: String,
        pinEnabled: Bool,
        pinCode: String?,
        resolution: String,
        frameRate: Int,
        muted: Bool,
        vsyncDisabled: Bool,
        keyPath: String?,
        regPath: String?,
        rcPath: String?,
        preventSleep: Bool,
        notificationsEnabled: Bool,
        language: String,
        profileName: String,
        rcPassThrough: [String]
    ) {
        self.deviceName = deviceName
        self.pinEnabled = pinEnabled
        self.pinCode = pinCode
        self.resolution = resolution
        self.frameRate = frameRate
        self.muted = muted
        self.vsyncDisabled = vsyncDisabled
        self.keyPath = keyPath
        self.regPath = regPath
        self.rcPath = rcPath
        self.preventSleep = preventSleep
        self.notificationsEnabled = notificationsEnabled
        self.language = language
        self.profileName = profileName
        self.rcPassThrough = rcPassThrough
    }

    /// Stage1-compat / fallback default: factory values, no rc transport
    /// (argv carries no `-rc`), PIN off, no identity paths. Kept because
    /// AppShell falls back to `.default` when no engine is wired.
    public static let `default` = EffectiveSnapshot(
        deviceName: "MiragePlay",
        pinEnabled: false,
        pinCode: nil,
        resolution: "1080p",
        frameRate: 30,
        muted: false,
        vsyncDisabled: true,
        keyPath: nil,
        regPath: nil,
        rcPath: nil,
        preventSleep: true,
        notificationsEnabled: true,
        language: "en",
        profileName: "預設",
        rcPassThrough: []
    )

    // MARK: - Table D mapping (S-7)

    /// Resolution label → the `-s` value (spec table D; the 1080p entry equals the
    /// upstream default 1920x1080[@60], uxplay.cpp:983).
    public static let resolutionPixelValues: [String: String] = [
        "480p": "854x480",
        "720p": "1280x720",
        "1080p": "1920x1080",
        "1440p": "2560x1440",
        "2160p": "3840x2160",
    ]

    /// `-s` value for a resolution label. A label that already matches the
    /// upstream `WxH` grammar (each field ≤ 4 digits) passes through; anything
    /// else falls back to the upstream default 1920x1080
    /// (grammar: uxplay.cpp:1068-1090).
    static func pixelValue(forResolution label: String) -> String {
        if let mapped = resolutionPixelValues[label] { return mapped }
        let parts = label.split(separator: "x", omittingEmptySubsequences: false)
        let looksLikeWxH = parts.count == 2
            && parts.allSatisfy { !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isNumber) }
        return looksLikeWxH ? label : "1920x1080"
    }

    // MARK: - Serialization form 1: argv (§2.1 order; S-2/S-4/S-5/S-8/S-9)

    /// Command-line form. Does NOT include the executable path, the
    /// `stdbuf -oL -eL` wrapper, env or CWD — those belong to core/spawn's
    /// spawn mechanics, not to the snapshot vocabulary.
    ///
    /// Order: `-n` → `-s` → `-fps` → `-vsync no` → `-a?` → `-pin <xxxx>?`
    /// → `-key`/`-reg`? → `-rc <path>?`.
    public func argv() -> [String] {
        var arguments: [String] = []
        arguments.append(contentsOf: ["-n", deviceName])
        arguments.append(contentsOf: ["-s", Self.pixelValue(forResolution: resolution)])
        arguments.append(contentsOf: ["-fps", String(frameRate)])
        if vsyncDisabled {
            arguments.append(contentsOf: ["-vsync", "no"])
        }
        if muted {
            arguments.append("-a")
        }
        if pinEnabled, let pinCode {
            arguments.append(contentsOf: ["-pin", pinCode])
            // S-9=B: identity paths ride only while PIN is on; gated here as
            // the last gate before the spawn leg (red-line defense in depth).
            if let keyPath { arguments.append(contentsOf: ["-key", keyPath]) }
            if let regPath { arguments.append(contentsOf: ["-reg", regPath]) }
        }
        if let rcPath {
            arguments.append(contentsOf: ["-rc", rcPath])
        }
        return arguments
    }

    // MARK: - Serialization form 2: rc body (§2.2; S-3 full mirror)

    /// rc-file body: same fields as `argv()`, same order, rc syntax. The rc
    /// copy is applied first by upstream and the command line second, so the
    /// mirrored values never override the argv copies (command-line > rc).
    /// `rcPassThrough` lines are injected verbatim; the rc file path itself is
    /// not mirrored (it is the transport).
    public func rcText() -> String {
        var lines: [String] = []
        lines.append("# MiragePlay snapshot（自動生成；v1 欄位與命令列同值——命令列恆優先）")
        lines.append("n " + Self.rcValue(deviceName))
        lines.append("s " + Self.pixelValue(forResolution: resolution))
        lines.append("fps \(frameRate)")
        if vsyncDisabled { lines.append("vsync no") }
        if muted { lines.append("a") }
        if pinEnabled, let pinCode {
            lines.append("pin \(pinCode)")
            if let keyPath { lines.append("key " + Self.rcValue(keyPath)) }
            if let regPath { lines.append("reg " + Self.rcValue(regPath)) }
        }
        lines.append(contentsOf: rcPassThrough)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders one rc value: quoted when it contains blanks (the upstream
    /// tokenizer only recognizes quotes at the start of an item, so the whole
    /// value is wrapped; `"` is chosen unless the value itself contains a
    /// double quote and no single quote — then `'` is used).
    static func rcValue(_ value: String) -> String {
        let needsQuoting = value.isEmpty || value.contains(" ") || value.contains("\t")
        guard needsQuoting else { return value }
        let quote = (value.contains("\"") && !value.contains("'")) ? "'" : "\""
        let escaped = value.replacingOccurrences(of: quote, with: "\\" + quote)
        return quote + escaped + quote
    }
}
