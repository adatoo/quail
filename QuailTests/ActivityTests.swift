import Foundation
import Testing
@testable import QuailServerCore

@Suite("Activity (GET /slots)")
struct ActivityTests {
    @Test("a request goes waiting → queued → reading → generating, with its rates, and leaves when it ends")
    func registryPhases() throws {
        let registry = ActivityRegistry()
        let start = Date(timeIntervalSince1970: 1000)
        let ticket = registry.begin(model: "m", now: start)
        #expect(registry.snapshot().first?.phase == .waitingForModel)
        ticket.accepted(promptTokens: 1000)
        #expect(registry.snapshot().first?.phase == .queued)
        ticket.promptProgress(done: 200, total: 1000, cached: 200, now: start.addingTimeInterval(1))
        ticket.promptProgress(done: 600, total: 1000, cached: 200, now: start.addingTimeInterval(2))
        var request = try #require(registry.snapshot().first)
        #expect(request.phase == .readingPrompt)
        #expect(request.promptDone == 600)
        // 400 new tokens in the second since reading started.
        #expect(request.promptPerSecond(now: start.addingTimeInterval(2)) == 400)
        ticket.token(now: start.addingTimeInterval(3))
        for i in 1 ... 10 {
            ticket.token(now: start.addingTimeInterval(3 + Double(i) * 0.1))
        }
        request = try #require(registry.snapshot().first)
        #expect(request.phase == .generating)
        #expect(request.promptDone == 1000)
        #expect(request.generated == 11)
        #expect(request.predictedPerSecond(now: start.addingTimeInterval(4)) == 10)
        ticket.end()
        ticket.end()
        #expect(registry.snapshot().isEmpty)
    }

    private static func slots(_ harness: RouteHarness, headers: [String: String] = [:]) async
        -> (status: Int, json: [String: Any])
    {
        let response = await harness.get("/slots", headers: headers)
        guard case let .data(data) = response.body else { return (response.status, [:]) }
        return (response.status, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }

    @Test("GET /slots shows a streaming request and its model, and forgets it when the client leaves")
    func slotsDuringAStream() async throws {
        let harness = RouteHarness(endless: true, promptProgress: true)
        let body = #"{"model":"Alpha","stream":true,"messages":[{"role":"user","content":"hi"}]}"#
        let response = await harness.send("/v1/chat/completions", body)
        guard case let .stream(chunks) = response.body else {
            Issue.record("not a stream")
            return
        }
        let reader = Task {
            for await _ in chunks {}
        }
        var generating: [String: Any]?
        for _ in 0 ..< 200 {
            let requests = await Self.slots(harness).json["requests"] as? [[String: Any]] ?? []
            if let request = requests.first, request["phase"] as? String == "generating",
               (request["generated"] as? Int ?? 0) > 3
            {
                generating = request
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = try #require(generating)
        #expect(request["model"] as? String == "Alpha")
        #expect((request["prompt_total"] as? Int ?? 0) > 0)
        #expect(request["prompt_done"] as? Int == request["prompt_total"] as? Int)
        let models = await Self.slots(harness).json["models"] as? [[String: Any]] ?? []
        #expect(models.first?["id"] as? String == "Alpha")
        #expect(models.first?["state"] as? String == "loaded")
        #expect(models.first?["leases"] as? Int == 1)

        reader.cancel()
        var cleared = false
        for _ in 0 ..< 200 {
            if await (Self.slots(harness).json["requests"] as? [Any])?.isEmpty == true {
                cleared = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cleared)
    }

    @Test("GET /slots shows a prompt being read before the first token")
    func slotsWhileReading() async throws {
        let harness = RouteHarness(promptProgress: true, firstTokenDelay: .milliseconds(800))
        let body = #"{"model":"Alpha","messages":[{"role":"user","content":"hello there"}]}"#
        let call = Task { () -> (Int, String?) in
            let reply = await harness.json("/v1/chat/completions", body)
            let message = (reply.json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            return (reply.status, message?["content"] as? String)
        }
        var reading: [String: Any]?
        for _ in 0 ..< 300 {
            let requests = await Self.slots(harness).json["requests"] as? [[String: Any]] ?? []
            if let request = requests.first, request["phase"] as? String == "reading_prompt" {
                reading = request
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let request = try #require(reading)
        let total = try #require(request["prompt_total"] as? Int)
        #expect(request["prompt_done"] as? Int == total / 2)
        let (status, content) = await call.value
        #expect(status == 200)
        // The progress never reaches the client: the reply is just the text.
        #expect(content == "Hello!")
        #expect(await (Self.slots(harness).json["requests"] as? [Any])?.isEmpty == true)
    }

    @Test("GET /slots needs the API key, and never loads a model")
    func slotsAuthAndNoLoad() async {
        let harness = RouteHarness(apiKey: "k")
        #expect(await Self.slots(harness).status == 401)
        let open = await Self.slots(harness, headers: ["authorization": "Bearer k"])
        #expect(open.status == 200)
        #expect((open.json["models"] as? [Any])?.isEmpty == true)
        #expect((open.json["requests"] as? [Any])?.isEmpty == true)
    }
}
