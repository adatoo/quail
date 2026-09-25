import Foundation
import Testing
@testable import QuailServerCore

@Suite("ServerArguments")
struct ServerArgumentsTests {
    private func run(_ arguments: [String]) throws -> ServerArguments {
        guard case let .run(parsed) = try ServerArguments.parse(arguments) else {
            throw ServerArgumentsError(message: "not a run command")
        }
        return parsed
    }

    @Test("parses every flag LlamaCppRuntime passes, in its own order")
    func llamaCppFlags() throws {
        let parsed = try run([
            "--host", "0.0.0.0", "--port", "9000", "--models-dir", "/store/gguf", "--models-max", "3",
            "--log-file", "/logs/quail.log", "--api-key", "s3cret", "--models-preset", "/store/presets.ini",
        ])
        #expect(parsed.host == "0.0.0.0")
        #expect(parsed.port == 9000)
        #expect(parsed.modelsDirectory?.path == "/store/gguf")
        #expect(parsed.modelsMax == 3)
        #expect(parsed.logFile?.path == "/logs/quail.log")
        #expect(parsed.apiKey == "s3cret")
        #expect(parsed.presetsFile?.path == "/store/presets.ini")
    }

    @Test("defaults are loopback, 8080, one loaded model, no key")
    func defaults() throws {
        let parsed = try run(["--models-dir", "/m"])
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.port == 8080)
        #expect(parsed.modelsMax == 1)
        #expect(parsed.apiKey == nil)
        #expect(parsed.engine == .auto)
    }

    @Test("--parallel sets how many requests a GGUF model decodes together, -np too")
    func parallelFlag() throws {
        #expect(try run(["--models-dir", "/m"]).parallel == ServerArguments.defaultParallel)
        #expect(try run(["--models-dir", "/m", "--parallel", "4"]).parallel == 4)
        #expect(try run(["--models-dir", "/m", "-np", "2"]).parallel == 2)
    }

    @Test("the chat page is served unless --no-webui says otherwise")
    func webUIFlag() throws {
        #expect(try run(["--models-dir", "/m"]).webUI)
        #expect(try !run(["--models-dir", "/m", "--no-webui"]).webUI)
    }

    @Test("--flag=value works, and an empty key means no key")
    func inlineValues() throws {
        let parsed = try run(["--models-dir=/m", "--port=1234", "--api-key="])
        #expect(parsed.port == 1234)
        #expect(parsed.apiKey == nil)
    }

    @Test("--mlx-dir alone is enough")
    func mlxOnly() throws {
        #expect(try run(["--mlx-dir", "/store/mlx"]).mlxDirectory?.path == "/store/mlx")
    }

    @Test("help and version short-circuit")
    func helpAndVersion() throws {
        #expect(try ServerArguments.parse(["--help"]) == .help)
        #expect(try ServerArguments.parse(["--models-dir", "/m", "--version"]) == .version)
    }

    @Test(
        "bad input is refused with a message that names the problem",
        arguments: [
            (["--models-dir", "/m", "--port", "http"], "--port"),
            (["--models-dir", "/m", "--port", "70000"], "--port"),
            (["--models-dir", "/m", "--models-max", "0"], "--models-max"),
            (["--models-dir", "/m", "--parallel", "0"], "--parallel"),
            (["--models-dir", "/m", "--parallel", "65"], "--parallel"),
            (["--models-dir", "/m", "--wat"], "--wat"),
            (["--models-dir"], "--models-dir needs a value"),
            (["--port", "80"], "--models-dir or --mlx-dir"),
        ]
    )
    func rejects(arguments: [String], mentions: String) {
        do {
            _ = try ServerArguments.parse(arguments)
            Issue.record("expected \(arguments) to be rejected")
        } catch {
            #expect(error.localizedDescription.contains(mentions))
        }
    }

    @Test("the test engine is selectable in Debug builds")
    func echoEngine() throws {
        #expect(try run(["--models-dir", "/m", "--engine", "echo"]).engine == .echo)
    }
}
