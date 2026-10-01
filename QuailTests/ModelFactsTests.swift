import Foundation
import Testing
@testable import Quail

@Suite("Model facts")
struct ModelFactsTests {
    private static func day(_ text: String) -> Date {
        Catalog.Document.day(text)!
    }

    private static func family(_ id: String, released: String? = nil, supersededBy: String? = nil) -> Catalog.Family {
        Catalog.Family(
            id: id, name: id.uppercased(), paramsB: 8,
            gguf: .init(repo: "org/\(id)-GGUF", quants: ["Q4_K_M"], defaultQuant: "Q4_K_M"),
            isCurated: true, released: released.map(day), supersededBy: supersededBy
        )
    }

    @Test("New for 30 days after release, not before it and not after")
    func newBadge() {
        let family = Self.family("m", released: "2026-09-17")
        #expect(ModelFacts.isNew(family, now: Self.day("2026-09-17")))
        #expect(ModelFacts.isNew(family, now: Self.day("2026-10-16")))
        #expect(!ModelFacts.isNew(family, now: Self.day("2026-10-17")))
        #expect(!ModelFacts.isNew(family, now: Self.day("2026-09-16")))
        #expect(!ModelFacts.isNew(Self.family("undated")))
    }

    @Test("a release day reads as that day wherever the Mac is")
    func dayText() {
        #expect(ModelFacts.dayText(Self.day("2026-08-05")) == "5 Aug 2026")
        #expect(ModelFacts.dayText(Self.day("2024-12-31")) == "31 Dec 2024")
    }

    @Test("newer follows the chain to the latest, and survives a loop or a missing id")
    func newer() {
        let chain = [
            Self.family("a", supersededBy: "b"), Self.family("b", supersededBy: "c"), Self.family("c"),
            Self.family("x", supersededBy: "y"), Self.family("y", supersededBy: "x"),
            Self.family("gone", supersededBy: "nowhere"),
        ]
        #expect(ModelFacts.newer(than: chain[0], in: chain)?.id == "c")
        #expect(ModelFacts.newer(than: chain[1], in: chain)?.id == "c")
        #expect(ModelFacts.newer(than: chain[2], in: chain) == nil)
        #expect(ModelFacts.newer(than: chain[3], in: chain)?.id == "y")
        #expect(ModelFacts.newer(than: chain[5], in: chain) == nil)
    }

    @Test("an Arena entry without its numbers yet is no rating; with them it reads as rating ± interval, rank")
    func arena() throws {
        let json = """
        {"revision": 1, "ramTiersGB": {}, "chipBandwidthGBps": {}, "families": [
          {"id": "a", "name": "A", "arena": {"name": "a"}, "variants": {"gguf": {"repo": "o/a", "quants": ["Q4_0"]}}},
          {"id": "b", "name": "B", "released": "2026-08-14", "modelCard": "Org/B",
           "arena": {"name": "b", "rating": 1439, "interval": 5, "rank": 94, "outOf": 410, "asOf": "2026-09-30"},
           "variants": {"gguf": {"repo": "o/b", "quants": ["Q4_0"]}}}
        ]}
        """
        let catalog = try JSONDecoder().decode(Catalog.Document.self, from: Data(json.utf8)).catalog
        #expect(catalog.families[0].arena == nil)
        let rated = try #require(catalog.families[1].arena)
        #expect(ModelFacts.arenaText(rated) == "1439 ± 5 · #94 of 410")
        #expect(ModelFacts.arenaCredit(rated).contains("30 Sep 2026"))
        #expect(catalog.families[1].released == Self.day("2026-08-14"))
        #expect(ModelFacts.modelCardURL(catalog.families[1])?.absoluteString == "https://huggingface.co/Org/B")
    }

    @Test("Quail's scores need all three and a date; a note stands in for scores that don't apply")
    func quailScores() throws {
        let json = """
        {"revision": 1, "ramTiersGB": {}, "chipBandwidthGBps": {}, "families": [
          {"id": "a", "name": "A", "quail": {"maths": 87, "knowledge": 64, "tools": 81, "asOf": "2026-10-02"},
           "variants": {"gguf": {"repo": "o/a", "quants": ["Q4_0"]}}},
          {"id": "b", "name": "B", "quail": {"maths": 87, "asOf": "2026-10-02"},
           "variants": {"gguf": {"repo": "o/b", "quants": ["Q4_0"]}}},
          {"id": "c", "name": "C", "quail": {"note": "It always thinks."},
           "variants": {"gguf": {"repo": "o/c", "quants": ["Q4_0"]}}}
        ]}
        """
        let families = try JSONDecoder().decode(Catalog.Document.self, from: Data(json.utf8)).catalog.families
        let scores = try #require(families[0].quailScores)
        #expect(ModelFacts.quailText(scores) == "Maths 87% · Knowledge 64% · Tools 81%")
        #expect(ModelFacts.quailMethod(scores).contains("2 Oct 2026"))
        #expect(families[1].quailScores == nil)
        #expect(families[2].quailScores == nil && families[2].quailNote == "It always thinks.")
    }

    @Test("a badge's short name drops the parenthetical note")
    func shortName() {
        var family = Self.family("m")
        family.name = "Qwen3.5 9B (vision)"
        #expect(ModelFacts.shortName(family) == "Qwen3.5 9B")
        family.name = "Bonsai 27B, 1-bit (vision)"
        #expect(ModelFacts.shortName(family) == "Bonsai 27B, 1-bit")
    }

    @Test("a smoke test or an embedding model doesn't say it's unranked")
    func expectsRanking() {
        var family = Self.family("m")
        family.role = "general"
        #expect(ModelFacts.expectsRanking(family))
        family.role = "embedding"
        #expect(!ModelFacts.expectsRanking(family))
        family.role = "smoke-test"
        #expect(!ModelFacts.expectsRanking(family))
    }
}
