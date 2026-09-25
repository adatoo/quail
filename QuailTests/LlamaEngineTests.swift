import Foundation
import Testing
@testable import QuailServerCore
@testable import QuailServerLlama

@Suite("LlamaEngine", .timeLimit(.minutes(2)))
struct LlamaEngineTests {
    private static let models = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quail/Models/gguf")
    private static let small = models.appendingPathComponent("Qwen3-0.6B-Q8_0.gguf")
    private static let smallExists = FileManager.default.fileExists(atPath: small.path)

    private func entry(_ url: URL) -> ModelEntry {
        ModelEntry(id: url.deletingPathExtension().lastPathComponent, kind: .gguf, path: url)
    }

    private func collect(_ engine: LlamaEngine, _ request: GenerationRequest) async throws
        -> (text: String, finished: (FinishReason, GenerationTimings)?)
    {
        var text = ""
        var finished: (FinishReason, GenerationTimings)?
        for try await event in engine.generate(request) {
            switch event {
            case let .token(_, piece): text += piece
            case let .finished(reason, timings): finished = (reason, timings)
            }
        }
        return (text, finished)
    }

    // MARK: no model needed

    @Test("a model file that isn't there, or isn't a GGUF, fails to load with a reason")
    func badFiles() async throws {
        let engine = LlamaEngine()
        await #expect(throws: EngineError.self) {
            try await engine.load(entry(URL(fileURLWithPath: "/nonexistent/none.gguf")))
        }
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).gguf")
        try Data("this is not a model".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        do {
            try await engine.load(entry(junk))
            Issue.record("loading a text file should fail")
        } catch let error as EngineError {
            #expect(error.localizedDescription.contains("couldn't load"))
        }
    }

    @Test("before a model is loaded, the engine says so and unload is harmless")
    func notLoaded() async {
        let engine = LlamaEngine()
        await #expect(throws: EngineError.notLoaded) { try await engine.tokenize(
            "hi",
            addSpecial: false,
            parseSpecial: false
        ) }
        await #expect(throws: EngineError.notLoaded) { try await engine.detokenize([1]) }
        #expect(await engine.chatTemplate() == nil)
        #expect(await engine.info().contextSize == 0)
        await engine.unload()
        var failed = false
        do {
            for try await _ in engine.generate(GenerationRequest(promptTokens: [1], maxTokens: 1)) {}
        } catch {
            failed = true
        }
        #expect(failed)
    }

    @Test("a character split across tokens is held back until it is whole")
    func utf8Assembly() {
        var assembler = UTF8Assembler()
        let bytes = Array("é日🎉".utf8) // 2, 3 and 4 bytes
        var out = ""
        for byte in bytes {
            let piece = assembler.append([byte])
            // Never half a character: whatever comes out is already valid text.
            #expect(!piece.contains("\u{FFFD}"))
            out += piece
        }
        #expect(out == "é日🎉")
        // Several characters in one token, and a token ending mid-character.
        var second = UTF8Assembler()
        #expect(second.append(Array("ab日".utf8).dropLast(1).map(\.self)) == "ab")
        #expect(second.append([Array("日".utf8)[2]]) == "日")
    }

    @Test("the incomplete tail is measured for every prefix of a 4-byte character")
    func incompleteTail() {
        let bytes = Array("🎉".utf8)
        #expect((1 ... 4).map { UTF8Assembler.incompleteTail(Array(bytes.prefix($0))) } == [1, 2, 3, 0])
        #expect(UTF8Assembler.incompleteTail(Array("abc".utf8)) == 0)
        #expect(UTF8Assembler.incompleteTail([]) == 0)
    }

    // MARK: a real model (skipped where the file isn't on disk)

    @Test("Qwen3-0.6B: info, template and a tokenize round trip", .enabled(if: smallExists))
    func loadsAndTokenizes() async throws {
        let engine = LlamaEngine()
        try await engine.load(entry(Self.small))
        let info = await engine.info()
        #expect(info.contextSize > 0)
        #expect(info.eosToken == "<|im_end|>")
        #expect(await engine.chatTemplate()?.contains("<|im_start|>") == true)
        let text = "Hello, wörld! 日本語 <|im_start|>"
        let tokens = try await engine.tokenize(text, addSpecial: false, parseSpecial: true)
        #expect(try await engine.detokenize(tokens) == text)
        // Special-token text is one token when parsed, several when not.
        let plain = try await engine.tokenize("<|im_start|>", addSpecial: false, parseSpecial: false)
        let special = try await engine.tokenize("<|im_start|>", addSpecial: false, parseSpecial: true)
        #expect(special.count == 1)
        #expect(plain.count > 1)
        await engine.unload()
    }

    @Test(
        "Qwen3-0.6B: greedy generation is repeatable, and a repeated prompt is served from the cache",
        .enabled(if: smallExists)
    )
    func generatesAndCaches() async throws {
        let engine = LlamaEngine()
        try await engine.load(entry(Self.small))
        let prompt = try await engine.tokenize(
            "<|im_start|>user\n/no_think Name three fruits.<|im_end|>\n<|im_start|>assistant\n",
            addSpecial: false, parseSpecial: true
        )
        var request = GenerationRequest(promptTokens: prompt, maxTokens: 40)
        request.sampling.temperature = 0
        let first = try await collect(engine, request)
        let second = try await collect(engine, request)
        #expect(!first.text.isEmpty)
        #expect(first.text == second.text)
        #expect(first.finished?.0 == .stop)
        #expect(first.finished?.1.cachedTokens == 0)
        // All but the last prompt token come from the cache the second time.
        #expect(second.finished?.1.cachedTokens == prompt.count - 1)
        #expect(second.finished?.1.promptTokens == 1)

        request.cachePrompt = false
        let uncached = try await collect(engine, request)
        #expect(uncached.finished?.1.cachedTokens == 0)
        #expect(uncached.text == first.text)
        await engine.unload()
    }

    @Test(
        "Qwen3-0.6B: max_tokens ends a reply as length, ignore_eos runs on, and a hang-up stops decoding",
        .enabled(if: smallExists)
    )
    func limitsAndCancel() async throws {
        let engine = LlamaEngine()
        try await engine.load(entry(Self.small))
        let prompt = try await engine.tokenize("Say hi.", addSpecial: false, parseSpecial: true)
        var request = GenerationRequest(promptTokens: prompt, maxTokens: 5)
        request.sampling.temperature = 0
        let short = try await collect(engine, request)
        #expect(short.finished?.0 == .length)
        #expect(short.finished?.1.generatedTokens == 5)

        request.maxTokens = 30
        request.ignoreEndOfSequence = true
        let long = try await collect(engine, request)
        #expect(long.finished?.1.generatedTokens == 30)

        // Stopping after a few tokens leaves the engine ready for the next request.
        request.maxTokens = 4000
        var seen = 0
        for try await event in engine.generate(request) {
            if case .token = event {
                seen += 1
            }
            if seen == 5 {
                break
            }
        }
        request.maxTokens = 3
        #expect(try await collect(engine, request).finished?.1.generatedTokens == 3)
        await engine.unload()
    }

    @Test("Qwen3-0.6B: the extra samplers change the output, and stay repeatable for a seed", .enabled(if: smallExists))
    func extraSamplers() async throws {
        let engine = LlamaEngine()
        #expect(engine.capabilities.extraSamplers)
        try await engine.load(entry(Self.small))
        let prompt = try await engine.tokenize(
            "The old lighthouse keeper looked at the sea and the old lighthouse keeper looked at the sea and",
            addSpecial: false, parseSpecial: true
        )
        func run(_ change: (inout SamplingParameters) -> Void) async throws -> String {
            var request = GenerationRequest(promptTokens: prompt, maxTokens: 60)
            request.cachePrompt = false
            request.sampling.temperature = 0.8
            request.sampling.seed = 7
            change(&request.sampling)
            return try await collect(engine, request).text
        }
        let plain = try await run { _ in }
        #expect(try await run { _ in } == plain) // a seed repeats

        // DRY penalises repeating the prompt, so the text moves off it.
        let dry = try await run { $0.dryMultiplier = 0.8 }
        #expect(dry != plain)
        #expect(try await run { $0.dryMultiplier = 0.8 } == dry)
        #expect(try await run { $0.xtcProbability = 1; $0.xtcThreshold = 0.05 } != plain)
        #expect(try await run { $0.typicalP = 0.5 } != plain)
        #expect(try await run { $0.topNSigma = 0.5 } != plain)
        for mirostat in [1, 2] {
            let text = try await run { $0.mirostat = mirostat }
            #expect(!text.isEmpty)
            #expect(try await run { $0.mirostat = mirostat } == text)
        }
        await engine.unload()
    }

    @Test("Qwen3-0.6B: a grammar bounds the reply, whatever the model would say", .enabled(if: smallExists))
    func grammar() async throws {
        let engine = LlamaEngine()
        #expect(engine.capabilities.grammar)
        try await engine.load(entry(Self.small))
        let prompt = try await engine.tokenize(
            "<|im_start|>user\n/no_think Is water wet? Explain at length.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
            addSpecial: false, parseSpecial: true
        )
        var request = GenerationRequest(promptTokens: prompt, maxTokens: 100)
        request.cachePrompt = false
        request.sampling.temperature = 0.8
        request.sampling.seed = 3
        request.grammar = #"root ::= "yes" | "no""#
        let short = try await collect(engine, request)
        #expect(["yes", "no"].contains(short.text))
        #expect(short.finished?.0 == .stop)

        request.grammar = try JSONSchemaGrammar.gbnf(
            for: OrderedJSON
                .parse(#"{"type":"object","properties":{"answer":{"type":"boolean"}},"required":["answer"]}"#),
            reasoning: .none
        )
        let object = try await collect(engine, request).text
        let parsed = try JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any]
        #expect(parsed?["answer"] is Bool)

        // A grammar that doesn't parse is the client's mistake, and the engine stays usable.
        request.grammar = "root ::= ("
        await #expect(throws: EngineError.self) { _ = try await collect(engine, request) }
        request.grammar = nil
        request.maxTokens = 3
        #expect(try await collect(engine, request).finished != nil)
        await engine.unload()
    }

    @Test("Qwen3-0.6B: a forced tool call is a call, whatever the prompt asks", .enabled(if: smallExists))
    func forcedToolCall() async throws {
        let engine = LlamaEngine()
        try await engine.load(entry(Self.small))
        let prompt = try await engine.tokenize(
            "<|im_start|>user\n/no_think Tell me a joke.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
            addSpecial: false, parseSpecial: true
        )
        let tools = try OrderedJSON.parse(
            #"[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"},"days":{"type":"integer","minimum":1,"maximum":7}},"required":["city","days"]}}}]"#
        ).arrayValue ?? []
        for seed in UInt64(1) ... 3 {
            var request = GenerationRequest(promptTokens: prompt, maxTokens: 200)
            request.cachePrompt = false
            request.sampling.temperature = 0.7
            request.sampling.seed = seed
            request.grammar = try JSONSchemaGrammar.toolCalls(
                tools: tools, name: "get_weather", format: .hermesJSON, parallel: false, reasoning: .none
            )
            let text = try await collect(engine, request).text
            var parser = ToolCallParser(format: .hermesJSON, tools: tools)
            var calls: [ParsedToolCall] = []
            for delta in parser.push(text) + parser.flush() {
                if case let .toolCall(call) = delta {
                    calls.append(call)
                }
            }
            #expect(calls.count == 1, "\(text)")
            #expect(calls.first?.name == "get_weather")
            let arguments = try JSONSerialization
                .jsonObject(with: Data((calls.first?.arguments ?? "{}").utf8)) as? [String: Any]
            #expect(arguments?["city"] is String)
            #expect((1 ... 7).contains(arguments?["days"] as? Int ?? 0))
        }
        await engine.unload()
    }
}
