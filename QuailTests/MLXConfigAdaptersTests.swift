import Foundation
import Testing
@testable import QuailServerCore

@Suite("MLX config adapters")
struct MLXConfigAdaptersTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestFixtures/MLXConfigs")

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any])
    }

    @Test("Nemotron 3.5's layer words become the pattern mlx-swift-lm reads — Nemotron 3 Nano's own layout")
    func nemotron35() throws {
        // mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit's config.json, 2026-09-30: `layers_block_type`
        // only. The same 52 layers as Nemotron 3 Nano's `hybrid_override_pattern`.
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("nemotron-3.5-lightning-30b-a3b.json"))
        #expect(try Self.object(data)["hybrid_override_pattern"] == nil)
        let adapted = try Self.object(MLXConfigAdapters.nemotronH(data))
        let nano = try Self.object(Data(contentsOf: Self.fixtures.appendingPathComponent(
            "nemotron-3-nano-30b-a3b.json"
        )))
        let pattern = try #require(adapted["hybrid_override_pattern"] as? String)
        #expect(pattern.count == 52)
        #expect(pattern == nano["hybrid_override_pattern"] as? String)
        // Everything else is as it was.
        #expect(adapted["num_hidden_layers"] as? Int == 52)
        #expect(adapted["n_routed_experts"] as? Int == 128)
    }

    @Test("a config that has the pattern is passed through byte for byte")
    func nanoUnchanged() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("nemotron-3-nano-30b-a3b.json"))
        #expect(try MLXConfigAdapters.nemotronH(data) == data)
    }

    @Test("every spelling mlx-lm maps, and the layer count when transformers left it out")
    func mapping() throws {
        let data = Data(#"{"layer_types": ["linear_attention", "moe", "full_attention", "mlp", "conv", "mamba"]}"#.utf8)
        let adapted = try Self.object(MLXConfigAdapters.nemotronH(data))
        #expect(adapted["hybrid_override_pattern"] as? String == "ME*-MM")
        #expect(adapted["num_hidden_layers"] as? Int == 6)
    }

    @Test("an unknown layer type is an error, not a guessed layout")
    func unknownType() {
        let data = Data(#"{"layers_block_type": ["mamba", "sliding_attention"]}"#.utf8)
        #expect(throws: MLXConfigAdapters.UnknownLayerType.self) {
            try MLXConfigAdapters.nemotronH(data)
        }
    }

    @Test("JSON5, as mlx-swift-lm reads configs, is adapted too, and stays JSON5")
    func json5() throws {
        let data = Data(#"{ layers_block_type: ["mamba", "moe"], time_step_limit: [0.0, Infinity], }"#.utf8)
        let adapted = try MLXConfigAdapters.nemotronH(data)
        #expect(try Self.object(adapted)["hybrid_override_pattern"] as? String == "ME")
        #expect(String(decoding: adapted, as: UTF8.self).hasSuffix("Infinity], }"))
    }

    @Test("a config that isn't JSON at all is left for mlx-swift-lm to refuse")
    func notJSON() throws {
        let data = Data("not a config".utf8)
        #expect(try MLXConfigAdapters.nemotronH(data) == data)
    }
}
