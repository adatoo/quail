import AppKit
import SwiftUI
import Testing
@testable import Quail

/// Renders the Quail window's pages, the Add Model sheet and the other windows to PNGs, so a layout change can be
/// looked at
/// without clicking through the app. Runs only with `TEST_RUNNER_QUAIL_SNAPSHOT_DIR` set (the
/// folder to write into); it asserts nothing about pixels.
@Suite("UI snapshots", .enabled(if: ProcessInfo.processInfo.environment["QUAIL_SNAPSHOT_DIR"] != nil))
@MainActor
struct UISnapshotTests {
    private static let outputDirectory = ProcessInfo.processInfo.environment["QUAIL_SNAPSHOT_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    private func makeAppState(
        runtime id: RuntimeID = .quail, results: [BenchmarkResult] = [], fakeRuntime: FakeRuntime? = nil
    ) async throws -> (AppState, URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-snapshots-\(UUID().uuidString)", isDirectory: true)
        let models = scratch.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: models.appendingPathComponent("gguf"),
            withIntermediateDirectories: true
        )
        for name in ["Qwen3-8B-Q4_K_M", "Qwen3.6-35B-A3B-UD-Q4_K_M"] {
            try Data(repeating: 0, count: 1024).write(to: models.appendingPathComponent("gguf/\(name).gguf"))
        }
        let mlx = models.appendingPathComponent("mlx/mlx-community--Qwen3-8B-4bit", isDirectory: true)
        try FileManager.default.createDirectory(at: mlx, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen3"}"#.utf8).write(to: mlx.appendingPathComponent("config.json"))
        let store = BenchmarkStore(fileURL: scratch.appendingPathComponent("benchmarks.json"))
        try store.save(results)
        let appState = try AppState(
            config: { var config = Config(); config.runtimeID = id; return config }(),
            configURL: scratch.appendingPathComponent("config.json"),
            secretStore: FakeSecretStore(),
            runtime: fakeRuntime ?? Self.fakeRuntime(id),
            modelsRootURL: models,
            catalogLocations: .init(bundle: .main, directory: scratch),
            shapeCache: ModelShapeCache(url: nil),
            downloader: HFDownloader(hubBaseURL: #require(URL(string: "http://127.0.0.1:9"))),
            benchmarkStore: store,
            serverPreflight: nil
        )
        appState.importHome = scratch // no other apps' models
        await appState.reconcileStore()
        return (appState, scratch)
    }

    private static func fakeRuntime(_ id: RuntimeID = .quail) -> FakeRuntime {
        FakeRuntime(launchSpec: LaunchSpec(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
            currentDirectoryURL: nil
        ), id: id, formats: id == .quail ? [.gguf, .mlxSafetensors] : [.gguf])
    }

    private func render(
        _ view: some View, size: CGSize, name: String, appearance: NSAppearance.Name = .aqua
    ) async throws {
        let directory = try #require(Self.outputDirectory)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFrontRegardless()
        // Let tasks, lists and async loads settle.
        for _ in 0 ..< 30 {
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
        }
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.close()
    }

    @Test("Add Model sheet")
    func addModelSheet() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let family = appState.catalog.families.first { $0.id == "qwen3.6-35b-a3b" }
        try await render(
            AddModelSheet(appState: appState, preselect: family),
            size: CGSize(width: 820, height: 580), name: "add-model"
        )
    }

    @Test("Add Model, MLX: Rapid-MLX's picks and catalog")
    func addModelSheetMLX() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pick = Recommender.rapidMLXPicks(catalog: appState.catalog, device: DeviceInfo.current()).first?.family
        try await render(
            AddModelSheet(appState: appState, defaultFilter: .mlx, preselect: pick),
            size: CGSize(width: 820, height: 580), name: "add-model-mlx"
        )
    }

    @Test("Models from other apps: the offer and the sheet")
    func importOffer() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let home = scratch.appendingPathComponent("home")
        for path in [
            ".lmstudio/models/lmstudio-community/Gemma-3-12B-GGUF/gemma-3-12b-it-Q4_K_M.gguf",
            ".omlx/models/Qwen3-4B-4bit/config.json",
            ".omlx/models/Qwen3-4B-4bit/model.safetensors",
        ] {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 1, count: 4096).write(to: url)
        }
        appState.importHome = home
        await appState.scanForImports()
        try await render(ModelsPane(appState: appState), size: CGSize(width: 700, height: 600), name: "import-offer")
        try await render(
            ImportModelsSheet(appState: appState),
            size: CGSize(width: 560, height: 420),
            name: "import-sheet"
        )
    }

    @Test("Activity window, busy")
    func activityWindow() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let history = Self.activityHistory(minutes: 1, serverMemory: 20_400_000_000)
        appState.activity.show(
            system: SystemSample(
                cpuPercent: 14, serverCPUPercent: 9, gpuPercent: 78, memoryUsedBytes: 33_500_000_000,
                memoryTotalBytes: 68_719_476_736, serverMemoryBytes: 20_400_000_000
            ),
            server: ServerActivity(
                models: [.init(
                    id: "mlx-community--Qwen3.6-35B-A3B-4bit",
                    state: "loaded",
                    leases: 3,
                    memoryBytes: 19_800_000_000
                )],
                requests: [
                    .init(
                        id: 1,
                        model: "mlx-community--Qwen3.6-35B-A3B-4bit",
                        phase: .readingPrompt,
                        promptTotal: 30000,
                        promptDone: 12400,
                        cached: 0,
                        generated: 0,
                        promptPerSecond: 2100,
                        predictedPerSecond: nil,
                        seconds: 6,
                        client: Self.claude
                    ),
                    .init(
                        id: 2,
                        model: "mlx-community--Qwen3.6-35B-A3B-4bit",
                        phase: .generating,
                        promptTotal: 800,
                        promptDone: 800,
                        cached: 0,
                        generated: 312,
                        promptPerSecond: 900,
                        predictedPerSecond: 52,
                        seconds: 9,
                        client: Self.claude
                    ),
                    .init(
                        id: 3,
                        model: "mlx-community--Qwen3.6-35B-A3B-4bit",
                        phase: .queued,
                        promptTotal: 200,
                        promptDone: 0,
                        cached: 0,
                        generated: 0,
                        promptPerSecond: nil,
                        predictedPerSecond: nil,
                        seconds: 2,
                        client: Self.webUI
                    ),
                ],
                clients: [
                    Self.clientTotals(Self.claude, requests: 14, busy: 400, active: 2),
                    Self.clientTotals(Self.webUI, requests: 5, busy: 118, active: 1),
                    Self.clientTotals(Self.curl, requests: 3, busy: 3, active: 0),
                ],
                uptimeSeconds: 5000
            ),
            history: history,
            clientReadings: [ClientReading(date: (history.last?.date ?? Date()).addingTimeInterval(-61), counters: [
                Self.claude.key: .init(requests: 2, promptTokens: 400, generated: 60, busySeconds: 345),
                Self.webUI.key: .init(requests: 2, promptTokens: 400, generated: 60, busySeconds: 98),
                Self.curl.key: .init(requests: 1, promptTokens: 100, generated: 10, busySeconds: 1),
            ]), ClientReading(date: history.last?.date ?? Date(), counters: [:])]
        )
        try await render(
            ActivityWindow(appState: appState),
            size: CGSize(width: 340, height: 640),
            name: "activity-window"
        )
        try await render(
            MenuBarActivityPreview(label: appState.activity.busyLabel ?? ""), size: CGSize(width: 200, height: 30),
            name: "menu-status"
        )
    }

    @Test("Activity window, server stopped: the Mac's figures and charts, over 1 and 15 minutes")
    func activityWindowStopped() async throws {
        let (appState, scratch) = try await makeAppState()
        defer {
            try? FileManager.default.removeItem(at: scratch)
            UserDefaults.standard.removeObject(forKey: "activityHistoryMinutes")
        }
        for minutes in [1, 15] {
            UserDefaults.standard.set(minutes, forKey: "activityHistoryMinutes")
            appState.activity.show(
                system: SystemSample(
                    cpuPercent: 9, gpuPercent: 3, memoryUsedBytes: 41_200_000_000, memoryTotalBytes: 68_719_476_736
                ),
                server: ServerActivity(),
                history: Self.activityHistory(minutes: minutes, serverMemory: nil),
                running: false
            )
            try await render(
                ActivityWindow(appState: appState), size: CGSize(width: 340, height: 420),
                name: "activity-stopped-\(minutes)min"
            )
        }
    }

    /// `minutes` of readings two seconds apart, ending now: waves for CPU and GPU, and memory that climbs.
    private static let claude = ServerActivity.Client(
        agent: "claude-cli", userAgent: "claude-cli/2.1.285 (external, sdk-cli)", address: "local"
    )
    private static let webUI = ServerActivity.Client(
        agent: "python-httpx", userAgent: "python-httpx/0.28.1", address: "192.168.1.20"
    )
    private static let curl = ServerActivity.Client(agent: "curl", userAgent: "curl/8.7.1", address: "local")

    private static func clientTotals(
        _ client: ServerActivity.Client, requests: Int, busy: Double, active: Int
    ) -> ServerActivity.ClientTotals {
        .init(
            agent: client.agent, userAgent: client.userAgent, address: client.address, requests: requests,
            promptTokens: requests * 6000, generatedTokens: requests * 650, busySeconds: busy, active: active
        )
    }

    private static func activityHistory(minutes: Int, serverMemory: Int64?) -> [ActivityPoint] {
        let count = minutes * 30
        let end = Date()
        return (0 ..< count).map { i in
            let wave = 40 + 35 * sin(Double(i) / 6)
            let climb = Double(i) / Double(max(1, count - 1))
            return ActivityPoint(
                date: end.addingTimeInterval(-2 * Double(count - 1 - i)),
                cpu: wave / 4, gpu: wave,
                memoryUsed: Int64(30_000_000_000 + 12_000_000_000 * climb), memoryTotal: 68_719_476_736,
                serverMemory: serverMemory.map { Int64(Double($0) * (0.6 + 0.4 * climb)) }
            )
        }
    }

    @Test("Models pane, before the store has been read")
    func modelsPaneLoading() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await render(
            ModelsPane(appState: appState, startsLoading: true), size: CGSize(width: 700, height: 600),
            name: "models-loading"
        )
    }

    @Test("Models pane, and a model's settings")
    func modelsPane() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await appState.setKVCache(.q8, forModel: "Qwen3-8B-Q4_K_M")
        // The window's detail column at its narrowest, and a narrow one to see the chips give way.
        for width in [820.0, 480.0] {
            try await render(
                ModelsPane(appState: appState), size: CGSize(width: width, height: 600), name: "models-\(Int(width))"
            )
        }
        let entry = try #require(appState.modelStore.loadCatalog().entries.first { $0.id == "Qwen3-8B-Q4_K_M" })
        try await render(
            ModelSettingsView(
                entry: entry, servable: true, isDefault: true,
                contextChoices: [
                    ContextChoice(tokens: 8192, verdict: .comfortable),
                    ContextChoice(tokens: 32768, verdict: .comfortable),
                    ContextChoice(tokens: 131_072, verdict: .wontFit, fitsWith4BitKV: true),
                ],
                kvCacheChoices: KVCacheSetting.allCases.map { KVCacheChoice(setting: $0, verdict: .comfortable) },
                onSetContext: { _ in }, onSetKVCache: { _ in }, onToggleDefault: {}, onBenchmark: {}, onDelete: {}
            ),
            size: CGSize(width: 400, height: 330), name: "model-settings"
        )
    }

    @Test("Models pane with the server running: a model loaded and busy, one loading, and none")
    func modelsPaneLoaded() async throws {
        let runtime = Self.fakeRuntime()
        let (appState, scratch) = try await makeAppState(fakeRuntime: runtime)
        defer { try? FileManager.default.removeItem(at: scratch) }
        appState.setDefaultModel("Qwen3-8B-Q4_K_M")
        func served(_ states: [(String, String)]) -> Result<[ServedModel], Error> {
            .success(states.map { ServedModel(id: $0.0, status: .init(value: $0.1, failed: nil, exitCode: nil)) })
        }
        await runtime.setListModelsResult(served([
            ("Qwen3-8B-Q4_K_M", "loaded"), ("mlx-community--Qwen3-8B-4bit", "loading"),
            ("Qwen3.6-35B-A3B-UD-Q4_K_M", "unloaded"),
        ]))
        await appState.start()
        let generating = ServerActivity.Request(
            id: 1, model: "Qwen3-8B-Q4_K_M", phase: .generating, promptTotal: 800, promptDone: 800, cached: 0,
            generated: 120, promptPerSecond: 900, predictedPerSecond: 43, seconds: 4
        )
        appState.activity.show(
            system: SystemSample(serverMemoryBytes: 9_800_000_000),
            server: ServerActivity(
                models: [
                    .init(id: "Qwen3-8B-Q4_K_M", state: "loaded", leases: 1),
                    .init(id: "mlx-community--Qwen3-8B-4bit", state: "loading", loadingSeconds: 6, leases: 0),
                ],
                requests: [generating]
            ),
            history: []
        )
        for width in [820.0, 480] {
            try await render(
                ModelsPane(appState: appState), size: CGSize(width: width, height: 640),
                name: "models-loaded-\(Int(width))"
            )
        }
        await runtime.setListModelsResult(served([
            ("Qwen3-8B-Q4_K_M", "unloaded"), ("mlx-community--Qwen3-8B-4bit", "unloaded"),
            ("Qwen3.6-35B-A3B-UD-Q4_K_M", "unloaded"),
        ]))
        await appState.refreshServedModels()
        try await render(
            ModelsPane(appState: appState),
            size: CGSize(width: 820, height: 520),
            name: "models-none-loaded"
        )
        await appState.stop()
    }

    @Test("llama.cpp chosen: MLX models are said to be unavailable")
    func llamaCppWarnings() async throws {
        let (appState, scratch) = try await makeAppState(runtime: .llamaCpp)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await renderWindow(appState, page: .server, name: "llama-server")
        try await render(ModelsPane(appState: appState), size: CGSize(width: 700, height: 600), name: "llama-models")
        let family = appState.catalog.families.first { $0.id == "qwen3.6-35b-a3b" }
        try await render(
            AddModelSheet(appState: appState, defaultFilter: .mlx, preselect: family),
            size: CGSize(width: 820, height: 580), name: "llama-add-model"
        )
    }

    @Test("Server page: stopped; on the network with the API key, and without; a custom address")
    func serverPage() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        appState.setKeepAwake(true)
        try await renderWindow(appState, page: .server, name: "server-stopped")
        appState.setHost("0.0.0.0")
        appState.setAPIKeyEnabled(true)
        try await renderWindow(appState, page: .server, name: "server-lan-key")
        appState.setAPIKeyEnabled(false)
        try await renderWindow(appState, page: .server, name: "server-lan-open")
        appState.setAPIKeyEnabled(true)
        appState.setHost("192.168.1.20")
        try await renderWindow(appState, page: .server, name: "server-custom-host")
    }

    @Test("Server page: running, then with a change that needs a restart")
    func serverPageRunning() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        appState.setDefaultModel("Qwen3-8B-Q4_K_M")
        await appState.start()
        try await renderWindow(appState, page: .server, name: "server-running")
        appState.setModelsMax(2)
        try await renderWindow(appState, page: .server, name: "server-restart-needed")
        await appState.stop()
    }

    @Test("Benchmark pane, with an old result and one with the returning-turn and four-at-once columns")
    func benchmarkPane() async throws {
        var old = BenchmarkTests.sampleResult(model: "Qwen3-8B-Q4_K_M", chip: "Apple M4 Pro", speed: 46)
        old.date = Date(timeIntervalSince1970: 1_780_000_000)
        var new = BenchmarkTests.sampleResult(model: "mlx-community--Qwen3-8B-4bit", chip: "Apple M4 Pro", speed: 54)
        new.model.format = "mlx"
        new.engine.runtime = "Quail server"
        new.measurements.returningTurnMs = .of([180, 201, 230])
        new.measurements.concurrent4 = .of([55, 56])
        let (appState, scratch) = try await makeAppState(results: [new, old])
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await renderWindow(appState, page: .benchmark, name: "benchmark")
        // The narrowest the window goes: the table scrolls sideways rather than being clipped.
        try await renderWindow(appState, page: .benchmark, name: "benchmark-min", width: 1010)
    }

    @Test("General, About, Connect and Models pages in the window")
    func otherPages() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await renderWindow(appState, page: .general, name: "general")
        try await renderWindow(appState, page: .about, name: "about")
        // With a website: "Learn more" beside the short captions, and About's Website and Documentation links.
        let site = URL(string: "https://adatoo.github.io/quail/")
        try await renderWindow(appState, page: .about, name: "about-website", website: site)
        appState.setKeepAwake(true)
        try await renderWindow(appState, page: .server, name: "server-website", website: site)
        try await renderWindow(appState, page: .connect, name: "connect")
        try await renderWindow(appState, page: .models, name: "main-window")
        // The sidebar on its own too: inside the split view, offscreen rendering leaves it blank.
        appState.mainPage = .server
        try await render(MainSidebar(appState: appState), size: CGSize(width: 200, height: 320), name: "sidebar")
    }

    /// The website's picture of the Quail window (`task site:screenshots`), light and dark: the server running
    /// with a model loaded. The sidebar and the page are drawn side by side, since offscreen rendering leaves the
    /// real split view's sidebar blank.
    @Test("Website: the Quail window, light and dark")
    func websiteScreenshots() async throws {
        let runtime = Self.fakeRuntime()
        let (appState, scratch) = try await makeAppState(fakeRuntime: runtime)
        defer { try? FileManager.default.removeItem(at: scratch) }
        appState.setDefaultModel("Qwen3-8B-Q4_K_M")
        await runtime.setListModelsResult(.success([
            ServedModel(id: "Qwen3-8B-Q4_K_M", status: .init(value: "loaded", failed: nil, exitCode: nil)),
        ]))
        await appState.start()
        appState.mainPage = .server
        let window = HStack(spacing: 0) {
            MainSidebar(appState: appState)
                .frame(width: 200)
            Divider()
            ServerPane(appState: appState)
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await render(
                window, size: CGSize(width: 1100, height: 700), name: "quail-window-\(name)", appearance: appearance
            )
        }
        await appState.stop()
    }

    /// The whole Quail window, sidebar included, on `page`.
    private func renderWindow(
        _ appState: AppState, page: MainPage, name: String, width: Double = 1100, height: Double = 760,
        website: URL? = nil
    ) async throws {
        appState.mainPage = page
        try await render(
            MainWindow(appState: appState).environment(\.websiteBase, website),
            size: CGSize(width: width, height: height), name: name
        )
    }
}
