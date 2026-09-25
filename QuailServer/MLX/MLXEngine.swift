import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import QuailServerCore
import Tokenizers

/// The MLX engine: `mlx-swift-lm` behind the `Engine` seam (ADR D-044). One instance holds one loaded
/// model directory. Generation runs inside the `ModelContainer`, which serves one caller at a time,
/// so a second request waits for the first, as the router's lease already arranges.
final class MLXEngine: Engine, @unchecked Sendable {
    /// The context asked for when a model's config doesn't say (its KV cache grows as it is used,
    /// so this is only the length a request may not exceed).
    static let defaultContext = 32768

    private let lock = NSLock()
    private var loaded: Loaded?

    init() {}

    /// Everything a request needs from the loaded model; replaced whole on load.
    private final class Loaded: @unchecked Sendable {
        let container: ModelContainer
        let info: EngineInfo
        let chatTemplate: String?
        let tokenizer: any MLXLMCommon.Tokenizer
        /// The prompt-prefix cache, touched only inside the container's serial access.
        var reusable: ReusableCache?

        init(
            container: ModelContainer, info: EngineInfo, chatTemplate: String?,
            tokenizer: any MLXLMCommon.Tokenizer
        ) {
            self.container = container
            self.info = info
            self.chatTemplate = chatTemplate
            self.tokenizer = tokenizer
        }
    }

    /// Keys and values for `tokens`, left in memory by the last request.
    private final class ReusableCache: @unchecked Sendable {
        let layers: [any KVCache]
        var tokens: [Int]

        init(layers: [any KVCache], tokens: [Int]) {
            self.layers = layers
            self.tokens = tokens
        }
    }

    private var current: Loaded? {
        lock.withLock { loaded }
    }

    // MARK: Load

    func load(_ entry: ModelEntry) async throws {
        await unload()
        // A model folder that is a symlink (a model kept elsewhere and linked into the store) loads nothing
        // through mlx-swift-lm's file enumeration ("Key lm_head.weight not found"), so load the real folder.
        let directory = entry.path.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw EngineError.loadFailed("the model folder \(directory.path) doesn't exist")
        }
        let files = ModelFiles(directory: directory)
        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: directory, using: TokenizerBridgeLoader()
            )
            let tokenizer = await container.tokenizer
            let contextSize = entry.contextSize ?? files.contextLength ?? Self.defaultContext
            let info = EngineInfo(
                contextSize: contextSize,
                bosToken: files.token("bos_token") ?? tokenizer.bosToken ?? "",
                eosToken: files.token("eos_token") ?? tokenizer.eosToken ?? ""
            )
            let made = Loaded(container: container, info: info, chatTemplate: files.chatTemplate, tokenizer: tokenizer)
            lock.withLock { loaded = made }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError
                .loadFailed("MLX couldn't load \(entry.id): \(error.localizedDescription)")
        }
    }

    func unload() async {
        lock.withLock { loaded = nil }
        // Weights and caches are freed with the container; give the GPU back what MLX pooled.
        Memory.clearCache()
    }

    func info() async -> EngineInfo {
        current?.info ?? EngineInfo(contextSize: 0, bosToken: "", eosToken: "")
    }

    func chatTemplate() async -> String? {
        current?.chatTemplate
    }

    // MARK: Text and tokens

    func tokenize(_ text: String, addSpecial: Bool, parseSpecial _: Bool) async throws -> [Int] {
        guard let loaded = current else { throw EngineError.notLoaded }
        // The tokenizer always recognises special-token text; `parseSpecial: false` can't be honoured.
        return loaded.tokenizer.encode(text: text, addSpecialTokens: addSpecial)
    }

    func detokenize(_ tokens: [Int]) async throws -> String {
        guard let loaded = current else { throw EngineError.notLoaded }
        return loaded.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
    }

    // MARK: Generation

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        AsyncThrowingStream { continuation in
            // The container runs its closure in a task of its own, so the request's cancellation has to
            // travel by a flag of ours as well.
            let cancelled = CancelFlag()
            let task = Task {
                do {
                    guard let loaded = current else { throw EngineError.notLoaded }
                    try await loaded.container.perform { context in
                        try await Self.run(
                            request, context: context, loaded: loaded, cancelled: cancelled,
                            emit: { continuation.yield($0) }
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                cancelled.set()
                task.cancel()
            }
        }
    }

    private static func run(
        _ request: GenerationRequest, context: ModelContext, loaded: Loaded, cancelled: CancelFlag,
        emit: @escaping @Sendable (GenerationEvent) -> Void
    ) async throws {
        let prompt = request.promptTokens
        guard !prompt.isEmpty else { throw EngineError.generationFailed("the prompt has no tokens") }
        let parameters = Self.parameters(for: request)

        // Keep the longest prefix of the last prompt that this one shares (and always feed at least
        // one token, whose logits the first sample needs).
        var layers: [any KVCache] = []
        var reused = 0
        if request.cachePrompt, let cache = loaded.reusable, cache.layers.allSatisfy(\.isTrimmable) {
            let limit = min(cache.tokens.count, prompt.count - 1)
            while reused < limit, cache.tokens[reused] == prompt[reused] {
                reused += 1
            }
            let held = cache.layers.first?.offset ?? 0
            reused = min(reused, held)
            if reused > 0 {
                for layer in cache.layers where layer.offset > reused {
                    layer.trim(layer.offset - reused)
                }
                layers = cache.layers
            }
        }
        loaded.reusable = nil
        if layers.isEmpty {
            reused = 0
            layers = context.model.newCache(parameters: parameters)
        }

        // Prefill in slices of the library's step size, so a client that leaves during a long prompt
        // stops it at the next slice: `TokenIterator`'s initialiser would otherwise process the whole
        // prompt before anything can be cancelled. The last one to two slices are left to the iterator,
        // which also hands the penalty processors the tail of the prompt.
        let step = parameters.prefillStepSize
        let started = ContinuousClock.now
        var remaining = LMInput.Text(tokens: MLXArray(prompt[reused...].map { Int32(truncatingIfNeeded: $0) }))
        var fed = reused
        while remaining.tokens.size > 2 * step {
            if cancelled.isSet || Task.isCancelled {
                // What the cache holds now is a prefix of this prompt; keep it for a retry.
                loaded.reusable = ReusableCache(layers: layers, tokens: Array(prompt.prefix(fed)))
                return
            }
            _ = context.model(remaining[.newAxis, ..<step], cache: layers, state: nil)
            eval(layers)
            remaining = remaining[step...]
            fed += step
        }
        let sliced = started.duration(to: .now)
        let input = LMInput(text: remaining)
        var processor = parameters.processor()
        if request.ignoreEndOfSequence {
            processor = BanTokens(ids: Self.stopTokens(context), wrapping: processor)
        }

        // The prompt is processed here, in the iterator's initialiser.
        let iterator = try TokenIterator(
            input: input, model: context.model, cache: layers, processor: processor,
            sampler: SeededSampler(request.sampling), prefillStepSize: parameters.prefillStepSize,
            maxTokens: request.maxTokens
        )
        let (stream, task) = generateTokenTask(
            promptTokenCount: prompt.count - reused, modelConfiguration: context.configuration,
            tokenizer: context.tokenizer, iterator: iterator
        )
        defer { task.cancel() }

        var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        var generated: [Int] = []
        var finished: GenerateCompletionInfo?
        for await event in stream {
            switch event {
            case let .token(id):
                generated.append(id)
                detokenizer.append(token: id)
                emit(.token(id: id, text: detokenizer.next() ?? ""))
            case let .info(info):
                finished = info
            }
        }

        // What the cache now holds: the prompt, then each token fed back in. Keep what we can name.
        let known = prompt + generated
        let held = layers.first?.offset ?? 0
        if held > known.count {
            for layer in layers {
                layer.trim(held - known.count)
            }
        }
        let kept = min(held, known.count)
        loaded.reusable = ReusableCache(layers: layers, tokens: Array(known.prefix(kept)))

        // The library reports a reply that hit the token limit as "cancelled" (it looks at a copy of the
        // iterator), so only a hang-up is taken as one here.
        guard let info = finished, !cancelled.isSet, !Task.isCancelled else { return }
        emit(.finished(info.stopReason == .stop ? .stop : .length, GenerationTimings(
            promptTokens: prompt.count - reused, promptSeconds: info.promptTime + sliced.seconds,
            generatedTokens: info.generationTokenCount, generatedSeconds: info.generateTime,
            cachedTokens: reused
        )))
    }

    private static func parameters(for request: GenerationRequest) -> GenerateParameters {
        let s = request.sampling
        return GenerateParameters(
            maxTokens: request.maxTokens, temperature: Float(s.temperature), topP: Float(s.topP), topK: s.topK,
            minP: Float(s.minP), repetitionPenalty: s.repeatPenalty != 1 ? Float(s.repeatPenalty) : nil,
            repetitionContextSize: 64, presencePenalty: s.presencePenalty != 0 ? Float(s.presencePenalty) : nil,
            frequencyPenalty: s.frequencyPenalty != 0 ? Float(s.frequencyPenalty) : nil
        )
    }

    private static func stopTokens(_ context: ModelContext) -> [Int] {
        var ids = Set(context.configuration.eosTokenIds.map(\.self))
        if let eos = context.tokenizer.eosTokenId {
            ids.insert(eos)
        }
        return Array(ids)
    }
}

/// mlx-swift-lm's samplers each draw from a random state seeded at random, which leaves no way to
/// honour a request's `seed`; this is the same top-p, min-p, top-k, temperature draw (mlx-lm's order and
/// definitions) with a state of ours. Temperature 0 is greedy.
private struct SeededSampler: LogitSampler {
    let temperature: Float
    let topP: Float
    let topK: Int
    let minP: Float
    let state: MLXRandom.RandomState

    init(_ sampling: SamplingParameters) {
        temperature = Float(sampling.temperature)
        topP = Float(sampling.topP)
        topK = sampling.topK
        minP = Float(sampling.minP)
        state = MLXRandom.RandomState(seed: sampling.seed ?? UInt64.random(in: 0 ... UInt64.max))
    }

    func sample(logits: MLXArray) -> MLXArray {
        if temperature <= 0 {
            return argMax(logits, axis: -1)
        }
        var logits = logits
        if logits.dtype == .bfloat16 {
            logits = logits.asType(.float32)
        }
        return withRandomState(state) {
            var logprobs = logSoftmax(logits)
            let negInf = MLXArray(-Float.infinity)
            if topP > 0, topP < 1 {
                // Keep the smallest set of tokens whose probability adds up past topP.
                let order = argSort(logprobs, axis: -1)
                let sorted = takeAlong(logprobs, order, axis: -1)
                let cumulative = cumsum(exp(sorted), axis: -1)
                let kept = MLX.where(cumulative .> (1 - topP), sorted, negInf)
                logprobs = putAlong(logprobs, order, values: kept, axis: -1)
            }
            if minP > 0 {
                let threshold = logprobs.max(axis: -1, keepDims: true) + log(MLXArray(minP))
                logprobs = MLX.where(logprobs .>= threshold, logprobs, negInf)
            }
            if topK > 0, topK < logprobs.dim(-1) {
                let drop = argPartition(-logprobs, kth: topK - 1, axis: -1)[0..., topK...]
                logprobs = putAlong(logprobs, drop, values: negInf, axis: -1)
            }
            return categorical(logprobs * (1 / temperature))
        }
    }
}

/// Makes some tokens unsampleable, so `ignore_eos` really runs to the length limit.
private struct BanTokens: LogitProcessor {
    let ids: [Int]
    var wrapped: (any LogitProcessor)?

    init(ids: [Int], wrapping wrapped: (any LogitProcessor)?) {
        self.ids = ids
        self.wrapped = wrapped
    }

    mutating func prompt(_ prompt: MLXArray) {
        wrapped?.prompt(prompt)
    }

    func process(logits: MLXArray) -> MLXArray {
        let logits = wrapped?.process(logits: logits) ?? logits
        for id in ids {
            logits[0..., id] = MLXArray(-Float.infinity)
        }
        return logits
    }

    mutating func didSample(token: MLXArray) {
        wrapped?.didSample(token: token)
    }
}

private // Set once from any thread, read by the prefill loop.
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

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

// MARK: Model folder files

/// What the server reads from the model folder itself: the chat template, the special-token strings
/// and the context length. (The weights and tokenizer go through `mlx-swift-lm`.)
private struct ModelFiles {
    let directory: URL

    private func json(_ name: String) -> [String: Any]? {
        (try? Data(contentsOf: directory.appendingPathComponent(name)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// `max_position_embeddings`, at the top level or inside `text_config` (multimodal models).
    var contextLength: Int? {
        guard let config = json("config.json") else { return nil }
        let text = config["text_config"] as? [String: Any]
        return (config["max_position_embeddings"] as? Int) ?? (text?["max_position_embeddings"] as? Int)
    }

    /// A special token's text: a plain string, or `{"content": …}`.
    func token(_ key: String) -> String? {
        guard let value = json("tokenizer_config.json")?[key] else { return nil }
        return (value as? String) ?? (value as? [String: Any])?["content"] as? String
    }

    /// The model's Jinja chat template: its own file, or `tokenizer_config.json`'s entry (a string,
    /// or a list of named templates of which `default` is used).
    var chatTemplate: String? {
        let file = directory.appendingPathComponent("chat_template.jinja")
        if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty {
            return text
        }
        let value = json("tokenizer_config.json")?["chat_template"]
        if let text = value as? String {
            return text
        }
        if let list = value as? [[String: Any]] {
            let chosen = list.first { $0["name"] as? String == "default" } ?? list.first
            return chosen?["template"] as? String
        }
        return nil
    }
}

// MARK: Tokenizer

/// swift-transformers' tokenizer, presented as the one `mlx-swift-lm` asks for. The chat template is the
/// server's own (`ChatTemplate`), so this one is never asked to apply it.
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let inner: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        inner.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        inner.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        inner.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        inner.convertIdToToken(id)
    }

    var bosToken: String? {
        inner.bosToken
    }

    var eosToken: String? {
        inner.eosToken
    }

    var unknownToken: String? {
        inner.unknownToken
    }

    func applyChatTemplate(
        messages _: [[String: any Sendable]], tools _: [[String: any Sendable]]?,
        additionalContext _: [String: any Sendable]?
    ) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
}

private struct TokenizerBridgeLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try await TokenizerBridge(inner: AutoTokenizer.from(modelFolder: directory))
    }
}
