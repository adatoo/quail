import Foundation
import Testing
@testable import QuailServerCore

/// A stand-in embedding engine: a token per word (its length), a vector of `[token count, 1, 0, 0]`, and a rerank
/// score of the words a document shares with the query.
private struct FakeEmbeddingEngine: EmbeddingEngine {
    var contextSize = 16

    func load(_: ModelEntry) async throws {}
    func unload() async {}

    func tokenize(_ text: String, addSpecial _: Bool, parseSpecial _: Bool) async throws -> [Int] {
        text.split(separator: " ").map(\.count)
    }

    func detokenize(_ tokens: [Int]) async throws -> String {
        tokens.map(String.init).joined(separator: " ")
    }

    func info() async -> EngineInfo {
        EngineInfo(contextSize: contextSize, bosToken: "", eosToken: "")
    }

    func embed(_ inputs: [[Int]], normalize: Bool) async throws -> [[Float]] {
        inputs.map { tokens in
            let vector: [Float] = [Float(tokens.count), 1, 0, 0]
            return normalize ? InferenceRoutes.normalized(vector) : vector
        }
    }

    func rerank(query: String, documents: [String]) async throws -> [RerankScore] {
        let words = Set(query.lowercased().split(separator: " "))
        return documents.map { document in
            let shared = document.lowercased().split(separator: " ").filter { words.contains($0) }.count
            return RerankScore(score: Double(shared), tokens: query.split(separator: " ").count + shared)
        }
    }
}

@Suite("/v1/embeddings and /v1/rerank")
struct EmbeddingRoutesTests {
    private let routes: ServerRoutes

    init() {
        var embedder = ModelEntry.fake("Embedder")
        embedder.task = .embedding
        var reranker = ModelEntry.fake("Reranker")
        reranker.task = .rerank
        let log = ServerLog(toStandardError: false)
        let world = ScriptedWorld()
        let router = ModelRouter(
            entries: [.fake("Chat"), embedder, reranker],
            modelsMax: 1,
            makeEngine: { entry in
                entry.task == .chat ? ScriptedEngine(world: world) as any Engine : FakeEmbeddingEngine()
            },
            log: log
        )
        routes = ServerRoutes(router: router, apiKey: nil, log: log, buildLabel: "test", webUI: false)
    }

    private func post(_ path: String, _ body: String) async -> (status: Int, json: Any?) {
        let response = await routes.handle(HTTPRequest(
            method: "POST", target: path, headers: [:], body: Data(body.utf8)
        ))
        guard case let .data(data) = response.body else { return (response.status, nil) }
        return (response.status, try? JSONSerialization.jsonObject(with: data))
    }

    private func vectors(_ json: Any?) -> [[Double]] {
        let data = (json as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return data.map { $0["embedding"] as? [Double] ?? [] }
    }

    @Test("every shape of input, in order, with the tokens counted")
    func inputShapes() async {
        let (status, json) = await post(
            "/v1/embeddings", #"{"model": "Embedder", "input": ["one two three", "four", [5, 6]]}"#
        )
        #expect(status == 200)
        let object = json as? [String: Any]
        #expect(object?["object"] as? String == "list")
        #expect(object?["model"] as? String == "Embedder")
        let data = object?["data"] as? [[String: Any]] ?? []
        #expect(data.map { $0["index"] as? Int } == [0, 1, 2])
        #expect(data.allSatisfy { $0["object"] as? String == "embedding" })
        // The first coordinate is the input's token count, before normalizing.
        let lengths = vectors(json).map { vector in vector[0] / vector[1] }
        #expect(lengths.map { $0.rounded() } == [3, 1, 2])
        let usage = object?["usage"] as? [String: Int]
        #expect(usage?["prompt_tokens"] == 6)
        #expect(usage?["total_tokens"] == 6)

        let single = await post("/v1/embeddings", #"{"model": "Embedder", "input": "hello there"}"#)
        #expect(vectors(single.json).count == 1)
        let tokens = await post("/v1/embeddings", #"{"model": "Embedder", "input": [1, 2, 3, 4]}"#)
        #expect(vectors(tokens.json).count == 1)
        #expect(vectors(tokens.json).first.map { ($0[0] / $0[1]).rounded() } == 4)
    }

    @Test("vectors are unit length unless asked not to be, and base64 is their float32 bytes")
    func normalizationAndBase64() async throws {
        let plain = await post("/v1/embeddings", #"{"model": "Embedder", "input": "a b c"}"#)
        let vector = try #require(vectors(plain.json).first)
        #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 1e-6)

        let raw = await post("/v1/embeddings", #"{"model": "Embedder", "input": "a b c", "embd_normalize": -1}"#)
        #expect(vectors(raw.json).first == [3, 1, 0, 0])

        let encoded = await post(
            "/v1/embeddings",
            #"{"model": "Embedder", "input": "a b c", "encoding_format": "base64"}"#
        )
        let item = try #require(((encoded.json as? [String: Any])?["data"] as? [[String: Any]])?.first)
        #expect(item["encoding_format"] as? String == "base64")
        let bytes = try #require(Data(base64Encoded: item["embedding"] as? String ?? ""))
        // Little-endian float32s, which is this Mac's own order.
        let floats: [Float] = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(zip(floats, vector).allSatisfy { abs(Double($0) - $1) < 1e-6 })
    }

    @Test("dimensions cuts each vector and makes it unit length again")
    func dimensions() async {
        let (status, json) = await post("/v1/embeddings", #"{"model": "Embedder", "input": "a b c", "dimensions": 1}"#)
        #expect(status == 200)
        #expect(vectors(json).first == [1])
    }

    @Test("bad requests are refused with a reason")
    func badRequests() async {
        let cases = [
            #"{"model": "Embedder"}"#,
            #"{"model": "Embedder", "input": "a", "encoding_format": "hex"}"#,
            #"{"model": "Embedder", "input": "a", "dimensions": 0}"#,
            #"{"model": "Embedder", "input": "a", "embd_normalize": 1}"#,
            #"{"model": "Embedder", "input": [{"a": 1}]}"#,
            #"{"model": "Embedder", "input": ""}"#,
            // Longer than the 16 tokens the fake model holds.
            #"{"model": "Embedder", "input": "\#(Array(repeating: "w", count: 17).joined(separator: " "))"}"#,
        ]
        for body in cases {
            let (status, json) = await post("/v1/embeddings", body)
            #expect(status == 400, "\(body)")
            #expect(((json as? [String: Any])?["error"] as? [String: Any])?["message"] != nil)
        }
    }

    @Test("a model of another task is sent to its own route")
    func wrongTask() async {
        let chat = await post("/v1/embeddings", #"{"model": "Chat", "input": "a"}"#)
        #expect(chat.status == 400)
        let message = (((chat.json as? [String: Any])?["error"] as? [String: Any])?["message"] as? String) ?? ""
        #expect(message.contains("/v1/chat/completions"))
        let reranker = await post("/v1/embeddings", #"{"model": "Reranker", "input": "a"}"#)
        #expect(reranker.status == 400)
        let embedder = await post("/v1/rerank", #"{"model": "Embedder", "query": "a", "documents": ["a"]}"#)
        #expect(embedder.status == 400)
    }

    @Test("rerank answers best first in Jina's shape, honouring top_n and return_documents")
    func rerankJina() async {
        let body = #"""
        {"model": "Reranker", "query": "capital of France", "top_n": 2, "return_documents": true,
         "documents": ["bananas are yellow", "Paris is the capital of France", "France is in Europe"]}
        """#
        let (status, json) = await post("/v1/rerank", body)
        #expect(status == 200)
        let object = json as? [String: Any]
        let results = object?["results"] as? [[String: Any]] ?? []
        #expect(results.map { $0["index"] as? Int } == [1, 2])
        #expect(results.map { $0["relevance_score"] as? Double } == [3, 1])
        #expect((results.first?["document"] as? [String: String])?["text"] == "Paris is the capital of France")
        #expect((object?["usage"] as? [String: Int])?["prompt_tokens"] == 13)
        // llama-server's other paths answer the same.
        for path in ["/rerank", "/v1/reranking", "/reranking"] {
            #expect(await post(path, body).status == 200)
        }
    }

    @Test("rerank answers TEI's bare array when sent texts")
    func rerankTEI() async {
        let body = #"{"model": "Reranker", "query": "capital", "texts": ["no", "the capital"], "return_text": true}"#
        let (status, json) = await post("/v1/rerank", body)
        #expect(status == 200)
        let results = json as? [[String: Any]] ?? []
        #expect(results.map { $0["index"] as? Int } == [1, 0])
        #expect(results.first?["score"] as? Double == 1)
        #expect(results.first?["text"] as? String == "the capital")
    }

    @Test("rerank refuses a request without a query or documents")
    func rerankBadRequests() async {
        for body in [
            #"{"model": "Reranker", "documents": ["a"]}"#,
            #"{"model": "Reranker", "query": "a", "documents": []}"#,
            #"{"model": "Reranker", "query": "a", "documents": [1]}"#,
        ] {
            #expect(await post("/v1/rerank", body).status == 400, "\(body)")
        }
    }
}
