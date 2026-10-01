import Foundation
import Testing
@testable import QuailServerCore

@Suite("Bonsai 2's rotation manifest")
struct PrismHadamardManifestTests {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestFixtures/MLXConfigs/ternary-bonsai-2-27b.json")

    private static func realManifest() throws -> PrismHadamardManifest {
        try JSONDecoder().decode(PrismHadamardManifest.self, from: Data(contentsOf: fixture))
    }

    private static func manifest(
        schemaVersion: Int = 2, baseModelType: String? = "qwen3_5", tensorNamespace: String? = "mlx-vlm-qwen3_5",
        layout: String? = "grouped", modules: [PrismHadamardManifest.Module] = [.init(path: "lm_head", block: 64)],
        mode: String = "affine"
    ) -> PrismHadamardManifest {
        PrismHadamardManifest(
            schemaVersion: schemaVersion, baseModelType: baseModelType, tensorNamespace: tensorNamespace,
            gdnActivationLayout: layout, modules: modules,
            quantization: .init(bits: 2, groupSize: 128, mode: mode)
        )
    }

    private static func validate(_ manifest: PrismHadamardManifest) throws {
        try manifest.validate(baseModelType: "qwen3_5", tensorNamespace: "mlx-vlm-qwen3_5")
    }

    @Test("the real pack's config decodes: 402 rotated modules, blocks of 1024, float16")
    func realPack() throws {
        // prism-ml/Ternary-Bonsai-2-27B-mlx-2bit's config.json, 2026-09-30.
        let manifest = try Self.realManifest()
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.baseModelType == "qwen3_5")
        #expect(manifest.gdnActivationLayout == "grouped")
        #expect(manifest.quantization == .init(bits: 2, groupSize: 128, mode: "affine"))
        #expect(manifest.modules.count == 402)
        #expect(Set(manifest.modules.map(\.block)) == [1024])
        #expect(manifest.modules.filter(\.embedding).map(\.path) == ["model.embed_tokens"])
        #expect(try manifest.activationDType() == "float16")
        try Self.validate(manifest)
    }

    @Test("the rotated modules are the ones Quail's Qwen3.5 copy has as plain Linear or Embedding layers")
    func pathsMatchTheCopy() throws {
        let paths = try Self.realManifest().modules.map(\.path)
        let leaves = Set(paths.map { $0.components(separatedBy: ".").last ?? $0 })
        // Qwen35.swift keeps these unfused, under these keys; in_proj_a and in_proj_b stay unrotated.
        #expect(leaves == [
            "embed_tokens", "lm_head", "q_proj", "k_proj", "v_proj", "o_proj",
            "in_proj_qkv", "in_proj_z", "out_proj", "gate_proj", "up_proj", "down_proj",
        ])
    }

    @Test("a manifest Quail can't honour is refused before a model is built")
    func validation() {
        typealias E = PrismHadamardManifest.Error
        #expect(throws: E.unsupportedSchemaVersion(1)) { try Self.validate(Self.manifest(schemaVersion: 1)) }
        #expect(throws: E.unsupportedBaseModelType("qwen3", expected: "qwen3_5")) {
            try Self.validate(Self.manifest(baseModelType: "qwen3"))
        }
        #expect(throws: E.unsupportedTensorNamespace(nil, expected: "mlx-vlm-qwen3_5")) {
            try Self.validate(Self.manifest(tensorNamespace: nil))
        }
        #expect(throws: E.unsupportedActivationLayout("interleaved")) {
            try Self.validate(Self.manifest(layout: "interleaved"))
        }
        #expect(throws: E.emptyManifest) { try Self.validate(Self.manifest(modules: [])) }
        #expect(throws: E.unsupportedQuantizationMode("mxfp4")) { try Self.validate(Self.manifest(mode: "mxfp4")) }
        #expect(throws: E.unsupportedBlockSize("lm_head", block: 96)) {
            try Self.validate(Self.manifest(modules: [.init(path: "lm_head", block: 96)]))
        }
        #expect(throws: E.mixedActivationDTypes(["bfloat16", "float16"])) {
            try Self.validate(Self.manifest(modules: [
                .init(path: "a", block: 64, dtype: "float16"), .init(path: "b", block: 64, dtype: "bfloat16"),
            ]))
        }
        #expect(throws: E.unsupportedActivationDType("float32")) {
            try Self.validate(Self.manifest(modules: [.init(path: "a", block: 64, dtype: "float32")]))
        }
        // With no layout named, none is needed.
        #expect(throws: Never.self) { try Self.validate(Self.manifest(layout: nil)) }
    }

    @Test("the cast skips the packed modules' own tensors and A_log, and takes everything else")
    func castChoice() throws {
        let manifest = try Self.realManifest()
        let prefix = "language_model."
        #expect(!manifest.castsUnpacked("language_model.model.layers.0.mlp.up_proj.scales", pathPrefix: prefix))
        #expect(!manifest.castsUnpacked("language_model.model.layers.0.mlp.up_proj.signs", pathPrefix: prefix))
        #expect(!manifest.castsUnpacked("language_model.lm_head.biases", pathPrefix: prefix))
        #expect(!manifest.castsUnpacked("language_model.model.layers.0.linear_attn.A_log", pathPrefix: prefix))
        #expect(manifest.castsUnpacked("language_model.model.norm.weight", pathPrefix: prefix))
        #expect(manifest.castsUnpacked(
            "language_model.model.layers.0.linear_attn.in_proj_a.weight",
            pathPrefix: prefix
        ))
        #expect(manifest.castsUnpacked("language_model.model.layers.0.linear_attn.dt_bias", pathPrefix: prefix))
    }
}
