import Foundation
import Testing
@testable import Quail
@testable import QuailServerCore

@Suite("QuailServerRuntime")
struct QuailServerRuntimeTests {
    private static let executable = URL(fileURLWithPath: "/tmp/fake/quail-server")

    private func config(apiKey: String? = nil, mlx: URL? = nil) -> EndpointConfig {
        EndpointConfig(
            host: "127.0.0.1", port: 8099, apiKey: apiKey, modelsDirectory: URL(fileURLWithPath: "/store/gguf"),
            modelsMax: 2, presetsFile: URL(fileURLWithPath: "/store/presets.ini"), mlxDirectory: mlx
        )
    }

    @Test("serves GGUF and MLX, and is bundled")
    func facts() throws {
        let runtime = QuailServerRuntime(executableURL: Self.executable)
        #expect(runtime.id == .quail)
        #expect(runtime.supportedFormats == [.gguf, .mlxSafetensors])
        #expect(try runtime.webUIURL(base: #require(URL(string: "http://127.0.0.1:8099")))?
            .absoluteString == "http://127.0.0.1:8099")
    }

    @Test("launch flags are llama-server's plus --mlx-dir, and the key only when there is one")
    func launchFlags() {
        let runtime = QuailServerRuntime(executableURL: Self.executable, logFile: URL(fileURLWithPath: "/logs/q.log"))
        let spec = runtime.launchSpec(config: config(apiKey: "k", mlx: URL(fileURLWithPath: "/store/mlx")), model: nil)
        #expect(spec.executableURL == Self.executable)
        #expect(spec.environment.isEmpty)
        #expect(spec.arguments == [
            "--host", "127.0.0.1", "--port", "8099", "--models-dir", "/store/gguf", "--models-max", "2",
            "--log-file", "/logs/q.log", "--mlx-dir", "/store/mlx", "--api-key", "k",
            "--models-preset", "/store/presets.ini",
        ])
        let plain = runtime.launchSpec(config: config(), model: nil).arguments
        #expect(!plain.contains("--mlx-dir") && !plain.contains("--api-key"))
    }

    @Test("every flag it passes is one quail-server accepts")
    func flagsParse() throws {
        let runtime = QuailServerRuntime(executableURL: Self.executable, logFile: URL(fileURLWithPath: "/logs/q.log"))
        let spec = runtime.launchSpec(config: config(apiKey: "k", mlx: URL(fileURLWithPath: "/store/mlx")), model: nil)
        guard case let .run(parsed) = try ServerArguments.parse(spec.arguments) else {
            Issue.record("expected a run command")
            return
        }
        #expect(parsed.mlxDirectory?.path == "/store/mlx")
        #expect(parsed.modelsDirectory?.path == "/store/gguf")
        #expect(parsed.apiKey == "k")
    }
}
