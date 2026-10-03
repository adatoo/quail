import Foundation
import llama
import QuailServerCore

/// The GGUF engine for models that don't chat (ADR D-072, #181): an embedding model's pooled vectors and a
/// reranker's scores, through libllama's embedding mode, as llama-server's `--embeddings` and `--reranking` do. One
/// instance holds one model; its blocking C calls run on one queue of its own. Requests are served one batch at a
/// time: an embedding is one forward pass, so there's nothing to interleave.
public struct LlamaEmbeddingEngine: EmbeddingEngine {
    private let runtime = LlamaEmbeddingRuntime()

    public init() {}

    public func load(_ model: ModelEntry) async throws {
        try await runtime.run { try $0.load(model) }
    }

    public func unload() async {
        try? await runtime.run { $0.unload() }
    }

    public func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) async throws -> [Int] {
        try await runtime.run { runtime in
            guard let vocab = runtime.vocab else { throw EngineError.notLoaded }
            return try LlamaVocab.tokenize(text, in: vocab, addSpecial: addSpecial, parseSpecial: parseSpecial)
        }
    }

    public func detokenize(_ tokens: [Int]) async throws -> String {
        try await runtime.run { runtime in
            guard let vocab = runtime.vocab else { throw EngineError.notLoaded }
            return LlamaVocab.detokenize(tokens, in: vocab)
        }
    }

    public func info() async -> EngineInfo {
        await (try? runtime.run { $0.info }) ?? EngineInfo(contextSize: 0, bosToken: "", eosToken: "")
    }

    public func embed(_ inputs: [[Int]], normalize: Bool) async throws -> [[Float]] {
        try await runtime.run { try $0.embed(inputs, normalize: normalize) }
    }

    public func rerank(query: String, documents: [String]) async throws -> [RerankScore] {
        try await runtime.run { try $0.rerank(query: query, documents: documents) }
    }
}

/// The loaded model and its context. Every member runs on `queue`.
final class LlamaEmbeddingRuntime: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.datoos.quail.llama-embedding", qos: .userInitiated)

    var model: OpaquePointer?
    var context: OpaquePointer?
    var vocab: OpaquePointer?
    var batch: llama_batch?
    /// Tokens one forward pass takes (`n_batch`, which is `n_ubatch` here: an encoder sees a whole input at once).
    var batchSize = 0
    /// Inputs one forward pass takes, each its own sequence.
    var sequences = 0
    /// A T5-style encoder runs through `llama_encode`; everything else, BERT included, through `llama_decode`.
    var encoderOnly = false
    private(set) var info = EngineInfo(contextSize: 0, bosToken: "", eosToken: "")

    /// The context asked for when the preset doesn't say: the model's own, up to this. An input longer than the
    /// context is refused, as llama-server refuses one longer than its batch.
    static let defaultContext = 8192
    /// Inputs batched into one forward pass at most.
    static let maxSequences = 32

    deinit {
        queue.sync { unload() }
    }

    func run<T: Sendable>(_ work: @escaping @Sendable (LlamaEmbeddingRuntime) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try continuation.resume(returning: work(self))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Load

    func load(_ entry: ModelEntry) throws {
        unload()
        _ = Backend.started
        guard FileManager.default.fileExists(atPath: entry.path.path) else {
            throw EngineError.loadFailed("the model file \(entry.path.path) doesn't exist")
        }
        var modelParams = llama_model_default_params()
        if let layers = entry.gpuLayers {
            modelParams.n_gpu_layers = Int32(layers)
        }
        guard let loaded = llama_model_load_from_file(entry.path.path, modelParams) else {
            throw EngineError.loadFailed(
                "llama.cpp couldn't load \(entry.path.lastPathComponent) (not a GGUF file, an architecture this "
                    + "llama.cpp doesn't know, or not enough memory)"
            )
        }
        let trained = Int(llama_model_n_ctx_train(loaded))
        let wanted = max(
            entry.contextSize ?? min(trained > 0 ? trained : Self.defaultContext, Self.defaultContext), 64
        )

        var params = llama_context_default_params()
        params.embeddings = true
        params.pooling_type = Self.poolingType(entry.pooling, task: entry.task)
        params.n_ctx = UInt32(wanted)
        // One pass holds whole inputs: an encoder attends over all of an input at once, so it can't be split.
        params.n_batch = UInt32(wanted)
        params.n_ubatch = UInt32(wanted)
        params.n_seq_max = UInt32(min(Self.maxSequences, Int(llama_max_parallel_sequences())))
        params.kv_unified = true
        let threads = Int32(LlamaRuntime.performanceCores)
        params.n_threads = threads
        params.n_threads_batch = threads
        guard let made = llama_init_from_model(loaded, params) else {
            llama_model_free(loaded)
            throw EngineError.loadFailed(
                "llama.cpp couldn't create a \(wanted)-token embedding context for \(entry.path.lastPathComponent); "
                    + "try a smaller context size"
            )
        }
        let pooling = llama_pooling_type(made)
        if pooling == LLAMA_POOLING_TYPE_NONE {
            llama_free(made)
            llama_model_free(loaded)
            throw EngineError.loadFailed(
                "\(entry.path.lastPathComponent) doesn't say how to pool its vectors into one; set its pooling "
                    + "(mean, cls or last) in the model's settings"
            )
        }
        if entry.task == .rerank, pooling != LLAMA_POOLING_TYPE_RANK {
            llama_free(made)
            llama_model_free(loaded)
            throw EngineError.loadFailed("\(entry.path.lastPathComponent) isn't a reranker: it has no ranking head")
        }
        model = loaded
        context = made
        vocab = llama_model_get_vocab(loaded)
        encoderOnly = llama_model_has_encoder(loaded) && !llama_model_has_decoder(loaded)
        batchSize = Int(llama_n_batch(made))
        sequences = Int(llama_n_seq_max(made))
        batch = llama_batch_init(Int32(batchSize), 0, Int32(sequences))
        info = EngineInfo(
            contextSize: Int(llama_n_ctx(made)),
            bosToken: LlamaVocab.text(of: llama_vocab_bos(vocab), in: vocab),
            eosToken: LlamaVocab.text(of: llama_vocab_eos(vocab), in: vocab)
        )
    }

    static func poolingType(_ pooling: PoolingType?, task: ModelTask) -> llama_pooling_type {
        switch pooling {
        case .none?: LLAMA_POOLING_TYPE_NONE
        case .mean?: LLAMA_POOLING_TYPE_MEAN
        case .cls?: LLAMA_POOLING_TYPE_CLS
        case .last?: LLAMA_POOLING_TYPE_LAST
        case .rank?: LLAMA_POOLING_TYPE_RANK
        // The model's own, or a reranker's head when its header doesn't say (gpustack's bge-reranker-v2-m3).
        case nil: task == .rerank ? LLAMA_POOLING_TYPE_RANK : LLAMA_POOLING_TYPE_UNSPECIFIED
        }
    }

    func unload() {
        if let batch {
            llama_batch_free(batch)
        }
        batch = nil
        if let context {
            llama_free(context)
        }
        if let model {
            llama_model_free(model)
        }
        context = nil
        model = nil
        vocab = nil
        info = EngineInfo(contextSize: 0, bosToken: "", eosToken: "")
    }

    // MARK: Embedding

    /// Pools each input into one vector: as many inputs per forward pass as fit the batch, each its own sequence,
    /// read back with `llama_get_embeddings_seq`, as llama.cpp's embedding example does.
    func embed(_ inputs: [[Int]], normalize: Bool) throws -> [[Float]] {
        guard let model else { throw EngineError.notLoaded }
        let width = Int(llama_model_n_embd_out(model))
        return try forward(inputs, width: width).map { normalize ? Self.l2Normalized($0) : $0 }
    }

    /// A reranker scores each document joined to the query, the way llama-server joins them: the model's own
    /// `rerank` template when its GGUF has one (Qwen3-Reranker), or else `[BOS] query [EOS] [SEP] document [EOS]`
    /// with the tokens the vocabulary says to add. The score is the ranking head's first output, unscaled, as
    /// llama-server returns it.
    func rerank(query: String, documents: [String]) throws -> [RerankScore] {
        guard let model, let vocab, let context else { throw EngineError.notLoaded }
        guard llama_pooling_type(context) == LLAMA_POOLING_TYPE_RANK else {
            throw EngineError.invalidRequest("this model isn't loaded as a reranker")
        }
        let template = llama_model_chat_template(model, "rerank").map { String(cString: $0) }
        let inputs = try documents.map { document -> [Int] in
            if let template {
                let prompt = template.replacingOccurrences(of: "{query}", with: query)
                    .replacingOccurrences(of: "{document}", with: document)
                return try LlamaVocab.tokenize(prompt, in: vocab, addSpecial: false, parseSpecial: true)
            }
            var eos = llama_vocab_eos(vocab)
            if eos == LLAMA_TOKEN_NULL {
                eos = llama_vocab_sep(vocab)
            }
            var tokens: [Int] = []
            if llama_vocab_get_add_bos(vocab) {
                tokens.append(Int(llama_vocab_bos(vocab)))
            }
            tokens += try LlamaVocab.tokenize(query, in: vocab, addSpecial: false, parseSpecial: false)
            if llama_vocab_get_add_eos(vocab) {
                tokens.append(Int(eos))
            }
            if llama_vocab_get_add_sep(vocab) {
                tokens.append(Int(llama_vocab_sep(vocab)))
            }
            tokens += try LlamaVocab.tokenize(document, in: vocab, addSpecial: false, parseSpecial: false)
            if llama_vocab_get_add_eos(vocab) {
                tokens.append(Int(eos))
            }
            return tokens
        }
        for (index, tokens) in inputs.enumerated() where tokens.count > batchSize {
            throw EngineError.invalidRequest(
                "document \(index) and the query come to \(tokens.count) tokens, more than the \(batchSize) this "
                    + "model is loaded with; shorten it, or raise the model's context size"
            )
        }
        return try zip(forward(inputs, width: 1), inputs).map { output, tokens in
            RerankScore(score: Double(output[0]), tokens: tokens.count)
        }
    }

    /// Runs the inputs through the model, packed into as few passes as fit, and returns the first `width` floats of
    /// each one's pooled output.
    private func forward(_ inputs: [[Int]], width: Int) throws -> [[Float]] {
        guard let context, var batch else { throw EngineError.notLoaded }
        defer { self.batch = batch }
        var outputs: [[Float]] = Array(repeating: [], count: inputs.count)
        var start = 0
        while start < inputs.count {
            // Pack inputs while they fit.
            var end = start
            var tokens = 0
            while end < inputs.count, end - start < sequences, tokens + inputs[end].count <= batchSize {
                tokens += inputs[end].count
                end += 1
            }
            guard end > start else {
                throw EngineError.invalidRequest(
                    "input \(start) is \(inputs[start].count) tokens, more than the \(batchSize) this model is "
                        + "loaded with"
                )
            }
            llama_memory_clear(llama_get_memory(context), true)
            var count: Int32 = 0
            for (sequence, index) in (start ..< end).enumerated() {
                for (position, token) in inputs[index].enumerated() {
                    let i = Int(count)
                    batch.token[i] = llama_token(truncatingIfNeeded: token)
                    batch.pos[i] = llama_pos(position)
                    batch.n_seq_id[i] = 1
                    batch.seq_id[i]![0] = llama_seq_id(sequence)
                    batch.logits[i] = 1
                    count += 1
                }
            }
            batch.n_tokens = count
            let code = encoderOnly ? llama_encode(context, batch) : llama_decode(context, batch)
            guard code == 0 else {
                throw EngineError.generationFailed("llama.cpp couldn't run the model (error \(code))")
            }
            for (sequence, index) in (start ..< end).enumerated() {
                guard let pooled = llama_get_embeddings_seq(context, llama_seq_id(sequence)) else {
                    throw EngineError.generationFailed("llama.cpp returned no embedding for input \(index)")
                }
                outputs[index] = Array(UnsafeBufferPointer(start: pooled, count: width))
            }
            start = end
        }
        return outputs
    }

    static func l2Normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { Float(Double($0) / norm) }
    }
}
