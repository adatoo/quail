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

    @Test("Quail server's chat link carries a one-time ticket that the page trades for the key, once")
    func chatSignIn() async throws {
        let fixture = try await Fixture(apiKey: "sekret")
        defer { fixture.server.stop() }
        let runtime = QuailServerRuntime(executableURL: URL(fileURLWithPath: "/bin/true"))

        let url = try #require(await runtime.chatURL(base: fixture.base, apiKey: "sekret"))
        #expect(url.absoluteString.hasPrefix(fixture.base.absoluteString))
        #expect(!url.absoluteString.contains("sekret"))
        let fragment = try #require(url.fragment)
        #expect(fragment.hasPrefix("ticket="))
        let ticket = String(fragment.dropFirst("ticket=".count))

        func exchange(_ ticket: String) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: fixture.base.appending(path: "auth/exchange"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["ticket": ticket])
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
        }
        let first = try await exchange(ticket)
        #expect(first.0 == 200 && first.1["key"] as? String == "sekret")
        #expect(try await exchange(ticket).0 == 401) // used

        // Without a key there is nothing to hand over, and llama.cpp's page can't take one.
        #expect(await runtime.chatURL(base: fixture.base, apiKey: nil) == fixture.base)
        #expect(await fixture.runtime.chatURL(base: fixture.base, apiKey: "sekret") == fixture.base)
        // A wrong key gets no ticket, and the plain page.
        #expect(await runtime.chatURL(base: fixture.base, apiKey: "wrong") == fixture.base)
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

    @Test(
        "the benchmark's client — tokenize, props, model states, a streamed completion with timings — works unchanged"
    )
    func benchmarkClient() async throws {
        let world = ScriptedWorld()
        let log = ServerLog(toStandardError: false)
        let router = ModelRouter(
            entries: [.fake("Alpha")],
            modelsMax: 1,
            makeEngine: { _ in
                var engine = ScriptedEngine(world: world)
                engine.endless = true
                engine.contextSize = 2048
                return engine
            },
            log: log
        )
        let routes = ServerRoutes(router: router, apiKey: "k", log: log, buildLabel: "quail-server test")
        let server = HTTPServer(host: "127.0.0.1", port: 0, log: log)
        let port = try await server.start { await routes.handle($0) }
        defer { server.stop() }
        let client = try LlamaCppBenchmarkClient(base: #require(URL(string: "http://127.0.0.1:\(port)")), apiKey: "k")

        #expect(try await client.tokenize("Hi", model: "Alpha") == [72, 105])
        let props = try await client.properties(model: "Alpha")
        #expect(props.contextSize == 2048)
        #expect(props.slots == 1)
        #expect(props.build == "quail-server test")
        #expect(try await client.modelStates()["Alpha"] == "loaded") // /props?model= loaded it

        // Exactly max_tokens are generated (ignore_eos), and the server's own timings come back.
        let timing = try await client.complete(model: "Alpha", prompt: Array(repeating: 65, count: 100), maxTokens: 20)
        #expect(timing.generatedTokens == 20)
        #expect(timing.promptTokens == 100)
        #expect(timing.promptPerSecond == 200) // 100 tokens in the scripted 0.5 s
        #expect(timing.generatedPerSecond == 80) // 20 tokens in the scripted 0.25 s
        #expect(timing.timeToFirstTokenMs > 0)
        let request = try #require(world.requests.last)
        #expect(request.ignoreEndOfSequence)
        #expect(!request.cachePrompt)
        #expect(request.sampling.temperature == 0)
        #expect(request.sampling.seed == 42)
    }

    @Test("a client that hangs up during a long prompt stops the engine and frees the model")
    func hangUpDuringPromptProcessing() async throws {
        let world = ScriptedWorld()
        let log = ServerLog(toStandardError: false)
        let router = ModelRouter(
            entries: [.fake("Alpha")],
            modelsMax: 1,
            makeEngine: { _ in
                var engine = ScriptedEngine(world: world)
                engine.firstTokenDelay = .seconds(30) // a huge prompt
                return engine
            },
            log: log
        )
        let routes = ServerRoutes(router: router, apiKey: nil, log: log)
        let server = HTTPServer(host: "127.0.0.1", port: 0, log: log)
        let port = try await server.start { await routes.handle($0) }
        defer { server.stop() }

        for path in ["/v1/completions", "/v1/chat/completions"] {
            let body = path == "/v1/completions"
                ? #"{"model":"Alpha","prompt":"x"}"#
                : #"{"model":"Alpha","messages":[{"role":"user","content":"x"}]}"#
            let before = world.cancelled
            func requestAndHangUp() async throws {
                let client = try RawHTTPClient(port: port)
                client
                    .send(
                        "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                    )
                #expect(await eventually {
                    let leased = await router.leaseCount("Alpha")
                    return !world.requests.isEmpty && leased == 1
                })
            }
            try await requestAndHangUp()
            #expect(await eventually(timeout: .seconds(5)) { world.cancelled == before + 1 }, "\(path)")
            #expect(await eventually { await router.leaseCount("Alpha") == 0 }, "\(path)")
        }
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
