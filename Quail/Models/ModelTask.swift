import Foundation

/// What a model is for (ADR D-072): chat, turning text into vectors for search (embedding), or scoring documents
/// against a query (rerank). Only chat models are offered as the default model, pinged, or listed in the chat
/// page; the others are served on `/v1/embeddings` and `/v1/rerank`. `quail-server` has its own copy of this
/// enum (`QuailServer/Core/ModelTask.swift`): the app doesn't link the server's code.
enum ModelTask: String, Sendable, Equatable, CaseIterable {
    case chat
    case embedding
    case rerank

    var label: String {
        switch self {
        case .chat: "Chat"
        case .embedding: "Embeddings"
        case .rerank: "Reranking"
        }
    }

    /// The `presets.ini` lines that tell the server, llama-server's own keys (`--embeddings`, `--reranking`,
    /// `--pooling`), which both servers read. Checked against llama-server b11306's router: it starts the model's
    /// instance with `--embeddings --pooling mean` from them. A reranker pools with its classification head.
    func presetLines(pooling: String?) -> String {
        switch self {
        case .chat:
            ""
        case .embedding:
            "embeddings = true\n" + (pooling.map { "pooling = \($0)\n" } ?? "")
        case .rerank:
            "reranking = true\npooling = \(pooling ?? "rank")\n"
        }
    }

    /// What a GGUF's header says it is: llama.cpp's converter writes `<arch>.pooling_type` for embedding models
    /// (1 mean, 2 CLS, 3 last) and rerankers (4 rank, with `<arch>.classifier.output_labels`); an encoder that
    /// isn't causal (BERT and its kin) can't chat either. Checked on the headers of Qwen3-Embedding, EmbeddingGemma,
    /// nomic-embed v1.5, bge-m3 and Qwen3-Reranker. nil for a chat model.
    static func detected(in metadata: GGUFMetadata) -> (task: ModelTask, pooling: String?)? {
        if metadata.hasClassifier || metadata.poolingType == 4 {
            return (.rerank, "rank")
        }
        if let pooling = metadata.poolingType, let name = poolingNames[pooling] {
            return (.embedding, name)
        }
        if metadata.causalAttention == false {
            return (.embedding, nil)
        }
        return nil
    }

    /// llama.cpp's `enum llama_pooling_type` values for the pooled kinds.
    private static let poolingNames = [1: "mean", 2: "cls", 3: "last"]

    /// What an MLX folder's files say it is: sentence-transformers' files (`modules.json`,
    /// `config_sentence_transformers.json`, `1_Pooling/`) or an encoder-only architecture make an embedding model,
    /// a `…ForSequenceClassification` one a reranker. The same rule as the server's `MLXEmbeddingDetector`. nil for
    /// a chat model.
    static func detected(inMLXDirectory directory: URL) -> ModelTask? {
        let fm = FileManager.default
        let config = (try? Data(contentsOf: directory.appendingPathComponent("config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let architectures = config?["architectures"] as? [String] ?? []
        if architectures.contains(where: { $0.hasSuffix("ForSequenceClassification") }) {
            return .rerank
        }
        let sentenceTransformers = ["modules.json", "config_sentence_transformers.json", "1_Pooling/config.json"]
            .contains { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
        if sentenceTransformers {
            return .embedding
        }
        if let type = config?["model_type"] as? String, encoderModelTypes.contains(type) {
            return .embedding
        }
        return nil
    }

    private static let encoderModelTypes: Set<String> = [
        "bert", "roberta", "xlm-roberta", "distilbert", "nomic_bert", "modernbert",
    ]
}
