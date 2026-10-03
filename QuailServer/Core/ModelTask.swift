import Foundation

/// What a model is for (ADR D-072). A chat model generates text through the chat and completion routes; an
/// embedding model turns text into vectors (`/v1/embeddings`), and a reranking model scores documents against a
/// query (`/v1/rerank`). The presets say which, with llama-server's own keys (`embeddings`, `reranking`), so the
/// same `presets.ini` means the same thing to both servers.
public enum ModelTask: String, Equatable, Sendable {
    case chat
    case embedding
    case rerank

    /// How the routes that need another task name this one in an error.
    var noun: String {
        switch self {
        case .chat: "a chat model"
        case .embedding: "an embedding model"
        case .rerank: "a reranking model"
        }
    }

    /// The route a model of this task answers on, for an error that sends a request there.
    var route: String {
        switch self {
        case .chat: "/v1/chat/completions"
        case .embedding: "/v1/embeddings"
        case .rerank: "/v1/rerank"
        }
    }
}

/// How an embedding model turns its tokens' vectors into one: llama.cpp's `--pooling` values. `rank` is a
/// reranker's classification head, which gives a score instead of a vector.
public enum PoolingType: String, Equatable, Sendable, CaseIterable {
    case none
    case mean
    case cls
    case last
    case rank
}

/// Recognises an MLX embedding model from its folder, since an MLX model has no preset of its own when the
/// server runs without the app: sentence-transformers' files (`modules.json`, `config_sentence_transformers.json`,
/// `1_Pooling/`), or an encoder-only architecture, which can't chat.
enum MLXEmbeddingDetector {
    static let encoderModelTypes: Set<String> = [
        "bert", "roberta", "xlm-roberta", "distilbert", "nomic_bert", "modernbert",
    ]

    static func task(of directory: URL) -> ModelTask {
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
        return .chat
    }
}
