import Foundation

/// Owns exactly one child `Process` at a time: launch it, stream its stdout
/// and stderr, and restart it with back-off if it exits unexpectedly.
///
/// **Environment.** `LaunchSpec.environment` is used exactly as given —
/// never merged with `ProcessInfo.processInfo.environment` — per AGENTS.md
/// ("never inherit the user's shell environment when spawning a runtime").
/// `stdin` is always closed.
///
/// **Killing.** `stop()` sends a plain `SIGTERM` (`Process.terminate()`) to
/// the one process this actor owns. That is sufficient even for
/// llama-server's router mode, which forks a child process per loaded
/// model: tested against a real model load, `SIGTERM` to the router's PID
/// alone triggers the router's own shutdown handler, which stops its child
/// itself before exiting. No process-group kill is needed — see
/// docs/DECISIONS.md D-009's correction.
actor ProcessSupervisor {
    /// Something happened that the owner (`ServerController`) needs to
    /// react to: a line of output, or the process exiting.
    enum Event: Sendable {
        case log(stream: LogStream, text: String)
        /// `willRestart` is true when the supervisor is about to retry on
        /// its own; the owner only needs to treat this as terminal (move to
        /// `.failed`) when it's false.
        case exited(status: Int32, willRestart: Bool, restartAttempt: Int)
    }

    private let maxRestarts: Int
    private let backoff: [TimeInterval]

    private var process: Process?
    private var spec: LaunchSpec?
    private var restartAttempt = 0
    private var stoppedIntentionally = false
    private var continuation: AsyncStream<Event>.Continuation?
    private var restartTask: Task<Void, Never>?

    init(maxRestarts: Int = 3, backoff: [TimeInterval] = [2, 4, 8]) {
        self.maxRestarts = maxRestarts
        self.backoff = backoff
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// The current child's PID, if running. Exposed for diagnostics and for
    /// tests that need to simulate an external crash.
    var currentProcessID: Int32? {
        process?.processIdentifier
    }

    /// Starts the child process. Returns a stream of log lines and
    /// lifecycle events that ends once the process has exited for good
    /// (either stopped intentionally, or restarts exhausted).
    func start(spec: LaunchSpec) -> AsyncStream<Event> {
        self.spec = spec
        restartAttempt = 0
        stoppedIntentionally = false

        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        launch(spec: spec)
        return stream
    }

    /// Ends the current run intentionally. Safe to call even if nothing is
    /// running.
    func stop() {
        stoppedIntentionally = true
        restartTask?.cancel()
        restartTask = nil
        if let process, process.isRunning {
            process.terminate()
        } else {
            // Nothing running (e.g. stop() called while waiting to retry).
            continuation?.finish()
            continuation = nil
        }
    }

    private func launch(spec: LaunchSpec) {
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.currentDirectoryURL
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let continuation = continuation
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            Self.forwardAvailableData(from: handle, stream: .stdout, to: continuation)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            Self.forwardAvailableData(from: handle, stream: .stderr, to: continuation)
        }

        process.terminationHandler = { [weak self] finished in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            Task { await self?.handleExit(status: status) }
        }

        self.process = process
        do {
            try process.run()
        } catch {
            self.process = nil
            continuation?.yield(.log(stream: .stderr, text: "failed to launch: \(error.localizedDescription)"))
            continuation?.yield(.exited(status: -1, willRestart: false, restartAttempt: restartAttempt))
            continuation?.finish()
            self.continuation = nil
        }
    }

    private func handleExit(status: Int32) {
        process = nil

        if stoppedIntentionally {
            continuation?.yield(.exited(status: status, willRestart: false, restartAttempt: restartAttempt))
            continuation?.finish()
            continuation = nil
            return
        }

        guard restartAttempt < maxRestarts, let spec else {
            continuation?.yield(.exited(status: status, willRestart: false, restartAttempt: restartAttempt))
            continuation?.finish()
            continuation = nil
            return
        }

        let delay = backoff[min(restartAttempt, backoff.count - 1)]
        restartAttempt += 1
        continuation?.yield(.exited(status: status, willRestart: true, restartAttempt: restartAttempt))

        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.retryLaunch(spec: spec)
        }
    }

    private func retryLaunch(spec: LaunchSpec) {
        guard !stoppedIntentionally else { return }
        launch(spec: spec)
    }

    /// Runs on the pipe's dispatch queue, not on this actor — `continuation`
    /// is `Sendable`, so it's safe to yield into from here directly instead
    /// of hopping through `Task { await ... }` for every line of output.
    ///
    /// **Must** clear `handle.readabilityHandler` on EOF (empty data):
    /// otherwise, once the write end of the pipe closes, GCD keeps invoking
    /// the handler in a tight spin (thousands of times a second) because
    /// the FD stays "readable" at EOF. Left unhandled this starves the
    /// process's termination handler for several seconds — measured
    /// directly: a plain `/bin/echo` took 14s to report exit instead of
    /// under a second.
    private static func forwardAvailableData(
        from handle: FileHandle,
        stream: LogStream,
        to continuation: AsyncStream<Event>.Continuation?
    ) {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        continuation?.yield(.log(stream: stream, text: text))
    }
}
