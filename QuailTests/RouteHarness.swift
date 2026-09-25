import Foundation
@testable import Quail
@testable import QuailServerCore

/// A `ServerRoutes` over a scripted engine, for the tests of routes that take JSON and answer JSON
/// or a stream of events.
struct RouteHarness {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestFixtures/ChatTemplates/templates")

    static func template(_ name: String) -> String {
        (try? String(contentsOf: fixtures.appendingPathComponent("\(name).jinja"), encoding: .utf8)) ?? ""
    }

    static let hermesCall = [
        "<tool_call>\n",
        #"{"name": "get_weather", "arguments": {"city": "Paris"}}"#,
        "\n</tool_call>",
    ]

    let routes: ServerRoutes
    let world = ScriptedWorld()

    init(
        pieces: [String] = ["Hello", "!"],
        template: String? = RouteHarness.template("qwen3"),
        apiKey: String? = nil,
        endless: Bool = false,
        webUI: Bool = true,
        grammar: Bool = false
    ) {
        let world = world
        let log = ServerLog(toStandardError: false)
        let router = ModelRouter(
            entries: [.fake("Alpha")],
            modelsMax: 1,
            makeEngine: { _ in
                var engine = ScriptedEngine(world: world)
                engine.pieces = pieces
                engine.template = template
                engine.bos = ""
                engine.eos = "<|im_end|>"
                engine.endless = endless
                engine.capabilities = .init(grammar: grammar)
                return engine
            },
            log: log
        )
        routes = ServerRoutes(router: router, apiKey: apiKey, log: log, buildLabel: "quail-server test", webUI: webUI)
    }

    func send(_ path: String, _ body: String, headers: [String: String] = [:]) async -> HTTPResponse {
        await routes.handle(HTTPRequest(method: "POST", target: path, headers: headers, body: Data(body.utf8)))
    }

    func get(_ path: String, headers: [String: String] = [:]) async -> HTTPResponse {
        await routes.handle(HTTPRequest(method: "GET", target: path, headers: headers, body: Data()))
    }

    func json(
        _ path: String,
        _ body: String,
        headers: [String: String] = [:]
    ) async -> (status: Int, json: [String: Any]) {
        let response = await send(path, body, headers: headers)
        guard case let .data(data) = response.body else { return (response.status, [:]) }
        return (response.status, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }

    struct Event {
        let name: String
        let data: [String: Any]

        subscript(key: String) -> Any? {
            data[key]
        }
    }

    /// A stream's named events; `raw` is everything that was sent, to check what isn't an event.
    func events(_ path: String, _ body: String) async -> (status: Int, events: [Event], raw: String) {
        let response = await send(path, body)
        guard case let .stream(chunks) = response.body else { return (response.status, [], "") }
        var raw = ""
        for await chunk in chunks {
            raw += String(decoding: chunk, as: UTF8.self)
        }
        let events = Self.parseEvents(raw)
        return (response.status, events, raw)
    }

    static func parseEvents(_ raw: String) -> [Event] {
        raw.components(separatedBy: "\n\n").compactMap { block -> Event? in
            var name = "", data = ""
            for line in block.split(separator: "\n") {
                if line.hasPrefix("event: ") {
                    name = String(line.dropFirst(7))
                } else if line.hasPrefix("data: ") {
                    data = String(line.dropFirst(6))
                }
            }
            guard !name.isEmpty,
                  let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any]
            else { return nil }
            return Event(name: name, data: object)
        }
    }

    /// The prompt text the engine was handed (its "tokens" are UTF-8 bytes).
    var prompt: String {
        String(
            decoding: (world.requests.last?.promptTokens ?? []).map { UInt8(truncatingIfNeeded: $0) },
            as: UTF8.self
        )
    }
}
