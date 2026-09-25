import Foundation
import llama
import QuailServerCore

// Serving several requests from one loaded model (ADR D-048). A request takes a slot, which is a sequence of
// the shared context; a step of the scheduler decodes one batch holding a token for every request that is
// generating and a share of the prompt for every request that is still reading its prompt. Each step is its
// own block on the runtime's queue, so `tokenize` and the like run between steps instead of waiting for all
// the requests to end.

/// A request waiting for a slot.
struct PendingRequest {
    let request: GenerationRequest
    let cancelled: CancelFlag
    let emit: (GenerationEvent) -> Void
    /// Called once, with the error that ended the request, or nil if it ended (or was cancelled) without one.
    let finish: (Error?) -> Void
}

/// One sequence of the context.
final class Slot {
    let id: llama_seq_id
    /// The tokens whose keys and values this sequence holds, for prompt-prefix reuse.
    var cached: [llama_token] = []
    /// Which use of the slot was last, so the least recently used one is taken (and evicted) first.
    var lastUsed: UInt64 = 0
    var job: Job?

    init(id: llama_seq_id) {
        self.id = id
    }
}

/// A request being served.
final class Job {
    enum Phase { case prompt, generating }

    let pending: PendingRequest
    let sampler: UnsafeMutablePointer<llama_sampler>
    let grammar: UnsafeMutablePointer<llama_sampler>?
    var phase = Phase.prompt
    /// The prompt's tokens (with images, only its text tokens, which the samplers that look back read).
    var prompt: [llama_token]
    /// How many of them are in the context.
    var fed: Int
    let reused: Int
    /// The prompt's size in tokens, images included.
    let promptCount: Int
    var maxTokens: Int
    /// Set for a prompt with images, whose positions aren't token counts (an M-RoPE image spans fewer).
    var nextPosition: llama_pos?
    /// A sampled token that is yet to be decoded.
    var pendingToken: llama_token?
    var produced = 0
    var counted = 0
    var utf8 = UTF8Assembler()
    let started: ContinuousClock.Instant
    var promptDone: ContinuousClock.Instant?
    /// Where this step's batch has the logits to sample from.
    var row: Int32 = -1
    /// How many prompt tokens this step's batch carries.
    var chunk = 0

    var hasImages: Bool {
        !pending.request.media.isEmpty
    }

    init(
        pending: PendingRequest, sampler: UnsafeMutablePointer<llama_sampler>,
        grammar: UnsafeMutablePointer<llama_sampler>?, prompt: [llama_token], fed: Int, promptCount: Int,
        maxTokens: Int, started: ContinuousClock.Instant
    ) {
        self.pending = pending
        self.sampler = sampler
        self.grammar = grammar
        self.prompt = prompt
        self.fed = fed
        reused = fed
        self.promptCount = promptCount
        self.maxTokens = maxTokens
        self.started = started
    }

    func free() {
        llama_sampler_free(sampler)
        grammar.map { llama_sampler_free($0) }
    }
}

extension LlamaRuntime {
    /// Fewer shared tokens than this aren't worth a copy.
    static let minimumSharedPrefix = 32

    // MARK: Entry

    /// Hands a request in from any thread. Its events and its end come back through `emit` and `finish`, on the
    /// runtime's queue.
    func submit(
        _ request: GenerationRequest, cancelled: CancelFlag,
        emit: @escaping (GenerationEvent) -> Void, finish: @escaping (Error?) -> Void
    ) {
        let pending = PendingRequest(request: request, cancelled: cancelled, emit: emit, finish: finish)
        let start = incomingLock.withLock { () -> Bool in
            incoming.append(pending)
            guard !stepQueued else { return false }
            stepQueued = true
            return true
        }
        if start {
            queue.async { self.step() }
        }
    }

    /// Ends every request with `error` (the model is going away).
    func failEverything(_ error: Error) {
        let taken = incomingLock.withLock { () -> [PendingRequest] in
            defer { incoming = [] }
            return incoming
        }
        for pending in taken + waiting {
            pending.finish(error)
        }
        waiting = []
        for slot in slots {
            if let job = slot.job {
                job.free()
                job.pending.finish(error)
                slot.job = nil
            }
            slot.cached = []
        }
    }

    // MARK: A step

    /// One round: take in new requests, give them slots, decode one batch, and hand each request its token.
    func step() {
        guard context != nil, batch != nil else {
            failEverything(EngineError.notLoaded)
            incomingLock.withLock { stepQueued = false }
            return
        }
        let arrived = incomingLock.withLock { () -> [PendingRequest] in
            defer { incoming = [] }
            return incoming
        }
        waiting += arrived
        dropCancelled()
        admit()
        decodeBatch()

        let more = incomingLock.withLock { () -> Bool in
            let busy = !incoming.isEmpty || !waiting.isEmpty || slots.contains { $0.job != nil }
            if !busy {
                stepQueued = false
            }
            return busy
        }
        if more {
            queue.async { self.step() }
        }
    }

    /// Requests whose client has gone stop here. A slot keeps what it had decoded, for the next request.
    private func dropCancelled() {
        waiting.removeAll { pending in
            guard pending.cancelled.isSet else { return false }
            pending.finish(nil)
            return true
        }
        for slot in slots {
            if let job = slot.job, job.pending.cancelled.isSet {
                release(slot)
                job.pending.finish(nil)
            }
        }
    }

    // MARK: Admission

    private func admit() {
        while let pending = waiting.first {
            let free = slots.filter { $0.job == nil }
            guard !free.isEmpty else { return }
            waiting.removeFirst()
            do {
                try start(pending, in: free)
            } catch {
                pending.finish(error)
            }
        }
    }

    private func start(_ pending: PendingRequest, in free: [Slot]) throws {
        guard let vocab else { throw EngineError.notLoaded }
        let request = pending.request
        let started = ContinuousClock().now
        let sampler = makeSampler(request)
        var grammar: UnsafeMutablePointer<llama_sampler>?
        if let text = request.grammar {
            guard let made = llama_sampler_init_grammar(vocab, text, "root") else {
                llama_sampler_free(sampler)
                throw EngineError.invalidRequest("the grammar couldn't be parsed (GBNF, start rule \"root\")")
            }
            grammar = made
        }
        func abandon() {
            llama_sampler_free(sampler)
            grammar.map { llama_sampler_free($0) }
        }

        if !request.media.isEmpty {
            // An image prompt is evaluated by libmtmd's own decode calls, which takes the whole context for
            // its duration, and starts from an emptied sequence: images have no token ids to reuse.
            let slot = free.min { $0.lastUsed < $1.lastUsed }!
            reset(slot)
            let evaluated: (textTokens: [llama_token], total: Int, next: llama_pos)
            do {
                evaluated = try evaluateImagePrompt(request, sequence: slot.id)
            } catch {
                abandon()
                reset(slot)
                throw error
            }
            let job = Job(
                pending: pending, sampler: sampler, grammar: grammar, prompt: evaluated.textTokens, fed: 0,
                promptCount: evaluated.total, maxTokens: min(request.maxTokens, info.contextSize - evaluated.total),
                started: started
            )
            job.nextPosition = evaluated.next
            slot.job = job
            job.phase = .generating
            for token in job.prompt {
                llama_sampler_accept(sampler, token)
            }
            // The evaluation left the logits of the prompt's last token as the context's last output.
            job.row = -1
            sampleAndHandle(job, in: slot)
            return
        }

        let prompt = request.promptTokens.map { llama_token(truncatingIfNeeded: $0) }
        guard !prompt.isEmpty else {
            abandon()
            throw EngineError.generationFailed("the prompt has no tokens")
        }
        /// Which slot, and how much of the prompt is already in it. The last prompt token is always decoded
        /// afresh, because sampling needs its logits.
        func prefix(of slot: Slot) -> Int {
            guard request.cachePrompt else { return 0 }
            let limit = min(slot.cached.count, prompt.count - 1)
            var n = 0
            while n < limit, slot.cached[n] == prompt[n] {
                n += 1
            }
            return n
        }
        let slot: Slot
        var reused: Int
        if slotCount > 1, let context, llama_memory_can_shift(llama_get_memory(context)) {
            // The slot that loses the least: a prompt that carries on from a sequence's whole cache loses nothing,
            // an empty slot loses nothing, and a slot whose cache this prompt only partly follows loses the rest
            // of it. Among equals, the one holding more of this prompt, then the least recently used. What the
            // slot doesn't hold of this prompt's start is copied from whichever slot holds most of it, busy or
            // not: in a unified cache a copy of a sequence's first cells is just another owner of them, so
            // another conversation's cache is never thrown away for the sake of a shared system prompt.
            func loss(_ slot: Slot) -> Int {
                slot.cached.count - prefix(of: slot)
            }
            slot = free.min { a, b in
                if loss(a) != loss(b) {
                    return loss(a) < loss(b)
                }
                if prefix(of: a) != prefix(of: b) {
                    return prefix(of: a) > prefix(of: b)
                }
                return a.lastUsed < b.lastUsed
            }!
            reused = keepPrefix(of: slot, upTo: prefix(of: slot))
            let donor = slots.filter { $0 !== slot }.max { prefix(of: $0) < prefix(of: $1) }
            if let donor, prefix(of: donor) >= Self.minimumSharedPrefix, prefix(of: donor) > reused {
                let shared = prefix(of: donor)
                reset(slot)
                llama_memory_seq_cp(llama_get_memory(context), donor.id, slot.id, 0, llama_pos(shared))
                slot.cached = Array(donor.cached[..<shared])
                reused = shared
            }
        } else {
            // One slot, or a model whose memory can't share a start: the free slot with the most of the prompt.
            slot = free.max { a, b in
                let (pa, pb) = (prefix(of: a), prefix(of: b))
                return pa != pb ? pa < pb : a.lastUsed > b.lastUsed
            }!
            reused = keepPrefix(of: slot, upTo: prefix(of: slot))
        }
        let job = Job(
            pending: pending, sampler: sampler, grammar: grammar, prompt: prompt, fed: reused,
            promptCount: prompt.count, maxTokens: request.maxTokens, started: started
        )
        slot.job = job
    }

    /// Makes a slot's sequence hold the first `count` of its cached tokens and no more; returns how many it does.
    private func keepPrefix(of slot: Slot, upTo count: Int) -> Int {
        guard let context else { return 0 }
        if count < slot.cached.count {
            // A model whose memory can't drop a tail (recurrent, sliding-window) refuses; start over.
            if count == 0 || !llama_memory_seq_rm(llama_get_memory(context), slot.id, llama_pos(count), -1) {
                reset(slot)
                return 0
            }
            slot.cached = Array(slot.cached[..<count])
        }
        return count
    }

    /// Empties one sequence.
    private func reset(_ slot: Slot) {
        guard let context else { return }
        _ = llama_memory_seq_rm(llama_get_memory(context), slot.id, -1, -1)
        slot.cached = []
    }

    /// The end of a request: its samplers go, and its slot is free for the next one. A prompt with images
    /// leaves nothing to reuse, so its sequence is emptied.
    private func release(_ slot: Slot) {
        guard let job = slot.job else { return }
        job.free()
        slot.job = nil
        tick += 1
        slot.lastUsed = tick
        if job.hasImages {
            reset(slot)
        }
    }

    // MARK: The batch

    private func decodeBatch() {
        guard let context, var batch else { return }
        // Whatever would need the pool to give up a sequence that nobody is using.
        var attempts = 0
        while true {
            var count: Int32 = 0
            var members: [(slot: Slot, job: Job, token: llama_token?)] = []
            func add(_ token: llama_token, at position: llama_pos, for slot: Slot, wantsLogits: Bool) {
                let i = Int(count)
                batch.token[i] = token
                batch.pos[i] = position
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = slot.id
                batch.logits[i] = wantsLogits ? 1 : 0
                count += 1
            }

            // A token for each request that is generating.
            for slot in slots {
                guard let job = slot.job, job.phase == .generating, let token = job.pendingToken else { continue }
                job.row = count
                add(token, at: job.nextPosition ?? llama_pos(slot.cached.count), for: slot, wantsLogits: true)
                members.append((slot, job, token))
            }
            // What room is left goes to the prompts, shared out evenly, starting from a different one each step.
            let reading = slots.filter { $0.job?.phase == .prompt }
            if !reading.isEmpty {
                let room = batchSize - Int(count)
                let share = max(1, room / reading.count)
                for offset in 0 ..< reading.count {
                    let slot = reading[(rotor + offset) % reading.count]
                    guard let job = slot.job else { continue }
                    let space = batchSize - Int(count)
                    let take = min(
                        job.prompt.count - job.fed,
                        space,
                        offset == 0 ? max(share, space - share * (reading.count - 1)) : share
                    )
                    job.chunk = max(0, take)
                    guard take > 0 else { continue }
                    for i in 0 ..< take {
                        let last = job.fed + i == job.prompt.count - 1
                        if last {
                            job.row = count
                        }
                        add(job.prompt[job.fed + i], at: llama_pos(slot.cached.count + i), for: slot, wantsLogits: last)
                    }
                    members.append((slot, job, nil))
                }
                rotor += 1
            }
            guard count > 0 else { return }

            batch.n_tokens = count
            let code = llama_decode(context, batch)
            if code == 0 {
                self.batch = batch
                afterDecode(members)
                return
            }
            for (_, job, _) in members {
                job.chunk = 0
            }
            if code == 1, attempts < slotCount, evictIdleSequence() {
                // The pool was full; an idle sequence gave up its cells. Build the batch again.
                attempts += 1
                continue
            }
            let error: EngineError = code == 1
                ? .generationFailed("the prompt and reply don't fit in the model's context")
                : .generationFailed("llama.cpp failed to decode (code \(code))")
            for (slot, job, _) in members {
                release(slot)
                reset(slot)
                job.pending.finish(error)
            }
            return
        }
    }

    /// Empties the least recently used sequence that holds nothing in use; false if there isn't one.
    private func evictIdleSequence() -> Bool {
        guard let victim = slots.filter({ $0.job == nil && !$0.cached.isEmpty }).min(by: { $0.lastUsed < $1.lastUsed })
        else { return false }
        reset(victim)
        return true
    }

    /// What a decoded batch changes: the tokens are now in their sequences, and every request that has logits
    /// gets its next token.
    private func afterDecode(_ members: [(slot: Slot, job: Job, token: llama_token?)]) {
        for (slot, job, token) in members {
            switch job.phase {
            case .generating:
                if job.nextPosition != nil {
                    job.nextPosition! += 1
                } else if let token {
                    slot.cached.append(token)
                }
                job.pendingToken = nil
                sampleAndHandle(job, in: slot)
            case .prompt:
                slot.cached += job.prompt[job.fed ..< job.fed + job.chunk]
                job.fed += job.chunk
                job.chunk = 0
                guard job.fed == job.prompt.count else { continue }
                job.phase = .generating
                // The samplers that look back (penalties, DRY) see the prompt too, as llama-server's do.
                for token in job.prompt {
                    llama_sampler_accept(job.sampler, token)
                }
                sampleAndHandle(job, in: slot)
            }
        }
    }

    // MARK: Tokens

    /// Draws the request's next token from its row of the batch and acts on it.
    private func sampleAndHandle(_ job: Job, in slot: Slot) {
        guard let context, let vocab else { return }
        let request = job.pending.request
        let token = sample(job.sampler, grammar: job.grammar, context: context, row: job.row)
        // The prompt is done when its logits can be read: `llama_decode` returns once the work is queued on the
        // GPU, and reading the logits is what waits for it (llama-server times it the same way).
        if job.promptDone == nil {
            job.promptDone = ContinuousClock().now
        }
        if !request.ignoreEndOfSequence, llama_vocab_is_eog(vocab, token) {
            job.counted += 1
            finish(job, in: slot, reason: .stop)
            return
        }
        job.produced += 1
        job.counted += 1
        job.pending.emit(.token(id: Int(token), text: job.utf8.append(piece(of: token))))
        if job.produced >= job.maxTokens {
            finish(job, in: slot, reason: .length)
        } else {
            job.pendingToken = token
        }
    }

    private func finish(_ job: Job, in slot: Slot, reason: FinishReason) {
        let done = ContinuousClock().now
        let promptDone = job.promptDone ?? done
        job.pending.emit(.finished(reason, GenerationTimings(
            promptTokens: job.promptCount - job.reused,
            promptSeconds: (promptDone - job.started).seconds,
            generatedTokens: job.counted,
            generatedSeconds: (done - promptDone).seconds,
            cachedTokens: job.reused
        )))
        release(slot)
        job.pending.finish(nil)
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
