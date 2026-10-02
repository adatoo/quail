import Foundation
import Testing
@testable import Quail

/// Each layer's cache (ADR D-071), from the shapes of real catalog models: their GGUF headers' keys and their MLX
/// `config.json`s, cut to the fields that matter.
@Suite("Per-layer KV cache")
struct KVLayersTests {
    private typealias Layers = ModelShape.KVLayers

    /// `count` repeats of `pattern`, as a per-layer key is written.
    private static func repeating<T>(_ pattern: [T], _ count: Int) -> [T] {
        Array([[T]](repeating: pattern, count: count).joined())
    }

    private static func gguf(_ build: (inout GGUFFixtureBuilder) -> Void) throws -> GGUFMetadata {
        var fixture = GGUFFixtureBuilder()
        build(&fixture)
        let url = try fixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        return try GGUFMetadata.read(from: url)
    }

    private static func mlx(_ json: String) throws -> ModelShape {
        try #require(ModelShape.from(mlx: MLXMetadata.parse(Data(json.utf8)), weightBytes: 1_000_000_000))
    }

    // MARK: GGUF

    @Test("Gemma 4 31B GGUF: 50 sliding-window layers at 16 × 256, 10 global at 4 × 512, all over the whole context")
    func gemma4GGUF() throws {
        let metadata = try Self.gguf { fixture in
            fixture.addString("general.architecture", "gemma4")
            fixture.addUInt32("gemma4.block_count", 60)
            fixture.addUInt32Array("gemma4.attention.head_count_kv", Self.repeating([16, 16, 16, 16, 16, 4], 10))
            fixture.addUInt32("gemma4.attention.key_length", 512)
            fixture.addUInt32("gemma4.attention.value_length", 512)
            fixture.addUInt32("gemma4.attention.sliding_window", 1024)
            fixture.addBoolArray(
                "gemma4.attention.sliding_window_pattern", Self.repeating([true, true, true, true, true, false], 10)
            )
            fixture.addUInt32("gemma4.attention.key_length_swa", 256)
            fixture.addUInt32("gemma4.attention.value_length_swa", 256)
        }
        let shape = try #require(ModelShape.from(gguf: metadata, weightBytes: 18_323_733_440))
        #expect(shape.kvLayers == [
            Layers(count: 50, kvHeads: 16, keyValueDim: 512),
            Layers(count: 10, kvHeads: 4, keyValueDim: 1024),
        ])
        // (50 × 16 × 512 + 10 × 4 × 1024) × 2 bytes = 901,120 a token, against the plain formula's
        // 60 × 16 × 1024 × 2 = 1,966,080, which counted every layer as global.
        #expect(FitEstimator.kvBytes(shape, contextSize: 1, kvCache: .full) == 901_120)
        #expect(FitEstimator.kvBytes(shape, contextSize: 32768, kvCache: .full) == 901_120 * 32768)
    }

    @Test("Qwen3.5 9B GGUF: only every fourth layer keeps a cache; the extra MTP layer doesn't")
    func qwen35GGUF() throws {
        let metadata = try Self.gguf { fixture in
            fixture.addString("general.architecture", "qwen35")
            fixture.addUInt32("qwen35.block_count", 33)
            fixture.addUInt32("qwen35.attention.head_count_kv", 4)
            fixture.addUInt32("qwen35.attention.key_length", 256)
            fixture.addUInt32("qwen35.attention.value_length", 256)
            fixture.addUInt32("qwen35.full_attention_interval", 4)
        }
        let shape = try #require(ModelShape.from(gguf: metadata, weightBytes: 6_000_000_000))
        #expect(shape.kvLayers == [Layers(count: 8, kvHeads: 4, keyValueDim: 512)])
    }

    @Test("Nemotron H GGUF: layers with no KV heads keep no cache, where the first array element read 0 before")
    func nemotronGGUF() throws {
        let heads: [UInt32] = [0, 0, 0, 0, 0, 2] + Self.repeating([0, 0, 0, 0, 0, 0, 2], 4) + [0, 0, 2]
        let metadata = try Self.gguf { fixture in
            fixture.addString("general.architecture", "nemotron_h_moe")
            fixture.addUInt32("nemotron_h_moe.block_count", UInt32(heads.count))
            fixture.addUInt32Array("nemotron_h_moe.attention.head_count_kv", heads)
            fixture.addUInt32("nemotron_h_moe.attention.key_length", 128)
            fixture.addUInt32("nemotron_h_moe.attention.value_length", 128)
        }
        let shape = try #require(ModelShape.from(gguf: metadata, weightBytes: 19_000_000_000))
        #expect(shape.kvHeadCount == 2)
        #expect(shape.kvLayers == [Layers(count: 6, kvHeads: 2, keyValueDim: 256)])
    }

    @Test("a model whose layers are all alike keeps the plain formula, whichever way the header writes it")
    func plainGGUF() throws {
        let metadata = try Self.gguf { fixture in
            fixture.addString("general.architecture", "llama")
            fixture.addUInt32("llama.block_count", 4)
            fixture.addUInt32Array("llama.attention.head_count_kv", [8, 8, 8, 8])
            fixture.addUInt32("llama.attention.key_length", 128)
            fixture.addUInt32("llama.attention.value_length", 128)
        }
        let shape = try #require(ModelShape.from(gguf: metadata, weightBytes: 1_000_000_000))
        #expect(shape.kvLayers == nil)
        #expect(FitEstimator.kvBytes(shape, contextSize: 100, kvCache: .full) == 2 * 4 * 8 * 128 * 2 * 100)
    }

    // MARK: MLX

    @Test("Gemma 4 31B MLX: the sliding-window layers hold 1,024 tokens at most, and stay full precision")
    func gemma4MLX() throws {
        let types = Self.repeating(Array(repeating: "\"sliding_attention\"", count: 5) + ["\"full_attention\""], 10)
        let shape = try Self.mlx("""
        {"model_type": "gemma4", "text_config": {"model_type": "gemma4_text", "num_hidden_layers": 60,
         "num_key_value_heads": 16, "head_dim": 256, "num_global_key_value_heads": 4, "global_head_dim": 512,
         "sliding_window": 1024, "layer_types": [\(types.joined(separator: ","))]}}
        """)
        #expect(shape.kvLayers == [
            Layers(count: 50, kvHeads: 16, keyValueDim: 512, window: 1024),
            Layers(count: 10, kvHeads: 4, keyValueDim: 1024),
        ])
        let windowed: Int64 = 50 * 16 * 512 * 2 * 1024
        let global: Int64 = 10 * 4 * 1024 * 2
        #expect(FitEstimator.kvBytes(shape, contextSize: 512, kvCache: .full) == 512 * (50 * 16 * 512 * 2 + global))
        #expect(FitEstimator.kvBytes(shape, contextSize: 32768, kvCache: .full) == windowed + global * 32768)
        // A 4-bit setting shrinks only the global layers: MLX doesn't quantize a rotating cache (ADR D-057).
        #expect(FitEstimator.kvBytes(shape, contextSize: 32768, kvCache: .q4)
            == windowed + Int64(10 * 4 * 1024 * 0.5625) * 32768)
    }

    @Test("gpt-oss MLX: alternate layers keep a 128-token window")
    func gptOSSMLX() throws {
        let types = Self.repeating(["\"sliding_attention\"", "\"full_attention\""], 12)
        let shape = try Self.mlx("""
        {"model_type": "gpt_oss", "num_hidden_layers": 24, "num_key_value_heads": 8, "head_dim": 64,
         "sliding_window": 128, "layer_types": [\(types.joined(separator: ","))]}
        """)
        #expect(shape.kvLayers == [
            Layers(count: 12, kvHeads: 8, keyValueDim: 128, window: 128),
            Layers(count: 12, kvHeads: 8, keyValueDim: 128),
        ])
    }

    @Test("Qwen3.6 MLX: linear-attention layers keep no cache")
    func qwen36MLX() throws {
        let types = Self.repeating(Array(repeating: "\"linear_attention\"", count: 3) + ["\"full_attention\""], 10)
        let shape = try Self.mlx("""
        {"model_type": "qwen3_5_moe", "text_config": {"num_hidden_layers": 40, "num_key_value_heads": 2,
         "head_dim": 256, "full_attention_interval": 4, "layer_types": [\(types.joined(separator: ","))]}}
        """)
        #expect(shape.kvLayers == [Layers(count: 10, kvHeads: 2, keyValueDim: 512)])
    }

    @Test("Nemotron H MLX: only its attention blocks keep a cache, by either spelling")
    func nemotronMLX() throws {
        let byType = try Self.mlx("""
        {"model_type": "nemotron_h", "num_hidden_layers": 6, "num_key_value_heads": 2, "head_dim": 128,
         "layers_block_type": ["mamba", "moe", "attention", "mamba", "moe", "attention"]}
        """)
        #expect(byType.kvLayers == [Layers(count: 2, kvHeads: 2, keyValueDim: 256)])
        let byPattern = try Self.mlx("""
        {"model_type": "nemotron_h", "num_hidden_layers": 6, "num_key_value_heads": 2, "head_dim": 128,
         "hybrid_override_pattern": "ME*ME*"}
        """)
        #expect(byPattern.kvLayers == byType.kvLayers)
    }

    @Test("Gemma 3's every-sixth-layer pattern, and layers sharing an earlier one's cache")
    func gemmaPatternAndSharedLayers() throws {
        let gemma3 = try Self.mlx("""
        {"model_type": "gemma3_text", "num_hidden_layers": 12, "num_key_value_heads": 8, "head_dim": 256,
         "sliding_window": 1024, "sliding_window_pattern": 6}
        """)
        #expect(gemma3.kvLayers == [
            Layers(count: 10, kvHeads: 8, keyValueDim: 512, window: 1024),
            Layers(count: 2, kvHeads: 8, keyValueDim: 512),
        ])
        let shared = try Self.mlx("""
        {"model_type": "gemma4_text", "num_hidden_layers": 4, "num_key_value_heads": 1, "head_dim": 256,
         "num_kv_shared_layers": 2, "layer_types": ["full_attention", "full_attention", "full_attention",
         "full_attention"]}
        """)
        #expect(shared.kvLayers == [Layers(count: 2, kvHeads: 1, keyValueDim: 512)])
    }

    @Test("a plain MLX model, or one with a sliding_window but no windowed layers, keeps the plain formula")
    func plainMLX() throws {
        let qwen2 = try Self.mlx("""
        {"model_type": "qwen2", "num_hidden_layers": 64, "num_key_value_heads": 8, "hidden_size": 5120,
         "num_attention_heads": 40, "sliding_window": 131072}
        """)
        #expect(qwen2.kvLayers == nil)
    }

    // MARK: Fit

    /// The bench M1 Max: 64 GB, and the working-set ceiling Metal reported for it on 2026-10-02.
    private static let m1Max64 = DeviceInfo(
        chipName: "Apple M1 Max", performanceCoreCount: 8, efficiencyCoreCount: 2,
        unifiedMemoryBytes: 68_719_476_736, gpuWorkingSetCeilingBytes: 55_662_788_608, freeMemoryBytes: nil
    )

    @Test("the largest fitting context accounts for windowed layers, which stop growing past their window")
    func largestContextWithWindow() {
        let shape = ModelShape(
            weightBytes: 0, layerCount: 2, kvHeadCount: 1, headDim: 1,
            kvLayers: [
                Layers(count: 1, kvHeads: 1, keyValueDim: 1000, window: 100),
                Layers(count: 1, kvHeads: 1, keyValueDim: 1000),
            ]
        )
        // 2,000 bytes a token up to 100 tokens, then 2,000 a token for the global layer alone.
        #expect(FitEstimator.largestContext(shape, fitting: 100_000, kvCache: .full, limit: 1000) == 25)
        #expect(FitEstimator.largestContext(shape, fitting: 1_000_000, kvCache: .full, limit: 1000) == 400)
        #expect(FitEstimator.largestContext(shape, fitting: 10_000_000, kvCache: .full, limit: 1000) == 1000)
        #expect(FitEstimator.largestContext(shape, fitting: -1, kvCache: .full, limit: 1000) == 0)
    }

    @Test("Gemma 4 31B GGUF on the bench Mac: 32K is Tight but fits, as it ran; Automatic is 16K")
    func gemma4GGUFOnBenchMac() throws {
        let shape = ModelShape(
            weightBytes: 18_323_733_440, layerCount: 60, kvHeadCount: 16, headDim: 512,
            kvLayers: [
                Layers(count: 50, kvHeads: 16, keyValueDim: 512),
                Layers(count: 10, kvHeads: 4, keyValueDim: 1024),
            ]
        )
        let estimate = try #require(FitEstimator.estimate(
            model: shape, device: Self.m1Max64, runtime: .quail, requestedContextSize: 32768
        ))
        #expect(estimate.verdict == .tight(reducedContextSize: 32768))
        #expect(FitEstimator.automaticContextSize(model: shape, device: Self.m1Max64, runtime: .quail) == 16384)
    }

    @Test("Gemma 4 31B MLX on a 64 GB Mac: 32K is comfortable once the windowed layers are counted as such")
    func gemma4MLXFits() throws {
        var shape = try Self.mlx("""
        {"model_type": "gemma4_text", "num_hidden_layers": 6, "num_key_value_heads": 16, "head_dim": 256,
         "num_global_key_value_heads": 4, "global_head_dim": 512, "sliding_window": 1024,
         "layer_types": ["sliding_attention", "sliding_attention", "sliding_attention", "sliding_attention",
         "sliding_attention", "full_attention"]}
        """)
        shape.weightBytes = 18_444_421_751
        let estimate = try #require(FitEstimator.estimate(
            model: shape, device: Self.m1Max64, runtime: .omlx, requestedContextSize: 32768
        ))
        #expect(estimate.verdict == .comfortable)
    }
}
