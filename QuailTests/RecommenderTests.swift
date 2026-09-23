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

    private static func device(memoryGB: Int) -> DeviceInfo {
        var info = DeviceInfo()
        info.unifiedMemoryBytes = Int64(memoryGB) * 1_073_741_824
        return info
    }

    @Test("candidates: only curated, GGUF-capable, in-tier, non-excluded-role families, sorted by rank")
    func candidatesFiltersAndSorts() {
        let families = [
            Self.family(id: "SmokeTest", paramsB: 0.6, role: "smoke-test", rank: 1),
            Self.family(id: "Embedding", paramsB: 4, role: "embedding", rank: 1),
            Self.family(id: "SmallA", paramsB: 8, rank: 2),
            Self.family(id: "SmallB", paramsB: 4, rank: 1),
            Self.family(id: "MediumOnly", paramsB: 20, rank: 1),
            Self.family(id: "MLXOnly", paramsB: 8, rank: 1, gguf: false, mlx: true),
            Self.family(id: "Uncurated", paramsB: 8, rank: 1, curated: false),
        ]
        let catalog = Self.catalog(families)

        let candidates = Recommender.candidates(catalog: catalog, device: Self.device(memoryGB: 16))

        #expect(candidates.map(\.id) == ["SmallB", "SmallA"])
    }

    @Test("candidates: a machine bigger than every tier's maxGB falls back to the largest tier")
    func candidatesFallsBackToLargestTier() {
        let families = [
            Self.family(id: "Huge", paramsB: 70, rank: 1),
            Self.family(id: "Small", paramsB: 4, rank: 1),
        ]
        let catalog = Self.catalog(families)

        let candidates = Recommender.candidates(catalog: catalog, device: Self.device(memoryGB: 20000))

        #expect(candidates.map(\.id) == ["Huge"])
    }

    @Test("candidates: picks the medium tier for a 32-48 GB machine, not small")
    func candidatesPicksMediumTier() {
        let families = [
            Self.family(id: "SmallOnly", paramsB: 8, rank: 1),
            Self.family(id: "MediumOnly", paramsB: 20, rank: 1),
        ]
        let catalog = Self.catalog(families)

        let candidates = Recommender.candidates(catalog: catalog, device: Self.device(memoryGB: 40))

        #expect(candidates.map(\.id) == ["MediumOnly"])
    }

    @Test("candidates: empty when the device's memory is unknown")
    func candidatesEmptyWithoutMemory() {
        let catalog = Self.catalog([Self.family(id: "SmallA", paramsB: 8, rank: 1)])

        let candidates = Recommender.candidates(catalog: catalog, device: DeviceInfo())

        #expect(candidates.isEmpty)
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
}
