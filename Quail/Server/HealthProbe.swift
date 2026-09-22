import Foundation

/// Polls a `Runtime`'s `/health` until it reports up, or streams a
/// single-token completion to measure time-to-first-token. Used by
/// `ServerController` while waiting for a freshly spawned process to bind
/// its port (docs/IMPLEMENTATION_PLAN.md Phase 1 step 4: "wait for port
/// bind by polling /health up to 90s") and, in a later PR, by the Ping
/// sheet (step 8).
enum HealthProbe {
    struct TimedOut: Error, Sendable {}

    /// Polls `runtime.health(base:apiKey:)` every `pollInterval` until it
    /// reports up, or throws `TimedOut` after `timeout` seconds. Transient
    /// errors while the process is still binding its port are expected and
    /// swallowed; only the timeout is surfaced.
    static func waitUntilHealthy(
        runtime: any Runtime,
        base: URL,
        apiKey: String? = nil,
        timeout: TimeInterval = 90,
        pollInterval: TimeInterval = 0.5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let health = try? await runtime.health(base: base, apiKey: apiKey), health.isUp {
                return
            }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        throw TimedOut()
    }
}
