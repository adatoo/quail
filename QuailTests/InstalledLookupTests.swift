import Foundation
import Testing
@testable import Quail

@Suite("InstalledLookup")
struct InstalledLookupTests {
    private static let qwen = Catalog.Family(
        id: "qwen3-0.6b", name: "Qwen3 0.6B", paramsB: 0.6, role: "smoke-test", rank: 99,
        gguf: Catalog.GGUFVariant(repo: "Qwen/Qwen3-0.6B-GGUF", quants: ["Q8_0", "Q4_K_M"], defaultQuant: "Q8_0"),
        mlx: Catalog.MLXVariant(repo: "mlx-community/Qwen3-0.6B-4bit"),
        isCurated: true
    )

    private static func entry(
        _ id: String, format: ModelFormat = .gguf, family: String? = nil, repo: String? = nil, quant: String? = nil
    ) -> InstalledModel {
        InstalledModel(
            id: id,
            family: family,
            format: format,
            bytes: 1,
            sourceRepo: repo,
            quant: quant,
            addedAt: .init()
        )
    }

    @Test("matches by recorded family, by source repo, and hand-placed GGUFs by repo name prefix")
    func matching() {
        let installed = [
            Self.entry("A-Q4_K_M", family: "qwen3-0.6b", quant: "Q4_K_M"),
            Self.entry(
                "mlx-community--Qwen3-0.6B-4bit",
                format: .mlxSafetensors,
                repo: "mlx-community/Qwen3-0.6B-4bit"
            ),
            Self.entry("Qwen3-0.6B-Q8_0"), // hand-placed: no family, no repo
            Self.entry("Qwen3-0.6B-Other-Q8_0", family: "someone-else"), // recorded family wins
            Self.entry("Qwen3-8B-Q8_0"),
        ]
        let ids = InstalledLookup.entries(for: Self.qwen, in: installed).map(\.id)
        #expect(ids == ["A-Q4_K_M", "mlx-community--Qwen3-0.6B-4bit", "Qwen3-0.6B-Q8_0"])
    }

    @Test("entry(for:format:quant:) picks the right quant, by recorded quant or filename")
    func perQuant() {
        let installed = [
            Self.entry("Qwen3-0.6B-Q8_0"),
            Self.entry("x", family: "qwen3-0.6b", quant: "Q4_K_M"),
        ]
        #expect(InstalledLookup.entry(for: Self.qwen, format: .gguf, quant: "Q8_0", in: installed)?
            .id == "Qwen3-0.6B-Q8_0")
        #expect(InstalledLookup.entry(for: Self.qwen, format: .gguf, quant: "q4_k_m", in: installed)?.id == "x")
        #expect(InstalledLookup.entry(for: Self.qwen, format: .gguf, quant: "Q5_K_M", in: installed) == nil)
        #expect(InstalledLookup.entry(for: Self.qwen, format: .mlxSafetensors, quant: nil, in: installed) == nil)
    }
}
