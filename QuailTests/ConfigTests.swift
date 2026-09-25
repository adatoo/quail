import Foundation
import Testing
@testable import Quail

@Suite("Config")
struct ConfigTests {
    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-config-tests-\(UUID().uuidString).json")
    }

    @Test("load returns defaults when the file doesn't exist")
    func loadReturnsDefaultsWhenMissing() {
        let config = Config.load(from: scratchURL())
        #expect(config == Config())
    }

    @Test("load returns defaults when the file is malformed JSON")
    func loadReturnsDefaultsWhenMalformed() throws {
        let url = scratchURL()
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Config.load(from: url)
        #expect(config == Config())
    }

    @Test("save then load round-trips every field")
    func saveThenLoadRoundTrips() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var original = Config()
        original.host = "0.0.0.0"
        original.port = 9090
        original.modelsMax = 2
        original.apiKeyEnabled = true
        original.openAtLogin = true
        original.autoStartServer = true
        original.modelsDirectoryBookmark = Data([0x01, 0x02, 0x03])
        try original.save(to: url)

        let loaded = Config.load(from: url)
        #expect(loaded == original)
    }

    @Test("a JSON file missing a newer field decodes with that field's default")
    func missingFieldFallsBackToDefault() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Simulates a config.json written by an older version of Quail,
        // before `autoStartServer` existed.
        let legacyJSON = """
        {"runtimeID":"llamaCpp","host":"127.0.0.1","port":8080,"modelsMax":1,"apiKeyEnabled":false,"openAtLogin":true}
        """
        try Data(legacyJSON.utf8).write(to: url)

        let loaded = Config.load(from: url)
        #expect(loaded.openAtLogin == true)
        #expect(loaded.autoStartServer == false) // the field that was "missing"
        #expect(loaded.modelsDirectoryBookmark == nil) // also missing from the legacy JSON
        // The file predates the on-by-default rule, so AppState will apply it once.
        #expect(loaded.apiKeyDefaultApplied == false)
        #expect(loaded.apiKeyEnabled == false)

        // A new Config starts with the key on and nothing left to apply.
        #expect(Config().apiKeyEnabled)
        #expect(Config().apiKeyDefaultApplied)
    }
}
