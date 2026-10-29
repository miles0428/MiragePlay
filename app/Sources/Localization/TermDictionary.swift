import Foundation

/// TermDictionary — the term-dictionary body of the stage G language landing.
///
/// The dictionary is the **config carrier** of the language policy
/// (BLUEPRINT L146 [YC 2026-10-17 R4-Q1]: "the term dictionary is written in config and read
/// term by term in the selected language"; the fill-in point = `app/Resources/Strings/` [L147]). File shape:
///
/// ```json
/// {
///   "format": "mirrorboard-term-dictionary",
///   "version": 1,
///   "defaultLanguage": "en",
///   "languages": ["en", "zh-Hant", "zh-Hans"],
///   "terms": { "<term>": { "en": "…", "zh-Hant": "…", "zh-Hans": "…" } }
/// }
/// ```
///
/// Values are the fills-package §B three-language table
/// (`.task_state/spec_closeout-fills_20261017.md` §B — the authority table;
/// The EN column is "a PM proposal value, revocable in one line after YC's hands-on check").
///
/// Read-only, value type, thread-agnostic (the app uses it on the main
/// thread only, same discipline as every other unit).
public struct TermDictionary: Sendable {

    /// A parse/structure error — the loaders surface the reason and never crash.
    public enum DictionaryError: Error, Equatable {
        /// The body is valid JSON but not a term dictionary (shape/type).
        case malformed(String)
        /// The `format` marker is missing or not ours.
        case unsupportedFormat(String)
    }

    /// The format marker every dictionary file must carry.
    public static let formatMarker = "mirrorboard-term-dictionary"

    /// Language codes the dictionary declares (BCP-47; S-10 form).
    public let languages: [String]

    /// The dictionary's declared default language — the fallback target when
    /// the selected language misses a term.
    public let defaultLanguage: String

    /// term → language → value (the dictionary body).
    public let terms: [String: [String: String]]

    /// The number of terms carried (used for evidence/audit).
    public var termCount: Int { terms.count }

    public init(languages: [String], defaultLanguage: String, terms: [String: [String: String]]) {
        self.languages = languages
        self.defaultLanguage = defaultLanguage
        self.terms = terms
    }

    /// Parses a dictionary JSON body.
    ///
    /// - Throws: `DictionaryError` when the body is not a well-formed term
    ///   dictionary (JSON syntax errors surface as `.malformed`).
    public init(data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DictionaryError.malformed("JSON parse failed: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw DictionaryError.malformed("root is not an object")
        }
        guard let format = root["format"] as? String, format == Self.formatMarker else {
            throw DictionaryError.unsupportedFormat("\(root["format"] ?? "nil")")
        }
        guard let languageList = root["languages"] as? [String], !languageList.isEmpty else {
            throw DictionaryError.malformed("languages missing/empty")
        }
        guard let defaultLanguage = root["defaultLanguage"] as? String,
              languageList.contains(defaultLanguage) else {
            throw DictionaryError.malformed("defaultLanguage missing or not in languages")
        }
        guard let rawTerms = root["terms"] as? [String: Any] else {
            throw DictionaryError.malformed("terms missing")
        }
        var terms: [String: [String: String]] = [:]
        for (term, value) in rawTerms {
            guard let values = value as? [String: String] else {
                throw DictionaryError.malformed("term '\(term)' is not a language→string map")
            }
            terms[term] = values
        }
        self.init(languages: languageList, defaultLanguage: defaultLanguage, terms: terms)
    }

    /// Loads and parses a dictionary file.
    public static func load(from url: URL) throws -> TermDictionary {
        try TermDictionary(data: Data(contentsOf: url))
    }

    /// Raw lookup: the term's value in the given language.
    ///
    /// - Returns: the value, or nil when the term or the language entry is
    ///   absent (no fallback here — fallback is `LanguageService`'s policy).
    public func value(for term: String, language: String) -> String? {
        terms[term]?[language]
    }
}
