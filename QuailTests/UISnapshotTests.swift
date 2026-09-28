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
        runtime id: RuntimeID = .quail, results: [BenchmarkResult] = []
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
            runtime: FakeRuntime(launchSpec: LaunchSpec(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                currentDirectoryURL: nil
            ), id: id, formats: id == .quail ? [.gguf, .mlxSafetensors] : [.gguf]),
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

    private func render(_ view: some View, size: CGSize, name: String) async throws {
        let directory = try #require(Self.outputDirectory)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
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
        let history = (0 ..< 60).map { i -> Double? in 40 + 35 * sin(Double(i) / 6) }
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
                        seconds: 6
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
                        seconds: 9
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
                        seconds: 2
                    ),
                ]
            ),
            cpuHistory: history.map { $0.map { $0 / 4 } }, gpuHistory: history
        )
        try await render(
            ActivityWindow(appState: appState),
            size: CGSize(width: 340, height: 360),
            name: "activity-window"
        )
        try await render(
            MenuBarActivityPreview(label: appState.activity.busyLabel ?? ""), size: CGSize(width: 200, height: 30),
            name: "menu-status"
        )
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

    @Test("Models pane")
    func modelsPane() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        await appState.setKVCache(.q8, forModel: "Qwen3-8B-Q4_K_M")
        // The Settings window's width, and a narrow one to see the chips give way.
        for width in [700.0, 480.0] {
            try await render(
                ModelsPane(appState: appState), size: CGSize(width: width, height: 600), name: "models-\(Int(width))"
            )
        }
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

    @Test("Server page: on this Mac; on the network with the API key, and without")
    func serverPage() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        appState.setKeepAwake(true)
        try await renderWindow(appState, page: .server, name: "server")
        appState.setHost("0.0.0.0")
        appState.setAPIKeyEnabled(true)
        try await renderWindow(appState, page: .server, name: "server-lan-key")
        appState.setAPIKeyEnabled(false)
        try await renderWindow(appState, page: .server, name: "server-lan-open")
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
        try await renderWindow(appState, page: .connect, name: "connect")
        try await renderWindow(appState, page: .models, name: "main-window")
        // The sidebar on its own too: inside the split view, offscreen rendering leaves it blank.
        appState.mainPage = .server
        try await render(MainSidebar(appState: appState), size: CGSize(width: 200, height: 320), name: "sidebar")
    }

    /// The whole Quail window, sidebar included, on `page`.
    private func renderWindow(
        _ appState: AppState, page: MainPage, name: String, width: Double = 1100, height: Double = 760
    ) async throws {
        appState.mainPage = page
        try await render(MainWindow(appState: appState), size: CGSize(width: width, height: height), name: name)
    }
}
