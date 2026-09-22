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
            modelsRootURL: scratchDir.appendingPathComponent("Models", isDirectory: true),
            catalogLocations: .init(bundle: .main, directory: scratchDir)
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

    @Test("addUserCatalogRepo persists an uncurated entry; remove deletes it")
    func userCatalogRepoRoundTripThroughAppState() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        #expect(appState.catalog.families.isEmpty)

        appState.addUserCatalogRepo("someone/New-GGUF", format: .gguf)
        appState.addUserCatalogRepo("  ") // trims to empty, no-op
        appState.addUserCatalogRepo("someone/New-GGUF", format: .gguf) // dedup

        let entry = try #require(appState.catalog.families.first)
        #expect(entry.id == "someone/New-GGUF")
        #expect(!entry.isCurated)
        #expect(entry.gguf?.repo == "someone/New-GGUF")

        // Survives a fresh AppState pointed at the same directory.
        let reloaded = makeAppState(scratchDir: scratch)
        #expect(reloaded.catalog.families.count == 1)

        reloaded.removeUserCatalogRepo("someone/New-GGUF")
        #expect(reloaded.catalog.families.isEmpty)
        #expect(Catalog.loadUserEntries(from: scratch.appendingPathComponent("user-catalog.json")).isEmpty)
        reloaded.removeUserCatalogRepo("never-existed") // no-op, file intact
        #expect(Catalog.loadUserEntries(from: scratch.appendingPathComponent("user-catalog.json")).isEmpty)
    }

    @Test("selectModel: refused stopped/uninstalled/MLX; hot-swaps an installed GGUF while running")
    func selectModelGuards() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        // Server not running.
        await #expect(throws: AppState.ModelSelectionError.serverNotRunning) {
            try await appState.selectModel(id: "Anything")
        }

        await appState.start()
        try appState.modelStore.ensureDirectoriesExist()
        try appState.modelStore.saveCatalog(StoreCatalog(entries: [
            InstalledModel(id: "Big-Q8_0", format: .gguf, bytes: 1, addedAt: .init()),
            InstalledModel(id: "Mlx-4bit", format: .mlxSafetensors, bytes: 1, addedAt: .init()),
        ]))

        await #expect(throws: AppState.ModelSelectionError.notInstalled) {
            try await appState.selectModel(id: "NotThere")
        }
        await #expect(throws: AppState.ModelSelectionError.needsMLXRuntime) {
            try await appState.selectModel(id: "Mlx-4bit")
        }

        // FakeRuntime's select defaults to .success(.hotSwapped).
        try await appState.selectModel(id: "Big-Q8_0")

        await appState.stop()
    }

    @Test("setModelsMax persists; rejects 0 and unchanged values")
    func setModelsMaxPersists() {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        appState.setModelsMax(0)
        #expect(appState.config.modelsMax == 1) // default untouched
        appState.setModelsMax(4)
        #expect(appState.config.modelsMax == 4)
        let reloaded = Config.load(from: scratch.appendingPathComponent("config.json"))
        #expect(reloaded.modelsMax == 4)
    }

    @Test("loadedModelStates: empty while stopped, the router's statuses while running")
    func loadedModelStates() async {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        #expect(await appState.loadedModelStates() == [:])

        await appState.start()
        // FakeRuntime's default listModels is the empty success.
        #expect(await appState.loadedModelStates() == [:])

        let runtime = appState.runtime as? FakeRuntime
        let status = ServedModel.Status(value: "loaded", failed: nil, exitCode: nil)
        await runtime?.setListModelsResult(.success([
            ServedModel(id: "Qwen3-0.6B-Q8_0", status: status),
        ]))
        let states = await appState.loadedModelStates()
        #expect(states["Qwen3-0.6B-Q8_0"] == "loaded")

        await appState.stop()
    }

    @Test("relocateModelsDirectory moves the store, bookmarks it, and repoints users")
    func relocate() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        let destination = scratch.appendingPathComponent("Elsewhere", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        // Put something in the store first, plus a stray .partial that
        // must NOT move (a resume starts clean at the new root).
        try appState.modelStore.ensureDirectoriesExist()
        try Data("hi".utf8).write(
            to: appState.modelStore.ggufDirectory.appendingPathComponent("X.gguf")
        )
        try Data("stale".utf8).write(
            to: appState.modelStore.partialDirectory.appendingPathComponent("junk.partial")
        )
        let source = appState.modelStore.rootURL

        try await appState.relocateModelsDirectory(to: destination)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("gguf/X.gguf").path))
        #expect(fm.fileExists(atPath: source.appendingPathComponent(".partial/junk.partial").path))
        #expect(!fm.fileExists(atPath: destination.appendingPathComponent(".partial/junk.partial").path))
        #expect(appState.modelStore.rootURL == destination)
        #expect(appState.installs.modelStore.rootURL == destination)

        // The bookmark is real enough to resolve back to the same path,
        // and it persisted to config.json like every other field.
        let reloaded = Config.load(from: scratch.appendingPathComponent("config.json"))
        let bookmark = try #require(reloaded.modelsDirectoryBookmark)
        let resolved = try #require(Paths.resolveModelsDirectory(bookmark: bookmark))
        #expect(resolved.standardizedFileURL == destination.standardizedFileURL)
    }

    @Test("delete removes the file, its companions, its row and its preset section")
    func deleteModel() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        let store = appState.modelStore
        try store.ensureDirectoriesExist()
        let fm = FileManager.default
        try Data("a".utf8).write(to: store.ggufDirectory.appendingPathComponent("Gone.gguf"))
        try Data("b".utf8).write(to: store.ggufDirectory.appendingPathComponent("mmproj-Gone-F16.gguf"))
        try Data("c".utf8).write(to: store.ggufDirectory.appendingPathComponent("Gone-Mate.gguf"))
        try store.saveCatalog(StoreCatalog(entries: [
            InstalledModel(id: "Gone", format: .gguf, bytes: 1, addedAt: .init()),
            InstalledModel(id: "Gone-Mate", format: .gguf, bytes: 1, addedAt: .init()),
        ]))
        try store.regeneratePresets(catalog: store.loadCatalog())

        await #expect(throws: AppState.ModelDeletionError.notInstalled) {
            try await appState.deleteInstalledModel(id: "Never")
        }

        try await appState.deleteInstalledModel(id: "Gone")

        #expect(!fm.fileExists(atPath: store.ggufDirectory.appendingPathComponent("Gone.gguf").path))
        #expect(!fm.fileExists(atPath: store.ggufDirectory.appendingPathComponent("mmproj-Gone-F16.gguf").path))
        #expect(fm.fileExists(atPath: store.ggufDirectory.appendingPathComponent("Gone-Mate.gguf").path))
        let catalog = store.loadCatalog()
        #expect(catalog.entries.map(\.id) == ["Gone-Mate"])
        let ini = try String(contentsOf: store.presetsFile, encoding: .utf8)
        #expect(!ini.contains("[Gone]"))
        #expect(ini.contains("[Gone-Mate]"))
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
