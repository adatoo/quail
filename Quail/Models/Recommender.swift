import Foundation

/// docs/ARCHITECTURE.md §7's "Recommendations": "the curated catalog
/// filtered to Comfortable, sorted by a hand-set quality-per-GB rank.
/// Three tiers..." Split into two pure steps so the cheap, synchronous
/// half (which families are even candidates) can run before the
/// expensive half (their actual fit verdicts, which need a network
/// round-trip per family — see `AppState.loadCatalogVerdicts`).
enum Recommender {
    /// Roles that "recommended" doesn't mean, even if they'd otherwise
    /// land in a machine's tier — a 0.6B smoke-test model is never what
    /// a user browsing for a general model wants, and an embedding model
    /// isn't something Quail's router serves for chat.
    private static let excludedRoles: Set<String> = ["smoke-test", "embedding"]

    /// Curated, GGUF-capable families whose `paramsB` sits inside this
    /// Mac's RAM tier (`Catalog.tier(forMemoryBytes:)`), sorted by
    /// `rank` ascending. GGUF only: it's the only format anything can
    /// serve before Phase 3's MLX runtimes. Empty if the device's memory
    /// or the catalog's tiers aren't known — never a guess.
    static func candidates(catalog: Catalog, device: DeviceInfo) -> [Catalog.Family] {
        guard let bytes = device.unifiedMemoryBytes,
              let (_, tier) = catalog.tier(forMemoryBytes: bytes),
              let range = tier.recommendedRange
        else { return [] }

        return catalog.families
            .filter(\.isCurated)
            .filter { $0.gguf != nil }
            .filter { !excludedRoles.contains($0.role ?? "") }
            .filter { family in
                guard let params = family.paramsB else { return false }
                return range.contains(params)
            }
            .sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
    }

    /// `candidates`, narrowed to `.comfortable` (§7: "filtered to
    /// Comfortable") — a family with no verdict yet (still loading, or
    /// the lookup failed) is dropped rather than shown as a false
    /// positive. `verdicts` is keyed by the family's GGUF repo id, at
    /// whatever quant `AppState.loadCatalogVerdicts` resolved (the
    /// catalog's own recommended default) — one verdict per family is
    /// what "is this worth recommending" needs, not every quant's.
    static func finalize(candidates: [Catalog.Family], verdicts: [String: FitEstimate]) -> [Catalog.Family] {
        candidates.filter { family in
            guard let repo = family.gguf?.repo, let verdict = verdicts[repo] else { return false }
            return verdict.verdict == .comfortable
        }
    }
}
