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

    /// A minimal stand-in for an installed GGUF — `hasServableModel` and
    /// `installedGGUFFiles()` only look at the filename, never parse the
    /// bytes, so content is irrelevant here (`GGUFMetadataTests` is where
    /// real header bytes matter).
    @discardableResult
    private func writeFixtureGGUF(named name: String = "Fixture-Q8_0", to store: ModelStore) throws -> URL {
        try store.ensureDirectoriesExist()
        let url = store.ggufDirectory.appendingPathComponent("\(name).gguf")
        try Data("fixture".utf8).write(to: url)
        return url
    }

    /// A config with the API key off, which is what most of these tests are about; the on-by-default
    /// behaviour has its own tests below.
    private static var keyOffConfig: Config {
        var config = Config()
        config.apiKeyEnabled = false
        return config
    }

    private func makeAppState(
        config: Config = keyOffConfig,
        scratchDir: URL,
        secretStore: FakeSecretStore = FakeSecretStore(),
        // A `Resources/catalog.json`-shaped document, written to
        // `scratchDir` and used as the bundled seed — `CatalogTests`'
        // own trick (a bare directory works as a `Bundle` for resource
        // lookup). `nil` keeps the real `.main` bundle, which resolves
        // to an empty catalog outside `Quail.app` (see
        // `userCatalogRepoRoundTripThroughAppState`'s own expectation).
        catalogSeed: String? = nil,
        downloader: HFDownloader = HFDownloader(),
        runtime: FakeRuntime? = nil
    )
        -> AppState
    {
        let launchSpec = LaunchSpec(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            environment: [:],
            currentDirectoryURL: nil
        )
        let bundle: Bundle
        if let catalogSeed {
            try? catalogSeed.write(
                to: scratchDir.appendingPathComponent("catalog.json"), atomically: true, encoding: .utf8
            )
            bundle = Bundle(url: scratchDir)!
        } else {
            bundle = .main
        }
        return AppState(
            config: config,
            configURL: scratchDir.appendingPathComponent("config.json"),
            secretStore: secretStore,
            runtime: runtime ?? FakeRuntime(launchSpec: launchSpec),
            logStore: LogStore(),
            modelsRootURL: scratchDir.appendingPathComponent("Models", isDirectory: true),
            catalogLocations: .init(bundle: bundle, directory: scratchDir),
            downloader: downloader,
            // The live preflight inspects this machine's real processes
            // and ports (8080 is often taken on a dev machine).
            serverPreflight: nil
        )
    }

    @Test("starts stopped, and start() reaches ready against a fake runtime")
    func startReachesReady() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        try writeFixtureGGUF(named: "Alpha", to: appState.modelStore)
        appState.setDefaultModel("Alpha")

        #expect(appState.statusLabel == "Stopped")
        #expect(appState.canStart)
        #expect(!appState.canStop)

        await appState.start()
        #expect(appState.statusLabel == "Running")
        #expect(appState.canStop)

        await appState.stop()
        #expect(appState.statusLabel == "Stopped")
    }

    /// The live bug: the Models tab's poll, written as `while ready {
    /// try? await Task.sleep … }`, kept spinning after SwiftUI cancelled
    /// its `.task` — the cancelled sleep returns instantly — and hammered
    /// `/models` until the Mac ran out of ephemeral ports.
    @Test("pollLoadedStates stops calling the server once its task is cancelled")
    func pollStopsOnCancel() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let runtime = FakeRuntime(launchSpec: LaunchSpec(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            environment: [:],
            currentDirectoryURL: nil
        ))
        let appState = makeAppState(scratchDir: scratch, runtime: runtime)
        try writeFixtureGGUF(named: "Alpha", to: appState.modelStore)
        await appState.start()
        #expect(appState.serverController.phase == .ready)

        let poll = Task { await appState.pollLoadedStates(every: .milliseconds(10)) { _ in } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await runtime.listModelsCallCount > 2, "the poll should be running")

        poll.cancel()
        await poll.value
        let afterCancel = await runtime.listModelsCallCount
        try await Task.sleep(for: .milliseconds(300))
        // AppState's own 2 s menu poll may add one call; a runaway loop
        // adds thousands.
        #expect(await runtime.listModelsCallCount - afterCancel <= 1)

        await appState.stop()
    }

    private static func served(_ id: String, _ value: String, failed: Bool? = nil, exit: Int? = nil) -> ServedModel {
        ServedModel(id: id, status: .init(value: value, failed: failed, exitCode: exit))
    }

    @Test("readyStatus: green when serving (default or not), yellow while loading, red when the default failed")
    func readyStatusRules() {
        let none = AppState.readyStatus(models: [Self.served("A", "unloaded")], defaultModelID: nil)
        #expect(none == .init(label: "Running", detail: "No model loaded — loads on first request", color: .green))

        let loaded = AppState.readyStatus(
            models: [Self.served("A", "loaded"), Self.served("B", "unloaded")],
            defaultModelID: nil
        )
        #expect(loaded == .init(label: "Running", detail: "Loaded: A", color: .green))

        let loading = AppState.readyStatus(models: [Self.served("A", "loading")], defaultModelID: "A")
        #expect(loading == .init(label: "Loading model…", detail: "Loading A…", color: .yellow))

        let failed = AppState.readyStatus(
            models: [Self.served("A", "unloaded", failed: true, exit: 1), Self.served("B", "loaded")],
            defaultModelID: "A"
        )
        #expect(failed.color == .red)
        #expect(failed.detail == "A failed to load (exit 1) — see Logs")

        // A non-default model failing (some client asked for it) doesn't
        // turn the whole server red.
        let otherFailed = AppState.readyStatus(
            models: [Self.served("A", "loaded"), Self.served("B", "unloaded", failed: true)],
            defaultModelID: "A"
        )
        #expect(otherFailed.color == .green)
    }

    @Test("start with no default model is plain green Running, with what's loaded read from the server")
    func noDefaultModelIsGreen() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        try writeFixtureGGUF(to: appState.modelStore)
        #expect(appState.modelStatusLine == "No default model — loads on first request")

        await appState.start()
        #expect(appState.statusLabel == "Running")
        #expect(appState.statusColor == .green)
        #expect(appState.modelStatusLine == "No model loaded — loads on first request")

        let runtime = try #require(appState.runtime as? FakeRuntime)
        await runtime.setListModelsResult(.success([Self.served("Fixture-Q8_0", "loaded")]))
        await appState.refreshServedModels()
        #expect(appState.modelStatusLine == "Loaded: Fixture-Q8_0")

        await appState.stop()
        #expect(appState.servedModels.isEmpty)
    }

    @Test("canStart requires at least one installed GGUF; an mmproj companion alone doesn't count")
    func canStartRequiresAModel() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        #expect(!appState.hasServableModel)
        #expect(!appState.canStart)

        try Data("companion only".utf8).write(
            to: appState.modelStore.ggufDirectory.appendingPathComponent("mmproj-Something-F16.gguf")
        )
        #expect(!appState.hasServableModel)
        #expect(!appState.canStart)

        try writeFixtureGGUF(to: appState.modelStore)
        #expect(appState.hasServableModel)
        #expect(appState.canStart)
    }

    @discardableResult
    private func writeFixtureMLX(named name: String = "owner--Fixture-4bit", to store: ModelStore) throws -> URL {
        try store.ensureDirectoriesExist()
        let url = store.mlxDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appendingPathComponent("config.json"))
        return url
    }

    private static let sleeper = LaunchSpec(
        executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:], currentDirectoryURL: nil
    )

    @Test("an MLX model alone can start a runtime that serves MLX, not llama.cpp")
    func mlxOnlyStore() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let llama = makeAppState(scratchDir: scratch)
        try writeFixtureMLX(to: llama.modelStore)
        #expect(!llama.canServe(.mlxSafetensors))
        #expect(!llama.hasServableModel && !llama.canStart)

        let quail = makeAppState(
            scratchDir: scratch,
            runtime: FakeRuntime(launchSpec: Self.sleeper, id: .quail, formats: [.gguf, .mlxSafetensors])
        )
        #expect(quail.canServe(.mlxSafetensors))
        #expect(quail.hasServableModel && quail.canStart)
    }

    @Test("the Benchmark pane lists MLX models only under a runtime that serves them, and labels the format")
    func benchmarkableModels() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let llama = makeAppState(scratchDir: scratch)
        try writeFixtureGGUF(named: "Alpha", to: llama.modelStore)
        try writeFixtureMLX(named: "owner--Beta-4bit", to: llama.modelStore)
        try llama.modelStore.saveCatalog(llama.modelStore.refreshedCatalog(
            device: DeviceInfo.current(), ggufRuntime: .llamaCpp, bandwidthTable: [:]
        ))
        #expect(llama.benchmarkableModels == ["Alpha"])

        let quail = makeAppState(
            scratchDir: scratch,
            runtime: FakeRuntime(launchSpec: Self.sleeper, id: .quail, formats: [.gguf, .mlxSafetensors])
        )
        #expect(quail.benchmarkableModels == ["Alpha", "owner--Beta-4bit"])
        #expect(quail.formatLabel(ofModel: "Alpha") == "GGUF" && quail
            .formatLabel(ofModel: "owner--Beta-4bit") == "MLX")
    }

    @Test("the runtime changes only while stopped, is remembered, and decides whether presets list MLX models")
    func runtimeSwitch() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        try writeFixtureGGUF(named: "Alpha", to: appState.modelStore)
        try writeFixtureMLX(named: "owner--Beta-4bit", to: appState.modelStore)

        #expect(appState.setRuntime(.quail))
        #expect(appState.runtime.id == .quail && appState.config.runtimeID == .quail)
        #expect(Config.load(from: scratch.appendingPathComponent("config.json")).runtimeID == .quail)
        let presets = try String(contentsOf: appState.modelStore.presetsFile, encoding: .utf8)
        #expect(presets.contains("[owner--Beta-4bit]") && presets.contains("[Alpha]"))

        #expect(appState.setRuntime(.llamaCpp))
        #expect(try !String(contentsOf: appState.modelStore.presetsFile, encoding: .utf8).contains("owner--Beta-4bit"))
        #expect(!appState.setRuntime(.omlx)) // not startable yet

        // While running, a change is refused and nothing moves.
        let running = makeAppState(scratchDir: scratch)
        await running.start()
        #expect(running.serverController.phase == .ready)
        #expect(!running.canChangeRuntime)
        #expect(!running.setRuntime(.quail))
        #expect(running.runtime.id == .llamaCpp)
        await running.stop()
        #expect(running.setRuntime(.quail))
    }

    @Test("a config naming a runtime that can't start yet falls back to llama.cpp")
    func unavailableRuntimeFallsBack() {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var config = Self.keyOffConfig
        config.runtimeID = .rapidMLX
        let appState = AppState(
            config: config,
            configURL: scratch.appendingPathComponent("config.json"),
            secretStore: FakeSecretStore(),
            logStore: LogStore(),
            modelsRootURL: scratch.appendingPathComponent("Models", isDirectory: true),
            catalogLocations: .init(bundle: .main, directory: scratch),
            serverPreflight: nil
        )
        #expect(appState.runtime.id == .llamaCpp && appState.config.runtimeID == .llamaCpp)
    }

    @Test("start() no-ops (stays stopped) when the store has no model")
    func startNoOpsWithNoModel() async {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        await appState.start()

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

    @Test("regenerateAPIKey produces a 16-character base64url string (12 bytes), no padding")
    func regenerateAPIKeyLength() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)

        appState.setAPIKeyEnabled(true)
        let key = try #require(appState.apiKey)

        // 12 random bytes, base64url-encoded — see AppState.generateAPIKey's
        // doc comment for why this moved from 32 hex characters.
        #expect(key.count == 16)
        #expect(!key.contains("+"))
        #expect(!key.contains("/"))
        #expect(!key.contains("="))
        let base64urlAlphabet =
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(key.unicodeScalars.allSatisfy(base64urlAlphabet.contains))
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

    @Test("a fresh install has an API key: on by default, generated and stored at launch (ADR D-039)")
    func freshInstallHasKey() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let secretStore = FakeSecretStore()
        let appState = makeAppState(config: Config(), scratchDir: scratch, secretStore: secretStore)

        #expect(appState.config.apiKeyEnabled)
        let key = try #require(appState.apiKey)
        #expect(try secretStore.get(account: "llamaCppAPIKey") == key)
        // Nothing to migrate, so the file isn't rewritten just for this.
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("config.json").path))
    }

    @Test("a config from before the default, saying off, is switched on once and the change is saved")
    func legacyConfigIsSwitchedOn() throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let legacy = Data(
            #"{"runtimeID":"llamaCpp","host":"127.0.0.1","port":8080,"modelsMax":1,"apiKeyEnabled":false}"#
                .utf8
        )
        let configURL = scratch.appendingPathComponent("config.json")
        try legacy.write(to: configURL)
        let secretStore = FakeSecretStore()

        let appState = makeAppState(config: Config.load(from: configURL), scratchDir: scratch, secretStore: secretStore)
        #expect(appState.config.apiKeyEnabled)
        #expect(appState.apiKey != nil)
        // Saved, so it's a one-time change: the file now says it was applied.
        let saved = Config.load(from: configURL)
        #expect(saved.apiKeyEnabled)
        #expect(saved.apiKeyDefaultApplied)

        // The user turns it off; a relaunch respects that.
        appState.setAPIKeyEnabled(false)
        let relaunched = makeAppState(
            config: Config.load(from: configURL),
            scratchDir: scratch,
            secretStore: secretStore
        )
        #expect(!relaunched.config.apiKeyEnabled)
        #expect(relaunched.apiKey == nil)
    }

    @Test("a config with the key on but no stored key gets a new one instead of running open")
    func missingKeyIsRegenerated() throws {
        var config = Config()
        config.apiKeyEnabled = true // e.g. the Keychain entry was deleted
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let secretStore = FakeSecretStore()
        let appState = makeAppState(config: config, scratchDir: scratch, secretStore: secretStore)

        let key = try #require(appState.apiKey)
        #expect(try secretStore.get(account: "llamaCppAPIKey") == key)
    }

    @Test("the runtime is launched with --api-key by default")
    func runtimeGetsKey() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let launchSpec = LaunchSpec(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            environment: [:],
            currentDirectoryURL: nil
        )
        let runtime = FakeRuntime(launchSpec: launchSpec)
        let appState = makeAppState(config: Config(), scratchDir: scratch, runtime: runtime)
        try writeFixtureGGUF(to: appState.modelStore)
        await appState.start()
        #expect(appState.serverController.apiKey == appState.apiKey)
        #expect(appState.serverController.apiKey != nil)
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
        // An explicit empty seed, not a reliance on `.main` resolving to
        // an empty catalog: `QuailTests` runs hosted inside `Quail.app`
        // (TEST_HOST/BUNDLE_LOADER in the generated project), so
        // `Bundle.main` genuinely carries the real bundled catalog.json
        // once it's actually bundled (project.yml's Copy Bundle Resources
        // omission, fixed alongside this test). This test is about
        // user-added repos, not the curated catalog, so it starts from a
        // known-empty one instead of depending on what happens to ship.
        let emptySeed = #"{"revision":1,"ramTiersGB":{},"chipBandwidthGBps":{},"families":[]}"#
        let appState = makeAppState(scratchDir: scratch, catalogSeed: emptySeed)

        #expect(appState.catalog.families.isEmpty)

        appState.addUserCatalogRepo("someone/New-GGUF", format: .gguf)
        appState.addUserCatalogRepo("  ") // trims to empty, no-op
        appState.addUserCatalogRepo("someone/New-GGUF", format: .gguf) // dedup

        let entry = try #require(appState.catalog.families.first)
        #expect(entry.id == "someone/New-GGUF")
        #expect(!entry.isCurated)
        #expect(entry.gguf?.repo == "someone/New-GGUF")

        // Survives a fresh AppState pointed at the same directory.
        let reloaded = makeAppState(scratchDir: scratch, catalogSeed: emptySeed)
        #expect(reloaded.catalog.families.count == 1)

        reloaded.removeUserCatalogRepo("someone/New-GGUF")
        #expect(reloaded.catalog.families.isEmpty)
        #expect(Catalog.loadUserEntries(from: scratch.appendingPathComponent("user-catalog.json")).isEmpty)
        reloaded.removeUserCatalogRepo("never-existed") // no-op, file intact
        #expect(Catalog.loadUserEntries(from: scratch.appendingPathComponent("user-catalog.json")).isEmpty)
    }

    @Test("loadCatalogVerdicts: every family gets a verdict or a stated reason; reopening retries only failures")
    func loadCatalogVerdictsFetchesPerFamily() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        // A single tier covering every real machine's memory, so this
        // doesn't depend on how much RAM the test happens to run on —
        // only the tiny fixture model's own shape decides Comfortable.
        let seed = """
        {
          "revision": 1,
          "ramTiersGB": { "any": { "max": 999999, "recommendParamsB": [0, 999] } },
          "chipBandwidthGBps": {},
          "families": [
            { "id": "tiny", "name": "Tiny", "paramsB": 0.5, "role": "general", "rank": 1,
              "variants": { "gguf": { "repo": "org/Tiny-GGUF", "quants": ["Q8_0"], "default": "Q8_0" } } },
            { "id": "embed", "name": "Embed", "paramsB": 0.5, "role": "embedding", "rank": 1,
              "variants": { "gguf": { "repo": "org/Embed-GGUF", "quants": ["Q8_0"], "default": "Q8_0" } } }
          ]
        }
        """

        var fixture = GGUFFixtureBuilder()
        fixture.addString("general.architecture", "llama")
        fixture.addUInt32("llama.block_count", 2)
        fixture.addUInt32("llama.attention.head_count", 2)
        fixture.addUInt32("llama.attention.head_count_kv", 2)
        fixture.addUInt32("llama.embedding_length", 64)
        let headerBytes = fixture.data()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let listingRequestCount = LockedCount()
        StubURLProtocol.handler = { request in
            if request.url?.path.contains("/api/models/org/Embed-GGUF") == true {
                listingRequestCount.increment()
                return StubResponse(statusCode: 404, body: Data())
            }
            if request.url?.path.contains("/api/models/") == true {
                listingRequestCount.increment()
                let body = Data("""
                {"siblings":[{"rfilename":"Tiny-Q8_0.gguf","size":50000000}]}
                """.utf8)
                return StubResponse(statusCode: 200, body: body)
            }
            return StubResponse(statusCode: 200, body: headerBytes)
        }
        let downloader = try HFDownloader(
            urlSession: URLSession(configuration: config), hubBaseURL: #require(URL(string: "http://hub.test"))
        )
        let appState = makeAppState(scratchDir: scratch, catalogSeed: seed, downloader: downloader)
        #expect(appState.catalog.families.count == 2)

        await appState.loadCatalogVerdicts()

        // Every family is looked up — not only in-tier recommendation
        // candidates, which once left most Add-model rows blank.
        #expect(listingRequestCount.value == 2)
        let verdict = try #require(appState.catalogVerdicts["org/Tiny-GGUF"])
        #expect(verdict.verdict == .comfortable)
        #expect(appState.catalogFits["embed"] == .unknown("Repo not found on Hugging Face"))

        // Reopening doesn't refetch what's known, but does retry a failure.
        await appState.loadCatalogVerdicts()
        #expect(listingRequestCount.value == 3)
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

        try writeFixtureGGUF(named: "Big-Q8_0", to: appState.modelStore)
        await appState.start()
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

    @Test("setDefaultModel persists and is reflected in presets.ini on the next Start")
    func setDefaultModelPersistsAndAppliesAtStart() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        try writeFixtureGGUF(named: "Alpha", to: appState.modelStore)

        #expect(appState.config.defaultModelID == nil)
        appState.setDefaultModel("Alpha")
        #expect(appState.config.defaultModelID == "Alpha")

        let reloaded = Config.load(from: scratch.appendingPathComponent("config.json"))
        #expect(reloaded.defaultModelID == "Alpha")

        await appState.start()
        let ini = try String(contentsOf: appState.modelStore.presetsFile, encoding: .utf8)
        #expect(ini.contains("[Alpha]"))
        #expect(ini.contains("load-on-startup = true"))
        await appState.stop()

        appState.setDefaultModel(nil)
        #expect(appState.config.defaultModelID == nil)
    }

    @Test("deleting the default model clears defaultModelID too")
    func deletingDefaultModelClearsIt() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        try writeFixtureGGUF(named: "Alpha", to: appState.modelStore)
        try appState.modelStore.saveCatalog(StoreCatalog(entries: [
            InstalledModel(id: "Alpha", format: .gguf, bytes: 1, addedAt: .init()),
        ]))
        appState.setDefaultModel("Alpha")

        try await appState.deleteInstalledModel(id: "Alpha")

        #expect(appState.config.defaultModelID == nil)
        let reloaded = Config.load(from: scratch.appendingPathComponent("config.json"))
        #expect(reloaded.defaultModelID == nil)
    }

    @Test("loadedModelStates: empty while stopped, the router's statuses while running")
    func loadedModelStates() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        try writeFixtureGGUF(to: appState.modelStore)

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
        try Data("b".utf8).write(to: store.ggufDirectory.appendingPathComponent("mmproj-Gone.gguf"))
        try Data("c".utf8).write(to: store.ggufDirectory.appendingPathComponent("Gone-Mate.gguf"))
        // Another model's projector whose name starts with "mmproj-Gone" —
        // a prefix match used to delete it along with Gone's.
        try Data("d".utf8).write(to: store.ggufDirectory.appendingPathComponent("mmproj-Gone-Mate.gguf"))
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
        #expect(!fm.fileExists(atPath: store.ggufDirectory.appendingPathComponent("mmproj-Gone.gguf").path))
        #expect(fm.fileExists(atPath: store.ggufDirectory.appendingPathComponent("mmproj-Gone-Mate.gguf").path))
        #expect(fm.fileExists(atPath: store.ggufDirectory.appendingPathComponent("Gone-Mate.gguf").path))
        let catalog = store.loadCatalog()
        #expect(catalog.entries.map(\.id) == ["Gone-Mate"])
        let ini = try String(contentsOf: store.presetsFile, encoding: .utf8)
        #expect(!ini.contains("[Gone]"))
        #expect(ini.contains("[Gone-Mate]"))
    }

    @Test("delete leaves the server running unless that model is loaded; bumps storeRevision")
    func deleteStopsServerOnlyForLoadedModel() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        try writeFixtureGGUF(named: "Idle", to: appState.modelStore)
        try writeFixtureGGUF(named: "Busy", to: appState.modelStore)
        await appState.start()
        try appState.modelStore.saveCatalog(appState.modelStore.refreshedCatalog(
            device: DeviceInfo(), ggufRuntime: .llamaCpp, bandwidthTable: [:]
        ))
        let runtime = try #require(appState.runtime as? FakeRuntime)
        await runtime.setListModelsResult(.success([Self.served("Idle", "unloaded"), Self.served("Busy", "loaded")]))
        let revision = appState.storeRevision

        try await appState.deleteInstalledModel(id: "Idle")
        #expect(appState.serverController.phase == .ready)
        #expect(appState.storeRevision == revision + 1)

        try await appState.deleteInstalledModel(id: "Busy")
        #expect(appState.serverController.phase == .stopped)
    }

    @Test("reconcileStore: a default model deleted outside Quail is cleared and logged; catalog.json follows the disk")
    func reconcileClearsStaleDefault() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        let kept = try writeFixtureGGUF(named: "Kept", to: appState.modelStore)
        let gone = try writeFixtureGGUF(named: "Gone", to: appState.modelStore)
        appState.setDefaultModel("Gone")
        await appState.reconcileStore()
        #expect(appState.modelStore.loadCatalog().entries.map(\.id) == ["Gone", "Kept"])

        try FileManager.default.removeItem(at: gone) // "deleted in Finder"
        let revision = appState.storeRevision
        await appState.reconcileStore()

        #expect(appState.config.defaultModelID == nil)
        #expect(appState.modelStore.loadCatalog().entries.map(\.id) == ["Kept"])
        #expect(appState.storeRevision == revision + 1)
        let logged = await appState.logStore.recentLines.map(\.text)
        #expect(logged.contains { $0.contains("default model Gone is no longer in the store") })
        _ = kept
    }

    @Test("modelsChangedSinceStart: set when the store changes under a running server, cleared by restart")
    func modelsChangedSinceStart() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        try writeFixtureGGUF(named: "First", to: appState.modelStore)
        await appState.start()
        #expect(appState.serverController.phase == .ready)

        await appState.reconcileStore() // nothing changed
        #expect(!appState.modelsChangedSinceStart)

        try writeFixtureGGUF(named: "Added", to: appState.modelStore) // e.g. copied in via Finder
        await appState.reconcileStore()
        #expect(appState.modelsChangedSinceStart)

        await appState.restart()
        #expect(!appState.modelsChangedSinceStart)
        await appState.stop()
    }

    @Test("setContextSize persists the choice, rewrites presets, and asks for a restart while running")
    func setContextSize() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        try writeFixtureGGUF(named: "Model", to: appState.modelStore)
        await appState.start()
        #expect(!appState.modelsChangedSinceStart)

        await appState.setContextSize(32768, forModel: "Model")

        #expect(appState.modelStore.loadCatalog().entries.first?.userContextSize == 32768)
        let ini = try String(contentsOf: appState.modelStore.presetsFile, encoding: .utf8)
        #expect(ini.contains("ctx-size = 32768"))
        #expect(appState.modelsChangedSinceStart)

        await appState.setContextSize(nil, forModel: "Model") // back to Automatic
        #expect(appState.modelStore.loadCatalog().entries.first?.userContextSize == nil)
        await appState.stop()
    }

    @Test("start() creates the model store's directories and a presets.ini")
    func startCreatesModelStore() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let appState = makeAppState(scratchDir: scratch)
        try writeFixtureGGUF(to: appState.modelStore)

        await appState.start()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: appState.modelStore.ggufDirectory.path))
        #expect(fm.fileExists(atPath: appState.modelStore.mlxDirectory.path))
        #expect(fm.fileExists(atPath: appState.modelStore.hfCacheDirectory.path))
        #expect(fm.fileExists(atPath: appState.modelStore.presetsFile.path))

        await appState.stop()
    }
}

/// A thread-safe counter for `StubURLProtocol.handler` closures that need
/// to track how many times a concurrent (`TaskGroup`-driven) call hit a
/// particular endpoint — see `HFDownloaderTests`' own `CapturedValue` for
/// the same rationale (the handler can run off the main thread).
final class LockedCount: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
