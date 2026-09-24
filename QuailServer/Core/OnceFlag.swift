import Foundation

/// Lets exactly one caller through, however many try — for resuming a
/// continuation from callbacks that can fire more than once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
