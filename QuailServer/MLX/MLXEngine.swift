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
/// model directory. Requests queue for one serving task (`serve`), which runs inside the `ModelContainer`
/// and, for a model family that batches, decodes up to `parallel` text requests together (ADR D-056).
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
    /// Text requests decoded together, at most, by a model family that batches.
    private let parallel: Int
    private let queue = MLXQueue()

    /// - Parameter parallel: how many text requests may be decoded together (ADR D-056); 1 serves one at a time.
    init(parallel: Int = 1) {
        self.parallel = max(1, parallel)
    }

    /// Images, for a model whose vision half Quail can load (`MLXVision`); several requests at once, for a
    /// model family that batches.
    var capabilities: EngineCapabilities {
        lock.withLock {
            EngineCapabilities(vision: entry?.mlxVision ?? false, concurrentRequests: (loaded?.batchLimit ?? 1) > 1)
        }
    }

    /// Batched decoding (ADR D-056): on for the model families checked to give the same text batched as alone,
    /// off with `QUAIL_MLX_BATCH=0`, and on for any model whose caches can batch with `QUAIL_MLX_BATCH=1`.
    static let batchSetting = ProcessInfo.processInfo.environment["QUAIL_MLX_BATCH"]
    /// `model_type`s whose batched text was checked against the same requests run alone.
    static let batchedFamilies: Set<String> = ["qwen3", "qwen3_5", "qwen3_5_moe", "gemma4"]

    /// Whether MLX's buffer cache is limited and cleared while serving (`BufferCachePolicy`, #137); off with
    /// `QUAIL_MLX_CLEAR_CACHE=0`, which leaves MLX's defaults (a cache up to about the whole of memory).
    static let managesBufferCache = ProcessInfo.processInfo.environment["QUAIL_MLX_CLEAR_CACHE"] != "0"

    /// Gives MLX's cached buffers back to macOS, once the GPU has finished with the work queued so far.
    static func clearBufferCache() {
        Stream.defaultStream(.gpu).synchronize()
        Memory.clearCache()
    }

    /// Everything a request needs from the loaded model; replaced whole on load.
    final class Loaded: @unchecked Sendable {
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
        /// Text requests decoded together at most: 1 unless the family batches (ADR D-056).
        let batchLimit: Int
        /// Bits per element the KV cache is quantized to, if the preset asks (ADR D-057).
        let kvBits: Int?

        init(
            container: ModelContainer, info: EngineInfo, chatTemplate: String?,
            tokenizer: any MLXLMCommon.Tokenizer, vision: VisionSetup?, weightBytes: Int, disk: PromptDiskCache?,
            batchLimit: Int, kvBits: Int?
        ) {
            self.container = container
            self.info = info
            self.chatTemplate = chatTemplate
            self.tokenizer = tokenizer
            self.vision = vision
            self.weightBytes = weightBytes
            self.disk = disk
            self.batchLimit = batchLimit
            self.kvBits = kvBits
        }

        /// Whether a text prompt can be fed in pieces, positions coming from the cache: any text load, and Gemma
        /// 4's vision load (a model that only loads that way, Gemma 4 26B-A4B), whose vision model reads a text
        /// prompt as its text model does. Other vision models (Qwen3.5's keeps position state that only the
        /// iterator's `prepare` resets) are fed whole and reuse only a cache they can cut back (`runWhole`).
        var sliceable: Bool {
            vision.map { $0.family == .gemma4 } ?? true
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
    final class PromptCaches: @unchecked Sendable {
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

    /// Elements sharing one scale and bias in a quantized KV cache (mlx-lm's default).
    static let kvGroupSize = 64

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
    /// Prompt tokens read at a time with nothing else in progress, after `fed` of them (#139): 2,048, as mlx-lm reads
    /// them (Qwen3.6's 4,096-token prompt took 7.0 s instead of 8.3 s on the M1 Max), while the prompt so far is
    /// short enough for a slice's attention scores to stay near a gigabyte. Qwen3.5's and Gemma 4's attention heads
    /// are too wide for MLX's fused kernel, which then materialises the scores; past 8,192 tokens, the library's 512.
    /// A newcomer read between the others' steps always goes in 512, so it holds them up less at a time.
    static func aloneSliceTokens(after fed: Int) -> Int {
        fed < 8192 ? 2048 : 512
    }

    /// Copies of the layers that can't be cut back. References, not data: the model replaces these arrays
    /// rather than writing into them.
    static func snapshot(_ layers: [any KVCache]) -> [Int: any KVCache] {
        Dictionary(uniqueKeysWithValues: layers.enumerated().compactMap { index, layer in
            !layer.isTrimmable || layer.maxSize != nil ? (index, layer.copy()) : nil
        })
    }

    /// How many tokens a cache has been fed: the largest layer offset (a recurrent layer keeps none).
    static func held(_ layers: [any KVCache]) -> Int {
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
        await QuailModels.register()
        lock.withLock { self.entry = entry }
        if Self.managesBufferCache, let workingSet = GPU.maxRecommendedWorkingSetBytes() {
            Memory.cacheLimit = BufferCachePolicy.limit(workingSet: workingSet)
        }
        do {
            try await load(entry, vision: false)
        } catch where entry.mlxVision {
            FileHandle.standardError.write(Data(
                "\(entry.id): the text-only load failed, so it's served by its vision model (\(error))\n".utf8
            ))
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
            let canBatch = await container.perform { context in
                BatchedLayers.canBatch(context.model.newCache(parameters: nil))
                    && (context.model as? QGemma4Model)?.ownsEveryCache ?? true
            }
            let batched = switch Self.batchSetting {
            case "0": false
            case "1": canBatch
            default: canBatch && files.modelType.map(Self.batchedFamilies.contains) == true
            }
            // A quantized cache doesn't batch (`BatchedLayers.canBatch`).
            let batchLimit = batched && !vision && entry.mlxKVBits == nil ? parallel : 1
            let info = EngineInfo(
                contextSize: contextSize,
                bosToken: files.token("bos_token") ?? tokenizer.bosToken ?? "",
                eosToken: files.token("eos_token") ?? tokenizer.eosToken ?? "",
                supportsImages: entry.mlxVision,
                slots: batchLimit
            )
            let made = Loaded(
                container: container, info: info, chatTemplate: files.chatTemplate, tokenizer: tokenizer,
                vision: vision ? files.visionSetup : nil, weightBytes: weightBytes,
                disk: PromptDiskCache(
                    root: entry.promptCacheDirectory,
                    entry: entry,
                    weightBytes: weightBytes,
                    vision: vision
                ),
                batchLimit: batchLimit, kvBits: entry.mlxKVBits
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
    /// Only the serving task calls this, between requests, so swapping here is safe.
    private func loadedFor(_ request: GenerationRequest) async throws -> Loaded {
        guard let current else { throw EngineError.notLoaded }
        guard needsSwap(request, from: current), let entry = lock.withLock({ entry }) else { return current }
        await current.container.perform { _ in current.spillAll() }
        lock.withLock { loaded = nil }
        Memory.clearCache()
        try await load(entry, vision: !request.media.isEmpty)
        guard let swapped = self.current else { throw EngineError.notLoaded }
        return swapped
    }

    /// Whether `request` needs the other load than `loaded`.
    private func needsSwap(_ request: GenerationRequest, from loaded: Loaded) -> Bool {
        let wantsVision = !request.media.isEmpty
        return wantsVision != (loaded.vision != nil) && !lock.withLock { visionOnly }
            && (lock.withLock { entry?.mlxVision } == true || !wantsVision)
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

    /// What MLX's allocator holds (`GET /slots`): live arrays (weights, caches and work in progress) and the freed
    /// buffers it keeps for reuse, which macOS counts against the process until they're given back.
    func memoryBytes() async -> Int? {
        Memory.activeMemory + Memory.cacheMemory
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
            let job = MLXJob(request: request, emit: { continuation.yield($0) }, finish: { error in
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            })
            // The serving task notices a client that left by this flag, between steps.
            continuation.onTermination = { _ in job.cancelled.set() }
            if queue.add(job) {
                Task { await self.serve() }
            }
        }
    }

    /// The one task that serves the queue, oldest request first, until it's empty: text requests through
    /// `serveText` (together, for a family that batches), image turns and whole-prompt loads one at a time.
    private func serve() async {
        while let job = queue.nextOrStop() {
            if job.cancelled.isSet {
                queue.remove(job)
                job.done()
                continue
            }
            do {
                let loaded = try await loadedFor(job.request)
                // Weights kept wired while requests run, as mlx-lm does with `set_wired_limit`, so macOS doesn't
                // page a large model out between tokens under memory pressure (ADR D-055). The limit returns to
                // where it was when no request holds a ticket.
                let wired = WiredMemoryTicket(size: loaded.weightBytes, policy: MLXLMCommon.WiredSumPolicy())
                if job.request.media.isEmpty, loaded.sliceable {
                    await wired.withWiredLimit {
                        await loaded.container.perform { context in
                            self.serveText(context: context, loaded: loaded)
                        }
                    }
                } else {
                    queue.remove(job)
                    try await wired.withWiredLimit {
                        try await loaded.container.perform { context in
                            try await Self.runWhole(
                                job.request, context: context, loaded: loaded, cancelled: job.cancelled, emit: job.emit
                            )
                        }
                    }
                    job.done()
                }
            } catch {
                queue.remove(job)
                job.done(error)
            }
        }
    }

    /// Serves text requests on a load that feeds prompts in slices, while the oldest waiting request is one of
    /// them; returns when none is left in progress and the next (if any) needs something else.
    ///
    /// A request's prompt is fed alone, in slices; with nothing else in progress it then decodes alone, with
    /// prompt-lookup speculation, as before batching. For a family that batches, a request that arrives meanwhile
    /// is fed between the others' steps, one slice a step, and then joins them: each step feeds every sequence's
    /// next token as one `[B, 1]` batch through `BatchedLayers`, and each row is drawn with its own sampler. A
    /// sequence that ends leaves the batch with its cache, which goes back to the prompt caches; with one left, it
    /// decodes alone again. Steps are pipelined: the next tokens are queued before the last ones are handed out.
    private func serveText(context: ModelContext, loaded: Loaded) {
        var active: [MLXSequence] = []
        var batch: [any KVCache]?
        // The active sequences' next tokens when the last step drew them (else each one's `pending`).
        var current: MLXArray?
        var joining: MLXSequence?
        var bytesPerToken = 0
        var clearing = BufferCachePolicy()
        defer {
            if Self.managesBufferCache {
                Self.clearBufferCache()
            }
        }

        /// Counts a decode step, and clears the buffer cache when it's due.
        func stepped() {
            if Self.managesBufferCache, clearing.step() {
                Memory.clearCache()
            }
        }

        /// Whether a waiting request can start now.
        func admissible(_ job: MLXJob) -> Bool {
            guard job.request.media.isEmpty, self.current === loaded, !needsSwap(job.request, from: loaded)
            else { return false }
            if active.isEmpty, joining == nil {
                return true
            }
            guard joining == nil, active.count < loaded.batchLimit else { return false }
            // Rows are left-padded to the longest, and every step reads the padding too: a request much longer or
            // shorter than the others waits rather than cost the batch more than a quarter of the weights' reading.
            let lengths = active.map(\.history.count) + [job.request.promptTokens.count]
            let width = lengths.max() ?? 0
            let padding = lengths.reduce(0) { $0 + width - $1 }
            return padding * bytesPerToken <= loaded.weightBytes / 4
        }

        /// Hands the finished sequences at `leaving` their caches back and closes their replies.
        func leave(_ leaving: [Int]) {
            let staying = active.indices.filter { !leaving.contains($0) }
            for index in leaving {
                let sequence = active[index]
                if let batch {
                    sequence.layers = BatchedLayers.slice(batch, row: index)
                }
                sequence.finish(in: loaded)
                sequence.job.done()
                clearing.finished()
            }
            if let rows = batch {
                if staying.count >= 2 {
                    BatchedLayers.filter(rows, keeping: staying)
                    current = current?[MLXArray(staying.map { Int32($0) })]
                } else if let only = staying.first {
                    active[only].layers = BatchedLayers.slice(rows, row: only)
                    current = current?[only ..< only + 1]
                    batch = nil
                } else {
                    batch = nil
                    current = nil
                }
            } else {
                current = nil
            }
            active = staying.map { active[$0] }
        }

        /// One token for every active sequence.
        func step() {
            let layers = batch ?? active[0].layers
            let tokens = current ?? MLXArray(active.map { Int32(truncatingIfNeeded: $0.pending ?? 0) })
            let logits = context.model(
                .init(tokens: tokens.reshaped(active.count, 1)), cache: layers, state: nil
            ).logits
            let drawn = active.enumerated().map { index, sequence in
                let row = logits[index ..< index + 1, 0, 0...]
                sequence.ban(row)
                return sequence.draw(row[0])
            }
            let next = concatenated(drawn)
            asyncEval(next)
            let values = tokens.asArray(Int32.self)
            var leaving: [Int] = []
            for (index, sequence) in active.enumerated()
                where sequence.cancelled || !sequence.take(Int(values[index]))
            {
                leaving.append(index)
            }
            current = next
            if !leaving.isEmpty {
                leave(leaving)
            }
            stepped()
        }

        /// A sequence whose prompt is fed joins the active ones.
        func join(_ sequence: MLXSequence) {
            if let batch {
                BatchedLayers.extend(batch, with: sequence.layers)
            } else {
                batch = BatchedLayers.merge([active[0].layers, sequence.layers])
            }
            let earlier = current ?? MLXArray(active.map { Int32(truncatingIfNeeded: $0.pending ?? 0) })
            current = concatenated([earlier, MLXArray([Int32(truncatingIfNeeded: sequence.pending ?? 0)])])
            active.append(sequence)
            for sequence in active {
                sequence.layers = []
            }
        }

        func start(_ job: MLXJob) -> MLXSequence? {
            queue.remove(job)
            guard !job.cancelled.isSet else {
                job.done()
                return nil
            }
            do {
                return try MLXSequence(job, context: context, loaded: loaded)
            } catch {
                job.done(error)
                return nil
            }
        }

        while true {
            if joining == nil, let job = queue.first, admissible(job) {
                joining = start(job)
                continue
            }
            if let sequence = joining, active.isEmpty {
                // Nothing else in progress: the whole prompt, pipelined.
                joining = nil
                while !sequence.prefilled, !sequence.cancelled {
                    MLXTrace.time("slice", ["batch": 0]) {
                        sequence.prefillSlice(
                            context: context,
                            tokens: Self.aloneSliceTokens(after: sequence.fedTokens)
                        )
                    }
                }
                if sequence.cancelled {
                    sequence.abandonPrefill(in: loaded)
                    sequence.job.done()
                    continue
                }
                MLXTrace.time("first", ["batch": 0, "prompt": sequence.prompt.count - sequence.reused]) {
                    sequence.startDecoding(context: context)
                }
                if bytesPerToken == 0 {
                    bytesPerToken = BatchedLayers.bytesPerToken(sequence.layers)
                }
                active = [sequence]
                continue
            }
            if joining == nil, batch == nil, active.count == 1 {
                let sequence = active[0]
                if let tokens = current {
                    sequence.pending = tokens.item(Int.self)
                    current = nil
                }
                let before = sequence.generated.count
                let finished = MLXTrace.time("alone") {
                    sequence.decodeAlone(context: context) {
                        stepped()
                        return queue.first.map(admissible) ?? false
                    }
                }
                MLXTrace.note("alone-tokens", ["tokens": sequence.generated.count - before])
                if finished {
                    sequence.finish(in: loaded)
                    sequence.job.done()
                    clearing.finished()
                    active = []
                }
                continue
            }
            if active.isEmpty, joining == nil {
                return
            }
            if let sequence = joining {
                if sequence.cancelled {
                    joining = nil
                    sequence.abandonPrefill(in: loaded)
                    sequence.job.done()
                } else if !sequence.prefilled {
                    MLXTrace.time("slice", ["batch": active.count]) { sequence.prefillSlice(context: context) }
                } else {
                    joining = nil
                    MLXTrace.time("first", ["batch": active.count, "prompt": sequence.prompt.count - sequence.reused]) {
                        sequence.startDecoding(context: context)
                    }
                    MLXTrace.time("join", ["batch": active.count]) { join(sequence) }
                }
            }
            if !active.isEmpty {
                MLXTrace.time("step", ["batch": active.count]) { step() }
            }
        }
    }

    /// A request on a load that reads its prompt whole (`Loaded.sliceable`), through mlx-swift-lm's own
    /// iterator: an image turn, or a text turn on a vision load other than Gemma 4's, which goes in as a batch
    /// of one ([1, n]), as the vision half's language model reads it, reusing only a cache it can cut back.
    private static func runWhole(
        _ request: GenerationRequest, context: ModelContext, loaded: Loaded, cancelled: CancelFlag,
        emit: @escaping @Sendable (GenerationEvent) -> Void
    ) async throws {
        if !request.media.isEmpty {
            try await runWithImages(request, context: context, loaded: loaded, cancelled: cancelled, emit: emit)
            return
        }
        let prompt = request.promptTokens
        guard !prompt.isEmpty else { throw EngineError.generationFailed("the prompt has no tokens") }
        let parameters = Self.parameters(for: request, kvBits: loaded.kvBits)
        var layers: [any KVCache]
        var reused = 0
        if request.cachePrompt, let taken = loaded.caches.take(for: prompt, trimmableOnly: true) {
            (layers, reused) = (taken.layers, taken.tokens.count)
        } else {
            layers = context.model.newCache(parameters: parameters)
        }
        let remaining = MLXArray(prompt[reused...].map { Int32(truncatingIfNeeded: $0) })
        var processor = parameters.processor()
        if request.ignoreEndOfSequence {
            processor = BanTokens(ids: Self.stopTokens(context), wrapping: processor)
        }

        // The prompt is processed here, in the iterator's initialiser.
        let iterator = try TokenIterator(
            input: LMInput(text: .init(tokens: remaining.expandedDimensions(axis: 0))), model: context.model,
            cache: layers, processor: processor, sampler: SeededSampler(request.sampling),
            prefillStepSize: parameters.prefillStepSize, maxTokens: request.maxTokens
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
            if cancelled.isSet {
                break
            }
            switch event {
            case let .token(id):
                generated.append(id)
                detokenizer.append(token: id)
                emit(.token(id: id, text: detokenizer.next() ?? ""))
            case let .info(info):
                finished = info
            }
        }
        task.cancel()
        await task.value

        Self.keep(layers, prompt: prompt, generated: generated, checkpoints: [:], checkpointCount: 0, in: loaded)

        // The library reports a reply that hit the token limit as "cancelled" (it looks at a copy of the
        // iterator), so only a hang-up is taken as one here.
        guard let info = finished, !cancelled.isSet else { return }
        emit(.finished(info.stopReason == .stop ? .stop : .length, GenerationTimings(
            promptTokens: prompt.count - reused, promptSeconds: info.promptTime,
            generatedTokens: info.generationTokenCount, generatedSeconds: info.generateTime,
            cachedTokens: reused
        )))
    }

    /// Keeps the cache a request leaves for the next. It holds the prompt, then each token fed back in (a stop
    /// token too, or a guess past the end, which aren't in `generated`): what can be named is kept, and a cache
    /// that can't be cut back to that goes back to its checkpoint.
    static func keep(
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
        let parameters = Self.parameters(for: request, kvBits: loaded.kvBits)
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

    static func parameters(for request: GenerationRequest, kvBits: Int? = nil) -> GenerateParameters {
        let s = request.sampling
        return GenerateParameters(
            maxTokens: request.maxTokens, kvBits: kvBits, kvGroupSize: Self.kvGroupSize,
            temperature: Float(s.temperature), topP: Float(s.topP), topK: s.topK,
            minP: Float(s.minP), repetitionPenalty: s.repeatPenalty != 1 ? Float(s.repeatPenalty) : nil,
            repetitionContextSize: 64, presencePenalty: s.presencePenalty != 0 ? Float(s.presencePenalty) : nil,
            frequencyPenalty: s.frequencyPenalty != 0 ? Float(s.frequencyPenalty) : nil
        )
    }

    static func stopTokens(_ context: ModelContext) -> [Int] {
        var ids = Set(context.configuration.eosTokenIds.map(\.self))
        if let eos = context.tokenizer.eosTokenId {
            ids.insert(eos)
        }
        // A chat model's end-of-turn token, which some conversions leave out of their end-of-sequence ids (Gemma
        // 3 1B's config lists only `<eos>`, and its repo has no generation_config.json, so it wrote past
        // `<end_of_turn>`). llama.cpp treats these as end of generation from the vocabulary; so does this, for a
        // token the tokenizer really has.
        for token in endOfTurnTokens {
            if let id = context.tokenizer.convertTokenToId(token), context.tokenizer.convertIdToToken(id) == token {
                ids.insert(id)
            }
        }
        return Array(ids)
    }

    /// End-of-turn tokens of common chat templates (from llama.cpp's end-of-generation list). Not `<|endoftext|>`,
    /// which some models use inside a turn, nor `<|end|>`, which ends each Harmony message of gpt-oss's reply
    /// (its reasoning comes first), and which Phi-3 lists as its end of sequence anyway.
    static let endOfTurnTokens = ["<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<|eom_id|>"]
}

/// mlx-swift-lm's samplers each draw from a random state seeded at random, which leaves no way to
/// honour a request's `seed`; this is the same top-p, min-p, top-k, temperature draw (mlx-lm's order and
/// definitions) with a state of ours. Temperature 0 is greedy.
struct SeededSampler: LogitSampler {
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

/// Set once from any thread, read by the serving task.
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

    /// The architecture's name, as `config.json` gives it.
    var modelType: String? {
        json("config.json")?["model_type"] as? String
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
