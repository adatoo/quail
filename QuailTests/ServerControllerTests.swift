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

    /// Sleeps briefly (so `start()`'s own health-wait has definitely
    /// settled before this exits — otherwise a `FakeRuntime` that always
    /// reports healthy makes the very first exit race the initial
    /// health-wait instead of exercising a restart at all), then exits 1
    /// the first time it runs (leaving `marker` behind), then sleeps on
    /// every later run — a real crash-once-then-recover process.
    private static func flakySpec(marker: URL) -> LaunchSpec {
        LaunchSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "sleep 0.15; if [ -f '\(marker.path)' ]; then sleep 30; else touch '\(marker.path)'; exit 1; fi",
            ],
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

    @Test("a restart that recovers moves phase off .ready during the backoff window, then back once healthy")
    func restartThatRecoversLeavesReadyThenReturns() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-restart-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let runtime = FakeRuntime(launchSpec: Self.flakySpec(marker: marker))
        let supervisor = ProcessSupervisor(maxRestarts: 2, backoff: [0.05, 0.05])
        let controller = ServerController(
            runtime: runtime, logStore: LogStore(), supervisor: supervisor, healthTimeout: 5
        )

        await controller.start(config: Self.config)
        // `start()` only returns once its own health-wait has settled —
        // `FakeRuntime`'s default always-healthy result means this
        // succeeds immediately, well before the flaky process's 0.15s
        // delay, so there's no race with the crash below.
        #expect(controller.phase == .ready)

        // From here on health reports down — simulating the process
        // genuinely being unreachable during the restart, which
        // `FakeRuntime`'s canned (not real-process-linked) health can't
        // otherwise represent. `waitUntilHealthy`'s 0.5s poll interval
        // means the very next check (start()'s own, already resolved)
        // isn't affected; only the restart's re-check is.
        await runtime.setHealthResults([.failure(RuntimeError.httpStatus(503))])

        // Before this fix, `phase` stayed `.ready` through the whole
        // crash-restart window — confirmed by live testing (a Ping's
        // "server up" step failing with the menu still saying
        // "Running"). It must visibly leave `.ready` once the flaky
        // process crashes (~0.15s) and the restart's re-check starts
        // failing, not just eventually recover.
        var sawNonReady = false
        for _ in 0 ..< 200 { // ~2s
            if controller.phase != .ready {
                sawNonReady = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawNonReady, "phase should leave .ready once the crash-restart's health re-check starts failing")

        // Health recovers; the restart's still-polling re-check (marker
        // now exists, so the respawned process stays up) should pick
        // this up on its next 0.5s-interval poll and settle back to
        // .ready.
        await runtime.setHealthResults([.success(Health(status: "ok"))])
        var sawReadyAgain = false
        for _ in 0 ..< 150 { // ~3s
            if controller.phase == .ready {
                sawReadyAgain = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawReadyAgain, "phase should return to .ready once the restarted process is healthy again")

        await controller.stop()
    }

    @Test("apiKey reflects the config passed to start, not a later value")
    func apiKeyReflectsConfigPassedToStart() async {
        let runtime = FakeRuntime(launchSpec: Self.sleepSpec())
        let controller = ServerController(runtime: runtime, logStore: LogStore(), healthTimeout: 5)
        #expect(controller.apiKey == nil)

        var configured = Self.config
        configured.apiKey = "launched-with-this-key"
        await controller.start(config: configured)
        #expect(controller.apiKey == "launched-with-this-key")

        await controller.stop()
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

    @Test("a failing preflight moves straight to failed with its reason, without launching")
    func preflightFailureBlocksLaunch() async {
        let runtime = FakeRuntime(launchSpec: Self.sleepSpec())
        let supervisor = ProcessSupervisor()
        let controller = ServerController(
            runtime: runtime,
            logStore: LogStore(),
            supervisor: supervisor,
            healthTimeout: 5,
            preflight: { _ in PreflightResult(failure: "Port 8080 is already in use by llama-server (pid 1).") }
        )

        await controller.start(config: Self.config)

        #expect(controller.phase == .failed(reason: "Port 8080 is already in use by llama-server (pid 1)."))
        #expect(controller.recentFailureLogs == ["Port 8080 is already in use by llama-server (pid 1)."])
        #expect(await !supervisor.isRunning)
    }

    /// The live bug: an orphan on the same port answered `/health` while
    /// Quail's own process had already died failing to bind — and the menu
    /// went green. A healthy answer must not count once our process is gone.
    @Test("health from someone else's server doesn't count once our own process has exited")
    func healthWithoutOwnProcessIsNotReady() async {
        // First poll fails (while our process may still be alive); every
        // later one says "ok" — by then our process has exited and the
        // supervisor is sitting in a long backoff, so "ok" can only be
        // coming from someone else.
        let runtime = FakeRuntime(
            launchSpec: Self.crashSpec(),
            healthResults: [.failure(RuntimeError.httpStatus(503)), .success(Health(status: "ok"))]
        )
        let supervisor = ProcessSupervisor(maxRestarts: 3, backoff: [30, 30, 30])
        let controller = ServerController(
            runtime: runtime,
            logStore: LogStore(),
            supervisor: supervisor,
            healthTimeout: 1.5
        )

        await controller.start(config: Self.config)

        #expect(controller.phase != .ready)
        await controller.stop()
    }
}
