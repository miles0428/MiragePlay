import Foundation
import Localization

/// Stage2-G language self-test runner entry point.
///
/// Harness note (same convention as ConfigEngineSelfTest): this toolchain is
/// CommandLineTools-only — no XCTest / swift-testing is linkable — so this is
/// a plain SwiftPM executable target. Run either:
///   - `cd app && swift run LocalizationSelfTest`, or
///   - `scripts/test-language.sh` (wraps the above + the app-level phases).
///
/// Covers: dictionary load + structure, the §B authority values (spot
/// checks), three-language well-formedness, the app's full term-key manifest,
/// the missing-key fallback chain (selected → default → key) with the miss
/// hook, observer notification semantics, and the dictionary URL resolution.
///
/// Exit code 0 = all checks passed; 1 = failures (listed at the end).

var passed = 0
var failed = 0
var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
    } else {
        failed += 1
        failures.append(label)
        print("  FAIL — \(label)")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    check(actual == expected, "\(label) — actual: \(actual), expected: \(expected)")
}

/// Repo root derived from THIS file's location
/// (<repo>/app/Tests/LocalizationSelfTest/main.swift → up 4 levels).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // LocalizationSelfTest/
    .deletingLastPathComponent()   // Tests/
    .deletingLastPathComponent()   // app/
    .deletingLastPathComponent()   // repo root

/// The contract's fill-in point (BLUEPRINT L147) relative to the repo root. This harness reads
/// the SOURCE dictionary directly; the app itself only ever reads its bundle,
/// because P-1.4 removed the runtime project-root fallback.
let sourceDictionaryRelativePath = "app/Resources/Strings/terms.json"

let dictionaryPath = repoRoot.appendingPathComponent(sourceDictionaryRelativePath)

print("MiragePlay Stage2-G language self-test")
print("repo root: \(repoRoot.path)")
print("dictionary: \(dictionaryPath.path)")
print("run at: \(ISO8601DateFormatter().string(from: Date()))")
print("")

// MARK: - 1. Dictionary load + structure

print("-- dictionary load + structure")
let dictionary: TermDictionary
do {
    dictionary = try TermDictionary.load(from: dictionaryPath)
    check(true, "dictionary loads from the contract injection point (\(sourceDictionaryRelativePath))")
} catch {
    print("  FATAL — dictionary load failed: \(error)")
    exit(1)
}

equal(dictionary.languages, ["en", "zh-Hant", "zh-Hans"],
      "language set = English + Traditional Chinese + Simplified Chinese (R4-Q1)")
equal(dictionary.defaultLanguage, "en", "declared default language = en (defaults to English)")
check(dictionary.termCount >= 50, "term count ≥ 50 (actual: \(dictionary.termCount))")

// Three-language well-formedness: every term carries all three languages,
// non-empty (the dictionary is the deliverable — a gap must be a red test).
var malformed: [String] = []
for (term, values) in dictionary.terms {
    for language in dictionary.languages {
        if values[language]?.isEmpty != false {
            malformed.append("\(term)@\(language)")
        }
    }
}
check(malformed.isEmpty, "every term carries all three languages non-empty (gaps: \(malformed.sorted()))")

// MARK: - 2. §B authority values (spot checks, verbatim)

print("-- §B authority values (spot checks)")
let spotChecks: [(term: String, en: String, hant: String, hans: String)] = [
    ("panel.status.idle", "Stopped", "未開啟", "未开启"),
    ("panel.status.waiting", "Waiting for connection…", "等待連線中…", "等待连接中…"),
    ("panel.status.connected", "Connected: %@", "已連線：%@", "已连接：%@"),
    ("panel.status.stopping", "Stopping receiver…", "正在關閉接收…", "正在关闭接收…"),
    ("panel.status.startFailed", "Start failed: ", "啟動失敗：", "启动失败："),
    ("panel.button.start", "Start", "啟動", "启动"),
    ("panel.button.stop", "Stop", "關閉", "关闭"),
    ("panel.pin.protection", "PIN Protection", "PIN 保護", "PIN 保护"),
    ("panel.pin.code", "PIN Code", "PIN 碼", "PIN 码"),
    ("panel.pin.change", "New Code", "更換", "更换"),
    ("panel.entry.preferences", "Preferences…", "偏好設定…", "偏好设置…"),
    ("panel.entry.quit", "Quit", "退出", "退出"),
    ("menu.tooltip", "MiragePlay", "MiragePlay", "MiragePlay"),
    ("prefs.window.title", "Preferences", "偏好設定", "偏好设置"),
    ("prefs.tab.videoAudio", "Video & Audio", "影像與聲音", "影像与声音"),
    ("prefs.tab.connection", "Connection & Session", "連線與工作階段", "连接与工作阶段"),
    ("prefs.tab.language", "Language", "語言", "语言"),
    ("prefs.row.resolution", "Resolution", "解析度", "分辨率"),
    ("prefs.row.frameRate", "Frame Rate Limit", "幀率上限", "帧率上限"),
    ("prefs.row.mute", "Mute", "靜音", "静音"),
    ("prefs.button.apply", "Apply", "套用", "套用"),
    ("prefs.button.about", "About…", "關於…", "关于…"),
    ("prefs.apply.reminder", "Unsaved changes", "尚未套用的變更", "尚未套用的变更"),
    ("prefs.row.deviceName", "Device Name", "裝置名稱", "设备名称"),
    ("prefs.row.pinChange", "Change PIN", "PIN 改碼", "PIN 改码"),
    ("prefs.row.trusted", "Trusted Devices", "信任清單", "信任列表"),
    ("prefs.row.preventSleep", "Prevent Sleep", "防睡眠", "防止睡眠"),
    ("prefs.row.notifications", "Connection Notifications", "連線通知", "连接通知"),
    ("prefs.row.language", "Language", "語言", "语言"),
    ("about.title", "About MiragePlay", "關於 MiragePlay", "关于 MiragePlay"),
    ("about.appName", "MiragePlay", "MiragePlay", "MiragePlay"),
    ("about.copyright", "© 2026 Yu-Cheng Chung and Contributors", "© 2026 Yu-Cheng Chung and Contributors", "© 2026 Yu-Cheng Chung and Contributors"),
    ("about.license", "License: GPL-3.0-only", "授權條款：GPL-3.0-only", "许可协议：GPL-3.0-only"),
    ("about.thirdParty", "Third-party: UxPlay v1.73.6, OpenSSL 3, libplist, GStreamer (fallback leg only)", "第三方元件：UxPlay v1.73.6、OpenSSL 3、libplist、GStreamer（僅備用腿）", "第三方元件：UxPlay v1.73.6、OpenSSL 3、libplist、GStreamer（仅备用腿）"),
    ("about.source", "Source code", "原始碼", "源代码"),
    ("lang.option.en", "English", "English", "English"),
    ("lang.option.zh-Hant", "繁體中文", "繁體中文", "繁體中文"),
    ("lang.option.zh-Hans", "简体中文", "简体中文", "简体中文"),
    ("notify.connected", "Connected to %@", "已連線：%@", "已连接：%@"),
    ("notify.disconnected", "Disconnected", "已斷線", "已断开连接"),
    ("trust.ask.windowTitle", "Trust this device?", "信任此裝置？", "信任此设备？"),
    ("trust.ask.title", "Trust “%@”?", "要信任「%@」嗎？", "要信任“%@”吗？"),
    ("trust.ask.accept", "Trust", "信任", "信任"),
    ("trust.ask.decline", "Don't Trust", "不信任", "不信任"),
]
for spot in spotChecks {
    equal(dictionary.value(for: spot.term, language: "en"), Optional(spot.en), "\(spot.term) [en]")
    equal(dictionary.value(for: spot.term, language: "zh-Hant"), Optional(spot.hant), "\(spot.term) [zh-Hant]")
    equal(dictionary.value(for: spot.term, language: "zh-Hans"), Optional(spot.hans), "\(spot.term) [zh-Hans]")
}

// MARK: - 3. Term-key manifest (every key the UI sources actually use)

print("-- term-key manifest (UI ⟷ dictionary coverage)")
let manifest: [String] = [
    "panel.status.idle", "panel.status.waiting", "panel.status.connected",
    "panel.status.stopping", "panel.status.startFailed", "panel.status.startFailedGeneric",
    "panel.button.start", "panel.button.stop",
    "panel.pin.protection", "panel.pin.code", "panel.pin.change",
    "panel.entry.preferences", "panel.entry.quit",
    "menu.tooltip",
    "prefs.window.title", "prefs.tab.videoAudio", "prefs.tab.connection",
    "prefs.tab.language",
    "prefs.row.resolution", "prefs.row.frameRate", "prefs.row.mute",
    "prefs.button.apply", "prefs.button.about", "prefs.apply.reminder",
    "prefs.row.deviceName", "prefs.row.pinChange", "prefs.row.trusted",
    "prefs.trust.empty", "prefs.trust.edit", "prefs.trust.editorTitle",
    "prefs.trust.reset", "prefs.trust.done",
    "trust.ask.windowTitle", "trust.ask.title", "trust.ask.message",
    "trust.ask.accept", "trust.ask.decline",
    "prefs.row.preventSleep", "prefs.row.notifications",
    "prefs.row.language",
    "about.title", "about.appName", "about.copyright", "about.license", "about.thirdParty",
    "about.source",
    "lang.option.en", "lang.option.zh-Hant", "lang.option.zh-Hans",
    "notify.connected", "notify.disconnected",
]
for key in manifest {
    check(dictionary.terms[key] != nil, "manifest key present: \(key)")
}

// MARK: - 4. The missing-key fallback chain

print("-- missing-key fallback chain")
let fixtureJSON = """
{
  "format": "mirrorboard-term-dictionary",
  "version": 1,
  "defaultLanguage": "en",
  "languages": ["en", "zh-Hant", "zh-Hans"],
  "terms": {
    "full.term": { "en": "Full EN", "zh-Hant": "全繁", "zh-Hans": "全简" },
    "partial.term": { "en": "Fallback EN" },
    "empty.term": { "en": "Empty EN", "zh-Hant": "", "zh-Hans": "" }
  }
}
"""
let fixture = try TermDictionary(data: Data(fixtureJSON.utf8))
var misses: [(String, String)] = []
let fixtureService = LanguageService(dictionary: fixture, language: "zh-Hant")
fixtureService.onMissingTerm = { term, language, _ in misses.append((term, language)) }

equal(fixtureService.t("full.term"), "全繁", "selected-language hit")
equal(fixtureService.t("partial.term"), "Fallback EN", "miss in selected → falls back to en")
equal(fixtureService.t("absent.term"), "absent.term", "miss everywhere → the term key itself")
equal(fixtureService.t("empty.term"), "Empty EN", "empty-string value counts as a miss → falls back to en")
equal(misses.map { $0.0 }.sorted(), ["absent.term", "empty.term", "partial.term"],
      "misses recorded for the fallback chain (and only those)")
_ = fixtureService.t("partial.term")   // repeat lookup
equal(misses.count, 3, "miss recording is deduped per (term, language)")

fixtureService.setLanguage("en")
equal(fixtureService.t("partial.term"), "Fallback EN", "default-language hit is not a miss")
equal(fixtureService.t("absent.term"), "absent.term", "miss in default language → key")
check(misses.contains { $0.0 == "absent.term" && $0.1 == "en" }, "default-language miss recorded under 'en'")

// No dictionary at all (deployment error) → honest key rendering, never a crash.
let bare = LanguageService(dictionary: nil, language: "zh-Hans")
equal(bare.t("panel.status.idle"), "panel.status.idle", "no dictionary → term key (honest degradation)")

// MARK: - 5. Observer semantics (the mechanism behind the instant whole-UI effect)

print("-- observer semantics")
let observerService = LanguageService(dictionary: fixture, language: "en")
var notifications = 0
observerService.observe { notifications += 1 }
observerService.setLanguage("zh-Hant")
equal(notifications, 1, "setLanguage fires observers once")
observerService.setLanguage("zh-Hant")
equal(notifications, 1, "same-language set is a no-op (no spurious re-render)")
let token = observerService.observe { notifications += 1 }
observerService.removeObserver(token)
observerService.setLanguage("zh-Hans")
equal(notifications, 2, "removed observer no longer fires")

// MARK: - 6. Dictionary URL resolution

print("-- dictionary URL resolution")
// P-1.4: env override → `Bundle.main`, and NO project-root fallback. An
// unbundled binary (this harness) must therefore resolve to the path the
// packaged layout would use — derived from its own bundle — and never to the
// developer's checkout (P-2.3).
let defaultResolution = LanguageService.dictionaryURL(environment: [:])
check(defaultResolution.path.hasPrefix(Bundle.main.bundleURL.path),
      "default resolution derives from Bundle.main — actual: \(defaultResolution.path)")
check(defaultResolution.path.hasSuffix("Contents/Resources/Strings/terms.json"),
      "default resolution targets the packaged layout <bundle>/Contents/Resources/Strings/terms.json (P-1.1)")
check(defaultResolution.path != dictionaryPath.path,
      "default resolution is NOT the source-tree injection point (P-1.4 removed the fallback) — actual: \(defaultResolution.path)")
// The removed fallback used to make this harness silently read the source
// dictionary; now the resolution either loads from the bundle or fails loudly.
let defaultResolutionService = LanguageService(dictionaryURL: defaultResolution, language: "en")
check(defaultResolutionService.dictionary != nil || defaultResolutionService.loadErrorDescription != nil,
      "resolution either loads a dictionary or records why it could not (never a silent dev read)")
equal(LanguageService.dictionaryURL(environment: ["MIRRORBOARD_STRINGS_PATH": "/tmp/fixture.json"]).path,
      "/tmp/fixture.json",
      "MIRRORBOARD_STRINGS_PATH overrides the dictionary location")

// Production service over the real file: spot-check the integration path.
let realService = LanguageService(dictionaryURL: dictionaryPath, language: "en")
check(realService.dictionary != nil, "production init loads the real dictionary")
equal(realService.t("panel.status.idle"), "Stopped", "en default renders EN (defaults to English)")
realService.setLanguage("zh-Hant")
equal(realService.t("panel.status.idle"), "未開啟", "zh-Hant renders 繁中")
realService.setLanguage("zh-Hans")
equal(realService.t("panel.status.idle"), "未开启", "zh-Hans renders 簡中")
equal(realService.t("panel.status.connected", "iPad"), "已连接：iPad", "placeholder substitution")

// MARK: - 7. Dictionary error surfaces

print("-- dictionary error surfaces")
do {
    _ = try TermDictionary(data: Data("{}".utf8))
    check(false, "empty object must not parse as a dictionary")
} catch {
    check(true, "malformed dictionary refused (\(error))")
}
do {
    _ = try TermDictionary(data: Data("not json".utf8))
    check(false, "non-JSON must not parse")
} catch {
    check(true, "non-JSON refused (\(error))")
}

// MARK: - Summary

let failuresBlock = failures.isEmpty
    ? "    (none)"
    : failures.map { "    - " + $0 }.joined(separator: "\n")
print("""

self-test summary
  passed: \(passed)
  failed: \(failed)
  failures:
\(failuresBlock)
""")

if failed > 0 {
    print("RESULT: FAIL (\(failed) failures)")
    exit(1)
} else {
    print("RESULT: PASS (\(passed) checks)")
    exit(0)
}
