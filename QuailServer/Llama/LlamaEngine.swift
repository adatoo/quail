import Foundation
import llama
import QuailServerCore

/// The GGUF engine: `libllama` behind the `Engine` seam (ADR D-043). One instance holds one loaded
/// model, and its blocking C calls all run on one dedicated queue, never on Swift's cooperative pool.
public struct LlamaEngine: Engine {
    private let runtime: LlamaRuntime

    /// - Parameter parallel: how many requests are decoded together (slots); 1 serves one at a time (ADR D-048).
    public init(parallel: Int = 1) {
        runtime = LlamaRuntime(slotCount: max(1, parallel))
    }

    public var capabilities: EngineCapabilities {
        EngineCapabilities(extraSamplers: true, grammar: true, vision: true, concurrentRequests: true)
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

    /// How many slots are serving a request right now (for the tests and, later, `/slots`).
    func busySlots() async -> Int {
        await (try? runtime.run { $0.slots.filter { $0.job != nil }.count }) ?? 0
    }

    public func chatTemplate() async -> String? {
        try? await runtime.run { $0.chatTemplate }
    }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        let runtime = runtime
        return AsyncThrowingStream { continuation in
            let cancelled = CancelFlag()
            runtime.submit(
                request, cancelled: cancelled,
                emit: { continuation.yield($0) },
                finish: { error in
                    if let error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            )
            // The consumer going away (the client left, or a stop string matched) stops decoding
            // at the next step.
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
            mtmd_helper_log_set(filter, nil)
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
    let queue = DispatchQueue(label: "com.datoos.quail.llama", qos: .userInitiated)

    var model: OpaquePointer?
    var context: OpaquePointer?
    var vocab: OpaquePointer?
    /// libmtmd's context for the model's vision projector, if it has one.
    var vision: OpaquePointer?
    var batchSize = 512
    var threadPool: OpaquePointer?

    /// The requests being served, one per slot (a sequence of the context), and the batch they share.
    let slotCount: Int
    var slots: [Slot] = []
    var batch: llama_batch?
    /// Requests handed in from any thread, and whether a scheduler step is already queued.
    let incomingLock = NSLock()
    var incoming: [PendingRequest] = []
    var stepQueued = false
    /// Requests admitted from `incoming` that are waiting for a free slot, oldest first.
    var waiting: [PendingRequest] = []
    var tick: UInt64 = 0
    var rotor = 0

    init(slotCount: Int) {
        self.slotCount = slotCount
    }

    private(set) var info = EngineInfo(contextSize: 0, bosToken: "", eosToken: "")
    private(set) var chatTemplate: String?

    /// The context asked for when a model doesn't say: llama-server's own default is the model's
    /// full training context, which for a modern model is a KV cache of many gigabytes.
    static let defaultContext = 32768

    /// Performance cores (`hw.perflevel0.physicalcpu`), or the physical cores on a Mac without levels.
    static let performanceCores: Int = {
        for name in ["hw.perflevel0.physicalcpu", "hw.physicalcpu"] {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 {
                return Int(value)
            }
        }
        return 4
    }()

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
        contextParams.n_seq_max = UInt32(slotCount)
        // The slots share one pool of KV cells, so a lone long request can use all of the context (ADR D-048).
        contextParams.kv_unified = slotCount > 1
        // llama-server's default: one thread per performance core. The CPU still does the input embedding
        // lookup and the sampling with a model fully on the GPU, and libllama's own default is 4.
        let threads = Int32(Self.performanceCores)
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let made = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            throw EngineError.loadFailed(
                "llama.cpp couldn't create a \(wanted)-token context for \(entry.path.lastPathComponent); "
                    + "try a smaller context size or another model"
            )
        }
        model = loaded
        context = made
        // A thread pool that lives as long as the context, as llama-server keeps one: without it ggml makes a
        // fresh pool for every decode's CPU work (the input embedding lookup), which is per-token overhead.
        var poolParams = ggml_threadpool_params_default(threads)
        poolParams.poll = 50 // llama-server's default: spin briefly before sleeping
        threadPool = ggml_threadpool_new(&poolParams)
        if let threadPool {
            llama_attach_threadpool(made, threadPool, threadPool)
        }
        vocab = llama_model_get_vocab(loaded)
        batchSize = max(1, Int(llama_n_batch(made)))
        batch = llama_batch_init(Int32(batchSize), 0, 1)
        slots = (0 ..< slotCount).map { Slot(id: llama_seq_id($0)) }
        info = EngineInfo(
            contextSize: Int(llama_n_ctx(made)),
            bosToken: text(of: llama_vocab_bos(vocab)),
            eosToken: text(of: llama_vocab_eos(vocab)),
            slots: slotCount
        )
        chatTemplate = llama_model_chat_template(loaded, nil).map { String(cString: $0) }
        if let projector = entry.projector {
            try loadProjector(projector, model: loaded)
        }
    }

    /// A vision model's `mmproj` file. llama-server refuses to serve the model when this fails, and so do we: a
    /// model that's advertised as reading images and doesn't is worse than one that doesn't start.
    func loadProjector(_ path: URL, model: OpaquePointer) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            unload()
            throw EngineError.loadFailed("the vision projector \(path.path) doesn't exist")
        }
        var params = mtmd_context_params_default()
        params.print_timings = false
        guard let made = mtmd_init_from_file(path.path, model, params) else {
            unload()
            throw EngineError.loadFailed(
                "llama.cpp couldn't load the vision projector \(path.lastPathComponent) (it doesn't match the model, "
                    + "or isn't a projector for an architecture this llama.cpp knows)"
            )
        }
        guard mtmd_support_vision(made), String(cString: mtmd_get_marker(made)) == ImageInput.marker else {
            mtmd_free(made)
            unload()
            throw EngineError.loadFailed("the projector \(path.lastPathComponent) can't read images")
        }
        vision = made
        info.supportsImages = true
    }

    func unload() {
        failEverything(EngineError.notLoaded)
        if let batch {
            llama_batch_free(batch)
        }
        batch = nil
        slots = []
        if let vision {
            mtmd_free(vision)
        }
        vision = nil
        if let context {
            llama_free(context)
        }
        if let threadPool {
            ggml_threadpool_free(threadPool)
        }
        threadPool = nil
        if let model {
            llama_model_free(model)
        }
        context = nil
        model = nil
        vocab = nil
    }

    func text(of token: llama_token) -> String {
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
    func piece(of token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }
        return buffer.prefix(max(0, Int(count))).map { UInt8(bitPattern: $0) }
    }

    // MARK: Generation

    /// Tokenizes a prompt that has images (text chunks and image chunks, by libmtmd) and evaluates it into
    /// the empty context, chunk by chunk so a client that leaves stops it between chunks. Returns the text
    /// tokens (for the samplers that look back) and the prompt's total size in tokens, or nil if cancelled.
    func evaluateImagePrompt(
        _ request: GenerationRequest, sequence: llama_seq_id
    ) throws -> (textTokens: [llama_token], total: Int, next: llama_pos) {
        guard let vision, let context else { throw EngineError.invalidRequest("this model can't read images") }
        guard let text = request.promptText
        else { throw EngineError.invalidRequest("an image request needs its prompt text") }

        var bitmaps: [OpaquePointer] = []
        defer { bitmaps.forEach { mtmd_bitmap_free($0) } }
        for data in request.media {
            let wrapper = data.withUnsafeBytes { raw in
                mtmd_helper_bitmap_init_from_buf(
                    vision, raw.bindMemory(to: UInt8.self).baseAddress, data.count, false,
                    mtmd_helper_init_opt_default()
                )
            }
            if let video = wrapper.video_ctx {
                mtmd_helper_video_free(video)
                if let bitmap = wrapper.bitmap {
                    mtmd_bitmap_free(bitmap)
                }
                throw EngineError.invalidRequest("video input isn't supported")
            }
            guard let bitmap = wrapper.bitmap else {
                throw EngineError.invalidRequest("an image couldn't be decoded (JPEG, PNG, BMP and GIF are read)")
            }
            bitmaps.append(bitmap)
        }

        // A template that starts with the BOS text already has one; don't add a second.
        let addSpecial = info.bosToken.isEmpty || !text.hasPrefix(info.bosToken)
        guard let chunks = mtmd_input_chunks_init() else { throw EngineError.generationFailed("out of memory") }
        defer { mtmd_input_chunks_free(chunks) }
        let status = text.withCString { pointer -> Int32 in
            var input = mtmd_input_text(
                text: pointer,
                text_len: strlen(pointer),
                add_special: addSpecial,
                parse_special: true
            )
            var pointers = bitmaps.map { Optional($0) }
            return pointers.withUnsafeMutableBufferPointer { buffer in
                mtmd_tokenize(vision, chunks, &input, buffer.baseAddress, buffer.count)
            }
        }
        switch status {
        case 0: break
        case 1: throw EngineError.invalidRequest("the number of images doesn't match the image markers in the prompt")
        default: throw EngineError.invalidRequest("an image couldn't be prepared for the model")
        }

        let total = mtmd_helper_get_n_tokens(chunks)
        guard total < info.contextSize else {
            throw EngineError.invalidRequest(
                "the request exceeds the available context size (\(total) prompt tokens, "
                    + "\(info.contextSize) in the context), try increasing it"
            )
        }
        var textTokens: [llama_token] = []
        var position: llama_pos = 0
        let count = mtmd_input_chunks_size(chunks)
        for index in 0 ..< count {
            guard let chunk = mtmd_input_chunks_get(chunks, index) else { continue }
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                var length = 0
                if let tokens = mtmd_input_chunk_get_tokens_text(chunk, &length) {
                    textTokens += UnsafeBufferPointer(start: tokens, count: length)
                }
            }
            let code = mtmd_helper_eval_chunk_single(
                vision, context, chunk, position, sequence, Int32(batchSize), index == count - 1, &position
            )
            guard code == 0 else {
                throw EngineError.generationFailed("llama.cpp failed to evaluate the prompt's images (code \(code))")
            }
        }
        return (textTokens, total, position)
    }

    /// Draws the next token the way llama-server does: from the ordinary chain first, keeping the token if the
    /// grammar allows it, and only otherwise drawing again from the logits the grammar has already masked.
    /// (Masking first would be the same distribution but a different draw for the same seed.)
    func sample(
        _ chain: UnsafeMutablePointer<llama_sampler>, grammar: UnsafeMutablePointer<llama_sampler>?,
        context: OpaquePointer, row: Int32
    ) -> llama_token {
        guard let grammar else { return llama_sampler_sample(chain, context, row) }
        let vocabSize = Int(llama_vocab_n_tokens(vocab))
        let logits = llama_get_logits_ith(context, row)!
        var candidates = (0 ..< vocabSize).map { llama_token_data(id: Int32($0), logit: logits[$0], p: 0) }

        func pick(_ samplers: [UnsafeMutablePointer<llama_sampler>]) -> llama_token {
            candidates.withUnsafeMutableBufferPointer { buffer in
                var array = llama_token_data_array(
                    data: buffer.baseAddress,
                    size: vocabSize,
                    selected: -1,
                    sorted: false
                )
                for sampler in samplers {
                    llama_sampler_apply(sampler, &array)
                }
                return array.data[Int(array.selected)].id
            }
        }
        var token = pick([chain])
        var single = llama_token_data(id: token, logit: 1, p: 0)
        let allowed = withUnsafeMutablePointer(to: &single) { pointer in
            var array = llama_token_data_array(data: pointer, size: 1, selected: -1, sorted: false)
            llama_sampler_apply(grammar, &array)
            return array.data[0].logit != -.infinity
        }
        if !allowed {
            for index in 0 ..< vocabSize {
                candidates[index] = llama_token_data(id: Int32(index), logit: logits[index], p: 0)
            }
            token = pick([grammar, chain])
        }
        llama_sampler_accept(grammar, token)
        llama_sampler_accept(chain, token)
        return token
    }

    /// llama-server's default order: penalties, DRY, top-n-sigma, top-k, typical-p, top-p, min-p, XTC,
    /// temperature, then the draw. Temperature 0 is greedy; mirostat, when asked for, replaces the
    /// truncation samplers and the draw, as it does there.
    func makeSampler(_ request: GenerationRequest) -> UnsafeMutablePointer<llama_sampler> {
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

    func addDRY(_ s: SamplingParameters, to chain: UnsafeMutablePointer<llama_sampler>) {
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
