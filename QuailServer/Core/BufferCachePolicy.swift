import Foundation

/// When the MLX engine gives back the memory MLX keeps for reuse (#137, ADR D-055), kept free of MLX so it can be
/// tested.
///
/// MLX doesn't return a freed GPU buffer to macOS: it keeps it in a cache, to hand out again for the next array of
/// that size. By default the cache may grow almost to the whole of memory, and serving several requests at once
/// frees buffers of many sizes (each batch's caches grow, merge, split and shrink), so the process's footprint
/// climbed to 30 GB for an 8B model and stayed there. Three things hold it down, as mlx-lm, oMLX and Rapid-MLX do:
/// - **A limit** on the cache, set when a model loads: 2 GB, or a sixteenth of what the GPU may use on a Mac where
///   that's less, and never under 512 MB. On a Mac mini (M4 Pro, 64 GB) serving Qwen3 8B to eight requests at once,
///   peak footprint was 21 GB with MLX's default, 16 GB with Rapid-MLX's rule (a quarter of the working set, 12 GB
///   there), 11 GB with 2 GB and 9.5 GB with 512 MB; the 2 GB is what's left for the small arrays every step
///   makes again, which are what a cache is for. The large buffers a batch drops (its caches, each time they grow,
///   merge or split) are rarely the size of the next one.
/// - **Clearing it as decoding goes:** every `interval` steps, and `afterFinish` steps after a request ends, not
///   at once. oMLX saw kernel panics when it cleared the moment a request completed, while the GPU was still
///   finishing with that request's buffers.
/// - **Clearing it when nothing is running,** once the GPU has finished its work.
public struct BufferCachePolicy: Equatable, Sendable {
    /// Decode steps between clears while requests run (oMLX's and mlx-lm's batch generator's figure).
    public static let interval = 512
    /// Steps after a request ends before the cache is cleared.
    public static let afterFinish = 8

    /// The cache limit for a GPU that may use `workingSet` bytes (Metal's recommended working set).
    public static func limit(workingSet: Int) -> Int {
        max(min(2 << 30, workingSet / 16), 512 << 20)
    }

    private var sinceClear = 0
    private var countdown: Int?

    public init() {}

    /// Counts one decode step (every sequence's next token, batched or alone); true when the cache should be
    /// cleared now.
    public mutating func step() -> Bool {
        sinceClear += 1
        if let left = countdown {
            countdown = left > 1 ? left - 1 : nil
            if left <= 1 {
                return cleared()
            }
        }
        return sinceClear >= Self.interval ? cleared() : false
    }

    /// A request ended: the cache is cleared `afterFinish` steps from now, unless a clear is already due sooner.
    public mutating func finished() {
        if countdown == nil {
            countdown = Self.afterFinish
        }
    }

    private mutating func cleared() -> Bool {
        sinceClear = 0
        countdown = nil
        return true
    }
}
