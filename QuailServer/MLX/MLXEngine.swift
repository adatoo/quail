import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM
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
    /// The model asked for, kept to switch between its text-only and vision loads.
    private var entry: ModelEntry?
    /// Set when only the vision half loads: mlx-swift-lm's text-only Gemma 4 lacks the mixture-of-experts
    /// layers of Gemma 4 26B-A4B, which its vision model has.
    private var visionOnly = false

    init() {}

    /// Images, for a model whose vision half Quail can load (`MLXVision`).
    var capabilities: EngineCapabilities {
        EngineCapabilities(vision: lock.withLock { entry?.mlxVision } ?? false)
    }

    /// Everything a request needs from the loaded model; replaced whole on load.
    private final class Loaded: @unchecked Sendable {
        let container: ModelContainer
        let info: EngineInfo
        let chatTemplate: String?
        let tokenizer: any MLXLMCommon.Tokenizer
        /// Set when the vision half is loaded: how this architecture writes an image into the prompt.
        let vision: VisionSetup?
        /// The weights' size, which a request asks macOS to keep wired (resident) while it runs.
        let weightBytes: Int
        /// Prompt caches kept from earlier requests, touched only inside the container's serial access.
        let caches = PromptCaches()

        init(
            container: ModelContainer, info: EngineInfo, chatTemplate: String?,
            tokenizer: any MLXLMCommon.Tokenizer, vision: VisionSetup?, weightBytes: Int
        ) {
            self.container = container
            self.info = info
            self.chatTemplate = chatTemplate
            self.tokenizer = tokenizer
            self.vision = vision
            self.weightBytes = weightBytes
        }
    }

    /// Prompt caches kept from earlier requests (ADR D-055): a few conversations' worth, least recently used
    /// out first, so two callers (an agent and the chat page, or an agent's sub-tasks) stop evicting each
    /// other's prefix. Which one a prompt reuses, and how much, is `PromptCachePlan`'s decision.
    private final class PromptCaches: @unchecked Sendable {
        struct Entry {
            var layers: [any KVCache]
            /// What `layers` holds.
            var tokens: [Int]
            /// Copies of the layers that can't be cut back (a hybrid model's recurrent layers, sliding-window
            /// layers), by layer index, taken on the way through the last prompt, keyed by how many tokens in.
            var checkpoints: [Int: [Int: any KVCache]] = [:]

            var trimmable: Bool {
                layers.allSatisfy(\.isTrimmable)
            }

            var bytes: Int {
                (layers + checkpoints.values.flatMap(\.values)).flatMap { $0.innerState() }
                    .reduce(0) { $0 + $1.nbytes }
            }

            /// Back to the checkpoint `count` tokens in: its copies in place of the untrimmable layers, the
            /// others cut back to match.
            mutating func restore(to count: Int) {
                for (index, layer) in checkpoints[count] ?? [:] {
                    layers[index] = layer
                }
                for layer in layers where layer.isTrimmable && layer.offset > count {
                    layer.trim(layer.offset - count)
                }
                tokens = Array(tokens.prefix(count))
                checkpoints = checkpoints.filter { $0.key <= count }
            }
        }

        /// Oldest first.
        private var entries: [Entry] = []
        static let maxEntries = 4
        /// An eighth of the Mac's memory for caches beyond the newest one (which is kept whatever its size).
        static let maxBytes = Int(ProcessInfo.processInfo.physicalMemory / 8)

        /// The cache that holds the most of `prompt`, cut back (or returned to a checkpoint) to what it
        /// shares, with its checkpoints up to there, and taken out of the store while the request uses it;
        /// nil if none holds any of it.
        func take(for prompt: [Int], trimmableOnly: Bool) -> Entry? {
            let candidates = entries.map { entry in
                trimmableOnly
                    ? PromptCachePlan.Candidate(tokens: entry.trimmable ? entry.tokens : [], trimmable: true)
                    : PromptCachePlan.Candidate(
                        tokens: entry.tokens, trimmable: entry.trimmable, checkpoints: Array(entry.checkpoints.keys)
                    )
            }
            guard let choice = PromptCachePlan.choose(candidates, for: prompt) else { return nil }
            var entry = entries.remove(at: choice.index)
            if choice.fromCheckpoint {
                entry.restore(to: choice.reuse)
            }
            for layer in entry.layers where layer.isTrimmable && layer.offset > choice.reuse {
                layer.trim(layer.offset - choice.reuse)
            }
            entry.tokens = Array(prompt.prefix(choice.reuse))
            entry.checkpoints = entry.checkpoints.filter { $0.key <= choice.reuse }
            return entry
        }

        func put(_ entry: Entry) {
            guard !entry.tokens.isEmpty else { return }
            entries.append(entry)
            let drop = PromptCachePlan.evictions(
                sizes: entries.map(\.bytes), maxEntries: Self.maxEntries, maxBytes: Self.maxBytes
            )
            entries.removeFirst(drop)
        }
    }

    /// How far short of a prompt's end a hybrid model's cache is checkpointed: past any chat template's
    /// generation header, and as many tokens as the repetition penalty looks back over.
    static let checkpointMargin = 64
    /// How often a hybrid model's cache is checkpointed on the way through a long prompt, so a prompt that
    /// shares a long opening and then differs (Claude Code's permission check, asked about each command, is
    /// 27,000 tokens of instructions and then a different transcript) resumes near where they part. Each
    /// checkpoint of Qwen3.6 35B-A3B's recurrent layers is about 60 MB.
    static let checkpointInterval = 4096

    /// Copies of the layers that can't be cut back. References, not data: the model replaces these arrays
    /// rather than writing into them.
    private static func snapshot(_ layers: [any KVCache]) -> [Int: any KVCache] {
        Dictionary(uniqueKeysWithValues: layers.enumerated().compactMap { index, layer in
            !layer.isTrimmable || layer.maxSize != nil ? (index, layer.copy()) : nil
        })
    }

    /// How many tokens a cache has been fed: the largest layer offset (a recurrent layer keeps none).
    private static func held(_ layers: [any KVCache]) -> Int {
        layers.map(\.offset).max() ?? 0
    }

    private var current: Loaded? {
        lock.withLock { loaded }
    }

    // MARK: Load

    /// Loads text-only, even a model that can read images: mlx-swift-lm's vision models generate text at
    /// about half the speed of its text models (measured on Qwen3.6-35B-A3B: 11 against 20 tokens a
    /// second), so the vision half is loaded only when an image arrives, and dropped again at the next
    /// request without one (a reload of a few seconds from the page cache).
    func load(_ entry: ModelEntry) async throws {
        await unload()
        lock.withLock { self.entry = entry }
        do {
            try await load(entry, vision: false)
        } catch where entry.mlxVision {
            try await load(entry, vision: true)
            lock.withLock { visionOnly = true }
        }
    }

    private func load(_ entry: ModelEntry, vision: Bool) async throws {
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
            // Both from the local folder: no download either way.
            let container = if vision {
                try await VLMModelFactory.shared.loadContainer(from: directory, using: TokenizerBridgeLoader())
            } else {
                try await LLMModelFactory.shared.loadContainer(from: directory, using: TokenizerBridgeLoader())
            }
            let tokenizer = await container.tokenizer
            let weightBytes = await container.perform { context in
                context.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
            }
            let contextSize = entry.contextSize ?? files.contextLength ?? Self.defaultContext
            let info = EngineInfo(
                contextSize: contextSize,
                bosToken: files.token("bos_token") ?? tokenizer.bosToken ?? "",
                eosToken: files.token("eos_token") ?? tokenizer.eosToken ?? "",
                supportsImages: entry.mlxVision
            )
            let made = Loaded(
                container: container, info: info, chatTemplate: files.chatTemplate, tokenizer: tokenizer,
                vision: vision ? files.visionSetup : nil, weightBytes: weightBytes
            )
            lock.withLock { loaded = made }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError
                .loadFailed("MLX couldn't load \(entry.id): \(error.localizedDescription)")
        }
    }

    /// The load a request needs: the vision half for one with images, the faster text-only load otherwise.
    /// Requests reach an MLX engine one at a time (the router's lease), so swapping here is safe.
    private func loadedFor(_ request: GenerationRequest) async throws -> Loaded {
        guard let current else { throw EngineError.notLoaded }
        let wantsVision = !request.media.isEmpty
        guard wantsVision != (current.vision != nil), !lock.withLock({ visionOnly }),
              let entry = lock.withLock({ entry }), entry.mlxVision || !wantsVision
        else { return current }
        lock.withLock { loaded = nil }
        Memory.clearCache()
        try await load(entry, vision: wantsVision)
        guard let swapped = self.current else { throw EngineError.notLoaded }
        return swapped
    }

    func unload() async {
        lock.withLock {
            loaded = nil
            entry = nil
            visionOnly = false
        }
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
                    let loaded = try await self.loadedFor(request)
                    // Weights kept wired while the request runs, as mlx-lm does with `set_wired_limit`, so
                    // macOS doesn't page a large model out between tokens under memory pressure (ADR D-055).
                    // The limit returns to where it was when no request holds a ticket.
                    let wired = WiredMemoryTicket(size: loaded.weightBytes, policy: MLXLMCommon.WiredSumPolicy())
                    try await wired.withWiredLimit {
                        try await loaded.container.perform { context in
                            try await Self.run(
                                request, context: context, loaded: loaded, cancelled: cancelled,
                                emit: { continuation.yield($0) }
                            )
                        }
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
        if !request.media.isEmpty {
            try await runWithImages(request, context: context, loaded: loaded, cancelled: cancelled, emit: emit)
            return
        }
        // A text turn on a vision load (a model that only loads that way, Gemma 4 26B-A4B): only the
        // iterator's `prepare` resets the model's position state, so the prompt isn't fed in slices
        // first, and it goes in as a batch of one ([1, n]), as the vision half's language model reads it.
        let isVision = loaded.vision != nil

        // Start from the kept cache that holds the most of this prompt (always feeding at least one token,
        // whose logits the first sample needs). A vision load reuses only a cache it can cut back, as before:
        // its position state is reset only by the iterator's `prepare`.
        var layers: [any KVCache]
        var reused = 0
        var checkpoints: [Int: [Int: any KVCache]] = [:]
        if request.cachePrompt, let taken = loaded.caches.take(for: prompt, trimmableOnly: isVision) {
            (layers, reused, checkpoints) = (taken.layers, taken.tokens.count, taken.checkpoints)
        } else {
            layers = context.model.newCache(parameters: parameters)
        }

        // Prefill in slices of the library's step size, so a client that leaves during a long prompt
        // stops it at the next slice: `TokenIterator`'s initialiser would otherwise process the whole
        // prompt before anything can be cancelled. The last one to two slices are left to the iterator,
        // which also hands the penalty processors the tail of the prompt. Each slice is queued with
        // `asyncEval` and the loop waits only for the slice before it, so the GPU always has the next
        // slice ready while the CPU builds the one after (mlx-swift-lm 3.31.4 pipelines its own prefill
        // the same way); waiting on every slice left the GPU idle between them. One slice in flight
        // keeps a hang-up noticed within a slice or two.
        //
        // A hybrid model's recurrent layers (and sliding-window layers) can't be cut back afterwards, so
        // the point the next turn of a conversation resumes from is captured on the way instead:
        // `checkpointMargin` tokens short of the prompt's end, before the chat template's generation
        // header, which the next turn's history renders differently (a reasoning block dropped, or an
        // empty one added). Prefill stops there, copies those layers, and the iterator does the rest.
        // Checkpoints are also taken every `checkpointInterval` tokens on the way.
        let step = parameters.prefillStepSize
        let started = ContinuousClock.now
        let untrimmable = !isVision && layers.contains { !$0.isTrimmable || $0.maxSize != nil }
        var feedTo = reused
        if untrimmable {
            feedTo = max(reused, prompt.count - Self.checkpointMargin)
        } else if !isVision {
            while prompt.count - feedTo > 2 * step {
                feedTo += step
            }
        }
        var fed = reused
        var inFlight: [MLXArray] = []
        while fed < feedTo {
            if cancelled.isSet || Task.isCancelled {
                // What the cache holds now is a prefix of this prompt; keep it for a retry.
                eval(layers)
                loaded.caches.put(.init(layers: layers, tokens: Array(prompt.prefix(fed)), checkpoints: checkpoints))
                return
            }
            let count = min(step, feedTo - fed)
            let slice = MLXArray(prompt[fed ..< fed + count].map { Int32(truncatingIfNeeded: $0) })
            _ = context.model(.init(tokens: slice.expandedDimensions(axis: 0)), cache: layers, state: nil)
            let queued = layers.flatMap { $0.innerState() }
            asyncEval(queued)
            eval(inFlight)
            inFlight = queued
            fed += count
            if untrimmable, fed < feedTo, fed - (checkpoints.keys.max() ?? reused) >= Self.checkpointInterval {
                checkpoints[fed] = Self.snapshot(layers)
            }
        }
        if untrimmable {
            checkpoints[fed] = Self.snapshot(layers)
        }
        let checkpointCount = fed
        let sliced = started.duration(to: .now)
        let remaining = MLXArray(prompt[fed...].map { Int32(truncatingIfNeeded: $0) })
        let input = isVision
            ? LMInput(text: .init(tokens: remaining.expandedDimensions(axis: 0)))
            : LMInput(text: .init(tokens: remaining))
        var processor = parameters.processor()
        if request.ignoreEndOfSequence {
            processor = BanTokens(ids: Self.stopTokens(context), wrapping: processor)
        }

        // The rest of the prompt is processed here, in the iterator's initialiser.
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

        // What the cache now holds: the prompt, then each token fed back in (a stop token too, which isn't in
        // `generated`). Keep what we can name. A cache that can't be cut back to that goes back to its
        // checkpoint.
        let known = prompt + generated
        let held = Self.held(layers)
        for layer in layers where layer.isTrimmable && layer.offset > known.count {
            layer.trim(layer.offset - known.count)
        }
        var entry = PromptCaches.Entry(
            layers: layers, tokens: Array(known.prefix(min(held, known.count))), checkpoints: checkpoints
        )
        if !checkpoints.isEmpty, held != known.count {
            entry.tokens = prompt
            entry.restore(to: checkpointCount)
        }
        loaded.caches.put(entry)

        // The library reports a reply that hit the token limit as "cancelled" (it looks at a copy of the
        // iterator), so only a hang-up is taken as one here.
        guard let info = finished, !cancelled.isSet, !Task.isCancelled else { return }
        emit(.finished(info.stopReason == .stop ? .stop : .length, GenerationTimings(
            promptTokens: prompt.count - reused, promptSeconds: info.promptTime + sliced.seconds,
            generatedTokens: info.generationTokenCount, generatedSeconds: info.generateTime,
            cachedTokens: reused
        )))
    }

    /// An image turn (ADR D-047 amendment): the prompt text with each image's placeholder, the images
    /// through the model's own processor, and each placeholder widened to its image's share of tokens.
    /// A fresh cache, and nothing kept for the next request: positions after an image aren't a plain
    /// count of tokens, so a prefix can't safely be reused.
    private static func runWithImages(
        _ request: GenerationRequest, context: ModelContext, loaded: Loaded, cancelled: CancelFlag,
        emit: @escaping @Sendable (GenerationEvent) -> Void
    ) async throws {
        guard let vision = loaded.vision, let text = request.promptText else {
            throw EngineError.invalidRequest(ImageInput.unsupportedMessage)
        }
        let family = vision.family
        guard let imageID = context.tokenizer.convertTokenToId(family.imageToken) else {
            throw EngineError.generationFailed("the tokenizer has no \(family.imageToken) token")
        }
        let started = ContinuousClock.now
        let promptText = text.replacingOccurrences(of: ImageInput.marker, with: family.placeholder)
        let bos = loaded.info.bosToken
        var tokens = context.tokenizer.encode(
            text: promptText, addSpecialTokens: bos.isEmpty || !promptText.hasPrefix(bos)
        )
        var pixels: [MLXArray] = []
        var frames: [THW] = []
        for data in request.media {
            guard let image = CIImage(data: data) else {
                throw EngineError.invalidRequest("an image couldn't be read (is it a PNG, JPEG, HEIC or similar?)")
            }
            let (imagePixels, frame): (MLXArray, THW)
            switch vision {
            case .qwen35:
                guard let processor = context.processor as? Qwen3VLProcessor else {
                    throw EngineError.generationFailed("this model's image processor isn't the one Quail drives")
                }
                // This processor renders pixels without colour matching, so they'd come out in Core
                // Image's linear working space: mid-tones too dark (orange read as red). Put the sRGB
                // curve back first, as the image processors the model was trained with see it.
                (imagePixels, frame) = try processor.preprocess(
                    images: [MediaProcessing.inSRGBToneCurveSpace(image)], processing: nil
                )
            case .gemma4:
                guard let processor = context.processor as? Gemma4Processor else {
                    throw EngineError.generationFailed("this model's image processor isn't the one Quail drives")
                }
                // Gemma 4's processor applies the sRGB curve itself.
                (imagePixels, frame) = try processor.preprocess(images: [image], processing: nil)
            }
            pixels.append(imagePixels)
            frames.append(frame)
        }
        switch vision {
        case let .qwen35(mergeSize):
            tokens = try MLXVision.expand(
                tokens, padID: imageID, counts: frames.map { $0.t * $0.h * $0.w / (mergeSize * mergeSize) }
            )
        case let .gemma4(boi, eoi, seqLength):
            let run = [boi] + Array(repeating: imageID, count: seqLength) + (eoi.map { [$0] } ?? [])
            tokens = try MLXVision.expand(
                tokens, marker: imageID, replacements: Array(repeating: run, count: frames.count)
            )
        }
        guard tokens.count < loaded.info.contextSize else {
            throw EngineError.invalidRequest(
                "with its images the prompt is \(tokens.count) tokens, more than the model's context of \(loaded.info.contextSize)"
            )
        }
        let ids = MLXArray(tokens.map { Int32(truncatingIfNeeded: $0) }).expandedDimensions(axis: 0)
        let input = LMInput(
            text: .init(tokens: ids, mask: ones(like: ids).asType(.int8)),
            image: .init(pixels: concatenated(pixels), frames: frames)
        )
        let parameters = Self.parameters(for: request)
        var processorChain = parameters.processor()
        if request.ignoreEndOfSequence {
            processorChain = BanTokens(ids: Self.stopTokens(context), wrapping: processorChain)
        }
        let prepared = started.duration(to: .now)
        let iterator = try TokenIterator(
            input: input, model: context.model, cache: context.model.newCache(parameters: parameters),
            processor: processorChain, sampler: SeededSampler(request.sampling),
            prefillStepSize: parameters.prefillStepSize, maxTokens: request.maxTokens
        )
        let (stream, task) = generateTokenTask(
            promptTokenCount: tokens.count, modelConfiguration: context.configuration,
            tokenizer: context.tokenizer, iterator: iterator
        )
        defer { task.cancel() }
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        var finished: GenerateCompletionInfo?
        for await event in stream {
            if cancelled.isSet || Task.isCancelled {
                return
            }
            switch event {
            case let .token(id):
                detokenizer.append(token: id)
                emit(.token(id: id, text: detokenizer.next() ?? ""))
            case let .info(info):
                finished = info
            }
        }
        guard let info = finished, !cancelled.isSet, !Task.isCancelled else { return }
        emit(.finished(info.stopReason == .stop ? .stop : .length, GenerationTimings(
            promptTokens: tokens.count, promptSeconds: info.promptTime + prepared.seconds,
            generatedTokens: info.generationTokenCount, generatedSeconds: info.generateTime
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
            if topK > 0, topK < logprobs.dim(-1) {
                return sampleTopK(logprobs)
            }
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
            return categorical(logprobs * (1 / temperature))
        }
    }

    /// The same draw with top-k on (llama-server's default, 40), done on the k most likely tokens instead
    /// of the whole vocabulary: no sort of 150,000 entries per token (ADR D-055). All three filters keep a
    /// run of the most likely tokens, and top-p's cut for a token depends only on the tokens more likely
    /// than it, so filtering the top k gives the same set as filtering everything. Only the random draw
    /// differs (it's over k values now): a seed still always gives the same text, though not the text it
    /// gave before this change.
    private func sampleTopK(_ logprobs: MLXArray) -> MLXArray {
        let negInf = MLXArray(-Float.infinity)
        let candidates = argPartition(-logprobs, kth: topK - 1, axis: -1)[0..., ..<topK]
        var kept = takeAlong(logprobs, candidates, axis: -1)
        if topP > 0, topP < 1 {
            // A token stays if the tokens more likely than it add up to less than topP: over the whole
            // vocabulary that's `cumulative > 1 - topP`; over the top k, `cumulative > total - topP`.
            let order = argSort(kept, axis: -1)
            let sorted = takeAlong(kept, order, axis: -1)
            let cumulative = cumsum(exp(sorted), axis: -1)
            let total = cumulative.max(axis: -1, keepDims: true)
            let filtered = MLX.where(cumulative .> (total - topP), sorted, negInf)
            kept = putAlong(kept, order, values: filtered, axis: -1)
        }
        if minP > 0 {
            let threshold = kept.max(axis: -1, keepDims: true) + log(MLXArray(minP))
            kept = MLX.where(kept .>= threshold, kept, negInf)
        }
        let choice = categorical(kept * (1 / temperature))
        return takeAlong(candidates, choice.expandedDimensions(axis: -1), axis: -1).squeezed(axis: -1)
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

/// A vision-loaded model's image layout (`MLXVision.Family`), with what its config files say.
enum VisionSetup {
    case qwen35(mergeSize: Int)
    case gemma4(boi: Int, eoi: Int?, seqLength: Int)

    var family: MLXVision.Family {
        switch self {
        case .qwen35: .qwen35
        case .gemma4: .gemma4
        }
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

    /// How this architecture writes an image into the prompt, from its config files (defaults are the
    /// library's own).
    var visionSetup: VisionSetup? {
        guard let config = json("config.json"), let type = config["model_type"] as? String,
              let family = MLXVision.Family(modelType: type)
        else { return nil }
        let processor = json("preprocessor_config.json") ?? json("processor_config.json") ?? [:]
        switch family {
        case .qwen35:
            return .qwen35(mergeSize: processor["merge_size"] as? Int ?? 2)
        case .gemma4:
            return .gemma4(
                boi: config["boi_token_id"] as? Int ?? 255_999,
                eoi: config["eoi_token_id"] as? Int ?? 258_882,
                seqLength: processor["image_seq_length"] as? Int ?? 280
            )
        }
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
