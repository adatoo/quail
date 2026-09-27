import Foundation

/// What the server is doing right now, request by request, for `GET /slots` (ADR D-060): the app's menu bar and
/// Activity window poll it to show a model loading, a prompt being read (with progress) and tokens being written.
/// Records live only while their request does.
public final class ActivityRegistry: @unchecked Sendable {
    public enum Phase: String, Sendable, Equatable {
        /// Waiting for its model to load (or for room to load it).
        case waitingForModel = "waiting_for_model"
        /// The model is ready, but the engine hasn't started on this request (others are ahead of it).
        case queued
        case readingPrompt = "reading_prompt"
        case generating
    }

    public struct Request: Sendable, Equatable {
        public let id: Int
        public let model: String
        public var phase: Phase = .waitingForModel
        public var promptTotal = 0
        /// Prompt tokens in the cache so far, `cached` included.
        public var promptDone = 0
        /// Prompt tokens reused from an earlier request's cache.
        public var cached = 0
        public var generated = 0
        public let started: Date
        public var promptStarted: Date?
        public var generationStarted: Date?

        /// Prompt tokens a second read so far (reused ones don't count).
        public func promptPerSecond(now: Date = .init()) -> Double? {
            guard let promptStarted, promptDone > cached else { return nil }
            let elapsed = (generationStarted ?? now).timeIntervalSince(promptStarted)
            return elapsed > 0 ? Double(promptDone - cached) / elapsed : nil
        }

        /// Tokens a second written so far.
        public func predictedPerSecond(now: Date = .init()) -> Double? {
            guard let generationStarted, generated > 1 else { return nil }
            let elapsed = now.timeIntervalSince(generationStarted)
            return elapsed > 0 ? Double(generated - 1) / elapsed : nil
        }
    }

    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private var nextID = 1

    public init() {}

    /// Records a request for `model`; end it with the ticket's `end()`.
    public func begin(model: String, now: Date = .init()) -> ActivityTicket {
        let id = lock.withLock {
            defer { nextID += 1 }
            requests[nextID] = Request(id: nextID, model: model, started: now)
            return nextID
        }
        return ActivityTicket(registry: self, id: id)
    }

    func update(_ id: Int, _ change: (inout Request) -> Void) {
        lock.withLock {
            if var request = requests[id] {
                change(&request)
                requests[id] = request
            }
        }
    }

    func end(_ id: Int) {
        _ = lock.withLock { requests.removeValue(forKey: id) }
    }

    /// The requests in progress, oldest first.
    public func snapshot() -> [Request] {
        lock.withLock { requests.values.sorted { $0.id < $1.id } }
    }
}

/// One request's record in the `ActivityRegistry`. Ending it twice is harmless, so every way a request can finish
/// (an error before streaming, the stream's end, the client going away) can end it.
public final class ActivityTicket: Sendable {
    private let registry: ActivityRegistry
    let id: Int

    init(registry: ActivityRegistry, id: Int) {
        self.registry = registry
        self.id = id
    }

    func update(_ change: (inout ActivityRegistry.Request) -> Void) {
        registry.update(id, change)
    }

    public func end() {
        registry.end(id)
    }

    /// The engine has the request: queued until it reports prompt progress or a first token.
    func accepted(promptTokens: Int) {
        update {
            $0.phase = .queued
            $0.promptTotal = promptTokens
        }
    }

    func promptProgress(done: Int, total: Int, cached: Int, now: Date = .init()) {
        update {
            if $0.phase != .generating {
                $0.phase = .readingPrompt
            }
            if $0.promptStarted == nil {
                $0.promptStarted = now
            }
            $0.promptDone = done
            $0.promptTotal = total
            $0.cached = cached
        }
    }

    func token(now: Date = .init()) {
        update {
            if $0.generationStarted == nil {
                $0.generationStarted = now
                $0.phase = .generating
                $0.promptDone = $0.promptTotal
            }
            $0.generated += 1
        }
    }
}
