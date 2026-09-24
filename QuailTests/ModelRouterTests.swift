import Foundation
import Testing
@testable import QuailServerCore

@Suite("ModelRouter", .timeLimit(.minutes(1)))
struct ModelRouterTests {
    private static func makeRouter(
        _ ids: [String],
        max: Int = 1,
        world: FakeEngineWorld,
        startup: Set<String> = []
    ) -> ModelRouter {
        ModelRouter(
            entries: ids.map { .fake($0, loadOnStartup: startup.contains($0)) },
            modelsMax: max,
            makeEngine: world.factory,
            log: ServerLog(toStandardError: false)
        )
    }

    private func state(_ router: ModelRouter, _ id: String) async -> ModelState? {
        await router.snapshot(id)?.state
    }

    @Test("lists every entry, unloaded, in order")
    func lists() async {
        let router = Self.makeRouter(["a", "b"], world: FakeEngineWorld())
        let snapshots = await router.snapshots()
        #expect(snapshots.map(\.entry.id) == ["a", "b"])
        #expect(snapshots.allSatisfy { $0.state == .unloaded })
    }

    @Test("load returns at once and the model reads loading until the engine is ready")
    func loadIsAsynchronous() async throws {
        let world = FakeEngineWorld()
        await world.hold("a")
        let router = Self.makeRouter(["a"], world: world)

        try await router.load("a")
        #expect(await state(router, "a") == .loading)

        await world.release("a")
        #expect(await eventually { await state(router, "a") == .loaded })
    }

    @Test("with --models-max 1, loading another model unloads the first before the second starts")
    func evictsToMakeRoom() async throws {
        let world = FakeEngineWorld()
        let router = Self.makeRouter(["a", "b"], max: 1, world: world)

        try await router.load("a")
        #expect(await eventually { await state(router, "a") == .loaded })
        try await router.load("b")
        #expect(await eventually { await state(router, "b") == .loaded })

        #expect(await state(router, "a") == .unloaded)
        let unloadA = try #require(await world.index(of: "unload a"))
        let startB = try #require(await world.index(of: "load-start b"))
        #expect(unloadA < startB)
        #expect(await world.peakLoaded == 1)
    }

    @Test("evicts the least recently used model, not the oldest loaded")
    func leastRecentlyUsed() async throws {
        let world = FakeEngineWorld()
        let router = Self.makeRouter(["a", "b", "c"], max: 2, world: world)

        try await router.load("a")
        #expect(await eventually { await state(router, "a") == .loaded })
        try await router.load("b")
        #expect(await eventually { await state(router, "b") == .loaded })
        // Using "a" makes "b" the least recently used, though "a" loaded first.
        let recent = try await router.acquire("a")
        await router.release(recent)

        try await router.load("c")
        #expect(await eventually { await state(router, "c") == .loaded })
        #expect(await state(router, "a") == .loaded)
        #expect(await state(router, "b") == .unloaded)
    }

    @Test("a model with a request in flight is not evicted until the request ends")
    func leaseBlocksEviction() async throws {
        let world = FakeEngineWorld()
        let router = Self.makeRouter(["a", "b"], max: 1, world: world)
        let lease = try await router.acquire("a")

        try await router.load("b")
        // Give the router every chance to (wrongly) evict.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await state(router, "a") == .loaded)
        #expect(await state(router, "b") == .loading)
        #expect(await world.count("unload a") == 0)

        await router.release(lease)
        #expect(await eventually { await state(router, "b") == .loaded })
        #expect(await state(router, "a") == .unloaded)
    }

    @Test("an unload asked for mid-request happens when the request ends")
    func unloadWaitsForLease() async throws {
        let world = FakeEngineWorld()
        let router = Self.makeRouter(["a"], world: world)
        let lease = try await router.acquire("a")

        try await router.unload("a")
        #expect(await state(router, "a") == .loaded)

        await router.release(lease)
        #expect(await state(router, "a") == .unloaded)
        #expect(await world.count("unload a") == 1)
    }

    @Test("loads run one at a time, in order")
    func loadsAreSerialized() async throws {
        let world = FakeEngineWorld()
        await world.hold("a")
        let router = Self.makeRouter(["a", "b"], max: 2, world: world)

        try await router.load("a")
        try await router.load("b")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await world.count("load-start b") == 0)
        #expect(await state(router, "b") == .loading)

        await world.release("a")
        #expect(await eventually { await state(router, "b") == .loaded })
        let doneA = try #require(await world.index(of: "load-done a"))
        let startB = try #require(await world.index(of: "load-start b"))
        #expect(doneA < startB)
    }

    @Test("simultaneous requests for one unloaded model share a single load")
    func coalescesLoads() async throws {
        let world = FakeEngineWorld()
        await world.hold("a")
        let router = Self.makeRouter(["a"], world: world)

        async let first = router.acquire("a")
        async let second = router.acquire("a")
        #expect(await eventually { await world.count("load-start a") >= 1 })
        await world.release("a")
        let leases = try await [first, second]

        #expect(leases.count == 2)
        #expect(await world.count("load-start a") == 1)
        #expect(await router.leaseCount("a") == 2)
    }

    @Test("a failed load is reported, shown as failed, and retried by the next request")
    func failureThenRetry() async throws {
        let world = FakeEngineWorld()
        await world.failLoads(of: "a", reason: "out of memory")
        let router = Self.makeRouter(["a"], world: world)

        await #expect(throws: RouterError.loadFailed(model: "a", reason: "out of memory")) {
            _ = try await router.acquire("a")
        }
        #expect(await state(router, "a") == .failed("out of memory"))

        await world.failLoads(of: "a", reason: nil)
        let lease = try await router.acquire("a")
        #expect(lease.id == "a")
        #expect(await state(router, "a") == .loaded)
    }

    @Test("a model this build has no engine for fails with a reason a person can act on")
    func noEngine() async {
        let router = ModelRouter(
            entries: [.fake("a")],
            modelsMax: 1,
            makeEngine: { throw EngineError.noEngine($0.kind) },
            log: ServerLog(toStandardError: false)
        )
        do {
            _ = try await router.acquire("a")
            Issue.record("expected the load to fail")
        } catch let RouterError.loadFailed(_, reason) {
            #expect(reason.contains("no GGUF engine"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("an unload asked for while loading wins once the load finishes")
    func unloadWhileLoading() async throws {
        let world = FakeEngineWorld()
        await world.hold("a")
        let router = Self.makeRouter(["a"], world: world)

        try await router.load("a")
        try await router.unload("a")
        await world.release("a")

        #expect(await eventually { await state(router, "a") == .unloaded })
        #expect(await eventually { await world.count("unload a") == 1 })
    }

    @Test("unknown ids are rejected everywhere")
    func unknown() async {
        let router = Self.makeRouter(["a"], world: FakeEngineWorld())
        await #expect(throws: RouterError.unknownModel("zzz")) { try await router.load("zzz") }
        await #expect(throws: RouterError.unknownModel("zzz")) { try await router.unload("zzz") }
        await #expect(throws: RouterError.unknownModel("zzz")) { _ = try await router.acquire("zzz") }
    }

    @Test("load-on-startup models load, but no more than --models-max")
    func autoloads() async {
        let world = FakeEngineWorld()
        let router = Self.makeRouter(["a", "b", "c"], max: 2, world: world, startup: ["a", "b", "c"])
        await router.startAutoloads()

        #expect(await eventually { await state(router, "a") == .loaded })
        #expect(await eventually { await state(router, "b") == .loaded })
        #expect(await state(router, "c") == .unloaded)
        #expect(await world.count("load-start c") == 0)
    }

    @Test("withEngine releases its lease even when the body throws")
    func withEngineReleases() async throws {
        struct Boom: Error {}
        let router = Self.makeRouter(["a"], world: FakeEngineWorld())
        await #expect(throws: Boom.self) {
            try await router.withEngine("a") { _ in throw Boom() }
        }
        #expect(await router.leaseCount("a") == 0)
    }

    @Test("shutdown unloads what's loaded and refuses new work")
    func shutdown() async throws {
        let world = FakeEngineWorld()
        let router = Self.makeRouter(["a", "b"], max: 2, world: world)
        try await router.load("a")
        #expect(await eventually { await state(router, "a") == .loaded })

        await router.shutdown()

        #expect(await state(router, "a") == .unloaded)
        #expect(await world.count("unload a") == 1)
        await #expect(throws: RouterError.shuttingDown) { try await router.load("b") }
        await #expect(throws: RouterError.shuttingDown) { _ = try await router.acquire("b") }
    }
}
