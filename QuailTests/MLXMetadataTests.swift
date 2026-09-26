import Foundation
import Testing
@testable import Quail

@Suite("MLXMetadata")
struct MLXMetadataTests {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-mlx-config-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Real config.json from mlx-community/Qwen2.5-7B-Instruct-4bit, fetched
    /// while writing this parser — hidden_size/num_attention_heads divides
    /// evenly here (3584/28=128), so this also covers the computed-head_dim
    /// fallback path.
    private static let qwenConfig = """
    {
        "architectures": ["Qwen2ForCausalLM"],
        "hidden_size": 3584,
        "model_type": "qwen2",
        "num_attention_heads": 28,
        "num_hidden_layers": 28,
        "num_key_value_heads": 4,
        "quantization": { "group_size": 64, "bits": 4 },
        "vocab_size": 152064
    }
    """

    /// Real config.json from mlx-community/Mixtral-8x7B-Instruct-v0.1-4bit —
    /// a MoE model, covers num_experts_per_tok/num_local_experts.
    private static let mixtralConfig = """
    {
        "architectures": ["MixtralForCausalLM"],
        "hidden_size": 4096,
        "model_type": "mixtral",
        "num_attention_heads": 32,
        "num_experts_per_tok": 2,
        "num_hidden_layers": 32,
        "num_key_value_heads": 8,
        "num_local_experts": 8,
        "quantization": { "group_size": 64, "bits": 4 }
    }
    """

    /// Real config.json from mlx-community/gemma-2-9b-it-4bit — head_dim
    /// (256) does NOT equal hidden_size/num_attention_heads (3584/16=224),
    /// so this is the case that rules out always computing it.
    private static let gemma2Config = """
    {
        "architectures": ["Gemma2ForCausalLM"],
        "head_dim": 256,
        "hidden_size": 3584,
        "model_type": "gemma2",
        "num_attention_heads": 16,
        "num_hidden_layers": 42,
        "num_key_value_heads": 8,
        "quantization": { "group_size": 64, "bits": 4 }
    }
    """

    @Test("dense model: head_dim computed from hidden_size / num_attention_heads when absent")
    func denseModelComputesHeadDim() throws {
        let url = try write(Self.qwenConfig)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MLXMetadata.read(from: url)

        #expect(metadata.modelType == "qwen2")
        #expect(metadata.hiddenLayers == 28)
        #expect(metadata.headCountKV == 4)
        #expect(metadata.headDim == 128) // 3584 / 28
        #expect(metadata.quantBits == 4)
        #expect(metadata.quantGroupSize == 64)
        #expect(metadata.numExpertsPerToken == nil)
        #expect(metadata.numLocalExperts == nil)
    }

    @Test("MoE model: num_experts_per_tok and num_local_experts are read")
    func moeModelReadsExpertFields() throws {
        let url = try write(Self.mixtralConfig)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MLXMetadata.read(from: url)

        #expect(metadata.modelType == "mixtral")
        #expect(metadata.hiddenLayers == 32)
        #expect(metadata.headCountKV == 8)
        #expect(metadata.headDim == 128) // 4096 / 32
        #expect(metadata.numExpertsPerToken == 2)
        #expect(metadata.numLocalExperts == 8)
    }

    @Test("explicit head_dim is preferred over the computed value when they differ")
    func explicitHeadDimPreferredOverComputed() throws {
        let url = try write(Self.gemma2Config)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MLXMetadata.read(from: url)

        // 3584 / 16 = 224, but the real head_dim is 256 — must not compute.
        #expect(metadata.headDim == 256)
        #expect(metadata.hiddenLayers == 42)
        #expect(metadata.headCountKV == 8)
    }

    @Test("quantization_config is used as a fallback when quantization is absent")
    func quantizationConfigFallback() throws {
        let json = """
        {
            "model_type": "llama",
            "num_hidden_layers": 32,
            "quantization_config": { "group_size": 32, "bits": 8 }
        }
        """
        let url = try write(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MLXMetadata.read(from: url)

        #expect(metadata.quantBits == 8)
        #expect(metadata.quantGroupSize == 32)
    }

    @Test("unquantized model has nil quant fields")
    func unquantizedModelHasNilQuantFields() throws {
        let json = """
        { "model_type": "llama", "num_hidden_layers": 32 }
        """
        let url = try write(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MLXMetadata.read(from: url)

        #expect(metadata.quantBits == nil)
        #expect(metadata.quantGroupSize == nil)
    }

    @Test("num_attention_heads of zero leaves head_dim nil rather than dividing by zero")
    func zeroAttentionHeadsLeavesHeadDimNil() throws {
        let json = """
        { "model_type": "llama", "num_hidden_layers": 32, "num_attention_heads": 0, "hidden_size": 4096 }
        """
        let url = try write(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MLXMetadata.read(from: url)

        #expect(metadata.headDim == nil)
    }

    @Test("hidden_size or num_attention_heads entirely missing leaves head_dim nil")
    func missingFieldsForComputedHeadDimLeaveItNil() throws {
        let json = """
        { "model_type": "llama", "num_hidden_layers": 32 }
        """
        let url = try write(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MLXMetadata.read(from: url)

        #expect(metadata.headDim == nil)
    }

    @Test("unknown extra fields are ignored rather than failing decode")
    func unknownFieldsAreIgnored() throws {
        let json = """
        {
            "model_type": "llama",
            "num_hidden_layers": 32,
            "rope_theta": 1000000.0,
            "sliding_window": null,
            "some_future_field": { "nested": true }
        }
        """
        let url = try write(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MLXMetadata.read(from: url)

        #expect(metadata.modelType == "llama")
        #expect(metadata.hiddenLayers == 32)
    }

    @Test("malformed JSON throws invalidJSON")
    func malformedJSONThrows() throws {
        let url = try write("{ not valid json")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: MLXMetadata.MLXReadError.invalidJSON) {
            try MLXMetadata.read(from: url)
        }
    }

    @Test("nonexistent file throws")
    func nonexistentFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quail-mlx-config-does-not-exist-\(UUID().uuidString).json")
        #expect(throws: (any Error).self) {
            try MLXMetadata.read(from: url)
        }
    }

    // MARK: multimodal configs (text_config)

    /// Trimmed from mlx-community/Qwen3.6-35B-A3B-4bit: the language model's settings sit under
    /// `text_config`, and the experts are `num_experts`.
    private static let qwen36Config = """
    {
        "model_type": "qwen3_5_moe",
        "quantization": { "group_size": 64, "bits": 4 },
        "text_config": {
            "hidden_size": 2048, "head_dim": 256, "num_attention_heads": 16, "num_hidden_layers": 40,
            "num_key_value_heads": 2, "num_experts": 256, "num_experts_per_tok": 8,
            "max_position_embeddings": 262144, "full_attention_interval": 4
        },
        "vision_config": { "hidden_size": 1152, "num_hidden_layers": 27 }
    }
    """

    /// Trimmed from mlx-community/gemma-4-26b-a4b-it-4bit: nested too, with `top_k_experts`.
    private static let gemma4Config = """
    {
        "model_type": "gemma4",
        "quantization": { "group_size": 64, "bits": 4 },
        "text_config": {
            "hidden_size": 2816, "head_dim": 256, "num_attention_heads": 16, "num_hidden_layers": 30,
            "num_key_value_heads": 8, "num_experts": 128, "top_k_experts": 8, "max_position_embeddings": 262144
        }
    }
    """

    @Test("a multimodal config's text_config supplies the shape, experts and trained context")
    func nestedTextConfig() throws {
        let qwen = try MLXMetadata.parse(Data(Self.qwen36Config.utf8))
        #expect(qwen.hiddenLayers == 40 && qwen.headCountKV == 2 && qwen.headDim == 256)
        #expect(qwen.numLocalExperts == 256 && qwen.numExpertsPerToken == 8)
        #expect(qwen.trainedContext == 262_144 && qwen.quantBits == 4)
        let gemma = try MLXMetadata.parse(Data(Self.gemma4Config.utf8))
        #expect(gemma.hiddenLayers == 30 && gemma.headCountKV == 8 && gemma.headDim == 256)
        #expect(gemma.numLocalExperts == 128 && gemma.numExpertsPerToken == 8)

        let shape = try #require(ModelShape.from(mlx: qwen, weightBytes: 20_000_000_000))
        #expect(shape.layerCount == 40 && shape.trainedContext == 262_144)
        #expect(shape.activeWeightBytes == Int64(625_000_000), "\(String(describing: shape.activeWeightBytes))")
    }

    @Test("a top-level value wins over the nested one; a flat config reads its trained context")
    func topLevelWins() throws {
        let both = try MLXMetadata
            .parse(
                Data(
                    #"{"num_hidden_layers": 12, "text_config": {"num_hidden_layers": 40, "num_key_value_heads": 4, "head_dim": 64}}"#
                        .utf8
                )
            )
        #expect(both.hiddenLayers == 12 && both.headCountKV == 4)
        let flat = try MLXMetadata
            .parse(
                Data(
                    #"{"num_hidden_layers": 36, "num_key_value_heads": 8, "head_dim": 128, "max_position_embeddings": 40960, "num_experts": 128, "num_experts_per_tok": 8}"#
                        .utf8
                )
            )
        #expect(flat.trainedContext == 40960 && flat.numLocalExperts == 128)
    }

    /// Every MLX repo in the bundled catalog, read from Hugging Face, yields a shape. Network, so only when
    /// `QUAIL_TEST_NETWORK` is set.
    @Test(
        "every catalog MLX config gives a fit shape",
        .enabled(if: ProcessInfo.processInfo.environment["QUAIL_TEST_NETWORK"] != nil)
    )
    func catalogConfigs() async throws {
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Quail/Resources/catalog.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
        let repos = ((json?["families"] as? [[String: Any]]) ?? []).compactMap {
            (($0["variants"] as? [String: Any])?["mlx"] as? [String: Any])?["repo"] as? String
        }
        #expect(repos.count >= 10)
        for repo in repos {
            let (data, _) = try await URLSession.shared
                .data(from: #require(URL(string: "https://huggingface.co/\(repo)/resolve/main/config.json")))
            let metadata = try MLXMetadata.parse(data)
            let shape = ModelShape.from(mlx: metadata, weightBytes: 1)
            #expect(shape != nil, "\(repo)")
            #expect(metadata.trainedContext != nil, "\(repo) has no trained context")
        }
    }
}
