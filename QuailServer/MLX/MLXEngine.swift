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
        /// Where they go when they leave memory, if anywhere (`--prompt-cache-dir`).
        let disk: PromptDiskCache?
        /// A small model that drafts tokens for this one (preset `model-draft`), if one loaded.
        let draft: DraftModel?

        init(
            container: ModelContainer, info: EngineInfo, chatTemplate: String?,
            tokenizer: any MLXLMCommon.Tokenizer, vision: VisionSetup?, weightBytes: Int, disk: PromptDiskCache?,
            draft: DraftModel?
        ) {
            self.container = container
            self.info = info
            self.chatTemplate = chatTemplate
            self.tokenizer = tokenizer
            self.vision = vision
            self.weightBytes = weightBytes
            self.disk = disk
            self.draft = draft
        }

        /// Writes a cache leaving memory to disk. A hybrid model's is written as it was at its last checkpoint,
        /// where the next turn of its conversation picks up; what it holds beyond that is reused only by a
        /// prompt that repeats it exactly.
        func spill(_ entry: PromptCaches.Entry) {
            guard let disk else { return }
            var entry = entry
            if !entry.trimmable, let last = entry.checkpoints.keys.max(), last < entry.tokens.count {
                entry.restore(to: last)
            }
            disk.save(entry.layers, tokens: entry.tokens)
        }

        /// Every cache in memory to disk (the model is going away).
        func spillAll() {
            for entry in caches.removeAll() {
                spill(entry)
            }
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

        /// How many of `prompt`'s tokens the best cache here holds (0 for none), without taking it.
        func bestReuse(for prompt: [Int], trimmableOnly: Bool) -> Int {
            PromptCachePlan.choose(candidates(trimmableOnly: trimmableOnly), for: prompt)?.reuse ?? 0
        }

        private func candidates(trimmableOnly: Bool) -> [PromptCachePlan.Candidate] {
            entries.map { entry in
                trimmableOnly
                    ? PromptCachePlan.Candidate(tokens: entry.trimmable ? entry.tokens : [], trimmable: true)
                    : PromptCachePlan.Candidate(
                        tokens: entry.tokens, trimmable: entry.trimmable, checkpoints: Array(entry.checkpoints.keys)
                    )
            }
        }

        /// The cache that holds the most of `prompt`, cut back (or returned to a checkpoint) to what it
        /// shares, with its checkpoints up to there, and taken out of the store while the request uses it;
        /// nil if none holds any of it.
        func take(for prompt: [Int], trimmableOnly: Bool) -> Entry? {
            guard let choice = PromptCachePlan.choose(candidates(trimmableOnly: trimmableOnly), for: prompt)
            else { return nil }
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

        /// Keeps a cache; returns the ones that had to go to make room, oldest first.
        @discardableResult
        func put(_ entry: Entry) -> [Entry] {
            guard !entry.tokens.isEmpty else { return [] }
            entries.append(entry)
            let drop = PromptCachePlan.evictions(
                sizes: entries.map(\.bytes), maxEntries: Self.maxEntries, maxBytes: Self.maxBytes
            )
            defer { entries.removeFirst(drop) }
            return Array(entries.prefix(drop))
        }

        func removeAll() -> [Entry] {
            defer { entries = [] }
            return entries
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
    /// Prefill slices queued ahead of the one the loop waits for.
    static let slicesInFlight = 2

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
            let draft: DraftModel? = if !vision, let path = entry.draftModel {
                await DraftModel.load(from: path, matching: tokenizer)
            } else {
                nil
            }
            let made = Loaded(
                container: container, info: info, chatTemplate: files.chatTemplate, tokenizer: tokenizer,
                vision: vision ? files.visionSetup : nil, weightBytes: weightBytes,
                disk: PromptDiskCache(
                    root: entry.promptCacheDirectory,
                    entry: entry,
                    weightBytes: weightBytes,
                    vision: vision
                ),
                draft: draft
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
        await current.container.perform { _ in current.spillAll() }
        lock.withLock { loaded = nil }
        Memory.clearCache()
        try await load(entry, vision: wantsVision)
        guard let swapped = self.current else { throw EngineError.notLoaded }
        return swapped
    }

    func unload() async {
        // The caches in memory go to disk first, so a swap back (or a restart) picks them up.
        if let current {
            await current.container.perform { _ in current.spillAll() }
        }
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
        // A text turn on a vision load (a model that only loads that way, Gemma 4 26B-A4B) goes in as a
        // batch of one ([1, n]), as the vision half's language model reads it. Gemma 4's vision model reads
        // a text prompt as its text model does, positions from the cache, so its prompt can be fed in
        // slices and its caches reused like a text load's. Other vision models (Qwen3.5's keeps position
        // state that only the iterator's `prepare` resets) are fed whole and reuse only a cache they can
        // cut back.
        let isVision = loaded.vision != nil
        let sliceable = loaded.vision.map { $0.family == .gemma4 } ?? true

        // Start from the kept cache that holds the most of this prompt (always feeding at least one token,
        // whose logits the first sample needs).
        var layers: [any KVCache]
        var reused = 0
        var checkpoints: [Int: [Int: any KVCache]] = [:]
        // A cache on disk is loaded instead when it holds clearly more (loading costs about as much as
        // reading `checkpointMargin` tokens).
        let fromDisk = request.cachePrompt && sliceable && (loaded.disk?.bestReuse(for: prompt) ?? 0)
            > loaded.caches.bestReuse(for: prompt, trimmableOnly: !sliceable) + Self.checkpointMargin
        if fromDisk, let taken = loaded.disk?.take(for: prompt) {
            (layers, reused) = taken
        } else if request.cachePrompt, let taken = loaded.caches.take(for: prompt, trimmableOnly: !sliceable) {
            (layers, reused, checkpoints) = (taken.layers, taken.tokens.count, taken.checkpoints)
        } else {
            layers = context.model.newCache(parameters: parameters)
        }

        // Prefill in slices of the library's step size, so a client that leaves during a long prompt
        // stops it at the next slice: `TokenIterator`'s initialiser would otherwise process the whole
        // prompt before anything can be cancelled. The last one to two slices are left to the iterator,
        // which also hands the penalty processors the tail of the prompt. Each slice is queued with
        // `asyncEval` and the loop waits only for the one `slicesInFlight` back, so the GPU always has
        // work queued while the CPU builds the next graph (mlx-swift-lm 3.31.4 pipelines its own prefill
        // the same way; with one slice in flight Gemma 4's prompts ran 3–5% slower than the library's).
        // A hang-up is still noticed within two or three slices.
        //
        // A hybrid model's recurrent layers (and sliding-window layers) can't be cut back afterwards, so
        // the point the next turn of a conversation resumes from is captured on the way instead:
        // `checkpointMargin` tokens short of the prompt's end, before the chat template's generation
        // header, which the next turn's history renders differently (a reasoning block dropped, or an
        // empty one added). Prefill stops there, copies those layers, and the iterator does the rest.
        // Checkpoints are also taken every `checkpointInterval` tokens on the way. Stopping short costs a
        // forward pass of its own (on a 512-token prompt, 15% of Gemma 4 26B-A4B's prompt time), so it's done
        // only for a request that asks for its prompt to be cached.
        let step = parameters.prefillStepSize
        let started = ContinuousClock.now
        let untrimmable = sliceable && request.cachePrompt
            && layers.contains { !$0.isTrimmable || $0.maxSize != nil }
        var feedTo = reused
        if untrimmable {
            feedTo = max(reused, prompt.count - Self.checkpointMargin)
        } else if sliceable {
            while prompt.count - feedTo > 2 * step {
                feedTo += step
            }
        }
        var fed = reused
        var inFlight: [[MLXArray]] = []
        while fed < feedTo {
            if cancelled.isSet || Task.isCancelled {
                // What the cache holds now is a prefix of this prompt; keep it for a retry.
                eval(layers)
                for evicted in loaded.caches.put(.init(
                    layers: layers, tokens: Array(prompt.prefix(fed)), checkpoints: checkpoints
                )) {
                    loaded.spill(evicted)
                }
                return
            }
            let count = min(step, feedTo - fed)
            let slice = MLXArray(prompt[fed ..< fed + count].map { Int32(truncatingIfNeeded: $0) })
            _ = context.model(.init(tokens: slice.expandedDimensions(axis: 0)), cache: layers, state: nil)
            let queued = layers.flatMap { $0.innerState() }
            asyncEval(queued)
            inFlight.append(queued)
            if inFlight.count > Self.slicesInFlight {
                eval(inFlight.removeFirst())
            }
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

        // Prompt-lookup speculation needs a load whose prompt can be fed in pieces, and no penalty processors
        // (they'd have to see every guessed token in order).
        if sliceable, parameters.processor() == nil, request.maxTokens > 1, Self.lookupEnabled,
           request.speculativeMaxTokens != 0
        {
            var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            let outcome = Self.decodeWithLookup(
                rest: Array(prompt[fed...]), prompt: prompt, layers: &layers, context: context, request: request,
                draft: loaded.draft, cancelled: cancelled, emit: { id in
                    detokenizer.append(token: id)
                    emit(.token(id: id, text: detokenizer.next() ?? ""))
                }
            )
            Self.keep(
                layers, prompt: prompt, generated: outcome.generated, checkpoints: checkpoints,
                checkpointCount: checkpointCount, in: loaded
            )
            guard !cancelled.isSet, !Task.isCancelled else { return }
            var timings = GenerationTimings(
                promptTokens: prompt.count - reused, promptSeconds: outcome.firstTokenSeconds + sliced.seconds,
                generatedTokens: outcome.generated.count, generatedSeconds: outcome.generateSeconds,
                cachedTokens: reused
            )
            if outcome.drafted > 0 {
                timings.draftTokens = outcome.drafted
                timings.draftAccepted = outcome.accepted
            }
            emit(.finished(outcome.stopped ? .stop : .length, timings))
            return
        }

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

        Self.keep(
            layers, prompt: prompt, generated: generated, checkpoints: checkpoints,
            checkpointCount: checkpointCount, in: loaded
        )

        // The library reports a reply that hit the token limit as "cancelled" (it looks at a copy of the
        // iterator), so only a hang-up is taken as one here.
        guard let info = finished, !cancelled.isSet, !Task.isCancelled else { return }
        emit(.finished(info.stopReason == .stop ? .stop : .length, GenerationTimings(
            promptTokens: prompt.count - reused, promptSeconds: info.promptTime + sliced.seconds,
            generatedTokens: info.generationTokenCount, generatedSeconds: info.generateTime,
            cachedTokens: reused
        )))
    }

    /// Keeps the cache a request leaves for the next. It holds the prompt, then each token fed back in (a stop
    /// token too, or a guess past the end, which aren't in `generated`): what can be named is kept, and a cache
    /// that can't be cut back to that goes back to its checkpoint.
    private static func keep(
        _ layers: [any KVCache], prompt: [Int], generated: [Int], checkpoints: [Int: [Int: any KVCache]],
        checkpointCount: Int, in loaded: Loaded
    ) {
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
        for evicted in loaded.caches.put(entry) {
            loaded.spill(evicted)
        }
    }

    // MARK: Prompt-lookup speculation

    /// Off with `QUAIL_PROMPT_LOOKUP=0` in the server's environment, to compare; `nodraft` keeps this decode loop
    /// but never guesses (to tell the loop's own effect from the guessing's).
    static let lookupEnabled = ProcessInfo.processInfo.environment["QUAIL_PROMPT_LOOKUP"] != "0"
    static let lookupDrafts = ProcessInfo.processInfo.environment["QUAIL_PROMPT_LOOKUP"] != "nodraft"
    /// The most tokens guessed at once.
    static let maxDraft = 16
    /// The most a draft model guesses at once: each of its tokens is a step of its own.
    static let maxModelDraft = 6
    /// Tokens run without looking after a wholly wrong guess; the pause doubles each time, up to `maxBackoff`.
    static let lookEvery = 8
    static let maxBackoff = 256

    private struct LookupOutcome {
        var generated: [Int] = []
        var stopped = false
        var firstTokenSeconds = 0.0
        var generateSeconds = 0.0
        var drafted = 0
        var accepted = 0
    }

    /// The rest of the prompt, then generation with prompt-lookup speculation (ADR D-055, Phase 3c step 6).
    ///
    /// When the text so far ends with tokens seen before (`PromptLookup`), a step feeds the last token and the
    /// tokens that followed them then, all in one forward pass. Greedy keeps the guesses the model agrees with;
    /// sampling keeps each with the probability the model gives it and draws the first rejected one again from
    /// what's left (standard speculative sampling, so the text follows the same distribution). What wasn't kept
    /// is cut from the cache, or, for layers that can't be cut back, undone from a copy taken before the step
    /// and the kept tokens fed again.
    ///
    /// Guessing costs a pass over several tokens and a wait for its answer, so between guesses the loop runs
    /// plainly and pipelined, as mlx-swift-lm's own iterator does (the next token computing while the last is
    /// handed out), looking up the text so far as it goes and stopping to guess only when something recurs.
    /// After a guess that was wholly wrong it doesn't look for a while (`lookEvery` tokens, doubling each time
    /// it happens again). The guess grows while guesses are kept and shrinks when they aren't.
    private static func decodeWithLookup(
        rest: [Int], prompt: [Int], layers: inout [any KVCache], context: ModelContext, request: GenerationRequest,
        draft drafter: DraftModel?, cancelled: CancelFlag, emit: (Int) -> Void
    ) -> LookupOutcome {
        var outcome = LookupOutcome()
        let started = ContinuousClock.now
        let sampler = SeededSampler(request.sampling)
        let stops = Set(Self.stopTokens(context))
        let banned = request.ignoreEndOfSequence ? Array(stops) : []
        let untrimmable = layers.contains { !$0.isTrimmable || $0.maxSize != nil }
        let negInf = MLXArray(-Float.infinity)

        func forward(_ input: MLXArray) -> MLXArray {
            let rows = context.model(.init(tokens: input.expandedDimensions(axis: 0)), cache: layers, state: nil)
                .logits[0]
            for id in banned {
                rows[0..., id] = negInf
            }
            return rows
        }
        func forward(_ tokens: [Int]) -> MLXArray {
            forward(MLXArray(tokens.map { Int32(truncatingIfNeeded: $0) }))
        }
        /// The next token after `row`'s logits, not yet computed.
        func draw(_ row: MLXArray) -> MLXArray {
            sampler.sample(logits: row.expandedDimensions(axis: 0))
        }

        // All but the last prompt token first, whose logits are never read (so never computed), then the last.
        if rest.count > 1 {
            _ = forward(Array(rest.dropLast()))
        }
        var pending = draw(forward([rest[rest.count - 1]])[0]).item(Int.self)
        outcome.firstTokenSeconds = started.duration(to: .now).seconds
        let generating = ContinuousClock.now
        var history = prompt
        var plain = true
        var holdOff = 0
        var backoff = Self.lookEvery
        var guessLength = 4

        /// Hands a token out; false once generation should end.
        func take(_ token: Int) -> Bool {
            if !request.ignoreEndOfSequence, stops.contains(token) {
                outcome.stopped = true
                return false
            }
            outcome.generated.append(token)
            history.append(token)
            emit(token)
            return outcome.generated.count < request.maxTokens
        }

        var going = true
        while going, !cancelled.isSet, !Task.isCancelled {
            if plain {
                // Plain and pipelined: each token's successor is queued before the token is handed out. Stops
                // when the text so far ends with something seen before.
                var current = MLXArray([Int32(truncatingIfNeeded: pending)])
                while going, !cancelled.isSet, !Task.isCancelled {
                    let next = draw(forward(current)[0])
                    asyncEval(next)
                    going = take(current.item(Int.self))
                    current = next
                    if holdOff > 0 {
                        holdOff -= 1
                    } else if Self.lookupDrafts, drafter != nil
                        || !PromptLookup.draft(history, maxNgram: 4, minNgram: 3, maxTokens: 1).isEmpty
                    {
                        break
                    }
                }
                pending = current.item(Int.self)
                plain = false
                continue
            }

            guard take(pending) else { break }
            let most = min(
                guessLength, request.speculativeMaxTokens ?? Self.maxDraft, request.maxTokens - outcome.generated.count
            )
            var draft = PromptLookup.draft(history, maxNgram: 4, minNgram: 3, maxTokens: most)
            if draft.isEmpty, let drafter {
                // Nothing to look up: the draft model guesses instead.
                draft = drafter.propose(after: history, count: min(most, Self.maxModelDraft))
            }
            if draft.isEmpty {
                // It stopped recurring: back to plain.
                pending = draw(forward([pending])[0]).item(Int.self)
                plain = true
                continue
            }
            let input = [pending] + draft
            let before = untrimmable ? Self.snapshot(layers) : [:]
            let rows = forward(input)

            // How many guesses to keep, and the token after them.
            var kept = 0
            let next: Int
            if sampler.temperature <= 0 {
                let best = argMax(rows, axis: -1).asArray(Int32.self).map(Int.init)
                while kept < draft.count, best[kept] == draft[kept] {
                    kept += 1
                }
                next = best[kept]
            } else {
                let probabilities = sampler.probabilities(rows)
                let guessed = MLXArray(draft.map { Int32(truncatingIfNeeded: $0) }).expandedDimensions(axis: -1)
                let chance = takeAlong(probabilities[..<draft.count], guessed, axis: -1).squeezed(axis: -1)
                    .asArray(Float.self)
                let roll = MLXRandom.uniform(0 ..< 1, [draft.count], key: sampler.state).asArray(Float.self)
                while kept < draft.count, roll[kept] < chance[kept] {
                    kept += 1
                }
                let remaining = probabilities[kept]
                if kept < draft.count {
                    // The rejected guess can't be the draw.
                    remaining[draft[kept]] = MLXArray(Float(0))
                }
                next = categorical(log(remaining), key: sampler.state).item(Int.self)
            }
            outcome.drafted += draft.count
            outcome.accepted += kept

            // Undo what wasn't kept.
            let unkept = draft.count - kept
            if unkept > 0 {
                if before.isEmpty {
                    for layer in layers {
                        layer.trim(unkept)
                    }
                } else {
                    for layer in layers where layer.isTrimmable {
                        layer.trim(input.count)
                    }
                    for (index, layer) in before {
                        layers[index] = layer
                    }
                    _ = forward(Array(input[...kept]))
                }
            }
            if kept == 0 {
                plain = true
                holdOff = backoff
                backoff = min(backoff * 2, Self.maxBackoff)
                guessLength = 2
            } else {
                backoff = Self.lookEvery
                guessLength = unkept == 0 ? min(guessLength * 2, Self.maxDraft) : max(2, kept + 1)
            }

            for token in draft[..<kept] where going {
                going = take(token)
            }
            pending = next
        }
        outcome.generateSeconds = generating.duration(to: .now).seconds
        return outcome
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

    /// For each row of `logits`, the distribution `sample` draws from (the same filters and temperature), as
    /// probabilities over the whole vocabulary: what a speculative guess is checked against. Temperature
    /// above 0 only.
    func probabilities(_ logits: MLXArray) -> MLXArray {
        let negInf = MLXArray(-Float.infinity)
        let logprobs = logSoftmax(logits.asType(.float32), axis: -1)
        let vocabulary = logprobs.dim(-1)
        let k = topK > 0 && topK < vocabulary ? topK : vocabulary
        let candidates = argPartition(-logprobs, kth: k - 1, axis: -1)[0..., ..<k]
        var kept = takeAlong(logprobs, candidates, axis: -1)
        if topP > 0, topP < 1 {
            let order = argSort(kept, axis: -1)
            let sorted = takeAlong(kept, order, axis: -1)
            let cumulative = cumsum(exp(sorted), axis: -1)
            let total = cumulative.max(axis: -1, keepDims: true)
            kept = putAlong(kept, order, values: MLX.where(cumulative .> (total - topP), sorted, negInf), axis: -1)
        }
        if minP > 0 {
            let threshold = kept.max(axis: -1, keepDims: true) + log(MLXArray(minP))
            kept = MLX.where(kept .>= threshold, kept, negInf)
        }
        let masked = putAlong(MLX.full(logprobs.shape, values: negInf), candidates, values: kept, axis: -1)
        return softmax(masked * (1 / temperature), axis: -1)
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

struct TokenizerBridgeLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try await TokenizerBridge(inner: AutoTokenizer.from(modelFolder: directory))
    }
}
