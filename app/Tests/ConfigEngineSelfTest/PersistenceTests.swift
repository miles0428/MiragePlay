import Foundation
import ConfigEngine
import SharedTypes

/// Tests ②③ — persistence: single-group roundtrip + auto write-back, the
/// The save-as named-profile directory (the file name = the profile name),
/// listing, and the "no auto-created pile" rule ("the app does not bulk-create them").
enum PersistenceSuite {

    static func runAll() {
        runCase("②a no auto-creation + auto write-back") { try noAutoCreationAndAutoWriteBack() }
        runCase("②b full-field roundtrip through fresh instances") { try fullFieldRoundtripThroughFreshInstances() }
        runCase("③ Save As → configs dir + listing + dropdown") { try saveAsProfileDirectoryAndListing() }
    }

    static let fm = FileManager.default

    // MARK: - ② single-group persistence + auto write-back

    static func noAutoCreationAndAutoWriteBack() throws {
        let dir = TestSupport.scratchPath("persistence-no-auto")
        TestSupport.removeScratch(dir)
        TestReporter.check(!fm.fileExists(atPath: dir.path), "scratch starts absent")

        let store = ProfileStore(rootDirectory: dir)
        TestReporter.isNil(try store.loadCurrent(), "fresh install: nothing persisted")
        TestReporter.equal(try store.listProfiles(), [String](), "no profiles until a Save As")
        TestReporter.check(!fm.fileExists(atPath: dir.path), "load/list must not create anything")

        // Engine construction = read-only (no settings file appears).
        let engine = ConfigEngine(
            profileStore: ProfileStore(rootDirectory: dir),
            keyVault: KeyVault(bundleID: "com.ycchung.mirageplay", homeDirectory: dir),
            rcArgvSnap: RcArgvSnap(rcDirectory: dir.appendingPathComponent("rc")))
        TestReporter.equal(engine.currentModel, Presets.factoryModel, "fresh engine = factory model")
        TestReporter.check(!fm.fileExists(atPath: dir.path), "engine init must not create files")

        // The first change → auto write-back (⑫: any settings change writes back).
        try engine.setResolution("1440p")
        engine.setMuted(true)
        let reread = try ProfileStore(rootDirectory: dir).loadCurrent()
        TestReporter.equal(reread?.resolution, "1440p", "write-back: resolution")
        TestReporter.equal(reread?.muted, true, "write-back: muted")

        // Exactly the single active file exists — nothing else was created.
        let entries = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        TestReporter.equal(entries, ["settings.json"], "only the single active file exists")
        TestReporter.check(!fm.fileExists(atPath: dir.appendingPathComponent("configs").path),
                           "no configs dir before the first Save As")

        TestSupport.removeScratch(dir)
    }

    static func fullFieldRoundtripThroughFreshInstances() throws {
        let dir = try TestSupport.freshScratch("persistence-roundtrip")
        defer { TestSupport.removeScratch(dir) }
        let store = ProfileStore(rootDirectory: dir)

        // Every field carries a non-default value.
        var model = Presets.factoryModel
        model.deviceName = "YC 的 MacBook"
        model.pinEnabled = true
        model.pinCode = "4827"              // already set → P3 reuses it (across restarts)
        model.resolution = "1440p"
        model.frameRate = 60
        model.muted = true
        model.preventSleep = false
        model.notificationsEnabled = false
        model.language = "zh-Hant"
        model.profileName = "測試配置"
        model.rcPassThrough = ["p 7100"]    // channel structure demo (v1 default [])
        try store.saveCurrent(model)

        // A fresh store instance decodes the same bytes.
        let store2 = ProfileStore(rootDirectory: dir)
        TestReporter.equal(try store2.loadCurrent(), model, "roundtrip through a fresh store")

        // A fresh engine restores everything (a restart brings the last value) and the snapshot
        // surfaces the persisted values.
        let engine = ConfigEngine(
            profileStore: store2,
            keyVault: KeyVault(bundleID: "com.ycchung.mirageplay", homeDirectory: dir),
            rcArgvSnap: RcArgvSnap(rcDirectory: dir.appendingPathComponent("rc")))
        TestReporter.equal(engine.currentModel, model, "fresh engine restores the model")
        let snap = engine.effectiveSnapshot()
        TestReporter.equal(snap.deviceName, "YC 的 MacBook", "snap deviceName")
        TestReporter.equal(snap.resolution, "1440p", "snap resolution")
        TestReporter.equal(snap.frameRate, 60, "snap frameRate")
        TestReporter.check(snap.muted, "snap muted")
        TestReporter.check(!snap.preventSleep, "snap preventSleep")
        TestReporter.check(!snap.notificationsEnabled, "snap notificationsEnabled")
        TestReporter.equal(snap.language, "zh-Hant", "snap language")
        TestReporter.equal(snap.profileName, "測試配置", "snap profileName")
        TestReporter.equal(snap.pinCode, "4827", "snap pinCode (user-set → P3 reuse)")
        TestReporter.check(snap.rcText().contains("p 7100\n"), "channel structure survives persistence")

        // Raw JSON sanity: it is the model, serialized plainly.
        let raw = try String(contentsOf: store.currentSettingsURL, encoding: .utf8)
        TestReporter.check(raw.contains("\"deviceName\""), "settings.json carries deviceName")
        TestReporter.check(raw.contains("\"pinCode\""), "settings.json carries pinCode")

        TestSupport.writeEvidence("03-persistence-roundtrip.txt", [
            "single-group file: \(store.currentSettingsURL.path)",
            "fields round-tripped: 11/11",
            TestSupport.renderLines(raw),
        ].joined(separator: "\n") + "\n")
    }

    // MARK: - ③ save-as → the configs dir (file name = profile name) + listing

    static func saveAsProfileDirectoryAndListing() throws {
        let dir = try TestSupport.freshScratch("persistence-saveas")
        defer { TestSupport.removeScratch(dir) }
        let store = ProfileStore(rootDirectory: dir)
        let configsDir = dir.appendingPathComponent("configs")

        // Fresh: empty list, no configs dir (no auto-creation).
        TestReporter.equal(try store.listProfiles(), [String](), "fresh listing empty")
        TestReporter.check(!fm.fileExists(atPath: configsDir.path), "no configs dir at fresh state")

        var modelA = Presets.factoryModel
        modelA.resolution = "720p"
        let urlA = try store.saveProfile(modelA, named: "我的設定")
        // the file name = the profile name, exactly (no extension), inside <root>/configs/.
        TestReporter.check(TestSupport.pathsEqual(urlA.path, configsDir.appendingPathComponent("我的設定").path),
                           "profile file path = configs/<name>")
        TestReporter.equal(urlA.lastPathComponent, "我的設定", "file name = profile name exactly")

        var modelB = Presets.factoryModel
        modelB.frameRate = 120
        try store.saveProfile(modelB, named: "第二方案")

        let names = try store.listProfiles()
        TestReporter.equal(Set(names), Set(["我的設定", "第二方案"]), "list API returns both names")
        TestReporter.equal(names, names.sorted(), "listing is sorted")

        // Load round-trip by name.
        TestReporter.equal(try store.loadProfile(named: "我的設定"), modelA, "load by profile name")
        TestReporter.equal(try store.loadProfile(named: "第二方案"), modelB, "load the second profile")

        // Invalid names are refused (file name = profile name → path guards).
        TestReporter.throwsError("empty name refused") { _ = try store.saveProfile(modelA, named: "") }
        TestReporter.throwsError("slash refused") { _ = try store.saveProfile(modelA, named: "a/b") }
        TestReporter.throwsError("dot-dot refused") { _ = try store.saveProfile(modelA, named: "..") }
        TestReporter.throwsError("missing profile refused") { _ = try store.loadProfile(named: "不存在") }

        // Engine-level save-as + dropdown switching (R3-Q3): save → drift → load back.
        let engine = ConfigEngine(
            profileStore: store,
            keyVault: KeyVault(bundleID: "com.ycchung.mirageplay", homeDirectory: dir),
            rcArgvSnap: RcArgvSnap(rcDirectory: dir.appendingPathComponent("rc")))
        try engine.setResolution("2160p")
        try engine.saveProfileAs(named: "高解析")
        TestReporter.equal(engine.currentModel.profileName, "高解析", "save-as makes the name current")
        TestReporter.equal(try store.loadProfile(named: "高解析").resolution, "2160p", "saved profile carries drift-free value")
        TestReporter.equal(try store.loadProfile(named: "高解析").profileName, "高解析",
                           "saved file carries its own name (B4 = self-named; fixed in section F)")

        try engine.setResolution("480p")            // current drifts away
        try engine.loadProfile(named: "高解析")      // dropdown selection
        TestReporter.equal(engine.currentModel.resolution, "2160p", "dropdown load restores value")
        TestReporter.equal(engine.currentModel.profileName, "高解析", "dropdown load sets current name")
        TestReporter.equal(try store.loadCurrent()?.resolution, "2160p", "switch persists as active group")

        let evidence = [
            "configs dir: \(configsDir.path)",
            "files: \(try fm.contentsOfDirectory(atPath: configsDir.path).sorted())",
            "listProfiles() = \(names)",
            "file-name check: configs/我的設定 exists = \(fm.fileExists(atPath: configsDir.appendingPathComponent("我的設定").path))",
        ].joined(separator: "\n") + "\n"
        TestSupport.writeEvidence("04-saveas-listing.txt", evidence)
    }
}
