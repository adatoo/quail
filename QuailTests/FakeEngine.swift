import Foundation
@testable import QuailServerCore

/// Shared state behind every `FakeEngine` a test's factory makes: records what
/// happened in order, and lets a test hold a load open, fail it, or watch how
/// many models were resident at once.
actor FakeEngineWorld {
    private(set) var events: [String] = []
    private(set) var loadedNow: Set<String> = []
    private(set) var peakLoaded = 0

    private var held: Set<String> = []
    private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var failures: [String: String] = [:]

    /// Loads of `id` block until `release(_:)`.
    func hold(_ id: String) {
        held.insert(id)
    }

    func release(_ id: String) {
        held.remove(id)
        for gate in gates.removeValue(forKey: id) ?? [] {
            gate.resume()
        }
    }

    func failLoads(of id: String, reason: String?) {
        failures[id] = reason
    }

    func load(_ id: String) async throws {
        events.append("load-start \(id)")
        if held.contains(id) {
            await withCheckedContinuation { gates[id, default: []].append($0) }
        }
        if let reason = failures[id] {
            events.append("load-failed \(id)")
            throw EngineError.loadFailed(reason)
        }
        loadedNow.insert(id)
        peakLoaded = max(peakLoaded, loadedNow.count)
        events.append("load-done \(id)")
    }

    func unload(_ id: String) {
        loadedNow.remove(id)
        events.append("unload \(id)")
    }

    func count(_ event: String) -> Int {
        events.count { $0 == event }
    }

    func index(of event: String) -> Int? {
        events.firstIndex(of: event)
    }

    nonisolated var factory: EngineFactory {
        { entry in FakeEngine(id: entry.id, world: self) }
    }
}

struct FakeEngine: Engine {
    let id: String
    let world: FakeEngineWorld

    func load(_: ModelEntry) async throws {
        try await world.load(id)
    }

    func unload() async {
        await world.unload(id)
    }

    func tokenize(_ text: String, addSpecial _: Bool, parseSpecial _: Bool) async throws -> [Int] {
        text.utf8.map(Int.init)
    }

    func detokenize(_ tokens: [Int]) async throws -> String {
        String(decoding: tokens.map { UInt8(truncatingIfNeeded: $0) }, as: UTF8.self)
    }

    func chatTemplate() async -> String? {
        nil
    }

    func generate(_: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

extension ModelEntry {
    static func fake(_ id: String, kind: ModelKind = .gguf, loadOnStartup: Bool = false) -> ModelEntry {
        var entry = ModelEntry(id: id, kind: kind, path: URL(fileURLWithPath: "/models/\(id).gguf"))
        entry.loadOnStartup = loadOnStartup
        return entry
    }
}

/// Polls until `condition` holds, failing the test's wait after `timeout`.
/// The router and server are asynchronous by design; tests wait for the
/// state they expect instead of sleeping a guessed time.
func eventually(
    timeout: Duration = .seconds(3),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
