import Foundation
import Observation

/// The state machine the UI observes: `stopped → starting → ready →
/// stopping`, plus `failed` with the last log lines attached. Owns one
/// `ProcessSupervisor` and drives it via a `Runtime` adapter — see
/// docs/ARCHITECTURE.md §3.
///
/// `runtime` is injected as `any Runtime`, so tests exercise this whole
/// state machine against a `FakeRuntime` with no real process or network
/// call involved (AGENTS.md: "tests using a fake Runtime where a process
/// would otherwise be needed"). `ProcessSupervisor` itself still spawns a
/// real (trivial) child process in tests — only the HTTP calls are faked.
@MainActor
@Observable
final class ServerController {
    enum Phase: Sendable, Equatable {
        case stopped
        case starting
        case ready
        case stopping
        case failed(reason: String)

        var isFailed: Bool {
            if case .failed = self {
                return true
            }
            return false
        }
    }

    private(set) var phase: Phase = .stopped
    private(set) var recentFailureLogs: [String] = []

    private let runtime: any Runtime
    private let logStore: LogStore
    private let supervisor: ProcessSupervisor
    private let healthTimeout: TimeInterval
    private var eventTask: Task<Void, Never>?
    private var config: EndpointConfig?
    private var generation = 0

    /// - Parameter healthTimeout: how long to wait for `/health` to report
    ///   up before giving up and moving to `.failed`. Defaults to the 90s
    ///   from docs/IMPLEMENTATION_PLAN.md Phase 1 step 4; tests pass a much
    ///   shorter value so failure-path tests don't take 90 real seconds.
    init(
        runtime: any Runtime,
        logStore: LogStore,
        supervisor: ProcessSupervisor = ProcessSupervisor(),
        healthTimeout: TimeInterval = 90
    ) {
        self.runtime = runtime
        self.logStore = logStore
        self.supervisor = supervisor
        self.healthTimeout = healthTimeout
    }

    /// The endpoint's base URL, once `start(config:)` has been called.
    var baseURL: URL? {
        guard let config else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = config.host
        components.port = config.port
        return components.url
    }

    /// Starts the runtime and waits for it to become healthy. Returns once
    /// the phase has settled to `.ready` or `.failed` — callers that only
    /// want to kick it off and observe `phase` separately can ignore the
    /// return and just watch the property.
    func start(config: EndpointConfig) async {
        guard phase == .stopped || phase.isFailed else { return }
        self.config = config
        phase = .starting
        recentFailureLogs = []
        generation += 1
        let thisGeneration = generation

        guard let base = baseURL else {
            phase = .failed(reason: "invalid endpoint configuration")
            return
        }

        let spec = runtime.launchSpec(config: config, model: nil)
        let events = await supervisor.start(spec: spec)

        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                await handle(event: event, generation: thisGeneration)
            }
        }

        do {
            try await HealthProbe.waitUntilHealthy(
                runtime: runtime,
                base: base,
                apiKey: config.apiKey,
                timeout: healthTimeout
            )
            if generation == thisGeneration, phase == .starting {
                phase = .ready
            }
        } catch {
            if generation == thisGeneration, phase == .starting {
                await failWithRecentLogs(reason: "server did not become healthy within the timeout")
            }
        }
    }

    /// Stops the runtime and waits for `phase` to actually settle to
    /// `.stopped` before returning — not just for the `SIGTERM` to be sent.
    /// `supervisor.stop()` returning only means the signal was delivered;
    /// the process (and llama-server's own graceful shutdown of any child
    /// model instance, see D-009) still needs a moment to actually exit,
    /// which arrives later as a `ProcessSupervisor.Event` on `eventTask`.
    /// Awaiting that task's completion — rather than the phase becoming
    /// `.stopped` some other way — is what makes this safe to call
    /// concurrently and correct even if `handle(event:)` is still
    /// processing the final event when `supervisor.stop()` returns.
    func stop() async {
        guard phase == .ready || phase == .starting else { return }
        phase = .stopping
        await supervisor.stop()
        await eventTask?.value
    }

    private func handle(event: ProcessSupervisor.Event, generation eventGeneration: Int) async {
        // Ignore events from a superseded run (e.g. a fast stop-then-start).
        guard eventGeneration == generation else { return }

        switch event {
        case let .log(stream, text):
            await logStore.append(stream: stream, text: text)

        case let .exited(status, willRestart, _):
            await logStore.append(
                stream: .stderr,
                text: "process exited with status \(status)\(willRestart ? ", restarting…" : "")"
            )
            guard !willRestart else { return }

            if phase == .stopping {
                phase = .stopped
            } else {
                await failWithRecentLogs(reason: "process exited unexpectedly (status \(status))")
            }
        }
    }

    private func failWithRecentLogs(reason: String) async {
        let tail = await logStore.recentLines.suffix(50).map(\.text)
        recentFailureLogs = tail
        phase = .failed(reason: reason)
    }
}
