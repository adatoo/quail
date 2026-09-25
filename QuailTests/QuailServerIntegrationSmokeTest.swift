import Foundation
import Testing
@testable import Quail

/// End to end with the real `quail-server` the app embeds, a real GGUF and a real MLX model, driven through
/// `ServerController` → `ProcessSupervisor` → `QuailServerRuntime` as production does (ADR D-027 step 6).
/// Runs only when the models are on disk: `TEST_RUNNER_QUAIL_TEST_GGUF` (a `.gguf` file) and
/// `TEST_RUNNER_QUAIL_TEST_MLX` (an MLX model directory), as for the engine tests.
@Suite("QuailServer integration (models from the environment)", .timeLimit(.minutes(3)))
@MainActor
struct QuailServerIntegrationSmokeTest {
    private nonisolated static let gguf = ProcessInfo.processInfo.environment["QUAIL_TEST_GGUF"]
        .map { URL(fileURLWithPath: $0) }
    private nonisolated static let mlx = ProcessInfo.processInfo.environment["QUAIL_TEST_MLX"]
        .map { URL(fileURLWithPath: $0) }
    private nonisolated static let enabled = gguf.map { FileManager.default.fileExists(atPath: $0.path) } == true
        && mlx.map { FileManager.default.fileExists(atPath: $0.path) } == true

    @Test(
        "the app's quail-server serves a GGUF and an MLX model from one store, and stops cleanly",
        .enabled(if: enabled)
    )
    func servesBothFormats() async throws {
        let gguf = try #require(Self.gguf), mlx = try #require(Self.mlx)
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("quail-it-\(UUID().uuidString)")
        let ggufDir = store.appendingPathComponent("gguf"), mlxDir = store.appendingPathComponent("mlx")
        try FileManager.default.createDirectory(at: ggufDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        defer {
            if let log = try? String(contentsOf: store.appendingPathComponent("q.log"), encoding: .utf8) {
                print("quail-server log:\n\(log.suffix(1500))")
            }
            try? FileManager.default.removeItem(at: store)
        }
        try FileManager.default.createSymbolicLink(
            at: ggufDir.appendingPathComponent(gguf.lastPathComponent), withDestinationURL: gguf
        )
        try FileManager.default.createSymbolicLink(
            at: mlxDir.appendingPathComponent(mlx.lastPathComponent), withDestinationURL: mlx
        )

        let executable = Paths.quailServerExecutable
        try #require(FileManager.default.fileExists(atPath: executable.path), "no quail-server at \(executable.path)")
        let runtime = QuailServerRuntime(executableURL: executable, logFile: store.appendingPathComponent("q.log"))
        let controller = ServerController(runtime: runtime, logStore: LogStore(), healthTimeout: 60)
        let config = EndpointConfig(
            host: "127.0.0.1", port: 18299, apiKey: "it-key", modelsDirectory: ggufDir, mlxDirectory: mlxDir
        )
        await controller.start(config: config)
        #expect(controller.phase == .ready)
        let base = try #require(controller.baseURL)

        let ids = try await runtime.listModels(base: base, apiKey: "it-key").map(\.id)
        let ggufID = gguf.deletingPathExtension().lastPathComponent, mlxID = mlx.lastPathComponent
        #expect(Set(ids) == [ggufID, mlxID])

        for id in [mlxID, ggufID] {
            #expect(try await runtime.select(model: ModelRef(id: id), base: base, apiKey: "it-key") == .hotSwapped)
            let reply = try await complete(base: base, model: id)
            #expect(!reply.isEmpty, "\(id) answered nothing")
        }
        await controller.stop()
        #expect(controller.phase == .stopped)
    }

    private func complete(base: URL, model: String) async throws -> String {
        var request = URLRequest(url: base.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer it-key", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 48, "temperature": 0,
            "messages": [["role": "user", "content": "/no_think Say hi."]],
        ])
        request.timeoutInterval = 120
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if json?["choices"] == nil {
            Issue.record(Comment(rawValue: "\(model): \(String(decoding: data, as: UTF8.self).prefix(300))"))
        }
        let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        // A reasoning model may spend a short budget thinking; either part counts as an answer.
        return ((message?["reasoning_content"] as? String) ?? "") + ((message?["content"] as? String) ?? "")
    }
}
