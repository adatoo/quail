import Foundation
import llama
import QuailServerCore

/// The GGUF engine: `libllama` behind the `Engine` seam (ADR D-043). One instance holds one loaded
/// model, and its blocking C calls all run on one dedicated queue, never on Swift's cooperative pool.
public struct LlamaEngine: Engine {
    private let runtime = LlamaRuntime()

    public init() {}

    public var capabilities: EngineCapabilities {
        EngineCapabilities(extraSamplers: true)
    }

    public func load(_ model: ModelEntry) async throws {
        try await runtime.run { try $0.load(model) }
    }

    public func unload() async {
        try? await runtime.run { $0.unload() }
    }

    public func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) async throws -> [Int] {
        try await runtime.run { try $0.tokenize(text, addSpecial: addSpecial, parseSpecial: parseSpecial) }
    }

    public func detokenize(_ tokens: [Int]) async throws -> String {
        try await runtime.run { try $0.detokenize(tokens) }
    }

    public func info() async -> EngineInfo {
        await (try? runtime.run { $0.info }) ?? EngineInfo(contextSize: 0, bosToken: "", eosToken: "")
    }

    public func chatTemplate() async -> String? {
        try? await runtime.run { $0.chatTemplate }
    }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        let runtime = runtime
        return AsyncThrowingStream { continuation in
            let cancelled = CancelFlag()
            runtime.enqueue {
                do {
                    try $0.generate(request, cancelled: cancelled) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // The consumer going away (the client left, or a stop string matched) stops decoding
            // at the next token or prompt batch.
            continuation.onTermination = { _ in cancelled.set() }
        }
    }
}

/// Set once from any thread, read by the decode loop.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}

/// Backend start-up, once per process, and the log filter: llama.cpp is chatty at info level, and the
/// server's own log is where a user looks, so only warnings and errors get through.
private enum Backend {
    static let started: Void = {
        // The filter goes in first: ggml's Metal set-up logs from `llama_backend_init` itself.
        if ProcessInfo.processInfo.environment["QUAIL_LLAMA_VERBOSE"] == nil {
            let filter: ggml_log_callback = { level, text, _ in
                guard let text, LogFilter.shared.allows(level) else { return }
                FileHandle.standardError.write(Data((LogFilter.shared.prefix(for: level) + String(cString: text)).utf8))
            }
            llama_log_set(filter, nil)
            ggml_log_set(filter, nil)
        }
        llama_backend_init()
    }()
}

/// Lets warnings and errors through, with the continuation lines that belong to them (llama.cpp
/// prints one message as several calls, the later ones at a "continue" level).
private final class LogFilter: @unchecked Sendable {
    static let shared = LogFilter()
    private let lock = NSLock()
    private var showing = false

    func allows(_ level: ggml_log_level) -> Bool {
        lock.withLock {
            switch level {
            case GGML_LOG_LEVEL_WARN, GGML_LOG_LEVEL_ERROR: showing = true
            case GGML_LOG_LEVEL_CONT: break
            default: showing = false
            }
            return showing
        }
    }

    func prefix(for level: ggml_log_level) -> String {
        level == GGML_LOG_LEVEL_CONT ? "" : "llama.cpp: "
    }
}

/// The loaded model and everything that touches it. Every member runs on `queue`.
final class LlamaRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.datoos.quail.llama", qos: .userInitiated)

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    /// The tokens whose keys and values are in the context's memory, for prompt-prefix reuse.
    private var cached: [Int32] = []
    private var batchSize = 512

    private(set) var info = EngineInfo(contextSize: 0, bosToken: "", eosToken: "")
    private(set) var chatTemplate: String?

    /// The context asked for when a model doesn't say: llama-server's own default is the model's
    /// full training context, which for a modern model is a KV cache of many gigabytes.
    static let defaultContext = 32768

    deinit {
        // Only reached if the engine is dropped without `unload`.
        queue.sync { unload() }
    }

    func run<T: Sendable>(_ work: @escaping @Sendable (LlamaRuntime) throws -> T) async throws -> T {
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

    func enqueue(_ work: @escaping @Sendable (LlamaRuntime) -> Void) {
        queue.async { work(self) }
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
        let wanted = entry.contextSize ?? min(trained > 0 ? trained : Self.defaultContext, Self.defaultContext)

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(max(wanted, 256))
        contextParams.n_seq_max = 1
        guard let made = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            throw EngineError.loadFailed(
                "llama.cpp couldn't create a \(wanted)-token context for \(entry.path.lastPathComponent); "
                    + "try a smaller context size or another model"
            )
        }
        model = loaded
        context = made
        vocab = llama_model_get_vocab(loaded)
        cached = []
        batchSize = max(1, Int(llama_n_batch(made)))
        info = EngineInfo(
            contextSize: Int(llama_n_ctx(made)),
            bosToken: text(of: llama_vocab_bos(vocab)),
            eosToken: text(of: llama_vocab_eos(vocab))
        )
        chatTemplate = llama_model_chat_template(loaded, nil).map { String(cString: $0) }
    }

    func unload() {
        if let context {
            llama_free(context)
        }
        if let model {
            llama_model_free(model)
        }
        context = nil
        model = nil
        vocab = nil
        cached = []
    }

    private func text(of token: llama_token) -> String {
        guard token >= 0, let piece = llama_vocab_get_text(vocab, token) else { return "" }
        return String(cString: piece)
    }

    // MARK: Text and tokens

    func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) throws -> [Int] {
        guard let vocab else { throw EngineError.notLoaded }
        let bytes = Array(text.utf8)
        var tokens = [llama_token](repeating: 0, count: max(16, bytes.count / 2 + 8))
        var count = llama_tokenize(
            vocab, bytes.map { CChar(bitPattern: $0) }, Int32(bytes.count),
            &tokens, Int32(tokens.count), addSpecial, parseSpecial
        )
        if count < 0, count != .min {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(
                vocab, bytes.map { CChar(bitPattern: $0) }, Int32(bytes.count),
                &tokens, Int32(tokens.count), addSpecial, parseSpecial
            )
        }
        guard count >= 0 else { throw EngineError.generationFailed("the text is too long to tokenize") }
        return tokens.prefix(Int(count)).map(Int.init)
    }

    /// The text of tokens, special tokens included (what llama-server's `/detokenize` returns).
    func detokenize(_ tokens: [Int]) throws -> String {
        guard vocab != nil else { throw EngineError.notLoaded }
        var bytes: [UInt8] = []
        for token in tokens {
            bytes += piece(of: llama_token(truncatingIfNeeded: token))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// One token's bytes. A token can be part of a multi-byte character, so this is bytes, not text.
    private func piece(of token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }
        return buffer.prefix(max(0, Int(count))).map { UInt8(bitPattern: $0) }
    }

    // MARK: Generation

    func generate(
        _ request: GenerationRequest,
        cancelled: CancelFlag,
        emit: (GenerationEvent) -> Void
    ) throws {
        guard let context, let vocab else { throw EngineError.notLoaded }
        if cancelled.isSet {
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        let prompt = request.promptTokens.map { llama_token(truncatingIfNeeded: $0) }
        guard !prompt.isEmpty else { throw EngineError.generationFailed("the prompt has no tokens") }

        let reused = try prepareMemory(for: prompt, reuse: request.cachePrompt)
        // Decode what the cache doesn't have, in batches, so a client that leaves during a long
        // prompt stops it at the next batch rather than at the end.
        var position = reused
        while position < prompt.count {
            if cancelled.isSet {
                return
            }
            let end = min(position + batchSize, prompt.count)
            try decode(Array(prompt[position ..< end]))
            cached += prompt[position ..< end]
            position = end
        }
        let promptDone = clock.now

        let sampler = makeSampler(request)
        defer { llama_sampler_free(sampler) }
        // The samplers that look back (penalties, DRY) see the prompt too, as llama-server's do.
        for token in prompt {
            llama_sampler_accept(sampler, token)
        }
        var utf8 = UTF8Assembler()
        var produced = 0
        // llama-server counts the end-of-generation token that stopped a reply, though it sends no text.
        var counted = 0
        var reason = FinishReason.stop
        while true {
            if cancelled.isSet {
                return
            }
            let token = llama_sampler_sample(sampler, context, -1)
            if !request.ignoreEndOfSequence, llama_vocab_is_eog(vocab, token) {
                counted += 1
                break
            }
            produced += 1
            counted += 1
            emit(.token(id: Int(token), text: utf8.append(piece(of: token))))
            if produced >= request.maxTokens {
                reason = .length
                break
            }
            try decode([token])
            cached.append(token)
        }

        let done = clock.now
        emit(.finished(reason, GenerationTimings(
            promptTokens: prompt.count - reused,
            promptSeconds: (promptDone - started).seconds,
            generatedTokens: counted,
            generatedSeconds: (done - promptDone).seconds,
            cachedTokens: reused
        )))
    }

    /// Makes the context's memory hold a prefix of `prompt` and no more; returns how many tokens
    /// of it are there already. The last prompt token is always decoded afresh, because sampling
    /// needs its logits.
    private func prepareMemory(for prompt: [llama_token], reuse: Bool) throws -> Int {
        guard let context else { throw EngineError.notLoaded }
        let memory = llama_get_memory(context)
        var common = 0
        if reuse {
            let limit = min(cached.count, prompt.count - 1)
            while common < limit, cached[common] == prompt[common] {
                common += 1
            }
        }
        if common < cached.count {
            // A model whose memory can't drop a tail (recurrent, sliding-window) refuses; start over.
            if common == 0 || !llama_memory_seq_rm(memory, 0, llama_pos(common), -1) {
                llama_memory_clear(memory, true)
                cached = []
                return 0
            }
            cached = Array(cached[..<common])
        }
        return common
    }

    private func decode(_ tokens: [llama_token]) throws {
        guard let context else { throw EngineError.notLoaded }
        var tokens = tokens
        let code = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        switch code {
        case 0: break
        case 1: throw EngineError.generationFailed("the prompt and reply don't fit in the model's context")
        default: throw EngineError.generationFailed("llama.cpp failed to decode (code \(code))")
        }
    }

    /// llama-server's default order: penalties, DRY, top-n-sigma, top-k, typical-p, top-p, min-p, XTC,
    /// temperature, then the draw. Temperature 0 is greedy; mirostat, when asked for, replaces the
    /// truncation samplers and the draw, as it does there.
    private func makeSampler(_ request: GenerationRequest) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        let s = request.sampling
        let vocabSize = llama_vocab_n_tokens(vocab)
        let seed = s.seed.map { UInt32(truncatingIfNeeded: $0) } ?? UInt32.max // LLAMA_DEFAULT_SEED: random

        if request.ignoreEndOfSequence {
            // llama-server bans every end-of-generation token, so a fixed-length run really is one.
            let banned = (0 ..< vocabSize).filter { llama_vocab_is_eog(vocab, $0) }
                .map { llama_logit_bias(token: $0, bias: -.infinity) }
            llama_sampler_chain_add(chain, llama_sampler_init_logit_bias(vocabSize, Int32(banned.count), banned))
        }
        if s.repeatPenalty != 1 || s.presencePenalty != 0 || s.frequencyPenalty != 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(
                vocabSize, 64, Float(s.repeatPenalty), Float(s.frequencyPenalty), Float(s.presencePenalty)
            ))
        }
        if s.dryMultiplier > 0 {
            addDRY(s, to: chain)
        }
        if s.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else if s.mirostat != 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(s.temperature)))
            if s.mirostat == 1 {
                llama_sampler_chain_add(chain, llama_sampler_init_mirostat(
                    vocabSize, seed, Float(s.mirostatTau), Float(s.mirostatEta), 100
                ))
            } else {
                llama_sampler_chain_add(chain, llama_sampler_init_mirostat_v2(
                    seed, Float(s.mirostatTau), Float(s.mirostatEta)
                ))
            }
        } else {
            if s.topNSigma >= 0 {
                llama_sampler_chain_add(chain, llama_sampler_init_top_n_sigma(Float(s.topNSigma)))
            }
            if s.topK > 0 {
                llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(s.topK)))
            }
            if s.typicalP > 0, s.typicalP < 1 {
                llama_sampler_chain_add(chain, llama_sampler_init_typical(Float(s.typicalP), 1))
            }
            if s.topP < 1 {
                llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(s.topP), 1))
            }
            if s.minP > 0 {
                llama_sampler_chain_add(chain, llama_sampler_init_min_p(Float(s.minP), 1))
            }
            if s.xtcProbability > 0 {
                llama_sampler_chain_add(chain, llama_sampler_init_xtc(
                    Float(s.xtcProbability), Float(s.xtcThreshold), 1, seed
                ))
            }
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(s.temperature)))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))
        }
        return chain
    }

    private func addDRY(_ s: SamplingParameters, to chain: UnsafeMutablePointer<llama_sampler>) {
        // The C API takes an array of C strings that must stay alive for the call.
        let breakers = s.drySequenceBreakers.map { strdup($0) }
        defer { breakers.forEach { free($0) } }
        var pointers = breakers.map { UnsafePointer<CChar>($0) }
        llama_sampler_chain_add(chain, llama_sampler_init_dry(
            vocab, Float(s.dryMultiplier), Float(s.dryBase), Int32(s.dryAllowedLength),
            // The C API reads a negative window as none at all; the request's -1 means the whole context.
            s.dryPenaltyLastN < 0 ? Int32(info.contextSize) : Int32(s.dryPenaltyLastN), &pointers, pointers.count
        ))
    }
}

/// Turns a stream of token bytes into text, holding back the start of a character that a later
/// token finishes, so a client never sees half of one.
struct UTF8Assembler {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> String {
        pending += bytes
        let keep = Self.incompleteTail(pending)
        let ready = pending.dropLast(keep)
        let text = String(decoding: ready, as: UTF8.self)
        pending = Array(pending.suffix(keep))
        return text
    }

    /// How many bytes at the end are the start of a multi-byte character that isn't finished.
    static func incompleteTail(_ bytes: [UInt8]) -> Int {
        var seen = 0
        for byte in bytes.reversed().prefix(3) {
            seen += 1
            if byte & 0xC0 == 0x80 {
                continue // a continuation byte: the start is further back
            }
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return needed > seen ? seen : 0
        }
        return 0
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
