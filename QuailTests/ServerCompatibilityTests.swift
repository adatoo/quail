import Foundation
import Testing
@testable import Quail
@testable import QuailServerCore

/// The point of Phase 3's HTTP shapes: the adapter that drives `llama-server`
/// today can drive `quail-server` without a change. These run the real
/// `LlamaCppRuntime` and `HealthProbe` against a real `HTTPServer`.
@Suite("quail-server is a drop-in for LlamaCppRuntime", .timeLimit(.minutes(1)))
struct ServerCompatibilityTests {
    private struct Fixture {
        let server: HTTPServer
        let base: URL
        let world: FakeEngineWorld
        let runtime = LlamaCppRuntime(executableURL: URL(fileURLWithPath: "/bin/true"))

        init(apiKey: String?) async throws {
            world = FakeEngineWorld()
            let log = ServerLog(toStandardError: false)
            let router = ModelRouter(
                entries: [.fake("Alpha"), .fake("Beta")],
                modelsMax: 1,
                makeEngine: world.factory,
                log: log
            )
            let routes = ServerRoutes(router: router, apiKey: apiKey, log: log)
            server = HTTPServer(host: "127.0.0.1", port: 0, log: log)
            let port = try await server.start { await routes.handle($0) }
            base = URL(string: "http://127.0.0.1:\(port)")!
        }
    }

    @Test("health, list and select work as they do against llama-server")
    func adapterCalls() async throws {
        let fixture = try await Fixture(apiKey: nil)
        defer { fixture.server.stop() }
        let runtime = fixture.runtime

        #expect(try await runtime.health(base: fixture.base, apiKey: nil).isUp)
        let before = try await runtime.listModels(base: fixture.base, apiKey: nil)
        #expect(before.map(\.id) == ["Alpha", "Beta"])
        #expect(before.allSatisfy { $0.status.value == "unloaded" })

        #expect(try await runtime.select(model: ModelRef(id: "Beta"), base: fixture.base, apiKey: nil) == .hotSwapped)
        let loaded = await eventually {
            let models = await (try? runtime.listModels(base: fixture.base, apiKey: nil)) ?? []
            return models.first { $0.id == "Beta" }?.status.value == "loaded"
        }
        #expect(loaded)
    }

    @Test("with a key: /health is open, the rest 401s without it and works with it")
    func apiKey() async throws {
        let fixture = try await Fixture(apiKey: "sekret")
        defer { fixture.server.stop() }
        let runtime = fixture.runtime

        #expect(try await runtime.health(base: fixture.base, apiKey: nil).isUp)
        await #expect(throws: RuntimeError.httpStatus(401)) {
            _ = try await runtime.listModels(base: fixture.base, apiKey: nil)
        }
        await #expect(throws: RuntimeError.httpStatus(401)) {
            _ = try await runtime.listModels(base: fixture.base, apiKey: "wrong")
        }
        #expect(try await runtime.listModels(base: fixture.base, apiKey: "sekret").count == 2)
    }

    @Test("selecting a model that doesn't exist is a 404 the adapter reports")
    func unknownModel() async throws {
        let fixture = try await Fixture(apiKey: nil)
        defer { fixture.server.stop() }
        await #expect(throws: RuntimeError.httpStatus(404)) {
            _ = try await fixture.runtime.select(model: ModelRef(id: "Nope"), base: fixture.base, apiKey: nil)
        }
    }

    @Test("HealthProbe, which gates the menu going green, is satisfied")
    func healthProbe() async throws {
        let fixture = try await Fixture(apiKey: nil)
        defer { fixture.server.stop() }
        try await HealthProbe.waitUntilHealthy(
            runtime: fixture.runtime,
            base: fixture.base,
            timeout: 5,
            pollInterval: 0.05
        )
    }

    @Test("the flags LlamaCppRuntime.launchSpec builds parse as the same settings")
    func launchSpecFlags() throws {
        let store = URL(fileURLWithPath: "/store/gguf")
        let config = EndpointConfig(
            host: "127.0.0.1",
            port: 9191,
            apiKey: "k",
            modelsDirectory: store,
            modelsMax: 2,
            presetsFile: URL(fileURLWithPath: "/store/presets.ini")
        )
        let spec = LlamaCppRuntime(
            executableURL: URL(fileURLWithPath: "/bin/true"),
            logFile: URL(fileURLWithPath: "/logs/x.log")
        ).launchSpec(config: config, model: nil)

        guard case let .run(parsed) = try ServerArguments.parse(spec.arguments) else {
            Issue.record("expected a run command")
            return
        }
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.port == 9191)
        #expect(parsed.apiKey == "k")
        #expect(parsed.modelsDirectory == store)
        #expect(parsed.modelsMax == 2)
        #expect(parsed.presetsFile?.path == "/store/presets.ini")
        #expect(parsed.logFile?.path == "/logs/x.log")
    }
}
