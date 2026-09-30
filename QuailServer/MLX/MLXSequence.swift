import Foundation
import MLX
import MLXLMCommon
import QuailServerCore

/// A request waiting for, or being served by, the MLX engine's one serving task (ADR D-056).
final class MLXJob: @unchecked Sendable {
    let request: GenerationRequest
    /// Set when the client goes away; the serving task checks it between steps.
    let cancelled = CancelFlag()
    let emit: @Sendable (GenerationEvent) -> Void
    private let finish: @Sendable ((any Error)?) -> Void
    private let lock = NSLock()
    private var finished = false

    init(
        request: GenerationRequest, emit: @escaping @Sendable (GenerationEvent) -> Void,
        finish: @escaping @Sendable ((any Error)?) -> Void
    ) {
        self.request = request
        self.emit = emit
        self.finish = finish
    }

    /// Ends the reply's stream, with an error or without; only the first call counts.
    func done(_ error: (any Error)? = nil) {
        let first = lock.withLock {
            defer { finished = true }
            return !finished
        }
        if first {
            finish(error)
        }
    }
}

/// The MLX engine's waiting requests, oldest first, and whether a task is serving them.
final class MLXQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [MLXJob] = []
    private var serving = false

    /// Queues a job; true when no task is serving, and the caller should start one.
    func add(_ job: MLXJob) -> Bool {
        lock.withLock {
            jobs.append(job)
            defer { serving = true }
            return !serving
        }
    }

    /// The oldest job, left queued.
    var first: MLXJob? {
        lock.withLock { jobs.first }
    }

    /// For the serving task: the oldest job, left queued; nil when there's none, and then the task stops, so the
    /// next `add` starts another.
    func nextOrStop() -> MLXJob? {
        lock.withLock {
            if jobs.isEmpty {
                serving = false
            }
            return jobs.first
        }
    }

    func remove(_ job: MLXJob) {
        lock.withLock { jobs.removeAll { $0 === job } }
    }
}

/// One text request's generation in the MLX engine: its cache, how far its prompt is fed, what it has handed out,
/// and its sampler. Its prompt is fed alone, in slices (`prefillSlice`), then it decodes alone (`decodeAlone`,
/// with prompt-lookup speculation) or as one row of a batch (`MLXEngine.serveText`), moving between the two
/// whenever a token has been handed out and the next one drawn but not yet fed (`pending`).
final class MLXSequence {
    let job: MLXJob
    let prompt: [Int]
    /// This sequence's own caches; empty while they're merged into a batch.
    var layers: [any KVCache]
    let reused: Int
    private(set) var checkpoints: [Int: [Int: any KVCache]]
    private(set) var checkpointCount = 0
    private var fed: Int
    private let feedTo: Int
    private let untrimmable: Bool
    private var inFlight: [[MLXArray]] = []
    private let step: Int
    /// Bits the attention caches are quantized to once they hold anything (ADR D-057), or nil.
    private let kvBits: Int?

    let sampler: SeededSampler
    private var processor: (any LogitProcessor)?
    private let stops: Set<Int>
    private let banned: [Int]
    private var detokenizer: NaiveStreamingDetokenizer
    private(set) var generated: [Int] = []
    /// The prompt and every token handed out: what the cache holds between steps.
    private(set) var history: [Int]
    private var stopped = false
    /// The next token, drawn but not yet handed out or fed.
    var pending: Int?

    private let started = ContinuousClock.now
    private var firstToken: ContinuousClock.Instant?
    private var drafted = 0
    private var accepted = 0

    var request: GenerationRequest {
        job.request
    }

    var cancelled: Bool {
        job.cancelled.isSet
    }

    /// Prompt tokens in the cache so far.
    var fedTokens: Int {
        fed
    }

    var prefilled: Bool {
        fed >= feedTo
    }

    /// Starts from the kept cache that holds the most of this prompt (always leaving at least one token to feed,
    /// whose logits the first draw needs), and works out where slicing stops.
    init(_ job: MLXJob, context: ModelContext, loaded: MLXEngine.Loaded) throws {
        self.job = job
        let request = job.request
        prompt = request.promptTokens
        guard !prompt.isEmpty else { throw EngineError.generationFailed("the prompt has no tokens") }
        let parameters = MLXEngine.parameters(for: request, kvBits: loaded.kvBits)
        kvBits = loaded.kvBits

        // A cache on disk is loaded instead when it holds clearly more (loading costs about as much as reading
        // `checkpointMargin` tokens).
        var layers: [any KVCache]
        var reused = 0
        var checkpoints: [Int: [Int: any KVCache]] = [:]
        let fromDisk = request.cachePrompt && (loaded.disk?.bestReuse(for: prompt) ?? 0)
            > loaded.caches.bestReuse(for: prompt, trimmableOnly: false) + MLXEngine.checkpointMargin
        if fromDisk, let taken = loaded.disk?.take(for: prompt) {
            (layers, reused) = taken
        } else if request.cachePrompt, let taken = loaded.caches.take(for: prompt, trimmableOnly: false) {
            (layers, reused, checkpoints) = (taken.layers, taken.tokens.count, taken.checkpoints)
        } else {
            layers = try context.model.newCache(parameters: parameters)
        }
        self.layers = layers
        self.reused = reused
        self.checkpoints = checkpoints
        fed = reused

        // Prefill in slices of the library's step size, so a client that leaves during a long prompt stops it at
        // the next slice, and so other sequences can decode between slices. The last one to two slices are fed
        // with the first draw (`startDecoding`), which also hands the penalty processors the tail of the prompt.
        //
        // A hybrid model's recurrent layers (and sliding-window layers) can't be cut back afterwards, so the point
        // the next turn of a conversation resumes from is captured on the way instead: `checkpointMargin` tokens
        // short of the prompt's end, before the chat template's generation header, which the next turn's history
        // renders differently (a reasoning block dropped, or an empty one added). Checkpoints are also taken every
        // `checkpointInterval` tokens on the way. Stopping short costs a forward pass of its own (on a 512-token
        // prompt, 15% of Gemma 4 26B-A4B's prompt time), so it's done only for a request that asks for its prompt
        // to be cached.
        step = parameters.prefill.stepSize ?? 512
        untrimmable = request.cachePrompt && layers.contains { !$0.isTrimmable || $0.maxSize != nil }
        var feedTo = reused
        if untrimmable {
            feedTo = max(reused, prompt.count - MLXEngine.checkpointMargin)
        } else {
            while prompt.count - feedTo > 2 * step {
                feedTo += step
            }
        }
        self.feedTo = feedTo

        sampler = SeededSampler(request.sampling)
        processor = parameters.processor()
        let stops = Set(MLXEngine.stopTokens(context))
        self.stops = stops
        banned = request.ignoreEndOfSequence ? Array(stops) : []
        detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        history = prompt
        job.emit(.promptProgress(done: reused, total: prompt.count, cached: reused))
    }

    // MARK: Prompt

    /// Feeds the next slice of the prompt. Each slice is queued with `asyncEval` and only the one `slicesInFlight`
    /// back is waited for, so the GPU always has work queued while the CPU builds the next graph (mlx-swift-lm
    /// 3.31.4 pipelines its own prefill the same way; with one slice in flight Gemma 4's prompts ran 3–5% slower
    /// than the library's). A hang-up is still noticed within two or three slices.
    func prefillSlice(context: ModelContext, tokens: Int? = nil) {
        guard fed < feedTo else { return }
        let count = min(tokens ?? step, feedTo - fed)
        let slice = MLXArray(prompt[fed ..< fed + count].map { Int32(truncatingIfNeeded: $0) })
        _ = context.model(.init(tokens: slice.expandedDimensions(axis: 0)), cache: layers, state: nil)
        let queued = layers.flatMap { $0.innerState() }
        asyncEval(queued)
        inFlight.append(queued)
        if inFlight.count > MLXEngine.slicesInFlight {
            eval(inFlight.removeFirst())
        }
        fed += count
        job.emit(.promptProgress(done: fed, total: prompt.count, cached: reused))
        quantize()
        if untrimmable, fed < feedTo,
           fed - (checkpoints.keys.max() ?? reused) >= MLXEngine.checkpointInterval
        {
            checkpoints[fed] = MLXEngine.snapshot(layers)
        }
    }

    /// Feeds the rest of the prompt and draws the first token.
    func startDecoding(context: ModelContext) {
        inFlight = []
        if untrimmable {
            checkpoints[fed] = MLXEngine.snapshot(layers)
        }
        checkpointCount = fed
        let rest = Array(prompt[fed...])
        processor?.prompt(MLXArray(rest.map { Int32(truncatingIfNeeded: $0) }))
        // All but the last token first, whose logits are never read (so never computed), then the last.
        if rest.count > 1 {
            _ = forward(Array(rest.dropLast()), context: context)
        }
        pending = draw(forward([rest[rest.count - 1]], context: context)[0]).item(Int.self)
        fed = prompt.count
        firstToken = .now
    }

    /// A client that left while its prompt was being fed: what the cache holds is a prefix of the prompt, kept for
    /// a retry.
    func abandonPrefill(in loaded: MLXEngine.Loaded) {
        eval(layers)
        for evicted in loaded.caches.put(.init(
            layers: layers, tokens: Array(prompt.prefix(fed)), checkpoints: checkpoints
        )) {
            loaded.spill(evicted)
        }
    }

    // MARK: Steps

    /// This sequence's logits for `tokens` fed after what its cache holds, one row per token.
    func forward(_ tokens: [Int], context: ModelContext) -> MLXArray {
        forward(MLXArray(tokens.map { Int32(truncatingIfNeeded: $0) }), context: context)
    }

    func forward(_ input: MLXArray, context: ModelContext) -> MLXArray {
        let rows = context.model(.init(tokens: input.expandedDimensions(axis: 0)), cache: layers, state: nil)
            .logits[0]
        quantize()
        ban(rows)
        return rows
    }

    /// Swaps the plain attention caches for quantized ones, once, when the model asks for a quantized cache:
    /// what they hold so far is quantized then, and every later token as it's added. Recurrent and
    /// sliding-window layers stay as they are (mlx-swift-lm's `maybeQuantizeKVCache`).
    private func quantize() {
        guard let kvBits else { return }
        maybeQuantizeKVCache(cache: &layers, kvBits: kvBits, kvGroupSize: MLXEngine.kvGroupSize)
    }

    /// Makes the end-of-sequence tokens unsampleable for `ignore_eos`, in place.
    func ban(_ rows: MLXArray) {
        for id in banned {
            rows[0..., id] = MLXArray(-Float.infinity)
        }
    }

    /// The token after one row of logits, not yet computed, through the penalty processors if any.
    func draw(_ row: MLXArray) -> MLXArray {
        var logits = row.expandedDimensions(axis: 0)
        guard var processor else { return sampler.sample(logits: logits) }
        logits = processor.process(logits: logits)
        let token = sampler.sample(logits: logits)
        processor.didSample(token: token)
        self.processor = processor
        return token
    }

    /// Hands a token out; false once generation should end (a stop token, which isn't handed out, or the length
    /// limit).
    func take(_ token: Int) -> Bool {
        if !request.ignoreEndOfSequence, stops.contains(token) {
            stopped = true
            return false
        }
        generated.append(token)
        history.append(token)
        detokenizer.append(token: token)
        job.emit(.token(id: token, text: detokenizer.next() ?? ""))
        return generated.count < request.maxTokens
    }

    // MARK: Decoding alone

    /// Off with `QUAIL_PROMPT_LOOKUP=0` in the server's environment, to compare (`nodraft` too, the name it had
    /// when `0` meant mlx-swift-lm's own iterator).
    static let lookupEnabled = !["0", "nodraft"].contains(ProcessInfo.processInfo.environment["QUAIL_PROMPT_LOOKUP"])
    /// The most tokens guessed at once.
    static let maxDraft = 16
    /// Tokens run without looking after a wholly wrong guess; the pause doubles each time, up to `maxBackoff`.
    static let lookEvery = 8
    static let maxBackoff = 256

    /// Decodes with no other sequence to batch with, and prompt-lookup speculation (ADR D-055, Phase 3c step 6)
    /// when the request allows it. Returns true once the sequence has finished (or its client left), false when
    /// `shouldYield` asked it to stop so another sequence can join, with the cache holding `history` and the next
    /// token in `pending`.
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
    /// it happens again). The guess grows while guesses are kept and shrinks when they aren't. Penalty
    /// processors would have to see every guessed token in order, so a request with them never guesses.
    func decodeAlone(context: ModelContext, shouldYield: () -> Bool) -> Bool {
        guard var pending else { return true }
        let guessing = Self.lookupEnabled && processor == nil && request.maxTokens > 1
            && request.speculativeMaxTokens != 0
        let untrimmable = layers.contains { !$0.isTrimmable || $0.maxSize != nil }
        var plain = true
        var holdOff = 0
        var backoff = Self.lookEvery
        var guessLength = 4
        var going = true

        while going, !cancelled {
            if shouldYield() {
                self.pending = pending
                return false
            }
            if plain {
                // Plain and pipelined: each token's successor is queued before the token is handed out. Stops
                // when the text so far ends with something seen before, or another sequence wants to join.
                var current = MLXArray([Int32(truncatingIfNeeded: pending)])
                while going, !cancelled {
                    let next = draw(forward(current, context: context)[0])
                    asyncEval(next)
                    going = take(current.item(Int.self))
                    current = next
                    if shouldYield() {
                        break
                    }
                    if holdOff > 0 {
                        holdOff -= 1
                    } else if guessing, !PromptLookup.draft(history, maxNgram: 4, minNgram: 3, maxTokens: 1).isEmpty {
                        break
                    }
                }
                pending = current.item(Int.self)
                plain = false
                continue
            }

            guard take(pending) else { break }
            let draft = PromptLookup.draft(
                history, maxNgram: 4, minNgram: 3,
                maxTokens: min(
                    guessLength,
                    request.speculativeMaxTokens ?? Self.maxDraft,
                    request.maxTokens - generated.count
                )
            )
            if draft.isEmpty {
                // It stopped recurring: back to plain.
                pending = draw(forward([pending], context: context)[0]).item(Int.self)
                plain = true
                continue
            }
            let input = [pending] + draft
            let before = untrimmable ? MLXEngine.snapshot(layers) : [:]
            let rows = forward(input, context: context)

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
            drafted += draft.count
            accepted += kept

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
                    _ = forward(Array(input[...kept]), context: context)
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
        self.pending = nil
        return true
    }

    // MARK: Finishing

    /// Keeps the cache for the next request and, unless the client left, says how the reply ended.
    func finish(in loaded: MLXEngine.Loaded) {
        MLXEngine.keep(
            layers, prompt: prompt, generated: generated, checkpoints: checkpoints,
            checkpointCount: checkpointCount, in: loaded
        )
        guard !cancelled else { return }
        let first = firstToken ?? .now
        var timings = GenerationTimings(
            promptTokens: prompt.count - reused, promptSeconds: started.duration(to: first).seconds,
            generatedTokens: generated.count, generatedSeconds: first.duration(to: .now).seconds,
            cachedTokens: reused
        )
        if drafted > 0 {
            timings.draftTokens = drafted
            timings.draftAccepted = accepted
        }
        job.emit(.finished(stopped ? .stop : .length, timings))
    }
}
