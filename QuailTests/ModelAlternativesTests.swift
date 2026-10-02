import Foundation
import Testing
@testable import Quail

@Suite("Model alternatives")
struct ModelAlternativesTests {
    private static let day = Date(timeIntervalSince1970: 1_790_000_000)

    private static func family(
        _ id: String, role: String = "general", strengths: [String] = ["chat"], scores: (Int, Int, Int)?,
        supersededBy: String? = nil, curated: Bool = true
    ) -> Catalog.Family {
        Catalog.Family(
            id: id, name: id, role: role, strengths: strengths, isCurated: curated, supersededBy: supersededBy,
            quailScores: scores.map { Catalog.QuailScores(maths: $0.0, knowledge: $0.1, tools: $0.2, asOf: day) }
        )
    }

    private static func fit(
        _ gigabytes: Double,
        speed: Double? = 30,
        verdict: FitVerdict = .comfortable
    ) -> FitEstimate {
        FitEstimate(
            verdict: verdict, ramNeededBytes: Int64(gigabytes * 1e9), estimatedTokensPerSecond: speed
        )
    }

    @Test("one about the same size that scores higher, one much smaller, one much faster, each as good")
    func threeReasons() {
        let target = Self.family("target", scores: (90, 70, 85))
        let families = [
            target,
            Self.family("higher", scores: (92, 85, 86)), // knowledge +15, the rest within the margins
            Self.family("higher-but-huge", scores: (99, 95, 99)),
            Self.family("smaller", scores: (88, 65, 84)),
            Self.family("faster", scores: (91, 72, 83)),
        ]
        let fits = [
            "target": Self.fit(20), "higher": Self.fit(22), "higher-but-huge": Self.fit(40),
            "smaller": Self.fit(6, speed: 40), "faster": Self.fit(18, speed: 90),
        ]
        let result = ModelAlternatives.alternatives(for: target, in: families, fits: fits)
        #expect(result.map(\.family.id) == ["higher", "smaller", "faster"])
        #expect(result.map(\.reason) == [.scoresHigher, .smaller, .faster])
        #expect(result[0].detail == "Knowledge +15")
        #expect(result[2].detail == "~90 tok/s against ~30, about as good")
    }

    @Test("worse beyond a margin on any test rules a candidate out, however small or fast")
    func worseIsNotAnAlternative() {
        let target = Self.family("target", scores: (90, 70, 85))
        let families = [target, Self.family("weak-tools", scores: (95, 80, 70))]
        let fits = ["target": Self.fit(20), "weak-tools": Self.fit(5, speed: 200)]
        #expect(ModelAlternatives.alternatives(for: target, in: families, fits: fits).isEmpty)
    }

    @Test("a candidate must be scored, curated, fit this Mac, and not be the successor the card already shows")
    func candidatesAreFiltered() {
        let target = Self.family("target", scores: (80, 50, 60), supersededBy: "successor")
        let families = [
            target,
            Self.family("successor", scores: (95, 80, 90)),
            Self.family("unscored", scores: nil),
            Self.family("user", scores: (95, 80, 90), curated: false),
            Self.family("too-big", scores: (95, 80, 90)),
            Self.family("unchecked", scores: (95, 80, 90)),
            Self.family("embedding", role: "embedding", scores: (95, 80, 90)),
        ]
        let fits = [
            "target": Self.fit(10), "successor": Self.fit(10), "unscored": Self.fit(5), "user": Self.fit(5),
            "too-big": Self.fit(5, verdict: .wontFit), "embedding": Self.fit(1),
        ]
        #expect(ModelAlternatives.alternatives(for: target, in: families, fits: fits).isEmpty)
    }

    @Test("a coding model's alternatives are good at coding")
    func codingNeedsCoding() {
        let target = Self.family("coder", role: "coding", strengths: ["coding"], scores: (80, 50, 60))
        let families = [
            target,
            Self.family("chatty", scores: (95, 80, 90)),
            Self.family("general-coder", strengths: ["chat", "coding"], scores: (95, 80, 90)),
        ]
        let fits = ["coder": Self.fit(10), "chatty": Self.fit(10), "general-coder": Self.fit(11)]
        #expect(ModelAlternatives.alternatives(for: target, in: families, fits: fits).map(\.family.id)
            == ["general-coder"])
    }

    @Test("nothing to compare without the family's own scores or fit")
    func needsItsOwnScoresAndFit() {
        let other = Self.family("other", scores: (95, 80, 90))
        let unscored = Self.family("unscored", scores: nil)
        #expect(ModelAlternatives.alternatives(
            for: unscored, in: [unscored, other], fits: ["unscored": Self.fit(10), "other": Self.fit(10)]
        ).isEmpty)
        let scored = Self.family("scored", scores: (50, 40, 30))
        #expect(ModelAlternatives.alternatives(for: scored, in: [scored, other], fits: ["other": Self.fit(10)]).isEmpty)
    }

    @Test("a family isn't offered twice; a tiny model may step up by 2 GB")
    func eachOnceAndSmallStepUp() {
        let target = Self.family("tiny", scores: (50, 30, 40))
        let families = [target, Self.family("better-and-faster", scores: (80, 50, 80))]
        let fits = ["tiny": Self.fit(1.5, speed: 100), "better-and-faster": Self.fit(3.4, speed: 200)]
        let result = ModelAlternatives.alternatives(for: target, in: families, fits: fits)
        #expect(result.map(\.reason) == [.scoresHigher])
        #expect(result.first?.detail == "Maths +30, knowledge +20, tools +40")
    }
}
