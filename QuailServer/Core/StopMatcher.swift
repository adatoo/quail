import Foundation

/// Cuts a stream of generated text at the first stop string, holding back only what could still
/// turn into one. llama-server's rule: the stop string itself isn't part of the output, and text
/// before it is emitted as soon as it can no longer be the start of a stop.
struct StopMatcher: Sendable {
    private let stops: [[Unicode.Scalar]]
    private var pending: [Unicode.Scalar] = []

    /// Empty strings are ignored: they would match everywhere.
    init(_ stops: [String]) {
        self.stops = stops.filter { !$0.isEmpty }.map { Array($0.unicodeScalars) }
    }

    /// Text that's safe to emit now, and whether a stop string was hit (after which nothing more is
    /// emitted and the caller should end generation).
    mutating func push(_ piece: String) -> (emit: String, stopped: Bool) {
        guard !stops.isEmpty else { return (piece, false) }
        pending.append(contentsOf: piece.unicodeScalars)

        if let cut = earliestMatch() {
            let emit = String(String.UnicodeScalarView(pending[..<cut]))
            pending = []
            return (emit, true)
        }
        // Keep the longest tail that is a proper prefix of some stop.
        var held = 0
        for stop in stops {
            let limit = min(stop.count - 1, pending.count)
            var length = limit
            while length > held {
                if Array(pending.suffix(length)) == Array(stop.prefix(length)) {
                    held = length
                    break
                }
                length -= 1
            }
        }
        let emitCount = pending.count - held
        let emit = String(String.UnicodeScalarView(pending[..<emitCount]))
        pending.removeFirst(emitCount)
        return (emit, false)
    }

    /// The end of generation with no stop hit: what was being held back was never a stop.
    mutating func flush() -> String {
        let rest = String(String.UnicodeScalarView(pending))
        pending = []
        return rest
    }

    private func earliestMatch() -> Int? {
        var best: Int?
        for stop in stops where pending.count >= stop.count {
            for start in 0 ... (pending.count - stop.count) where best == nil || start < best! {
                if pending[start ..< start + stop.count].elementsEqual(stop) {
                    best = start
                    break
                }
            }
        }
        return best
    }
}
