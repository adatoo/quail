import Foundation

/// Other catalog families worth a look beside one (ADR D-070 amendment): one about the same size that scores
/// higher in Quail's own tests, one that needs much less memory and is about as good, and one that's much faster
/// on this Mac and about as good. Worked out from Quail's scores, the families' strengths, and this Mac's fit
/// estimates (memory at the default context, and speed); never from Arena's ratings, which cover too few of them
/// to compare. Size is memory, not parameters: a 1-bit 27B needs a fifth of a 4-bit one's.
enum ModelAlternatives {
    enum Reason: Sendable, Equatable {
        case scoresHigher
        case smaller
        case faster
    }

    struct Alternative: Sendable, Equatable {
        var family: Catalog.Family
        var reason: Reason
        /// "Knowledge +22, tools +12", "9.3 GB against 20 GB", "~85 tok/s against ~25".
        var detail: String
    }

    /// Differences within these, in points, are a tie: the 95% intervals of Quail's scores at their sample sizes
    /// (ADR D-070's amendment).
    static let mathsMargin = 5
    static let knowledgeMargin = 9
    static let toolsMargin = 5

    /// Smaller means needing at most this fraction of the memory.
    static let smallerFraction = 0.75
    /// About the same size, for one that scores higher: needing at most this many times the memory, or
    /// `sameSizeSlack` more, whichever allows more (a step up from a 2 GB model is more than 25%).
    static let sameSizeFactor = 1.25
    static let sameSizeSlack: Int64 = 2_000_000_000
    /// Faster means at least this many times the estimated speed.
    static let fasterFactor = 1.5

    /// At most one family for each reason, each family once, in the order of `Reason`'s cases. Empty when
    /// `family` has no scores or no fit estimate of its own to compare against. A candidate must be curated, scored,
    /// fit this Mac
    /// (`fits` holds its verdict, and it isn't Won't Fit) and be for the same kind of work: a coding model's
    /// alternatives are good at coding. `family`'s own successor isn't one: the card shows it as newer already.
    static func alternatives(
        for family: Catalog.Family, in families: [Catalog.Family], fits: [String: FitEstimate]
    ) -> [Alternative] {
        guard let scores = family.quailScores, let own = fits[family.id] else { return [] }
        func memory(_ family: Catalog.Family) -> Int64 {
            fits[family.id]?.ramNeededBytes ?? .max
        }
        let successor = ModelFacts.newer(than: family, in: families)?.id
        let candidates = families.filter { candidate in
            guard candidate.id != family.id, candidate.id != successor, candidate.isCurated,
                  candidate.quailScores != nil, let fit = fits[candidate.id], fit.verdict != .wontFit
            else { return false }
            if family.role == "coding" {
                return candidate.strengths.contains("coding")
            }
            return candidate.role == "general" || candidate.role == "coding"
        }

        var chosen: [Alternative] = []
        func choose(_ family: Catalog.Family?, _ reason: Reason, _ detail: (Catalog.Family) -> String) {
            guard let family, !chosen.contains(where: { $0.family.id == family.id }) else { return }
            chosen.append(Alternative(family: family, reason: reason, detail: detail(family)))
        }

        // Higher: about the same size, the best total of those ahead on some test and behind on none; the smaller
        // on a tie.
        let size = own.ramNeededBytes
        let sameSize = max(Int64(Double(size) * sameSizeFactor), size + sameSizeSlack)
        let higher = candidates
            .filter { isBetter($0.quailScores!, than: scores) && memory($0) <= sameSize }
            .max { total($0) == total($1) ? memory($0) > memory($1) : total($0) < total($1) }
        choose(higher, .scoresHigher) { gains($0.quailScores!, over: scores) }

        // Smaller: the smallest that's as good.
        let smaller = candidates
            .filter {
                isAsGood($0.quailScores!, as: scores) && Double(memory($0)) <= Double(size) * smallerFraction
                    && !chosen.contains(id: $0.id)
            }
            .min { memory($0) == memory($1) ? total($0) > total($1) : memory($0) < memory($1) }
        choose(smaller, .smaller) { "\(gigabytes(memory($0))) against \(gigabytes(size)), about as good" }

        // Faster: the fastest that's as good, by this Mac's estimates.
        if let speed = own.estimatedTokensPerSecond, speed > 0 {
            func speedOf(_ family: Catalog.Family) -> Double {
                fits[family.id]?.estimatedTokensPerSecond ?? 0
            }
            let faster = candidates
                .filter {
                    isAsGood($0.quailScores!, as: scores) && speedOf($0) >= speed * fasterFactor
                        && !chosen.contains(id: $0.id)
                }
                .max { speedOf($0) < speedOf($1) }
            choose(faster, .faster) {
                "~\(Int(speedOf($0).rounded())) tok/s against ~\(Int(speed.rounded())), about as good"
            }
        }
        return chosen
    }

    /// Ahead of `other` by more than the margin on at least one test, and behind by more than it on none.
    static func isBetter(_ scores: Catalog.QuailScores, than other: Catalog.QuailScores) -> Bool {
        isAsGood(scores, as: other) && differences(scores, other).contains { $0.difference > $0.margin }
    }

    /// Behind `other` by more than the margin on no test.
    static func isAsGood(_ scores: Catalog.QuailScores, as other: Catalog.QuailScores) -> Bool {
        differences(scores, other).allSatisfy { $0.difference >= -$0.margin }
    }

    private static func differences(
        _ scores: Catalog.QuailScores, _ other: Catalog.QuailScores
    ) -> [(test: String, difference: Int, margin: Int)] {
        [
            ("Maths", scores.maths - other.maths, mathsMargin),
            ("Knowledge", scores.knowledge - other.knowledge, knowledgeMargin),
            ("Tools", scores.tools - other.tools, toolsMargin),
        ]
    }

    /// "Knowledge +22, tools +12": the tests it's ahead on beyond the margin.
    private static func gains(_ scores: Catalog.QuailScores, over other: Catalog.QuailScores) -> String {
        let ahead = differences(scores, other).filter { $0.difference > $0.margin }
        return ahead.enumerated().map { index, item in
            "\(index == 0 ? item.test : item.test.lowercased()) +\(item.difference)"
        }.joined(separator: ", ")
    }

    private static func total(_ family: Catalog.Family) -> Int {
        family.quailScores.map { $0.maths + $0.knowledge + $0.tools } ?? 0
    }

    /// "9.3 GB": the memory a fit estimate needs, written as the fit card writes it.
    static func gigabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

private extension [ModelAlternatives.Alternative] {
    func contains(id: String) -> Bool {
        contains { $0.family.id == id }
    }
}
