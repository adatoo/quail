import Foundation

/// State shared between a request handler and the task that streams its reply.
final class Locked<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ state: State) {
        self.state = state
    }

    func withState<Result>(_ body: (inout State) -> Result) -> Result {
        lock.withLock { body(&state) }
    }
}
