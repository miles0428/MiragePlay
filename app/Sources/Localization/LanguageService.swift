import Foundation

/// LanguageService — the R4-Q1 language mechanism in one unit.
///
/// Policy (BLUEPRINT L146 [YC 2026-10-17 R4-Q1]): the language set is
/// English / Traditional Chinese / Simplified Chinese (pick one of three, English by
/// default); the dictionary body
/// L147); a selected language is applied by **looking up every term in the
/// selected language**; switching takes effect on the whole UI immediately
/// without touching the receiver; the selection persists with the settings
/// (the persistence truth lives in `SettingModel.language` / ConfigEngine —
/// this service mirrors it, the AppShell adapter keeps both in step).
///
/// Missing-term fallback (spec silent; PM-delegated definition, documented
/// in the wave report): selected language → the dictionary's declared
/// default language (`en`) → **the term key itself** (never a silent empty
/// string, never a crash). Every miss is recorded once per (term, language)
/// through `onMissingTerm` so the missing entries are observable/addressable.
///
/// Dictionary location resolution (the P-1.4 reader-side rule):
///   1. `MIRRORBOARD_STRINGS_PATH` environment override (test seam only — it
///      lets a run point at a fixture dictionary; never a shipping path);
///   2. **`Bundle.main`** — the ONLY shipping path: `<bundle>/Contents/
///      Resources/Strings/terms.json`, copied there by the bundle assembler
///      (P-1.1), NOT by a SwiftPM `resources:` declaration (P-1.2 — a nested
///      resource bundle would be unreadable from this target).
///
/// There is deliberately NO project-root fallback (P-1.4 / P-2.3): a source
/// tree path is a build-machine fact, not a runtime one. An unbundled binary
/// (`swift build` output run directly) therefore resolves to the path the
/// packaged layout WOULD have — a miss, which surfaces through
/// `loadErrorDescription` and honest key rendering instead of silently
/// reading the developer's checkout.
///
/// Resolving the bundle FIRST is what makes the packaged app self-contained:
/// a bundle launched from /Applications (or any machine without the project
/// tree) must read its own copy, otherwise every lookup degrades to the raw
/// term key.
///
/// A missing/unreadable dictionary file is a deployment error: the service
/// keeps functioning, every lookup returns the term key (visible, honest
/// degradation) and `loadErrorDescription` carries the reason for the
/// composition root to log.
///
/// Main-thread only (menu-bar app; same discipline as every other unit).
public final class LanguageService {

    // MARK: - Static configuration

    /// The fallback language when no dictionary is loaded at all (the default
    /// English [R4-Q1]).
    public static let fallbackLanguage = "en"

    /// In-bundle dictionary directory, relative to the bundle's resources
    /// (`Contents/Resources/Strings/terms.json` — P-1.1).
    public static let bundleDictionarySubdirectory = "Strings"

    /// Environment override used by the test harness to point at a fixture
    /// dictionary (missing-key fallback exercise).
    public static let dictionaryPathEnvironmentKey = "MIRRORBOARD_STRINGS_PATH"

    /// Resolves the dictionary URL (P-1.4): env override → `Bundle.main`.
    ///
    /// Never returns a path inside a source checkout: when the bundle carries
    /// no dictionary the result is the path the packaged layout would use, so
    /// the load fails loudly against `bundle.bundleURL` rather than silently
    /// succeeding on the developer's machine only.
    ///
    /// - Parameters:
    ///   - environment: process environment carrying the test override.
    ///   - bundle: bundle to search for the packaged dictionary; injectable so
    ///     a test can point at a synthetic bundle instead of the running one.
    /// - Returns: the URL the dictionary load is attempted from.
    public static func dictionaryURL(environment: [String: String],
                                     bundle: Bundle = .main) -> URL {
        if let override = environment[dictionaryPathEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let bundled = bundledDictionaryURL(in: bundle) {
            return bundled
        }
        return packagedDictionaryURL(in: bundle)
    }

    /// The dictionary location the packaged layout defines, derived from the
    /// bundle alone (`<bundle>/Contents/Resources/Strings/terms.json`). This
    /// is also the last probe of `bundledDictionaryURL`, so the "found" and
    /// "expected" paths can never drift apart.
    ///
    /// - Parameter bundle: candidate bundle.
    /// - Returns: the expected shipping path (may not exist).
    private static func packagedDictionaryURL(in bundle: Bundle) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(bundleDictionarySubdirectory, isDirectory: true)
            .appendingPathComponent("terms.json")
    }

    /// Locates the packaged dictionary inside `bundle` (nil = not packaged
    /// here, caller falls through to the expected shipping path).
    ///
    /// Two probes, because they answer different layouts:
    ///   - the resource lookup resolves against `Contents/Resources`, i.e. the
    ///     canonical `Contents/Resources/Strings/terms.json` an `.app` has;
    ///   - the explicit path covers a bundle whose `Info.plist`/resource layout
    ///     differs from the standard one. For an unbundled (raw `swift build`)
    ///     binary both probes simply miss.
    ///
    /// - Parameter bundle: candidate bundle.
    /// - Returns: the first existing dictionary URL, or nil.
    private static func bundledDictionaryURL(in bundle: Bundle) -> URL? {
        if let url = bundle.url(forResource: "terms",
                                withExtension: "json",
                                subdirectory: bundleDictionarySubdirectory),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let explicit = packagedDictionaryURL(in: bundle)
        if FileManager.default.fileExists(atPath: explicit.path) {
            return explicit
        }
        return nil
    }

    // MARK: - State

    /// The currently selected language (BCP-47: "en"/"zh-Hant"/"zh-Hans").
    public private(set) var language: String

    /// The loaded dictionary; nil when the file could not be loaded.
    public private(set) var dictionary: TermDictionary?

    /// The path the dictionary load was attempted from (evidence line).
    public let dictionaryPath: String

    /// Human-readable load failure (nil = loaded fine).
    public private(set) var loadErrorDescription: String?

    /// Miss hook — called once per (term, language) that needed a fallback.
    /// `fallback` names what filled the gap: the dictionary's default
    /// language code, or "key" when even the default language missed.
    /// The composition root wires it to the evidence log.
    public var onMissingTerm: ((_ term: String, _ language: String, _ fallback: String) -> Void)?

    private var observers: [(token: Int, handler: () -> Void)] = []
    private var nextObserverToken = 1
    private var recordedMisses: Set<String> = []

    // MARK: - Init

    /// Production init: loads the dictionary file (failure is non-fatal —
    /// see the type doc).
    public init(dictionaryURL: URL, language: String) {
        self.dictionaryPath = dictionaryURL.path
        self.language = language
        do {
            self.dictionary = try TermDictionary.load(from: dictionaryURL)
        } catch {
            self.dictionary = nil
            self.loadErrorDescription = error.localizedDescription
        }
    }

    /// Test seam: an already-parsed dictionary (no file I/O).
    public init(dictionary: TermDictionary?, language: String, path: String = "(in-memory)") {
        self.dictionary = dictionary
        self.dictionaryPath = path
        self.language = language
    }

    // MARK: - Language

    /// Languages the dictionary declares (the picker's domain). Without a
    /// dictionary only the fallback language is known.
    public var supportedLanguages: [String] {
        dictionary?.languages ?? [Self.fallbackLanguage]
    }

    /// Sets the selected language and notifies observers — no-op when the
    /// value is unchanged (no spurious re-render).
    public func setLanguage(_ code: String) {
        guard code != language else { return }
        language = code
        for observer in observers {
            observer.handler()
        }
    }

    // MARK: - Term lookup (read the table in the selected language)

    /// Looks up `term` in the selected language.
    ///
    /// Fallback chain: selected language → dictionary default language →
    /// the term key itself (each fallback beyond the first records a miss).
    public func t(_ term: String) -> String {
        guard let dictionary else {
            // No dictionary at all: the key is the honest rendering.
            recordMiss(term, fallback: "key")
            return term
        }
        if let value = dictionary.value(for: term, language: language), !value.isEmpty {
            return value
        }
        if let fallback = dictionary.value(for: term, language: dictionary.defaultLanguage),
           !fallback.isEmpty {
            recordMiss(term, fallback: dictionary.defaultLanguage)
            return fallback
        }
        recordMiss(term, fallback: "key")
        return term
    }

    /// `t(_:)` with one `%@` substitution (e.g. "Connected: %@").
    public func t(_ term: String, _ argument: String) -> String {
        String(format: t(term), argument)
    }

    // MARK: - Observers

    /// Registers a re-render handler; returns the removal token. Observers
    /// are called synchronously on `setLanguage`.
    @discardableResult
    public func observe(_ handler: @escaping () -> Void) -> Int {
        let token = nextObserverToken
        nextObserverToken += 1
        observers.append((token: token, handler: handler))
        return token
    }

    /// Removes an observer (no-op when unknown).
    public func removeObserver(_ token: Int) {
        observers.removeAll { $0.token == token }
    }

    // MARK: - Private

    /// Records the first miss per (term, language) — the evidence channel.
    private func recordMiss(_ term: String, fallback: String) {
        let marker = "\(term)@\(language)"
        guard recordedMisses.insert(marker).inserted else { return }
        onMissingTerm?(term, language, fallback)
    }
}
