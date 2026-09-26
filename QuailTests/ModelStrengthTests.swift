import Foundation
import Testing
@testable import Quail

@Suite("Model strengths")
struct ModelStrengthTests {
    private static func family(strengths: [String], mmproj: String? = nil) -> Catalog.Family {
        Catalog.Family(
            id: "m", name: "M", paramsB: 8, strengths: strengths,
            gguf: .init(repo: "org/M-GGUF", quants: ["Q4_K_M"], defaultQuant: "Q4_K_M", mmproj: mmproj),
            isCurated: true
        )
    }

    @Test("curated strings become strengths in display order; unknown ones from a newer catalog are skipped")
    func decoding() {
        let strengths = ModelStrength.strengths(of: Self.family(strengths: ["reasoning", "telepathy", "coding"]))
        #expect(strengths == [.coding, .reasoning])
    }

    @Test("vision comes from the GGUF projector, never from the curated list, and not for an MLX copy")
    func vision() {
        #expect(!ModelStrength.strengths(of: Self.family(strengths: ["vision"])).contains(.vision))
        let withProjector = Self.family(strengths: ["chat"], mmproj: "mmproj-F16.gguf")
        #expect(ModelStrength.strengths(of: withProjector) == [.chat, .vision])
        #expect(ModelStrength.strengths(of: withProjector, format: .gguf).contains(.vision))
        #expect(!ModelStrength.strengths(of: withProjector, format: .mlxSafetensors).contains(.vision))
    }

    @Test("audio is kept as a fact but not offered as something Quail can use")
    func audio() {
        #expect(ModelStrength.strengths(of: Self.family(strengths: ["audio"])) == [.audio])
        #expect(!ModelStrength.audio.isUsableInQuail)
    }

    @Test("the bundled catalog: every family says what it's good for, in words the app knows")
    func bundledCatalog() throws {
        let url = try #require(Bundle.main.url(forResource: "catalog", withExtension: "json"))
        let document = try JSONDecoder().decode(Catalog.Document.self, from: Data(contentsOf: url))
        for family in document.families {
            let raw = family.strengths ?? []
            #expect(!raw.isEmpty, "\(family.id) lists no strengths")
            for tag in raw {
                #expect(ModelStrength(rawValue: tag) != nil, "\(family.id): unknown strength '\(tag)'")
            }
            #expect(!raw.contains("vision"), "\(family.id): vision is derived from mmproj, not curated")
        }
    }
}
