import Foundation
import Testing
@testable import QuailServerCore
@testable import QuailServerLlama

/// The GGUF embedding engine on real models, when they're given: an embedding model in `QUAIL_TEST_EMBED_MODEL`
/// (Qwen3-Embedding 0.6B or nomic-embed v1.5, say) and a reranker in `QUAIL_TEST_RERANK_MODEL` (bge-reranker-v2-m3 or
/// Qwen3-Reranker). Their vectors were also checked against llama-server b11306's for the same files: the same to
/// a cosine of 1.0 (ADR D-072).
@Suite("LlamaEmbeddingEngine", .timeLimit(.minutes(2)))
struct LlamaEmbeddingEngineTests {
    private static func model(_ variable: String) -> URL? {
        ProcessInfo.processInfo.environment[variable].map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private static let embedModel = model("QUAIL_TEST_EMBED_MODEL")
    private static let rerankModel = model("QUAIL_TEST_RERANK_MODEL")

    @Test(
        "vectors are unit length, and a related text is nearer than an unrelated one",
        .enabled(if: embedModel != nil)
    )
    func embeds() async throws {
        let engine = LlamaEmbeddingEngine()
        var entry = try ModelEntry(id: "embed", kind: .gguf, path: #require(Self.embedModel))
        entry.task = .embedding
        try await engine.load(entry)
        let texts = [
            "What is the capital of France?", "Paris is the capital and largest city of France.",
            "Bananas are rich in potassium.",
        ]
        var inputs: [[Int]] = []
        for text in texts {
            try await inputs.append(engine.tokenize(text, addSpecial: true, parseSpecial: true))
        }
        let vectors = try await engine.embed(inputs, normalize: true)
        func dot(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        }
        #expect(vectors.count == 3)
        #expect(vectors.allSatisfy { abs(dot($0, $0) - 1) < 1e-4 })
        #expect(dot(vectors[0], vectors[1]) > dot(vectors[0], vectors[2]))
        // One at a time gives what a batch gives.
        let alone = try await engine.embed([inputs[1]], normalize: true)
        #expect(dot(alone[0], vectors[1]) > 0.9999)
        await engine.unload()
    }

    @Test("a reranker scores the answering document highest", .enabled(if: rerankModel != nil))
    func reranks() async throws {
        let engine = LlamaEmbeddingEngine()
        var entry = try ModelEntry(id: "rerank", kind: .gguf, path: #require(Self.rerankModel))
        entry.task = .rerank
        try await engine.load(entry)
        let scores = try await engine.rerank(
            query: "What is the capital of France?",
            documents: ["Bananas are yellow.", "Paris is the capital of France.", "France is in Europe."]
        )
        #expect(scores.count == 3)
        #expect(scores.map(\.score).max() == scores[1].score)
        #expect(scores.allSatisfy { $0.tokens > 0 })
        await engine.unload()
    }
}
