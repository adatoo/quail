import Foundation
import Jinja

/// `/v1/embeddings` and `/v1/rerank` (ADR D-072, #181): the models that don't chat, in llama-server's request and
/// response shapes (OpenAI's for embeddings; Jina's and TEI's for reranking), so a client written for either
/// server works with both.
extension InferenceRoutes {
    /// One `input` item: text, tokenized here with the model's own special tokens (as llama-server does), or
    /// token ids sent as they are.
    enum EmbeddingInput: Equatable {
        case text(String)
        case tokens([Int])
    }

    /// The shapes OpenAI's `input` takes: a string, an array of strings, an array of token ids, or an array of
    /// those arrays. llama-server's older `content` is read too.
    static func embeddingInputs(_ body: Value) throws -> [EmbeddingInput] {
        guard let input = body["input"] ?? body["content"], !input.isNull else {
            throw RequestError.invalid("\"input\" must be provided")
        }
        if let text = input.stringValue {
            return [.text(text)]
        }
        guard let items = input.arrayValue else {
            throw RequestError.invalid("\"input\" must be a string, an array of strings, or arrays of token ids")
        }
        if !items.isEmpty, items.allSatisfy({ $0.intValue != nil }) {
            return [.tokens(items.compactMap(\.intValue))]
        }
        let inputs = try items.map { item -> EmbeddingInput in
            if let text = item.stringValue {
                return .text(text)
            }
            if let tokens = item.arrayValue, tokens.allSatisfy({ $0.intValue != nil }) {
                return .tokens(tokens.compactMap(\.intValue))
            }
            throw RequestError.invalid("each \"input\" item must be a string or an array of token ids")
        }
        guard !inputs.isEmpty else { throw RequestError.invalid("\"input\" must not be empty") }
        return inputs
    }

    // MARK: /v1/embeddings

    func embeddings(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try jsonBody(request)
        let inputs = try Self.embeddingInputs(body)
        let base64: Bool
        switch body["encoding_format"]?.stringValue ?? "float" {
        case "float": base64 = false
        case "base64": base64 = true
        default: throw RequestError.invalid("\"encoding_format\" must be \"float\" or \"base64\"")
        }
        let dimensions = body["dimensions"]?.intValue
        if let dimensions, dimensions < 1 {
            throw RequestError.invalid("\"dimensions\" must be at least 1")
        }
        // llama-server's `embd_normalize`: -1 leaves the vectors as the model pools them, 2 (the default) is L2.
        let normalize: Bool
        switch body["embd_normalize"]?.intValue ?? 2 {
        case -1: normalize = false
        case 2: normalize = true
        default: throw RequestError.invalid("\"embd_normalize\" must be -1 (none) or 2 (Euclidean)")
        }
        let id = try await modelID(body: body, request: request, task: .embedding)
        let activity = router.activity.begin(model: id, client: RequestClient(request))
        defer { activity.end() }

        let (vectors, tokenCount) = try await router.withEngine(id) { engine in
            guard let engine = engine as? any EmbeddingEngine else {
                throw RequestError.invalid("model '\(id)' can't make embeddings")
            }
            let contextSize = await engine.info().contextSize
            var tokenized: [[Int]] = []
            for (index, input) in inputs.enumerated() {
                let tokens = switch input {
                case let .text(text): try await engine.tokenize(text, addSpecial: true, parseSpecial: true)
                case let .tokens(tokens): tokens
                }
                guard !tokens.isEmpty else { throw RequestError.invalid("input \(index) is empty") }
                guard contextSize <= 0 || tokens.count <= contextSize else {
                    throw RequestError.invalid(
                        "input \(index) is \(tokens.count) tokens, more than the \(contextSize) this model is "
                            + "loaded with; shorten it, or raise the model's context size"
                    )
                }
                tokenized.append(tokens)
            }
            let total = tokenized.reduce(0) { $0 + $1.count }
            activity.accepted(promptTokens: total)
            let vectors = try await engine.embed(tokenized, normalize: normalize && dimensions == nil)
            return (vectors, total)
        }
        // Matryoshka models are trained so a prefix of the vector is itself a good embedding; it's normalized
        // again after cutting, as OpenAI's `dimensions` returns unit vectors.
        let shaped = vectors.map { vector -> [Float] in
            guard let dimensions else { return vector }
            let cut = Array(vector.prefix(dimensions))
            return normalize ? Self.normalized(cut) : cut
        }
        return .json(200, EmbeddingsJSON(
            model: id,
            data: shaped.enumerated().map { index, vector in
                EmbeddingsJSON.Item(
                    embedding: base64 ? .base64(Self.base64(vector)) : .floats(vector),
                    index: index
                )
            },
            usage: .init(promptTokens: tokenCount, totalTokens: tokenCount)
        ))
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { Float(Double($0) / norm) }
    }

    /// The vector's float32s, little-endian, as OpenAI's `encoding_format: "base64"` sends them.
    static func base64(_ vector: [Float]) -> String {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }

    // MARK: /v1/rerank

    func rerank(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try jsonBody(request)
        guard let query = body["query"]?.stringValue else {
            throw RequestError.invalid("\"query\" must be provided, as a string")
        }
        // TEI sends `texts` and gets a bare array back; Jina and Cohere send `documents`.
        let tei = body["texts"] != nil
        let items = (body["documents"] ?? body["texts"])?.arrayValue ?? []
        let documents = items.compactMap { $0.stringValue ?? $0["text"]?.stringValue }
        guard !documents.isEmpty, documents.count == items.count else {
            throw RequestError.invalid("\"documents\" must be a non-empty array of strings")
        }
        let topN = body["top_n"]?.intValue ?? documents.count
        let returnText = tei ? body["return_text"]?.boolValue ?? false
            : body["return_documents"]?.boolValue ?? false
        let id = try await modelID(body: body, request: request, task: .rerank)
        let activity = router.activity.begin(model: id, client: RequestClient(request))
        defer { activity.end() }

        let scores = try await router.withEngine(id) { engine in
            guard let engine = engine as? any EmbeddingEngine else {
                throw RequestError.invalid("model '\(id)' can't rerank")
            }
            let scores = try await engine.rerank(query: query, documents: documents)
            activity.accepted(promptTokens: scores.reduce(0) { $0 + $1.tokens })
            return scores
        }
        let ranked = scores.enumerated()
            .sorted { $0.element.score > $1.element.score }
            .prefix(max(0, topN))
            .map { index, score in
                RerankJSON.Result(
                    index: index, score: score.score, text: returnText ? documents[index] : nil, tei: tei
                )
            }
        if tei {
            return .json(200, ranked)
        }
        let tokens = scores.reduce(0) { $0 + $1.tokens }
        return .json(200, RerankJSON(
            model: id, results: ranked, usage: .init(promptTokens: tokens, totalTokens: tokens)
        ))
    }
}

/// OpenAI's embeddings response, as llama-server writes it.
struct EmbeddingsJSON: Encodable {
    struct Item: Encodable {
        enum Vector {
            case floats([Float])
            case base64(String)
        }

        let embedding: Vector
        let index: Int

        enum CodingKeys: String, CodingKey {
            case embedding, index, object
            case encodingFormat = "encoding_format"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch embedding {
            case let .floats(values):
                try container.encode(values, forKey: .embedding)
            case let .base64(text):
                try container.encode(text, forKey: .embedding)
                try container.encode("base64", forKey: .encodingFormat)
            }
            try container.encode(index, forKey: .index)
            try container.encode("embedding", forKey: .object)
        }
    }

    struct Usage: Encodable {
        let promptTokens: Int
        let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case totalTokens = "total_tokens"
        }
    }

    let model: String
    let object = "list"
    let data: [Item]
    let usage: Usage
}

/// llama-server's rerank response: Jina's shape (`relevance_score`), or TEI's bare array (`score`) when the request
/// sent `texts`.
struct RerankJSON: Encodable {
    struct Result: Encodable {
        let index: Int
        let score: Double
        let text: String?
        let tei: Bool

        enum CodingKeys: String, CodingKey {
            case index, score, text, document
            case relevanceScore = "relevance_score"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(index, forKey: .index)
            try container.encode(score, forKey: tei ? .score : .relevanceScore)
            if let text {
                if tei {
                    try container.encode(text, forKey: .text)
                } else {
                    try container.encode(["text": text], forKey: .document)
                }
            }
        }
    }

    let model: String
    let object = "list"
    let results: [Result]
    let usage: EmbeddingsJSON.Usage
}
