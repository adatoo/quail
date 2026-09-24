import Foundation

/// How two saved results compare, worded so the direction is never in
/// doubt: one is the baseline, the other is measured against it.
enum BenchmarkComparison {
    struct Change: Equatable {
        enum Direction: Equatable { case faster, slower, same }

        var direction: Direction
        var text: String
    }

    /// Within this of the baseline counts as "same" — run-to-run noise.
    static let sameTolerance = 0.01

    /// `other` against `baseline` for a higher-is-better speed. `nil` when
    /// the baseline has nothing to divide by.
    static func change(baseline: Double, other: Double) -> Change? {
        guard baseline > 0, other >= 0 else { return nil }
        let ratio = other / baseline
        if abs(ratio - 1) < sameTolerance {
            return Change(direction: .same, text: "same")
        }
        if ratio > 1 {
            return Change(direction: .faster, text: String(format: "%.2f× faster", ratio))
        }
        return Change(direction: .slower, text: String(format: "%.0f%% slower", (1 - ratio) * 100))
    }

    /// The baseline of a pair: the one asked for if it's in the pair,
    /// otherwise the older run — the natural "before".
    static func baseline(
        of pair: [BenchmarkResult],
        preferred: BenchmarkResult.ID?
    ) -> BenchmarkResult? {
        guard pair.count == 2 else { return nil }
        if let preferred, let chosen = pair.first(where: { $0.id == preferred }) {
            return chosen
        }
        return pair.min { $0.date < $1.date }
    }
}
