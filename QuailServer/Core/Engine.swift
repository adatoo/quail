import Foundation

/// The seam between the shared server (router, chat layer, HTTP routes) and a
/// model runtime: `libllama` for GGUF (Phase 3 step 5), `mlx-swift-lm` for MLX
/// (step 4). Everything above this line is written once and serves both.
///
/// One engine instance holds one loaded model. It serves one request at a time
/// in v1 — the router holds a lease for the length of a request, but the
/// engine itself is not asked to interleave.
protocol Engine: Sendable {
    func load(_ model: ModelEntry) async throws
    func unload() async

    func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) async throws -> [Int]
    func detokenize(_ tokens: [Int]) async throws -> String

    /// What the shared layer needs to know about the loaded model.
    func info() async -> EngineInfo

    /// The model's own Jinja chat template, if it ships one (GGUF
    /// `tokenizer.chat_template`, or an MLX repo's `chat_template.jinja`).
    func chatTemplate() async -> String?

    /// Streams tokens. Ending the stream's consumption (cancellation, or the
    /// HTTP client going away) must stop generation.
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error>
}

/// Makes the engine for a model, or throws if this build has none for its kind.
typealias EngineFactory = @Sendable (ModelEntry) throws -> any Engine

/// The loaded model's facts, for `/props`, context checks and chat templates.
struct EngineInfo: Equatable, Sendable {
    /// Tokens the model can hold (prompt plus generation) as loaded.
    var contextSize: Int
    /// The model's own special-token strings, passed to its chat template.
    var bosToken: String
    var eosToken: String
}

/// llama-server's defaults, so a request that sets nothing samples the same way.
struct SamplingParameters: Equatable, Sendable {
    var temperature = 0.8
    var topK = 40
    var topP = 0.95
    var minP = 0.05
    var repeatPenalty = 1.0
    var presencePenalty = 0.0
    var frequencyPenalty = 0.0
    /// `nil` picks a random seed for each request.
    var seed: UInt64?
}

struct GenerationRequest: Equatable, Sendable {
    var promptTokens: [Int]
    var maxTokens: Int
    var sampling = SamplingParameters()
    /// Keep going past the end-of-sequence token (the benchmark's fixed-length runs).
    var ignoreEndOfSequence = false
    /// Reuse the KV cache for a prompt prefix already seen (`cache_prompt`).
    var cachePrompt = true
}

struct GenerationTimings: Equatable, Sendable {
    /// Prompt tokens the engine actually processed (the rest came from the prompt cache).
    var promptTokens: Int
    var promptSeconds: Double
    var generatedTokens: Int
    var generatedSeconds: Double
    /// Prompt tokens reused from the KV cache (`cache_n`).
    var cachedTokens = 0

    var promptTokensPerSecond: Double {
        promptSeconds > 0 ? Double(promptTokens) / promptSeconds : 0
    }

    var generatedTokensPerSecond: Double {
        generatedSeconds > 0 ? Double(generatedTokens) / generatedSeconds : 0
    }
}

enum FinishReason: String, Equatable, Sendable {
    case stop
    case length
    /// Never produced by an engine: the chat layer reports it when a reply ended in tool calls.
    case toolCalls = "tool_calls"
}

enum GenerationEvent: Equatable, Sendable {
    case token(id: Int, text: String)
    case finished(FinishReason, GenerationTimings)
}

enum EngineError: Error, Equatable, LocalizedError, Sendable {
    /// This build of quail-server has no engine for that model format.
    case noEngine(ModelKind)
    case loadFailed(String)
    case notLoaded

    var errorDescription: String? {
        switch self {
        case let .noEngine(kind):
            switch kind {
            case .gguf: "quail-server has no GGUF engine yet (Phase 3 step 5); use the llama.cpp runtime"
            case .mlx: "quail-server has no MLX engine yet (Phase 3 step 4)"
            }
        case let .loadFailed(reason): reason
        case .notLoaded: "the model isn't loaded"
        }
    }
}
