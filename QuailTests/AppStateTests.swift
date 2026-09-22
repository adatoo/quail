import Foundation
import Testing
@testable import Quail

/// Exercises `AppState` against `FakeRuntime` and `FakeSecretStore` — no
/// real process, network call, or Keychain access (see that file's doc
/// comment for why Keychain itself isn't touched here).
@Suite("AppState", .timeLimit(.minutes(1)))
@MainActor
struct AppStateTests {
    private func scratchConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-appstate-tests-\(UUID().uuidString).json")
    }

    private func makeAppState(
        config: Config = Config(),
        configURL: URL,
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
            configURL: configURL,
            secretStore: secretStore,
            runtime: FakeRuntime(launchSpec: launchSpec),
            logStore: LogStore()
        )
    }

    @Test("starts stopped, and start() reaches ready against a fake runtime")
    func startReachesReady() async {
        let url = scratchConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let appState = makeAppState(configURL: url)

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
        let url = scratchConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let appState = makeAppState(configURL: url)

        appState.setHost("0.0.0.0")
        appState.setPort(9090)

        #expect(appState.config.host == "0.0.0.0")
        #expect(appState.config.port == 9090)

        let reloaded = Config.load(from: url)
        #expect(reloaded.host == "0.0.0.0")
        #expect(reloaded.port == 9090)
    }

    @Test("enabling the API key stores a generated key; disabling deletes it")
    func apiKeyToggleStoresAndDeletes() throws {
        let url = scratchConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let secretStore = FakeSecretStore()
        let appState = makeAppState(configURL: url, secretStore: secretStore)

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
        let url = scratchConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let appState = makeAppState(configURL: url)

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
        let url = scratchConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let appState = makeAppState(config: config, configURL: url)

        // Doesn't crash or hang — start() must tolerate a nil key here.
        await appState.start()
        #expect(appState.statusLabel == "Running")
        await appState.stop()
    }
}
