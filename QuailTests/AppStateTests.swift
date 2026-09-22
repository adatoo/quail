import Foundation
import Testing
@testable import Quail

/// Exercises `AppState` against `FakeRuntime` and `FakeSecretStore` — no
/// real process, network call, or Keychain access (see that file's doc
/// comment for why Keychain itself isn't touched here). Every test gets
/// its own scratch directory for both `config.json` and the model store's
/// root, so `start()`'s `ModelStore.ensureDirectoriesExist()` /
/// `regeneratePresets()` calls never touch the real
/// `~/Library/Application Support/Quail`.
@Suite("AppState", .timeLimit(.minutes(1)))
@MainActor
struct AppStateTests {
    private func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-appstate-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeAppState(
        config: Config = Config(),
        scratchDir: URL,
        secretStore: FakeSecretStore = FakeSecretStore()
    )
        -> AppState
    {
        let launchSpec = LaunchSpec(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            environment: [:],
            currentDirectoryURL: nil
        )
        return AppState(
            config: config,
            configURL: scratchDir.appendingPathComponent("config.json"),
            secretStore: secretStore,
            runtime: FakeRuntime(launchSpec: launchSpec),
            logStore: LogStore(),
            modelsRootURL: scratchDir.appendingPathComponent("Models", isDirectory: true)
        )
    }

    @Test("starts stopped, and start() reaches ready against a fake runtime")
    func startReachesReady() async {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        #expect(appState.statusLabel == "Stopped")
        #expect(appState.canStart)
        #expect(!appState.canStop)

        await appState.start()
        #expect(appState.statusLabel == "Running")
        #expect(appState.canStop)

        await appState.stop()
        #expect(appState.statusLabel == "Stopped")
    }

    @Test("setHost and setPort persist to config.json")
    func setHostAndPortPersist() {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        appState.setHost("0.0.0.0")
        appState.setPort(9090)

        #expect(appState.config.host == "0.0.0.0")
        #expect(appState.config.port == 9090)

        let reloaded = Config.load(from: scratch.appendingPathComponent("config.json"))
        #expect(reloaded.host == "0.0.0.0")
        #expect(reloaded.port == 9090)
    }

    @Test("enabling the API key stores a generated key; disabling deletes it")
    func apiKeyToggleStoresAndDeletes() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let secretStore = FakeSecretStore()
        let appState = makeAppState(scratchDir: scratch, secretStore: secretStore)

        #expect(appState.apiKey == nil)

        appState.setAPIKeyEnabled(true)
        let key = appState.apiKey
        #expect(key != nil)
        #expect(key?.isEmpty == false)

        appState.setAPIKeyEnabled(false)
        #expect(appState.apiKey == nil)
        #expect(try secretStore.get(account: "llamaCppAPIKey") == nil)
    }

    @Test("regenerateAPIKey replaces the stored key while enabled, no-ops while disabled")
    func regenerateAPIKey() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        appState.regenerateAPIKey() // disabled: no-op
        #expect(appState.apiKey == nil)

        appState.setAPIKeyEnabled(true)
        let first = try #require(appState.apiKey)

        appState.regenerateAPIKey()
        let second = try #require(appState.apiKey)
        #expect(first != second)
    }

    @Test("a config loaded with apiKeyEnabled but no stored key starts the runtime without --api-key")
    func endpointConfigOmitsAPIKeyWhenNoneStored() async {
        var config = Config()
        config.apiKeyEnabled = true // e.g. Keychain access failed after the toggle was saved
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(config: config, scratchDir: scratch)

        // Doesn't crash or hang — start() must tolerate a nil key here.
        await appState.start()
        #expect(appState.statusLabel == "Running")
        await appState.stop()
    }

    @Test("start() creates the model store's directories and a presets.ini")
    func startCreatesModelStore() async {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        await appState.start()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: appState.modelStore.ggufDirectory.path))
        #expect(fm.fileExists(atPath: appState.modelStore.mlxDirectory.path))
        #expect(fm.fileExists(atPath: appState.modelStore.hfCacheDirectory.path))
        #expect(fm.fileExists(atPath: appState.modelStore.presetsFile.path))

        await appState.stop()
    }
}
