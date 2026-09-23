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
    ///
    /// - Parameter isOwnProcessAlive: an `ok` from `/health` only counts
    ///   while this returns true. A health endpoint says *something* is
    ///   answering on host:port, not that it's the process we launched —
    ///   found by live testing, an orphaned `llama-server` from an earlier
    ///   run answered `ok` while Quail's own process had already died
    ///   failing to bind the same port, and the menu went green for a
    ///   server that wasn't Quail's.
    static func waitUntilHealthy(
        runtime: any Runtime,
        base: URL,
        apiKey: String? = nil,
        timeout: TimeInterval = 90,
        pollInterval: TimeInterval = 0.5,
        isOwnProcessAlive: @Sendable () async -> Bool = { true }
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let health = try? await runtime.health(base: base, apiKey: apiKey), health.isUp,
               await isOwnProcessAlive()
            {
                return
            }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        throw TimedOut()
    }
}
