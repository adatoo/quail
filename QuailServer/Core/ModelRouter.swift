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
    }

    private var slots: [String: Slot]
    private let order: [String]
    private let modelsMax: Int
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
        order.compactMap { id in slots[id].map { ModelSnapshot(entry: $0.entry, state: $0.state) } }
    }

    func snapshot(_ id: String) -> ModelSnapshot? {
        slots[id].map { ModelSnapshot(entry: $0.entry, state: $0.state) }
    }

    func leaseCount(_ id: String) -> Int {
        slots[id]?.leases ?? 0
    }

    // MARK: Loading

    /// Queues a load and returns; the model reads `loading` until it's ready.
    func load(_ id: String) throws {
        guard slots[id] != nil else { throw RouterError.unknownModel(id) }
        if isShutDown {
            throw RouterError.shuttingDown
        }
        slots[id]?.unloadWhenIdle = false
        switch slots[id]!.state {
        case .loaded:
            slots[id]?.lastUsed = tick()
        case .loading:
            break
        case .unloaded, .failed:
            slots[id]?.state = .loading
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
                return ModelLease(id: id, engine: slots[id]!.engine!)
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

    func unload(_ id: String) async throws {
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
            slots[id]?.state = .loaded
            slots[id]?.lastUsed = tick()
            log.log(.info, "loaded \(id)")
        }
        settle(id)
    }

    /// Unloads least-recently-used models until one more fits, waiting for busy
    /// ones — and for unloads already in flight — to finish.
    private func makeRoom(for id: String) async {
        while slots[id]?.state == .loading, !isShutDown {
            if loadedCount >= modelsMax {
                let idle = slots.values
                    .filter { $0.state == .loaded && $0.leases == 0 }
                    .min { $0.lastUsed < $1.lastUsed }
                if let victim = idle {
                    await unloadNow(victim.entry.id)
                } else {
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
