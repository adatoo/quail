import Foundation
import Testing
@testable import Quail

@Suite("quail bench --url")
struct URLBenchmarkTests {
    /// A server that counts 1.3 tokens a word plus 12 for the chat template, reads 2,000 prompt tokens a second and
    /// writes 50 a second.
    private struct FakeServer: URLBenchmarkClient {
        var contextSize = 32768
        var stopsAt: Int?
        var sendsUsage = true

        func models() async throws -> [String] {
            ["fake-model"]
        }

        func chat(model _: String, prompt: String, maxTokens: Int) async throws -> StreamedReply {
            let words = prompt.split(separator: " ").count - 2 // the tag is two words
            let promptTokens = Int((Double(words) * 1.3).rounded()) + 12
            guard promptTokens + maxTokens <= contextSize else {
                throw URLBenchmarkError.http(400, "the request exceeds the available context size")
            }
            let generated = min(maxTokens, stopsAt ?? maxTokens)
            let first = Double(promptTokens) / 2000
            return StreamedReply(
                promptTokens: sendsUsage ? promptTokens : nil, completionTokens: sendsUsage ? generated : nil,
                chunks: generated, firstTokenSeconds: first, lastTokenSeconds: first + Double(generated - 1) / 50
            )
        }
    }

    @Test("prompts are sized from the server's own counts, and speeds come from its timing")
    func measuresAFakeServer() async throws {
        let result = try await URLBenchmarkRunner(client: FakeServer())
            .run(model: "fake-model", url: "http://127.0.0.1:1")
        let measured = result.measurements
        #expect(abs((result.promptTokens["512"] ?? 0) - 512) <= 2)
        #expect(abs((result.promptTokens["4096"] ?? 0) - 4096) <= 2)
        #expect(abs((measured.prompt512?.median ?? 0) - 2000) < 1)
        #expect(abs((measured.generation256?.median ?? 0) - 50) < 0.01)
        #expect(abs((measured.timeToFirstTokenMs?.median ?? 0) - 256) < 2)
        #expect(measured.returningTurnMs != nil)
        #expect(measured.concurrent4 != nil)
        #expect(measured.loadSeconds == nil)
        #expect(result.notes.isEmpty)
        #expect(result.suite == "quail-bench-url-1")
    }

    @Test("a prompt longer than the context is skipped with the server's reason; a short reply is noted")
    func refusalsAndEarlyStops() async throws {
        let result = try await URLBenchmarkRunner(client: FakeServer(contextSize: 3000, stopsAt: 100))
            .run(model: "fake-model", url: "http://127.0.0.1:1")
        #expect(result.measurements.prompt4096 == nil)
        #expect(result.measurements.skipped.contains {
            $0.hasPrefix("prompt 4096: the server refused it (HTTP 400: the request exceeds")
        })
        #expect(result.measurements.prompt512 != nil)
        #expect(result.notes.contains { $0.hasPrefix("the server stopped early (100, 100, 100 of 256 tokens)") })
    }

    @Test("without token counts the prompts can't be sized, so it says so rather than guessing")
    func needsUsage() async {
        await #expect(throws: URLBenchmarkError.noUsage) {
            try await URLBenchmarkRunner(client: FakeServer(sendsUsage: false))
                .run(model: "fake-model", url: "http://127.0.0.1:1")
        }
    }

    @Test("generation speed is the tokens after the first over the time from the first to the last")
    func generationSpeed() {
        let reply = StreamedReply(
            promptTokens: 10, completionTokens: 101, chunks: 101, firstTokenSeconds: 0.5, lastTokenSeconds: 2.5
        )
        #expect(URLBenchmarkRunner.generationSpeed(reply) == 50)
        #expect(URLBenchmarkRunner.generationSpeed(StreamedReply(chunks: 1, firstTokenSeconds: 1, lastTokenSeconds: 1))
            == nil)
    }

    @Test("stream lines: tokens of any kind, usage, the end")
    func parsesLines() {
        typealias Client = OpenAIBenchmarkClient
        #expect(Client.parse(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#) == .chunk(hasToken: true, usage: nil))
        #expect(Client.parse(#"data: {"choices":[{"delta":{"reasoning_content":"hm"}}]}"#)
            == .chunk(hasToken: true, usage: nil))
        #expect(Client.parse(#"data: {"choices":[{"delta":{"role":"assistant","content":""}}]}"#)
            == .chunk(hasToken: false, usage: nil))
        #expect(Client.parse(#"data: {"choices":[],"usage":{"prompt_tokens":520,"completion_tokens":1}}"#)
            == .chunk(hasToken: false, usage: .init(prompt: 520, completion: 1)))
        #expect(Client.parse("data: [DONE]") == .done)
        #expect(Client.parse(": keep-alive") == nil)
    }

    @Test("a server address with or without /v1 or a slash; anything else isn't one")
    func baseURL() {
        for text in ["http://127.0.0.1:11434", "http://127.0.0.1:11434/", "http://127.0.0.1:11434/v1/"] {
            #expect(OpenAIBenchmarkClient.base(from: text)?.absoluteString == "http://127.0.0.1:11434")
        }
        #expect(OpenAIBenchmarkClient.base(from: "127.0.0.1:8080") == nil)
        #expect(OpenAIBenchmarkClient.base(from: "ftp://host") == nil)
    }

    @Test("the passage both suites read is unchanged, so quail-bench-1 results stay comparable")
    func passageUnchanged() {
        #expect(BenchmarkSuite.passage == BenchmarkPassage.text)
        #expect(BenchmarkPassage.text.count == 699)
        #expect(BenchmarkPassage.text.hasPrefix("The lighthouse keeper kept a log"))
        #expect(BenchmarkPassage.text.hasSuffix("climbed the stairs to light the lamp."))
    }
}
