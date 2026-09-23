import Foundation

/// docs/ARCHITECTURE.md §7's "Recommendations": "the curated catalog
/// filtered to Comfortable, sorted by a hand-set quality-per-GB rank."
/// (Its RAM tiers no longer gate recommendations — see `candidates`.) Split into two pure steps so the cheap,
/// synchronous
/// half (which families are even candidates) can run before the
/// expensive half (their actual fit verdicts, which need a network
/// round-trip per family — see `AppState.loadCatalogVerdicts`).
enum Recommender {
    /// Roles that "recommended" doesn't mean, even if they'd otherwise
    /// land in a machine's tier — a 0.6B smoke-test model is never what
    /// a user browsing for a general model wants, and an embedding model
    /// isn't something Quail's router serves for chat.
    private static let excludedRoles: Set<String> = ["smoke-test", "embedding"]

    /// At most this many recommendations — the full list is right below.
    static let limit = 5

    /// Curated, GGUF-capable, non-excluded-role families small enough
    /// that they *might* fit this Mac (`FitEstimator.approxMaxParamsB`
    /// on the measured GPU ceiling — a cheap pre-filter before the real
    /// per-model verdicts). Sorted by `rank`, then larger first: rank is
    /// hand-set per family, and among equally-ranked models the bigger
    /// one that still runs comfortably is the better suggestion.
    ///
    /// No longer limited to the Mac's RAM tier (user decision, after live
    /// testing): a 64 GB Mac's tier is "35B+", which hid Gemma 4 31B and
    /// Qwen3.8 27B although both run comfortably. GGUF only: nothing can
    /// serve MLX before Phase 3. Empty if the GPU ceiling isn't known.
    static func candidates(catalog: Catalog, device: DeviceInfo) -> [Catalog.Family] {
        guard let ceiling = device.gpuWorkingSetCeilingBytes else { return [] }
        let maxParams = Double(FitEstimator.approxMaxParamsB(gpuCeilingBytes: ceiling, comfortable: false))

        return catalog.families
            .filter(\.isCurated)
            .filter { $0.gguf != nil }
            .filter { !excludedRoles.contains($0.role ?? "") }
            .filter { family in
                guard let params = family.paramsB else { return false }
                return params <= maxParams
            }
            .sorted { lhs, rhs in
                let (lr, rr) = (lhs.rank ?? .max, rhs.rank ?? .max)
                if lr != rr {
                    return lr < rr
                }
                return (lhs.paramsB ?? 0) > (rhs.paramsB ?? 0)
            }
    }

    /// The first candidate expected to run *comfortably*, from catalog
    /// data alone — for the Models pane's empty state, which shows a
    /// suggestion before any per-model verdict has been fetched.
    static func topPick(catalog: Catalog, device: DeviceInfo) -> Catalog.Family? {
        guard let ceiling = device.gpuWorkingSetCeilingBytes else { return nil }
        let comfortable = Double(FitEstimator.approxMaxParamsB(gpuCeilingBytes: ceiling, comfortable: true))
        return candidates(catalog: catalog, device: device).first { ($0.paramsB ?? .infinity) <= comfortable }
    }

    /// `candidates`, narrowed to `.comfortable` (§7: "filtered to
    /// Comfortable") — a family with no verdict yet (still loading, or
    /// the lookup failed) is dropped rather than shown as a false
    /// positive. `verdicts` is keyed by the family's GGUF repo id, at
    /// whatever quant `AppState.loadCatalogVerdicts` resolved (the
    /// catalog's own recommended default) — one verdict per family is
    /// what "is this worth recommending" needs, not every quant's.
    ///
    /// Ordered by `rank`, then by estimated speed on this Mac (faster
    /// first), then size — so among equally good models a fast MoE beats
    /// a slow dense one. Size alone used to break ties, which put an
    /// older Qwen3 32B above its successor Qwen3.8 27B.
    static func finalize(candidates: [Catalog.Family], verdicts: [String: FitEstimate]) -> [Catalog.Family] {
        let comfortable: [(family: Catalog.Family, speed: Double)] = candidates.compactMap { family in
            guard let repo = family.gguf?.repo, let verdict = verdicts[repo], verdict.verdict == .comfortable else {
                return nil
            }
            return (family, verdict.estimatedTokensPerSecond ?? -1)
        }
        let ordered = comfortable.enumerated().sorted { lhs, rhs in
            let (l, r) = (lhs.element, rhs.element)
            let (lr, rr) = (l.family.rank ?? .max, r.family.rank ?? .max)
            if lr != rr {
                return lr < rr
            }
            if l.speed != r.speed {
                return l.speed > r.speed
            }
            return lhs.offset < rhs.offset // keep `candidates`' own order (rank, then size)
        }
        return Array(ordered.prefix(limit).map(\.element.family))
    }
}
