import Testing
@testable import Quail

@Suite("quail chat: model or prompt?")
struct ChatTargetTests {
    private static let installed = ["Qwen3-8B-Q4_K_M", "Qwen3-8B-Q8_0", "Gemma-4-12B-Q4_K_M"]

    @Test("names match exactly, case-insensitively, or by a unique prefix")
    func matching() {
        #expect(ModelNameMatch.match("Gemma-4-12B-Q4_K_M", in: Self.installed) == .one("Gemma-4-12B-Q4_K_M"))
        #expect(ModelNameMatch.match("gemma-4-12b-q4_k_m", in: Self.installed) == .one("Gemma-4-12B-Q4_K_M"))
        #expect(ModelNameMatch.match("gemma", in: Self.installed) == .one("Gemma-4-12B-Q4_K_M"))
        #expect(ModelNameMatch.match("llama", in: Self.installed) == .none)
        #expect(ModelNameMatch.match("qwen3", in: Self.installed) == .ambiguous(["Qwen3-8B-Q4_K_M", "Qwen3-8B-Q8_0"]))
        #expect(ModelNameMatch.match("Qwen3-8B-Q8_0", in: Self.installed) == .one("Qwen3-8B-Q8_0"))
    }

    private func resolve(_ words: [String], model: String? = nil) throws -> ChatTarget.Resolved {
        try ChatTarget.resolve(words: words, explicitModel: model, installed: Self.installed)
    }

    @Test("no words: the default model, interactive")
    func bare() throws {
        #expect(try resolve([]) == .init(model: nil, prompt: []))
    }

    @Test("a first word naming a model is the model; the rest is the prompt")
    func modelFirst() throws {
        #expect(try resolve(["gemma"]) == .init(model: "Gemma-4-12B-Q4_K_M", prompt: []))
        #expect(try resolve(["gemma", "why", "is", "it"]) == .init(
            model: "Gemma-4-12B-Q4_K_M",
            prompt: ["why", "is", "it"]
        ))
    }

    @Test("a first word that names no model starts the prompt")
    func promptOnly() throws {
        #expect(try resolve(["why", "is", "the", "sky", "blue"]) == .init(
            model: nil,
            prompt: ["why", "is", "the", "sky", "blue"]
        ))
        #expect(try resolve(["hello"]) == .init(model: nil, prompt: ["hello"]))
    }

    @Test("a quoted prompt (one word with spaces) is never a model")
    func quotedPrompt() throws {
        #expect(try resolve(["gemma is a model"]) == .init(model: nil, prompt: ["gemma is a model"]))
    }

    @Test("-m names the model; every word is the prompt")
    func explicit() throws {
        #expect(try resolve(["gemma", "hi"], model: "gem") == .init(
            model: "Gemma-4-12B-Q4_K_M",
            prompt: ["gemma", "hi"]
        ))
        #expect(try resolve([], model: "Qwen3-8B-Q8_0") == .init(model: "Qwen3-8B-Q8_0", prompt: []))
    }

    @Test("an unknown or ambiguous -m is an error")
    func explicitErrors() {
        #expect(throws: ChatTarget.Failure.unknownModel("llama")) { try resolve(["hi"], model: "llama") }
        #expect(throws: ChatTarget.Failure.ambiguous("qwen3", ["Qwen3-8B-Q4_K_M", "Qwen3-8B-Q8_0"], guessed: false)) {
            try resolve([], model: "qwen3")
        }
    }

    @Test("an ambiguous first word is an error that says how to get out of it")
    func ambiguousFirstWord() {
        #expect(throws: ChatTarget.Failure.ambiguous("qwen3", ["Qwen3-8B-Q4_K_M", "Qwen3-8B-Q8_0"], guessed: true)) {
            try resolve(["qwen3", "hi"])
        }
        let message = ChatTarget.Failure.ambiguous("qwen3", ["A", "B"], guessed: true).description
        #expect(message.contains("-m"))
        #expect(message.contains("quote"))
    }
}
