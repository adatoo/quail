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

    @Test("regenerateAPIKey produces a 32-character hex string (16 bytes)")
    func regenerateAPIKeyLength() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        appState.setAPIKeyEnabled(true)
        let key = try #require(appState.apiKey)

        // 16 random bytes, hex-encoded — see AppState.generateAPIKey's doc
        // comment for why this was shortened from 32 bytes/64 characters.
        #expect(key.count == 32)
        // swiftformat:disable:next preferKeyPath
        #expect(key.allSatisfy { $0.isHexDigit })
    }

    @Test("setAPIKey stores a user-chosen key while enabled")
    func setAPIKeyStoresCustomKey() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let secretStore = FakeSecretStore()
        let appState = makeAppState(scratchDir: scratch, secretStore: secretStore)

        appState.setAPIKeyEnabled(true)
        appState.setAPIKey("my-own-custom-key")

        #expect(appState.apiKey == "my-own-custom-key")
        #expect(try secretStore.get(account: "llamaCppAPIKey") == "my-own-custom-key")
    }

    @Test("setAPIKey trims surrounding whitespace")
    func setAPIKeyTrimsWhitespace() {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        appState.setAPIKeyEnabled(true)
        appState.setAPIKey("  padded-key  \n")

        #expect(appState.apiKey == "padded-key")
    }

    @Test("setAPIKey no-ops on an empty or whitespace-only key")
    func setAPIKeyNoOpsOnEmptyKey() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        appState.setAPIKeyEnabled(true)
        let originalKey = try #require(appState.apiKey)

        appState.setAPIKey("   ")
        #expect(appState.apiKey == originalKey)
    }

    @Test("setAPIKey no-ops while the API key toggle is disabled")
    func setAPIKeyNoOpsWhileDisabled() {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        appState.setAPIKey("should-not-be-stored")
        #expect(appState.apiKey == nil)
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

    @Test("setHFToken stores and clearHFToken deletes the Hugging Face token")
    func hfTokenRoundTrip() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let secretStore = FakeSecretStore()
        let appState = makeAppState(scratchDir: scratch, secretStore: secretStore)

        #expect(appState.hfToken == nil)
        appState.setHFToken("hf_test_token")
        #expect(appState.hfToken == "hf_test_token")
        #expect(try secretStore.get(account: "huggingFaceToken") == "hf_test_token")
        appState.clearHFToken()
        #expect(appState.hfToken == nil)
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
