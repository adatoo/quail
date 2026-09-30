import Foundation

enum ModelState: Equatable, Sendable {
    case unloaded
    case loading
    case loaded
    /// The last load attempt failed; the next request for it tries again.
    case failed(String)
}

struct ModelSnapshot: Equatable, Sendable {
    let entry: ModelEntry
    let state: ModelState
    /// While it's loading: the busy models it's waiting on to finish their requests before one of them can make room.
    var waitingFor: [String] = []
}

enum RouterError: Error, Equatable, LocalizedError, Sendable {
    case unknownModel(String)
    case loadFailed(model: String, reason: String)
    case shuttingDown

    var errorDescription: String? {
        switch self {
        case let .unknownModel(id): "model \"\(id)\" not found"
        case let .loadFailed(model, reason): "failed to load \"\(model)\": \(reason)"
        case .shuttingDown: "the server is shutting down"
        }
    }
}

/// A claim on a loaded model for the length of one request. The router won't
/// evict or unload a model while it has leases, so a load of another model can
/// never pull the weights out from under a running generation.
struct ModelLease: Sendable {
    let id: String
    let engine: any Engine
    /// Stops this request if someone asks, by hand, for its model to go (`POST /models/load` or `/models/unload`).
    var interrupter = RequestInterrupter()
}

/// Stops the requests using one load of a model, when someone asks by hand for it to go: a load of another model
/// that needs its room, or an unload (ADR D-068). A request registers a handler for as long as it generates; one
/// that registers after the interruption is stopped at once, so a request that was about to start doesn't slip in.
final class RequestInterrupter: Sendable {
    private struct State {
        var handlers: [Int: @Sendable (String) -> Void] = [:]
        var next = 0
        var reason: String?
    }

    private let state = Locked(State())

    /// Calls `handler` with the reason when the model's requests are stopped (at once, if they already were).
    /// Returns the token to `remove` it with, or nil if it was called.
    func register(_ handler: @escaping @Sendable (String) -> Void) -> Int? {
        let (token, reason): (Int?, String?) = state.withState { state in
            if let reason = state.reason {
                return (nil, reason)
            }
            state.next += 1
            state.handlers[state.next] = handler
            return (state.next, nil)
        }
        if let reason {
            handler(reason)
        }
        return token
    }

    func remove(_ token: Int) {
        state.withState { _ = $0.handlers.removeValue(forKey: token) }
    }

    var interrupted: Bool {
        state.withState { $0.reason != nil }
    }

    /// Stops every request registered now, and every one that registers later.
    func interrupt(_ reason: String) {
        let handlers = state.withState { state -> [@Sendable (String) -> Void] in
            guard state.reason == nil else { return [] }
            state.reason = reason
            defer { state.handlers = [:] }
            return Array(state.handlers.values)
        }
        for handler in handlers {
            handler(reason)
        }
    }
}

/// Owns which models are loaded: at most `modelsMax`, least recently used out
/// first (llama-server's router semantics, D-011). Loads run one at a time, in
/// order — two loads at once would double the peak memory the fit verdicts
/// assumed — and `load` returns as soon as the load is queued, like
/// `POST /models/load` does.
actor ModelRouter {
    private struct Slot {
        var entry: ModelEntry
        var state = ModelState.unloaded
        var engine: (any Engine)?
        var leases = 0
        var lastUsed: UInt64 = 0
        /// An unload asked for while the model was busy or still loading.
        var unloadWhenIdle = false
        /// When its engine started loading, while it does (`GET /slots`).
        var loadStartedAt: Date?
        /// Stops the requests on this load of the model (ADR D-068); a fresh one for each load, and after an
        /// interruption that turned out not to be needed.
        var interrupter = RequestInterrupter()
        /// While loading: whether someone asked for it by hand, so busy models in its way have their requests
        /// stopped rather than waited for (ADR D-068).
        var interrupts = false
        /// While loading: the busy models it's waiting on (`GET /models`, `GET /slots`).
        var waitingFor: [String] = []
    }

    private var slots: [String: Slot]
    private let order: [String]
    let modelsMax: Int
    private let makeEngine: EngineFactory
    private let log: ServerLog

    private var clock: UInt64 = 0
    private var jobTail: Task<Void, Never>?
    private var unloading = 0
    private var isShutDown = false
    private var settleWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(entries: [ModelEntry], modelsMax: Int, makeEngine: @escaping EngineFactory, log: ServerLog) {
        slots = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, Slot(entry: $0)) })
        order = entries.map(\.id)
        self.modelsMax = max(1, modelsMax)
        self.makeEngine = makeEngine
        self.log = log
    }

    // MARK: Reading

    func snapshots() -> [ModelSnapshot] {
        order.compactMap { id in slots[id].map(Self.snapshot) }
    }

    func snapshot(_ id: String) -> ModelSnapshot? {
        slots[id].map(Self.snapshot)
    }

    private static func snapshot(_ slot: Slot) -> ModelSnapshot {
        ModelSnapshot(entry: slot.entry, state: slot.state, waitingFor: slot.state == .loading ? slot.waitingFor : [])
    }

    func leaseCount(_ id: String) -> Int {
        slots[id]?.leases ?? 0
    }

    /// The requests in progress, for `GET /slots` (ADR D-060). Not isolated: requests record themselves as they go.
    nonisolated let activity = ActivityRegistry()

    /// Each model that's loading or loaded, for `GET /slots`: its state, when its load started, its leases, its
    /// engine (to ask for its memory) and, while it loads, the busy models it's waiting on.
    func activeModels() -> [ActiveModel] {
        order.compactMap { id in
            guard let slot = slots[id], slot.state == .loading || slot.state == .loaded else { return nil }
            return ActiveModel(
                id: id, state: slot.state, loadStartedAt: slot.loadStartedAt, leases: slot.leases, engine: slot.engine,
                waitingFor: slot.state == .loading ? slot.waitingFor : []
            )
        }
    }

    struct ActiveModel {
        let id: String
        let state: ModelState
        let loadStartedAt: Date?
        let leases: Int
        let engine: (any Engine)?
        let waitingFor: [String]
    }

    // MARK: Loading

    /// Queues a load and returns; the model reads `loading` until it's ready. `interrupting`: someone asked for it
    /// by hand, so if every model in its way is busy, the least recently used one has its requests stopped rather
    /// than waited for (ADR D-068). A load a request needs waits.
    func load(_ id: String, interrupting: Bool = false) throws {
        guard slots[id] != nil else { throw RouterError.unknownModel(id) }
        if isShutDown {
            throw RouterError.shuttingDown
        }
        if slots[id]!.unloadWhenIdle {
            slots[id]?.unloadWhenIdle = false
            // Asked to stay after all: requests from now on run, though the ones stopped already stay stopped.
            if slots[id]!.interrupter.interrupted {
                slots[id]?.interrupter = RequestInterrupter()
            }
        }
        switch slots[id]!.state {
        case .loaded:
            slots[id]?.lastUsed = tick()
        case .loading:
            if interrupting {
                slots[id]?.interrupts = true
                wakeIdle()
            }
        case .unloaded, .failed:
            slots[id]?.state = .loading
            slots[id]?.interrupts = interrupting
            let previous = jobTail
            jobTail = Task {
                await previous?.value
                await self.performLoad(id)
            }
        }
    }

    /// Loads (if needed) and leases a model for one request. Pair with `release`.
    func acquire(_ id: String) async throws -> ModelLease {
        guard slots[id] != nil else { throw RouterError.unknownModel(id) }
        var waited = false
        for _ in 0 ..< 5 {
            if isShutDown {
                throw RouterError.shuttingDown
            }
            switch slots[id]!.state {
            case .loaded:
                slots[id]?.leases += 1
                slots[id]?.lastUsed = tick()
                return ModelLease(id: id, engine: slots[id]!.engine!, interrupter: slots[id]!.interrupter)
            case .loading:
                await settled(id)
                waited = true
            case .unloaded:
                try load(id)
                await settled(id)
                waited = true
            case let .failed(reason):
                // Someone else's failed attempt is worth one retry; our own isn't.
                if waited {
                    throw RouterError.loadFailed(model: id, reason: reason)
                }
                try load(id)
                await settled(id)
                waited = true
            }
        }
        throw RouterError.loadFailed(model: id, reason: "it kept being unloaded to make room for other models")
    }

    func release(_ lease: ModelLease) async {
        guard slots[lease.id] != nil else { return }
        slots[lease.id]!.leases = max(0, slots[lease.id]!.leases - 1)
        if slots[lease.id]!.leases == 0, slots[lease.id]!.unloadWhenIdle {
            await unloadNow(lease.id)
        }
        wakeIdle()
    }

    func withEngine<T: Sendable>(_ id: String, _ body: @Sendable (any Engine) async throws -> T) async throws -> T {
        let lease = try await acquire(id)
        do {
            let value = try await body(lease.engine)
            await release(lease)
            return value
        } catch {
            await release(lease)
            throw error
        }
    }

    /// Queues the loads for models flagged `load-on-startup` — no more than fit.
    func startAutoloads() {
        var started = 0
        for id in order where slots[id]!.entry.loadOnStartup {
            if started >= modelsMax {
                log.log(.warn, "not loading \(id) at startup: --models-max is \(modelsMax)")
                continue
            }
            try? load(id)
            started += 1
        }
    }

    // MARK: Unloading

    /// Unloads a model, or marks it to go once its requests end. `interrupting`: someone asked by hand, so its
    /// requests are stopped rather than waited for (ADR D-068).
    func unload(_ id: String, interrupting: Bool = false) async throws {
        guard slots[id] != nil else { throw RouterError.unknownModel(id) }
        switch slots[id]!.state {
        case .unloaded:
            break
        case .failed:
            slots[id]?.state = .unloaded
        case .loading:
            slots[id]?.unloadWhenIdle = true
        case .loaded:
            if slots[id]!.leases == 0 {
                await unloadNow(id)
            } else {
                slots[id]?.unloadWhenIdle = true
                if interrupting {
                    slots[id]!.interrupter.interrupt("\(id) was unloaded")
                }
            }
        }
    }

    func shutdown() async {
        isShutDown = true
        for id in order where slots[id]?.state == .loaded {
            await unloadNow(id)
        }
        wakeIdle()
        for id in Array(settleWaiters.keys) {
            settle(id)
        }
    }

    // MARK: Internals

    private func tick() -> UInt64 {
        clock &+= 1
        return clock
    }

    private var loadedCount: Int {
        slots.values.count { $0.state == .loaded }
    }

    private func performLoad(_ id: String) async {
        guard slots[id]?.state == .loading, !isShutDown else {
            settle(id)
            return
        }
        if slots[id]?.unloadWhenIdle == true {
            slots[id]?.unloadWhenIdle = false
            slots[id]?.state = .unloaded
            settle(id)
            return
        }

        await makeRoom(for: id)
        guard slots[id]?.state == .loading, !isShutDown else {
            settle(id)
            return
        }

        let entry = slots[id]!.entry
        log.log(.info, "loading \(id)")
        slots[id]?.loadStartedAt = Date()
        defer { slots[id]?.loadStartedAt = nil }
        let engine: any Engine
        do {
            engine = try makeEngine(entry)
            try await engine.load(entry)
        } catch {
            let reason = error.localizedDescription
            log.log(.error, "failed to load \(id): \(reason)")
            slots[id]?.state = .failed(reason)
            settle(id)
            return
        }

        if slots[id]?.unloadWhenIdle == true || isShutDown {
            await engine.unload()
            slots[id]?.unloadWhenIdle = false
            slots[id]?.state = .unloaded
        } else {
            slots[id]?.engine = engine
            slots[id]?.interrupter = RequestInterrupter()
            slots[id]?.state = .loaded
            slots[id]?.lastUsed = tick()
            log.log(.info, "loaded \(id)")
        }
        settle(id)
    }

    /// Unloads least-recently-used models until one more fits, waiting for busy
    /// ones — and for unloads already in flight — to finish. For a load asked for by
    /// hand, the least recently used busy model has its requests stopped (ADR D-068).
    private func makeRoom(for id: String) async {
        var interrupted: Set<String> = []
        defer {
            slots[id]?.waitingFor = []
            // A model stopped for this load that's still here (another made room first) serves requests again.
            for other in interrupted where slots[other]?.state == .loaded {
                slots[other]?.interrupter = RequestInterrupter()
            }
        }
        while slots[id]?.state == .loading, !isShutDown {
            if loadedCount >= modelsMax {
                let loaded = slots.values.filter { $0.state == .loaded }.sorted { $0.lastUsed < $1.lastUsed }
                if let victim = loaded.first(where: { $0.leases == 0 }) {
                    slots[id]?.waitingFor = []
                    await unloadNow(victim.entry.id)
                } else {
                    if slots[id]?.interrupts == true, let victim = loaded.first {
                        slots[id]?.waitingFor = [victim.entry.id]
                        if interrupted.insert(victim.entry.id).inserted {
                            log.log(.info, "stopping \(victim.entry.id)'s requests to load \(id)")
                            victim.interrupter.interrupt("\(victim.entry.id) was unloaded to load \(id)")
                        }
                    } else {
                        slots[id]?.waitingFor = loaded.map(\.entry.id)
                    }
                    await waitForChange()
                }
            } else if unloading > 0 {
                await waitForChange()
            } else {
                return
            }
        }
    }

    private func unloadNow(_ id: String) async {
        guard let engine = slots[id]?.engine else { return }
        slots[id]?.engine = nil
        slots[id]?.state = .unloaded
        slots[id]?.unloadWhenIdle = false
        unloading += 1
        log.log(.info, "unloading \(id)")
        await engine.unload()
        unloading -= 1
        wakeIdle()
    }

    private func settled(_ id: String) async {
        guard slots[id]?.state == .loading else { return }
        await withCheckedContinuation { settleWaiters[id, default: []].append($0) }
    }

    private func settle(_ id: String) {
        slots[id]?.interrupts = false
        let waiters = settleWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters {
            waiter.resume()
        }
        wakeIdle()
    }

    private func waitForChange() async {
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func wakeIdle() {
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
