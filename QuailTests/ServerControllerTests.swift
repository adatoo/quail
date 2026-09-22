import Foundation
import Testing
@testable import Quail

/// Exercises the `stopped → starting → ready → stopping` state machine
/// against a `FakeRuntime`, per AGENTS.md's "tests using a fake Runtime
/// where a process would otherwise be needed". `ProcessSupervisor` still
/// spawns a real (trivial) process — only the HTTP calls are faked.
@Suite("ServerController", .timeLimit(.minutes(1)))
@MainActor
struct ServerControllerTests {
    private static let config = EndpointConfig(
        host: "127.0.0.1",
        port: 8080,
        apiKey: nil,
        modelsDirectory: URL(fileURLWithPath: "/tmp/quail-tests-models")
    )

    private static func sleepSpec(_ seconds: String = "30") -> LaunchSpec {
        LaunchSpec(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: [seconds],
            environment: [:],
            currentDirectoryURL: nil
        )
    }

    private static func crashSpec() -> LaunchSpec {
        LaunchSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            environment: [:],
            currentDirectoryURL: nil
        )
    }

    @Test("start reaches ready once health reports up")
    func startReachesReady() async {
        let runtime = FakeRuntime(launchSpec: Self.sleepSpec())
        let controller = ServerController(runtime: runtime, logStore: LogStore(), healthTimeout: 5)

        #expect(controller.phase == .stopped)
        await controller.start(config: Self.config)
        #expect(controller.phase == .ready)

        await controller.stop() // waits for phase to actually settle, not just for SIGTERM to be sent
        #expect(controller.phase == .stopped)
    }

    @Test("start fails if health never reports up within the timeout")
    func startTimesOutToFailed() async {
        let runtime = FakeRuntime(
            launchSpec: Self.sleepSpec(),
            healthResults: [.failure(RuntimeError.httpStatus(503))]
        )
        let controller = ServerController(runtime: runtime, logStore: LogStore(), healthTimeout: 0.3)

        await controller.start(config: Self.config)

        guard case .failed = controller.phase else {
            Issue.record("expected .failed, got \(controller.phase)")
            return
        }
    }

    @Test("an unexpected exit that exhausts restarts moves to failed with recent logs")
    func unexpectedExitExhaustingRestartsFails() async throws {
        let runtime = FakeRuntime(launchSpec: Self.crashSpec())
        let supervisor = ProcessSupervisor(maxRestarts: 2, backoff: [0.01, 0.01])
        let controller = ServerController(
            runtime: runtime,
            logStore: LogStore(),
            supervisor: supervisor,
            healthTimeout: 5 // long enough that the crash-loop path wins the race
        )

        await controller.start(config: Self.config)

        // The health probe is still polling in the background inside
        // start(); give the crash loop (a few times ~0.01s apart) time to
        // exhaust its restarts and flip the phase before we assert.
        var sawFailed = false
        for _ in 0 ..< 100 {
            if case .failed = controller.phase {
                sawFailed = true; break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(sawFailed)
        #expect(!controller.recentFailureLogs.isEmpty)
    }

    @Test("calling start again while already ready is a no-op")
    func startWhileReadyIsANoOp() async {
        let runtime = FakeRuntime(launchSpec: Self.sleepSpec())
        let controller = ServerController(runtime: runtime, logStore: LogStore(), healthTimeout: 5)

        await controller.start(config: Self.config)
        #expect(controller.phase == .ready)

        await controller.start(config: Self.config) // guarded no-op; must not throw or reset state
        #expect(controller.phase == .ready)

        await controller.stop()
    }

    @Test("stop while stopped is a no-op")
    func stopWhileStoppedIsANoOp() async {
        let runtime = FakeRuntime(launchSpec: Self.sleepSpec())
        let controller = ServerController(runtime: runtime, logStore: LogStore(), healthTimeout: 5)

        #expect(controller.phase == .stopped)
        await controller.stop()
        #expect(controller.phase == .stopped)
    }

    @Test("baseURL reflects the config passed to start")
    func baseURLReflectsConfig() async {
        let runtime = FakeRuntime(launchSpec: Self.sleepSpec())
        let controller = ServerController(runtime: runtime, logStore: LogStore(), healthTimeout: 5)
        #expect(controller.baseURL == nil)

        await controller.start(config: Self.config)
        #expect(controller.baseURL?.host == "127.0.0.1")
        #expect(controller.baseURL?.port == 8080)

        await controller.stop()
    }
}
