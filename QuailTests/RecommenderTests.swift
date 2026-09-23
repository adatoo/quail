import Foundation
import Testing
@testable import Quail

/// Fabricated `Catalog`/`DeviceInfo` values throughout — the same style
/// `FitEstimatorTests` uses for the formulas `Recommender` builds on.
@Suite("Recommender")
struct RecommenderTests {
    private static let tiers: [String: Catalog.RAMTier] = [
        "small": Catalog.RAMTier(maxGB: 24, recommendParamsB: [0, 9]),
        "medium": Catalog.RAMTier(maxGB: 48, recommendParamsB: [9, 35]),
        "large": Catalog.RAMTier(maxGB: 9999, recommendParamsB: [35, 999]),
    ]

    private static func family(
        id: String,
        paramsB: Double?,
        role: String? = "general",
        rank: Int? = 1,
        curated: Bool = true,
        gguf: Bool = true,
        mlx: Bool = false
    )
        -> Catalog.Family
    {
        Catalog.Family(
            id: id, name: id, paramsB: paramsB, role: role, rank: rank,
            gguf: gguf ? Catalog.GGUFVariant(repo: "org/\(id)-GGUF", quants: ["Q4_K_M"], defaultQuant: "Q4_K_M") : nil,
            mlx: mlx ? Catalog.MLXVariant(repo: "org/\(id)-4bit") : nil,
            isCurated: curated
        )
    }

    private static func catalog(_ families: [Catalog.Family]) -> Catalog {
        Catalog(ramTiers: tiers, families: families)
    }

    /// A 64 GB M4 Pro's measured ceiling: ~85B fits at all, ~55B comfortably.
    private static let ceiling64GB: Int64 = 55_662_805_000

    private static func device(ceiling: Int64?) -> DeviceInfo {
        var info = DeviceInfo()
        info.gpuWorkingSetCeilingBytes = ceiling
        return info
    }

    @Test("candidates: curated, GGUF-capable, non-excluded roles, any size that might fit; rank then larger first")
    func candidatesFiltersAndSorts() {
        let families = [
            Self.family(id: "SmokeTest", paramsB: 0.6, role: "smoke-test", rank: 1),
            Self.family(id: "Embedding", paramsB: 4, role: "embedding", rank: 1),
            Self.family(id: "Small", paramsB: 8, rank: 2),
            Self.family(id: "Mid", paramsB: 31, rank: 2),
            Self.family(id: "Top", paramsB: 4, rank: 1),
            Self.family(id: "TooBig", paramsB: 120, rank: 1),
            Self.family(id: "MLXOnly", paramsB: 8, rank: 1, gguf: false, mlx: true),
            Self.family(id: "Uncurated", paramsB: 8, rank: 1, curated: false),
        ]

        let candidates = Recommender.candidates(
            catalog: Self.catalog(families),
            device: Self.device(ceiling: Self.ceiling64GB)
        )

        // Not tier-gated: a 64 GB Mac's "35B+" tier would have hidden all three.
        #expect(candidates.map(\.id) == ["Top", "Mid", "Small"])
    }

    @Test("candidates: empty when the GPU ceiling is unknown")
    func candidatesEmptyWithoutCeiling() {
        let catalog = Self.catalog([Self.family(id: "SmallA", paramsB: 8, rank: 1)])
        #expect(Recommender.candidates(catalog: catalog, device: Self.device(ceiling: nil)).isEmpty)
    }

    @Test("topPick: the best-ranked candidate expected to run comfortably, skipping ones that would be tight")
    func topPickSkipsTight() {
        let families = [
            Self.family(id: "Tight70B", paramsB: 70, rank: 1),
            Self.family(id: "Comfy32B", paramsB: 32, rank: 2),
        ]
        let pick = Recommender.topPick(catalog: Self.catalog(families), device: Self.device(ceiling: Self.ceiling64GB))
        #expect(pick?.id == "Comfy32B")
    }

    @Test("finalize: caps the shortlist at Recommender.limit")
    func finalizeCaps() {
        let candidates = (1 ... 8).map { (i: Int) in Self.family(id: "M\(i)", paramsB: 8, rank: i) }
        var verdicts: [String: FitEstimate] = [:]
        for family in candidates {
            verdicts["org/\(family.id)-GGUF"] = FitEstimate(
                verdict: .comfortable,
                ramNeededBytes: 1,
                estimatedTokensPerSecond: nil
            )
        }
        #expect(Recommender.finalize(candidates: candidates, verdicts: verdicts).map(\.id) == [
            "M1",
            "M2",
            "M3",
            "M4",
            "M5",
        ])
    }

    @Test("finalize: keeps only Comfortable verdicts, drops missing ones, preserves order")
    func finalizeKeepsOnlyComfortable() {
        let candidates = [
            Self.family(id: "SmallB", paramsB: 4, rank: 1),
            Self.family(id: "SmallA", paramsB: 8, rank: 2),
            Self.family(id: "NoVerdictYet", paramsB: 6, rank: 3),
        ]
        let verdicts: [String: FitEstimate] = [
            "org/SmallB-GGUF": FitEstimate(verdict: .comfortable, ramNeededBytes: 1, estimatedTokensPerSecond: nil),
            "org/SmallA-GGUF": FitEstimate(verdict: .wontFit, ramNeededBytes: 1, estimatedTokensPerSecond: nil),
        ]

        let finalized = Recommender.finalize(candidates: candidates, verdicts: verdicts)

        #expect(finalized.map(\.id) == ["SmallB"])
    }

    @Test("finalize: within a rank, faster on this Mac comes first; rank still dominates")
    func finalizeTieBreaksBySpeed() {
        let candidates = [
            Self.family(id: "Dense32B", paramsB: 32, rank: 1), // candidates' own order: larger first
            Self.family(id: "MoE26B", paramsB: 26, rank: 1),
            Self.family(id: "Fast8B", paramsB: 8, rank: 2),
        ]
        func verdict(_ speed: Double) -> FitEstimate {
            FitEstimate(verdict: .comfortable, ramNeededBytes: 1, estimatedTokensPerSecond: speed)
        }
        let verdicts = [
            "org/Dense32B-GGUF": verdict(10),
            "org/MoE26B-GGUF": verdict(180),
            "org/Fast8B-GGUF": verdict(400),
        ]
        #expect(Recommender.finalize(candidates: candidates, verdicts: verdicts).map(\.id) == [
            "MoE26B",
            "Dense32B",
            "Fast8B",
        ])
    }
}
