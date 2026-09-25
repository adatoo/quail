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

    /// A vision model to try images on: its path in `QUAIL_TEST_VISION_MODEL`, with `mmproj-<name>.gguf` beside it.
    private static let visionModel = ProcessInfo.processInfo.environment["QUAIL_TEST_VISION_MODEL"]
        .map { URL(fileURLWithPath: $0) }
    private static let visionExists = visionModel.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    private static let blocks = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestFixtures/Images/blocks.png")

    /// Text for a chat-style prompt, so a small model answers something (the tests compare texts, not read them).
    private func chat(_ engine: LlamaEngine, _ question: String, tokens: Int = 40, cache: Bool = false) async throws
        -> GenerationRequest
    {
        let prompt = try await engine.tokenize(
            "<|im_start|>user\n/no_think \(question)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
            addSpecial: false, parseSpecial: true
        )
        var request = GenerationRequest(promptTokens: prompt, maxTokens: tokens)
        request.sampling.temperature = 0
        request.cachePrompt = cache
        return request
    }

    private static let questions = [
        "Write a short story about a lighthouse keeper.", "Explain how a hash table works.",
        "List ten facts about octopuses.", "Describe the water cycle.", "What is a monad?",
        "Give me a recipe for pancakes.", "Explain TCP slow start.", "Write a haiku about rain.",
    ]

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

    @Test(
        "a model that can't read images refuses them, and one without a projector isn't offered them",
        .enabled(if: smallExists)
    )
    func imagesRefused() async throws {
        let engine = LlamaEngine()
        #expect(engine.capabilities.vision)
        try await engine.load(entry(Self.small))
        #expect(await engine.info().supportsImages == false)
        var request = GenerationRequest(promptTokens: [1], maxTokens: 4)
        request.promptText = "<__media__>"
        request.media = [Data([1, 2, 3])]
        await #expect(throws: EngineError.invalidRequest("this model can't read images")) {
            _ = try await collect(engine, request)
        }
        await engine.unload()
    }

    @Test("a vision model reads an image, and text after it is unaffected", .enabled(if: visionExists))
    func images() async throws {
        let model = try #require(Self.visionModel)
        var vision = entry(model)
        vision.projector = model.deletingLastPathComponent()
            .appendingPathComponent("mmproj-\(model.deletingPathExtension().lastPathComponent).gguf")
        let engine = LlamaEngine()
        try await engine.load(vision)
        #expect(await engine.info().supportsImages)

        let image = try Data(contentsOf: Self.blocks)
        let text = "<__media__>\nWhat colors are in this image?"
        var request = try await GenerationRequest(
            promptTokens: engine.tokenize(text, addSpecial: true, parseSpecial: true), maxTokens: 12
        )
        request.temperature0()
        request.promptText = text
        request.media = [image]
        let first = try await collect(engine, request)
        #expect(!first.text.isEmpty)
        // The image's tokens count towards the prompt, far more than the marker's text does.
        #expect((first.finished?.1.promptTokens ?? 0) > request.promptTokens.count + 10)
        #expect(try await collect(engine, request).text == first.text) // repeatable, nothing left over

        // Text after an image starts from empty memory, and the next text request reuses its own prefix.
        var plain = try await GenerationRequest(
            promptTokens: engine.tokenize("Say hello.", addSpecial: true, parseSpecial: true), maxTokens: 6
        )
        plain.temperature0()
        let a = try await collect(engine, plain)
        let b = try await collect(engine, plain)
        #expect(a.text == b.text && a.finished?.1.cachedTokens == 0 && (b.finished?.1.cachedTokens ?? 0) > 0)

        request.media = [Data("not an image".utf8)]
        await #expect(throws: EngineError
            .invalidRequest("an image couldn't be decoded (JPEG, PNG, BMP and GIF are read)"))
        {
            _ = try await collect(engine, request)
        }
        request.media = [image, image] // two images, one marker
        await #expect(throws: EngineError.self) { _ = try await collect(engine, request) }
        await engine.unload()
    }

    // MARK: several requests at once (ADR D-048)

    @Test("Qwen3-0.6B: four requests decoded together each give what they give alone", .enabled(if: smallExists))
    func parallelEqualsSerial() async throws {
        let engine = LlamaEngine(parallel: 4)
        try await engine.load(entry(Self.small))
        #expect(await engine.info().slots == 4)
        var requests: [GenerationRequest] = []
        for question in Self.questions.prefix(4) {
            try await requests.append(chat(engine, question))
        }
        var alone: [String] = []
        for request in requests {
            try await alone.append(collect(engine, request).text)
        }
        let together = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask { try await (index, collect(engine, request).text) }
            }
            var texts = [String](repeating: "", count: requests.count)
            for try await (index, text) in group {
                texts[index] = text
            }
            return texts
        }
        #expect(together == alone)
        #expect(!alone.contains(""))
        await eventuallyIdle(engine)
        await engine.unload()
    }

    @Test(
        "Qwen3-0.6B: a client that leaves doesn't disturb the others, and its slot comes back",
        .enabled(if: smallExists)
    )
    func hangUpAmongOthers() async throws {
        let engine = LlamaEngine(parallel: 3)
        try await engine.load(entry(Self.small))
        var requests: [GenerationRequest] = []
        for question in Self.questions.prefix(3) {
            try await requests.append(chat(engine, question, tokens: 60))
        }
        var alone: [String] = []
        for request in requests {
            try await alone.append(collect(engine, request).text)
        }
        let texts = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    if index == 1 { // leaves after three tokens
                        var seen = 0
                        for try await event in engine.generate(request) {
                            if case .token = event {
                                seen += 1
                            }
                            if seen == 3 {
                                break
                            }
                        }
                        return (index, "")
                    }
                    return try await (index, collect(engine, request).text)
                }
            }
            var texts = [String](repeating: "", count: requests.count)
            for try await (index, text) in group {
                texts[index] = text
            }
            return texts
        }
        #expect(texts[0] == alone[0] && texts[2] == alone[2])
        await eventuallyIdle(engine)
        #expect(try await collect(engine, requests[1]).text == alone[1]) // the freed slot serves the next
        await engine.unload()
    }

    @Test("Qwen3-0.6B: a conversation that comes back finds its own slot's cache", .enabled(if: smallExists))
    func slotsKeepTheirConversations() async throws {
        let engine = LlamaEngine(parallel: 2)
        try await engine.load(entry(Self.small))
        let filler = String(repeating: "Please answer carefully and in plain words. ", count: 5)
        let a = try await chat(
            engine,
            filler + "Tell me about the moon and its phases in detail please.",
            tokens: 8,
            cache: true
        )
        let b = try await chat(
            engine,
            "Tell me how planes stay in the air. " + filler,
            tokens: 8,
            cache: true
        )
        _ = try await collect(engine, a)
        _ = try await collect(engine, b)
        // Each again, longer: the cache is the whole earlier prompt, whichever slot is free.
        for request in [b, a, b, a] {
            let again = try await collect(engine, request)
            #expect(
                (again.finished?.1.cachedTokens ?? 0) >= request.promptTokens.count - 1,
                "cached \(again.finished?.1.cachedTokens ?? -1) of \(request.promptTokens.count)"
            )
        }
        await engine.unload()
    }

    @Test(
        "Qwen3-0.6B: a start another conversation holds is shared, and the answer is what a full decode gives",
        .enabled(if: smallExists)
    )
    func slotsShareAStart() async throws {
        let engine = LlamaEngine(parallel: 2)
        try await engine.load(entry(Self.small))
        let preamble = String(repeating: "You are a careful assistant who answers briefly and plainly. ", count: 6)
        let a = try await chat(engine, preamble + "What is the capital of France?", tokens: 12, cache: true)
        var b = try await chat(engine, preamble + "What is the capital of Japan?", tokens: 12, cache: true)
        _ = try await collect(engine, a)
        let shared = try await collect(engine, b)
        // Most of the prompt came from the other slot, not from decoding.
        #expect((shared.finished?.1.cachedTokens ?? 0) >= 60, "\(shared.finished?.1.cachedTokens ?? -1)")
        // The first conversation still has its own cache.
        let again = try await collect(engine, a)
        #expect(
            (again.finished?.1.cachedTokens ?? 0) >= a.promptTokens.count - 1,
            "again cached \(again.finished?.1.cachedTokens ?? -1) of \(a.promptTokens.count); shared \(shared.finished?.1.cachedTokens ?? -1)"
        )
        // And what the second got is what decoding it all gives (a request that asks for no cache takes the
        // least recently used slot, whatever it held).
        b.cachePrompt = false
        let fresh = try await collect(engine, b)
        #expect(fresh.finished?.1.cachedTokens == 0)
        #expect(shared.text == fresh.text)
        await engine.unload()
    }

    @Test("Qwen3-0.6B: constrained and plain requests run side by side", .enabled(if: smallExists))
    func constrainedBesidePlain() async throws {
        let engine = LlamaEngine(parallel: 3)
        try await engine.load(entry(Self.small))
        var constrained = try await chat(engine, "Is water wet?")
        constrained.grammar = #"root ::= "yes" | "no""#
        let plain = try await chat(engine, "Explain how a hash table works.")
        let alone = try await collect(engine, plain).text
        async let first = collect(engine, constrained)
        async let second = collect(engine, plain)
        async let third = collect(engine, constrained)
        let (one, two, three) = try await (first, second, third)
        #expect(["yes", "no"].contains(one.text) && one.text == three.text)
        #expect(two.text == alone)
        await engine.unload()
    }

    @Test(
        "Qwen3-0.6B: a hundred mixed requests with clients coming and going leave no slot held",
        .enabled(if: smallExists)
    )
    func stress() async throws {
        let engine = LlamaEngine(parallel: 3)
        try await engine.load(entry(Self.small))
        var requests: [GenerationRequest] = []
        for question in Self.questions {
            try await requests.append(chat(engine, question, tokens: 30, cache: true))
        }
        let prepared = requests
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 100 {
                group.addTask {
                    var request = prepared[index % prepared.count]
                    request.sampling.temperature = 0.8
                    request.sampling.seed = UInt64(index)
                    if index % 7 == 0 {
                        request.grammar = #"root ::= "a" | "b""#
                    }
                    let leaveAfter = index % 3 == 0 ? Int.random(in: 0 ... 5) : Int.max
                    var seen = 0
                    do {
                        for try await event in engine.generate(request) {
                            if case .token = event {
                                seen += 1
                            }
                            if seen >= leaveAfter {
                                break
                            }
                        }
                    } catch {
                        Issue.record("request \(index) failed: \(error)")
                    }
                }
            }
        }
        await eventuallyIdle(engine)
        // Nothing is left over: a request afterwards is what it would have been alone.
        let after = try await collect(engine, requests[0])
        #expect(after.finished?.0 == .length || after.finished?.0 == .stop)
        #expect(!after.text.isEmpty)
        await engine.unload()
    }

    /// Waits for every slot to be free (a request that ended has its slot released on the engine's queue).
    private func eventuallyIdle(_ engine: LlamaEngine) async {
        for _ in 0 ..< 200 where await engine.busySlots() > 0 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(await engine.busySlots() == 0)
    }
}

private extension GenerationRequest {
    mutating func temperature0() {
        sampling.temperature = 0
        cachePrompt = true
    }
}
