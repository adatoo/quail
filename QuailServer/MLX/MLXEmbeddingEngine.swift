import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXRerankers
import QuailServerCore

/// The MLX engine for models that don't chat (ADR D-072, #181): `mlx-swift-lm`'s `MLXEmbedders` for an embedding
/// model's pooled vectors, and its `MLXRerankers` for a reranker's scores. One instance holds one model. Inputs run
/// one at a time, each its own forward pass, so no input is padded: padding needs a mask every model family reads
/// the same way, and a single input needs none.
public actor MLXEmbeddingEngine: EmbeddingEngine {
    private var embedder: EmbedderModelContainer?
    private var reranker: RerankerContainer?
    private var tokenizer: (any MLXLMCommon.Tokenizer)?
    /// The preset's pooling, which overrides the model's own (`1_Pooling/config.json`, or the family's default).
    private var poolingOverride: Pooling.Strategy?
    private var loadedInfo = EngineInfo(contextSize: 0, bosToken: "", eosToken: "")

    /// The context reported when the model doesn't bound its positions (RoPE): inputs longer than this are refused.
    static let defaultContext = 8192

    public init() {}

    public func load(_ entry: ModelEntry) async throws {
        await unload()
        let directory = entry.path
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            throw EngineError.loadFailed("\(directory.path) has no config.json")
        }
        let loader = TokenizerBridgeLoader()
        do {
            let tokenizer = try await loader.load(from: directory)
            var positions: Int?
            if entry.task == .rerank {
                // The folder's name needn't say "reranker": Quail's catalog and the preset already do.
                reranker = try await RerankerModelFactory.shared.loadContainer(
                    from: directory, using: loader, allowUnverifiedModel: true
                )
            } else {
                let container = try await EmbedderModelFactory.shared.loadContainer(from: directory, using: loader)
                positions = await container.perform { $0.model.maxPositionEmbeddings }
                embedder = container
            }
            self.tokenizer = tokenizer
            poolingOverride = entry.pooling.flatMap(Self.strategy)
            let contextSize = min(positions ?? Self.defaultContext, entry.contextSize ?? Self.defaultContext)
            loadedInfo = EngineInfo(
                contextSize: contextSize,
                bosToken: tokenizer.bosToken ?? "",
                eosToken: tokenizer.eosToken ?? ""
            )
        } catch {
            await unload()
            let kind = entry.task == .rerank ? "a reranker" : "an embedding model"
            throw EngineError.loadFailed(
                "MLX couldn't load \(directory.lastPathComponent) as \(kind): \(error.localizedDescription)"
            )
        }
    }

    static func strategy(_ pooling: PoolingType) -> Pooling.Strategy? {
        switch pooling {
        case .mean: .mean
        case .cls: .cls
        case .last: .last
        case .none, .rank: nil
        }
    }

    public func unload() async {
        embedder = nil
        reranker = nil
        tokenizer = nil
        poolingOverride = nil
        loadedInfo = EngineInfo(contextSize: 0, bosToken: "", eosToken: "")
        MLXEngine.clearBufferCache()
    }

    public func tokenize(_ text: String, addSpecial: Bool, parseSpecial _: Bool) async throws -> [Int] {
        guard let tokenizer else { throw EngineError.notLoaded }
        return tokenizer.encode(text: text, addSpecialTokens: addSpecial)
    }

    public func detokenize(_ tokens: [Int]) async throws -> String {
        guard let tokenizer else { throw EngineError.notLoaded }
        return tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
    }

    public func info() async -> EngineInfo {
        loadedInfo
    }

    public func embed(_ inputs: [[Int]], normalize: Bool) async throws -> [[Float]] {
        guard let embedder else {
            throw EngineError.invalidRequest(reranker == nil ? "the model isn't loaded" : "this model is a reranker")
        }
        let override = poolingOverride
        return try await embedder.perform { context in
            let pooling = override.map { Pooling(strategy: $0) } ?? context.pooling
            var vectors: [[Float]] = []
            for tokens in inputs {
                let ids = MLXArray(tokens.map(Int32.init)).expandedDimensions(axis: 0)
                let output = context.model(
                    ids, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: ids), attentionMask: nil
                )
                // With no pooling named, a model that pools itself (EmbeddingGemma) gives its own vector; one that
                // doesn't would give every token's, which isn't an embedding.
                guard pooling.strategy != .none || output.pooledOutput != nil else {
                    throw EngineError.invalidRequest(
                        "this model doesn't say how to pool its vectors into one; set its pooling (mean, cls or last)"
                    )
                }
                let pooled = pooling(output, normalize: normalize)
                eval(pooled)
                vectors.append(pooled[0].asArray(Float.self))
            }
            return vectors
        }
    }

    public func rerank(query: String, documents: [String]) async throws -> [RerankScore] {
        guard let reranker, let tokenizer else {
            throw EngineError.invalidRequest(embedder == nil ? "the model isn't loaded" : "this model isn't a reranker")
        }
        let response = try await reranker.scores(query: query, documents: documents)
        var scores = Array(repeating: 0.0, count: documents.count)
        for result in response.results where scores.indices.contains(result.index) {
            scores[result.index] = result.score
        }
        let queryTokens = tokenizer.encode(text: query, addSpecialTokens: false).count
        return documents.enumerated().map { index, document in
            RerankScore(
                score: scores[index],
                tokens: queryTokens + tokenizer.encode(text: document, addSpecialTokens: false).count
            )
        }
    }
}
