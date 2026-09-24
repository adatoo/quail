import Foundation
import Testing
@testable import QuailServerCore

@Suite("EchoEngine")
struct EchoEngineTests {
    private func loaded(template: String? = nil) async throws -> EchoEngine {
        let engine = EchoEngine(chatTemplate: template)
        try await engine.load(.fake("echo"))
        return engine
    }

    @Test("tokenize and detokenize round-trip, including multi-byte text")
    func roundTrip() async throws {
        let engine = try await loaded()
        let tokens = try await engine.tokenize("héllo 🐦", addSpecial: false, parseSpecial: false)
        #expect(try await engine.detokenize(tokens) == "héllo 🐦")
    }

    @Test("using it before load, or after unload, fails")
    func requiresLoad() async throws {
        let engine = EchoEngine()
        await #expect(throws: EngineError.notLoaded) { try await engine.tokenize(
            "x",
            addSpecial: false,
            parseSpecial: false
        ) }
        try await engine.load(.fake("echo"))
        await engine.unload()
        await #expect(throws: EngineError.notLoaded) { try await engine.detokenize([65]) }
    }

    @Test("generation replays the prompt, then finishes with timings")
    func generates() async throws {
        let engine = try await loaded()
        let prompt = try await engine.tokenize("abc", addSpecial: false, parseSpecial: false)
        var text = ""
        var finished: (FinishReason, GenerationTimings)?
        for try await event in engine.generate(GenerationRequest(promptTokens: prompt, maxTokens: 10)) {
            switch event {
            case let .token(_, piece): text += piece
            case let .finished(reason, timings): finished = (reason, timings)
            }
        }
        #expect(text == "abc")
        #expect(finished?.0 == .stop)
        #expect(finished?.1.generatedTokens == 3)
        #expect(finished?.1.promptTokens == 3)
    }

    @Test("max tokens ends generation with 'length'")
    func maxTokens() async throws {
        let engine = try await loaded()
        let prompt = try await engine.tokenize("abcdef", addSpecial: false, parseSpecial: false)
        var pieces = 0
        var reason: FinishReason?
        for try await event in engine.generate(GenerationRequest(promptTokens: prompt, maxTokens: 2)) {
            switch event {
            case .token: pieces += 1
            case let .finished(finish, _): reason = finish
            }
        }
        #expect(pieces == 2)
        #expect(reason == .length)
    }

    @Test("it reports the template it was given")
    func template() async throws {
        #expect(try await loaded(template: "{{ x }}").chatTemplate() == "{{ x }}")
        #expect(try await loaded().chatTemplate() == nil)
    }

    @Test("timings turn counts and seconds into tokens per second")
    func timings() {
        let timings = GenerationTimings(promptTokens: 100, promptSeconds: 0.5, generatedTokens: 60, generatedSeconds: 2)
        #expect(timings.promptTokensPerSecond == 200)
        #expect(timings.generatedTokensPerSecond == 30)
        #expect(GenerationTimings(promptTokens: 1, promptSeconds: 0, generatedTokens: 1, generatedSeconds: 0)
            .generatedTokensPerSecond == 0)
    }
}
