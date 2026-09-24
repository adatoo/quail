import Foundation
import Testing
@testable import Quail
@testable import QuailServerCore

@Suite("ServerRoutes", .timeLimit(.minutes(1)))
struct ServerRoutesTests {
    private struct Harness {
        let routes: ServerRoutes
        let router: ModelRouter
        let world: FakeEngineWorld

        init(
            apiKey: String? = nil,
            ids: [String] = ["Alpha", "Beta"],
            max: Int = 1,
            guardian: RequestGuard = RequestGuard(bindHost: "127.0.0.1")
        ) {
            world = FakeEngineWorld()
            let log = ServerLog(toStandardError: false)
            router = ModelRouter(
                entries: ids.map { .fake($0) },
                modelsMax: max,
                makeEngine: world.factory,
                log: log
            )
            routes = ServerRoutes(router: router, apiKey: apiKey, log: log, requestGuard: guardian)
        }

        func call(
            _ method: String,
            _ path: String,
            headers: [String: String] = [:],
            body: String = ""
        ) async -> (status: Int, json: [String: Any]) {
            let response = await routes.handle(HTTPRequest(
                method: method, target: path, headers: headers, body: Data(body.utf8)
            ))
            guard case let .data(data) = response.body else { return (response.status, [:]) }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (response.status, json ?? [:])
        }
    }

    @Test("a cross-origin POST is refused before it reaches a route: nothing loads")
    func crossOriginDoesNothing() async {
        let harness = Harness()
        let refused = await harness.call(
            "POST", "/models/load",
            headers: ["host": "127.0.0.1:8080", "origin": "https://evil.example", "content-type": "text/plain"],
            body: #"{"model":"Alpha"}"#
        )
        #expect(refused.status == 403)
        // A queued load flips the state to `loading` at once, so this would already show it.
        #expect(await harness.router.snapshot("Alpha")?.state == .unloaded)

        let allowed = await harness.call(
            "POST", "/models/load",
            headers: ["host": "127.0.0.1:8080"],
            body: #"{"model":"Alpha"}"#
        )
        #expect(allowed.status == 200)
    }

    @Test("an allowed origin's response carries its Allow-Origin header")
    func allowedOriginHeader() async {
        let harness = Harness(guardian: RequestGuard(bindHost: "127.0.0.1", allowedOrigins: ["http://localhost:3000"]))
        let response = await harness.routes.handle(HTTPRequest(
            method: "GET", target: "/v1/models",
            headers: ["host": "127.0.0.1:8080", "origin": "http://localhost:3000"], body: Data()
        ))
        #expect(response.status == 200)
        #expect(response.headers.first { $0.name == "Access-Control-Allow-Origin" }?.value == "http://localhost:3000")
    }

    @Test("/health answers ok, with or without a key configured")
    func health() async {
        let open = await Harness().call("GET", "/health")
        #expect(open.status == 200)
        #expect(open.json["status"] as? String == "ok")

        let keyed = await Harness(apiKey: "k").call("GET", "/health")
        #expect(keyed.status == 200)
    }

    @Test("with a key set, everything but /health needs it — as Bearer or x-api-key")
    func auth() async {
        let harness = Harness(apiKey: "sekret")

        let none = await harness.call("GET", "/models")
        #expect(none.status == 401)
        let error = none.json["error"] as? [String: Any]
        #expect(error?["type"] as? String == "authentication_error")
        #expect(error?["message"] as? String == "Invalid API Key")

        #expect(await harness.call("GET", "/models", headers: ["authorization": "Bearer nope"]).status == 401)
        #expect(await harness.call("GET", "/models", headers: ["authorization": "sekret"]).status == 401)
        #expect(await harness.call("GET", "/models", headers: ["x-api-key": "nope"]).status == 401)
        #expect(await harness.call("GET", "/models", headers: ["authorization": "Bearer sekret"]).status == 200)
        #expect(await harness.call("GET", "/models", headers: ["authorization": "bearer sekret"]).status == 200)
        #expect(await harness.call("GET", "/models", headers: ["x-api-key": "sekret"]).status == 200)
        #expect(await harness.call("POST", "/models/load", body: "{}").status == 401)
    }

    @Test("no key configured means no auth")
    func noKey() async {
        #expect(await Harness().call("GET", "/models").status == 200)
    }

    @Test("/models and /v1/models list the same thing, in the shape ServedModel decodes")
    func modelList() async throws {
        let harness = Harness()
        for path in ["/models", "/v1/models"] {
            let response = await harness.routes.handle(HTTPRequest(
                method: "GET",
                target: path,
                headers: [:],
                body: Data()
            ))
            guard case let .data(data) = response.body else {
                Issue.record("expected a data body")
                return
            }
            struct List: Decodable {
                let data: [ServedModel]
                let object: String
            }
            let list = try JSONDecoder().decode(List.self, from: data)
            #expect(list.object == "list")
            #expect(list.data.map(\.id) == ["Alpha", "Beta"])
            #expect(list.data.allSatisfy { $0.status.value == "unloaded" && $0.status.failed == nil })
        }
    }

    @Test("POST /models/load answers success at once; the status catches up")
    func load() async {
        let harness = Harness()
        await harness.world.hold("Alpha")

        let loaded = await harness.call("POST", "/models/load", body: #"{"model":"Alpha"}"#)
        #expect(loaded.status == 200)
        #expect(loaded.json["success"] as? Bool == true)
        #expect(await harness.router.snapshot("Alpha")?.state == .loading)

        let listing = await harness.call("GET", "/models")
        let first = (listing.json["data"] as? [[String: Any]])?.first
        #expect((first?["status"] as? [String: Any])?["value"] as? String == "loading")

        await harness.world.release("Alpha")
        #expect(await eventually { await harness.router.snapshot("Alpha")?.state == .loaded })
    }

    @Test("POST /models/unload unloads")
    func unload() async {
        let harness = Harness()
        _ = await harness.call("POST", "/models/load", body: #"{"model":"Alpha"}"#)
        #expect(await eventually { await harness.router.snapshot("Alpha")?.state == .loaded })

        let response = await harness.call("POST", "/models/unload", body: #"{"model":"Alpha"}"#)
        #expect(response.status == 200)
        #expect(await harness.router.snapshot("Alpha")?.state == .unloaded)
    }

    @Test("a failed load is listed as unloaded with failed and exit_code, as llama-server does")
    func failedShape() async throws {
        let harness = Harness()
        await harness.world.failLoads(of: "Alpha", reason: "out of memory")
        _ = await harness.call("POST", "/models/load", body: #"{"model":"Alpha"}"#)
        #expect(await eventually { await harness.router.snapshot("Alpha")?.state == .failed("out of memory") })

        let response = await harness.routes.handle(HTTPRequest(
            method: "GET",
            target: "/models",
            headers: [:],
            body: Data()
        ))
        guard case let .data(data) = response.body else {
            Issue.record("expected a data body")
            return
        }
        struct List: Decodable { let data: [ServedModel] }
        let alpha = try #require(try JSONDecoder().decode(List.self, from: data).data.first)
        #expect(alpha.status.value == "unloaded")
        #expect(alpha.status.failed == true)
        #expect(alpha.status.exitCode == 1)
    }

    @Test("errors: unknown model 404, no model 400, wrong method 405, unknown path 404")
    func errors() async {
        let harness = Harness()
        let unknown = await harness.call("POST", "/models/load", body: #"{"model":"Nope"}"#)
        #expect(unknown.status == 404)
        #expect((unknown.json["error"] as? [String: Any])?["type"] as? String == "not_found_error")

        #expect(await harness.call("POST", "/models/load", body: "{}").status == 400)
        #expect(await harness.call("POST", "/models/load", body: "not json").status == 400)
        #expect(await harness.call("POST", "/models/unload", body: "").status == 400)
        #expect(await harness.call("GET", "/models/load").status == 405)
        #expect(await harness.call("POST", "/models").status == 405)
        #expect(await harness.call("POST", "/health").status == 405)
        #expect(await harness.call("GET", "/nothing-here").status == 404)
    }

    @Test("a query string doesn't change the route")
    func query() async {
        #expect(await Harness().call("GET", "/models?x=1").status == 200)
    }
}
