import Foundation

/// The seam between the shared server (router, chat layer, HTTP routes) and a
/// model runtime: `libllama` for GGUF (Phase 3 step 5), `mlx-swift-lm` for MLX
/// (step 4). Everything above this line is written once and serves both.
///
/// One engine instance holds one loaded model. It serves one request at a time
/// in v1 — the router holds a lease for the length of a request, but the
/// engine itself is not asked to interleave.
public protocol Engine: Sendable {
    /// What this engine can do beyond plain generation, so the shared layer can say so precisely.
    var capabilities: EngineCapabilities { get }

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

/// What an engine supports beyond plain text generation (ADR D-043, D-044). A request that needs
/// more than its engine offers is refused with a message naming what's missing, or, for a sampler
/// option, ignored with a line in the server log.
public struct EngineCapabilities: Equatable, Sendable {
    /// DRY, XTC, typical-p, top-n-sigma and mirostat.
    public var extraSamplers = false
    /// Output constrained by a GBNF grammar (JSON mode, JSON schemas, forced tool calls).
    public var grammar = false
    /// Image input, through a vision projector (ADR D-047).
    public var vision = false

    public init(extraSamplers: Bool = false, grammar: Bool = false, vision: Bool = false) {
        self.extraSamplers = extraSamplers
        self.grammar = grammar
        self.vision = vision
    }
}

public extension Engine {
    var capabilities: EngineCapabilities {
        EngineCapabilities()
    }
}

/// Makes the engine for a model, or throws if this build has none for its kind.
public typealias EngineFactory = @Sendable (ModelEntry) throws -> any Engine

/// The loaded model's facts, for `/props`, context checks and chat templates.
public struct EngineInfo: Equatable, Sendable {
    /// Tokens the model can hold (prompt plus generation) as loaded.
    public var contextSize: Int
    /// The model's own special-token strings, passed to its chat template.
    public var bosToken: String
    public var eosToken: String
    /// Whether the loaded model can read images (a vision projector is loaded).
    public var supportsImages: Bool

    public init(contextSize: Int, bosToken: String, eosToken: String, supportsImages: Bool = false) {
        self.contextSize = contextSize
        self.bosToken = bosToken
        self.eosToken = eosToken
        self.supportsImages = supportsImages
    }
}

/// llama-server's defaults, so a request that sets nothing samples the same way.
public struct SamplingParameters: Equatable, Sendable {
    public var temperature = 0.8
    public var topK = 40
    public var topP = 0.95
    public var minP = 0.05
    public var repeatPenalty = 1.0
    public var presencePenalty = 0.0
    public var frequencyPenalty = 0.0
    /// `nil` picks a random seed for each request.
    public var seed: UInt64?
    /// DRY ("don't repeat yourself") repetition penalty; 0 turns it off.
    public var dryMultiplier = 0.0
    public var dryBase = 1.75
    public var dryAllowedLength = 2
    /// -1 means the whole context.
    public var dryPenaltyLastN = -1
    public var drySequenceBreakers = ["\n", ":", "\"", "*"]
    /// XTC ("exclude top choices"); a probability of 0 turns it off.
    public var xtcProbability = 0.0
    public var xtcThreshold = 0.1
    /// Locally typical sampling; 1 turns it off.
    public var typicalP = 1.0
    /// Top-n-sigma; a negative value turns it off.
    public var topNSigma = -1.0
    /// 0 off, 1 or 2 for mirostat v1 or v2 (which replace top-k, top-p and min-p).
    public var mirostat = 0
    public var mirostatTau = 5.0
    public var mirostatEta = 0.1

    public init() {}

    /// Whether the request set anything only an engine with `extraSamplers` acts on.
    public var usesExtraSamplers: Bool {
        dryMultiplier > 0 || xtcProbability > 0 || typicalP < 1 || topNSigma >= 0 || mirostat != 0
    }
}

public struct GenerationRequest: Equatable, Sendable {
    public var promptTokens: [Int]
    public var maxTokens: Int
    public var sampling = SamplingParameters()
    /// Keep going past the end-of-sequence token (the benchmark's fixed-length runs).
    public var ignoreEndOfSequence = false
    /// Reuse the KV cache for a prompt prefix already seen (`cache_prompt`).
    public var cachePrompt = true
    /// A GBNF grammar (start rule `root`) the reply must follow; only for engines with the capability.
    public var grammar: String?
    /// With `media`: the prompt as text, an image's place marked by `ImageInput.marker`. The engine
    /// tokenizes this itself (the images become embeddings, not tokens); `promptTokens` is then only
    /// the text's own tokenization, for the caller's context check.
    public var promptText: String?
    /// Encoded images (PNG, JPEG…) in the order their markers appear in `promptText`.
    public var media: [Data] = []
}

public struct GenerationTimings: Equatable, Sendable {
    /// Prompt tokens the engine actually processed (the rest came from the prompt cache).
    public var promptTokens: Int
    public var promptSeconds: Double
    public var generatedTokens: Int
    public var generatedSeconds: Double
    /// Prompt tokens reused from the KV cache (`cache_n`).
    public var cachedTokens = 0

    public init(
        promptTokens: Int, promptSeconds: Double, generatedTokens: Int, generatedSeconds: Double, cachedTokens: Int = 0
    ) {
        self.promptTokens = promptTokens
        self.promptSeconds = promptSeconds
        self.generatedTokens = generatedTokens
        self.generatedSeconds = generatedSeconds
        self.cachedTokens = cachedTokens
    }

    var promptTokensPerSecond: Double {
        promptSeconds > 0 ? Double(promptTokens) / promptSeconds : 0
    }

    var generatedTokensPerSecond: Double {
        generatedSeconds > 0 ? Double(generatedTokens) / generatedSeconds : 0
    }
}

public enum FinishReason: String, Equatable, Sendable {
    case stop
    case length
    /// Never produced by an engine: the chat layer reports it when a reply ended in tool calls.
    case toolCalls = "tool_calls"
}

public enum GenerationEvent: Equatable, Sendable {
    case token(id: Int, text: String)
    case finished(FinishReason, GenerationTimings)
}

public enum EngineError: Error, Equatable, LocalizedError, Sendable {
    /// This build of quail-server has no engine for that model format.
    case noEngine(ModelKind)
    case loadFailed(String)
    /// The engine failed while decoding a request.
    case generationFailed(String)
    /// The request asked for something the engine can't do (a grammar that doesn't parse).
    case invalidRequest(String)
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case let .noEngine(kind):
            switch kind {
            case .gguf: "quail-server has no GGUF engine yet (Phase 3 step 5); use the llama.cpp runtime"
            case .mlx: "quail-server has no MLX engine yet (Phase 3 step 4)"
            }
        case let .loadFailed(reason), let .generationFailed(reason), let .invalidRequest(reason): reason
        case .notLoaded: "the model isn't loaded"
        }
    }
}
