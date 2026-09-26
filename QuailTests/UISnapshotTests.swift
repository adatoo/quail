import AppKit
import SwiftUI
import Testing
@testable import Quail

/// Renders the Add Model sheet and the Models pane to PNGs, so a layout change can be looked at
/// without clicking through the app. Runs only with `TEST_RUNNER_QUAIL_SNAPSHOT_DIR` set (the
/// folder to write into); it asserts nothing about pixels.
@Suite("UI snapshots", .enabled(if: ProcessInfo.processInfo.environment["QUAIL_SNAPSHOT_DIR"] != nil))
@MainActor
struct UISnapshotTests {
    private static let outputDirectory = ProcessInfo.processInfo.environment["QUAIL_SNAPSHOT_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    private func makeAppState() async throws -> (AppState, URL) {
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
        let appState = try AppState(
            config: Config(),
            configURL: scratch.appendingPathComponent("config.json"),
            secretStore: FakeSecretStore(),
            runtime: FakeRuntime(launchSpec: LaunchSpec(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                currentDirectoryURL: nil
            )),
            modelsRootURL: models,
            catalogLocations: .init(bundle: .main, directory: scratch),
            shapeCache: ModelShapeCache(url: nil),
            downloader: HFDownloader(hubBaseURL: #require(URL(string: "http://127.0.0.1:9"))),
            serverPreflight: nil
        )
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

    @Test("Models pane")
    func modelsPane() async throws {
        let (appState, scratch) = try await makeAppState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        // The Settings window's width, and a narrow one to see the chips give way.
        for width in [700.0, 480.0] {
            try await render(
                ModelsPane(appState: appState), size: CGSize(width: width, height: 600), name: "models-\(Int(width))"
            )
        }
    }
}
