import Foundation

/// Just enough of an MLX model directory's `config.json` (a HuggingFace
/// `transformers`-style config, as `mlx-lm`'s converter writes it) to
/// feed the device-fit formula in docs/ARCHITECTURE.md §7 ("What Quail
/// reads from the model"): layer count, KV head count, head dimension,
/// quantization bits, and the two fields that matter for MoE models.
///
/// A real `config.json` carries many more fields (rope settings, norm
/// eps, tokenizer info, ...); everything not listed above is ignored.
struct MLXMetadata: Sendable, Equatable {
    var modelType: String?
    var hiddenLayers: Int?
    var headCountKV: Int?
    /// Per-head attention dimension. Prefer the explicit `head_dim` key
    /// when present — some architectures (Gemma 2, for one: hidden_size
    /// 3584 over 16 heads is 224, but its real head_dim is 256) don't
    /// divide evenly, so `hidden_size / num_attention_heads` is only a
    /// fallback for configs that omit `head_dim` outright.
    var headDim: Int?
    var quantBits: Int?
    var quantGroupSize: Int?
    /// MoE routing: how many experts each token is sent to.
    var numExpertsPerToken: Int?
    /// MoE routing: how many experts exist to route between.
    var numLocalExperts: Int?
    /// The context the model was trained for (`max_position_embeddings`).
    var trainedContext: Int?
    /// Which layers keep a cache of past tokens, and how big, when they aren't all alike (`AttentionLayout`).
    var layout = AttentionLayout()

    /// The fields that say how a model's layers differ: sliding-window layers beside global ones (Gemma, gpt-oss,
    /// Muse Glimmer), and linear-attention or Mamba layers that keep a fixed-size state rather than a cache that
    /// grows with the context (Qwen3.5 family, Nemotron H). All empty for a model whose layers are all alike.
    struct AttentionLayout: Sendable, Equatable, Decodable {
        /// Per layer: `full_attention`, `sliding_attention`, `linear_attention`, …
        var layerTypes: [String]?
        var slidingWindow: Int?
        /// Gemma 3's older spelling: every Nth layer is global, the rest sliding-window.
        var slidingWindowPattern: Int?
        /// Gemma 4's global layers: fewer KV heads, each larger, than its sliding-window layers.
        var globalHeadCountKV: Int?
        var globalHeadDim: Int?
        /// Qwen3.5 family: every Nth layer is attention, the rest linear attention.
        var fullAttentionInterval: Int?
        /// Nemotron H: per layer, `attention`, `mamba`, `mlp` or `moe`.
        var layersBlockType: [String]?
        /// Nemotron H's other spelling: one character per layer, `*` for attention.
        var hybridOverridePattern: String?
        /// Gemma 3n and 4's small models: the last layers reuse an earlier layer's cache.
        var sharedKVLayers: Int?

        enum CodingKeys: String, CodingKey {
            case layerTypes = "layer_types"
            case slidingWindow = "sliding_window"
            case slidingWindowPattern = "sliding_window_pattern"
            case globalHeadCountKV = "num_global_key_value_heads"
            case globalHeadDim = "global_head_dim"
            case fullAttentionInterval = "full_attention_interval"
            case layersBlockType = "layers_block_type"
            case hybridOverridePattern = "hybrid_override_pattern"
            case sharedKVLayers = "num_kv_shared_layers"
        }

        init() {}

        /// Lenient: a field of an unexpected type (a pattern written as a list, say) is left out, not an error.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            layerTypes = try? container.decodeIfPresent([String].self, forKey: .layerTypes)
            slidingWindow = try? container.decodeIfPresent(Int.self, forKey: .slidingWindow)
            slidingWindowPattern = try? container.decodeIfPresent(Int.self, forKey: .slidingWindowPattern)
            globalHeadCountKV = try? container.decodeIfPresent(Int.self, forKey: .globalHeadCountKV)
            globalHeadDim = try? container.decodeIfPresent(Int.self, forKey: .globalHeadDim)
            fullAttentionInterval = try? container.decodeIfPresent(Int.self, forKey: .fullAttentionInterval)
            layersBlockType = try? container.decodeIfPresent([String].self, forKey: .layersBlockType)
            hybridOverridePattern = try? container.decodeIfPresent(String.self, forKey: .hybridOverridePattern)
            sharedKVLayers = try? container.decodeIfPresent(Int.self, forKey: .sharedKVLayers)
        }

        /// Each field from this one, else from `fallback` (a multimodal config's `text_config`).
        func filled(from fallback: AttentionLayout) -> AttentionLayout {
            var result = self
            result.layerTypes = layerTypes ?? fallback.layerTypes
            result.slidingWindow = slidingWindow ?? fallback.slidingWindow
            result.slidingWindowPattern = slidingWindowPattern ?? fallback.slidingWindowPattern
            result.globalHeadCountKV = globalHeadCountKV ?? fallback.globalHeadCountKV
            result.globalHeadDim = globalHeadDim ?? fallback.globalHeadDim
            result.fullAttentionInterval = fullAttentionInterval ?? fallback.fullAttentionInterval
            result.layersBlockType = layersBlockType ?? fallback.layersBlockType
            result.hybridOverridePattern = hybridOverridePattern ?? fallback.hybridOverridePattern
            result.sharedKVLayers = sharedKVLayers ?? fallback.sharedKVLayers
            return result
        }
    }

    private struct LayoutConfig: Decodable {
        var top: AttentionLayout
        var text: AttentionLayout?

        enum CodingKeys: String, CodingKey {
            case textConfig = "text_config"
        }

        init(from decoder: any Decoder) throws {
            top = try AttentionLayout(from: decoder)
            text = try? decoder.container(keyedBy: CodingKeys.self)
                .decodeIfPresent(AttentionLayout.self, forKey: .textConfig)
        }
    }

    enum MLXReadError: Error, Equatable {
        case invalidJSON
    }

    /// The raw shape of an MLX `config.json`. Every field is optional —
    /// architectures vary in what they include, and this parser is only
    /// as strict as it needs to be for the fields above.
    private struct RawConfig: Decodable {
        var modelType: String?
        var hiddenSize: Int?
        var numAttentionHeads: Int?
        var numHiddenLayers: Int?
        var numKeyValueHeads: Int?
        var headDim: Int?
        var numExpertsPerTok: Int?
        var numLocalExperts: Int?
        /// Other names architectures use for the expert counts (Qwen3 MoE, Qwen3.5+, Gemma 4, gpt-oss).
        var numExperts: Int?
        var topKExperts: Int?
        var expertsPerToken: Int?
        var maxPositionEmbeddings: Int?
        /// Multimodal architectures (Qwen3.5+, Gemma 4) keep the language model's settings here, not at the top.
        var textConfig: TextConfig?
        var quantization: Quantization?
        /// Some repos (following a later `transformers` convention) write
        /// `quantization_config` instead of `quantization`. Preferring
        /// `quantization`, since that's what `mlx-lm`'s own converter
        /// writes, matches what every real MLX repo checked while
        /// building this parser actually had.
        var quantizationConfig: Quantization?

        struct Quantization: Decodable {
            var bits: Int?
            var groupSize: Int?

            enum CodingKeys: String, CodingKey {
                case bits
                case groupSize = "group_size"
            }
        }

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case hiddenSize = "hidden_size"
            case numAttentionHeads = "num_attention_heads"
            case numHiddenLayers = "num_hidden_layers"
            case numKeyValueHeads = "num_key_value_heads"
            case headDim = "head_dim"
            case numExpertsPerTok = "num_experts_per_tok"
            case numLocalExperts = "num_local_experts"
            case numExperts = "num_experts"
            case topKExperts = "top_k_experts"
            case expertsPerToken = "experts_per_token"
            case maxPositionEmbeddings = "max_position_embeddings"
            case textConfig = "text_config"
            case quantization
            case quantizationConfig = "quantization_config"
        }
    }

    private struct TextConfig: Decodable {
        var hiddenSize: Int?
        var numAttentionHeads: Int?
        var numHiddenLayers: Int?
        var numKeyValueHeads: Int?
        var headDim: Int?
        var numExpertsPerTok: Int?
        var numLocalExperts: Int?
        var numExperts: Int?
        var topKExperts: Int?
        var expertsPerToken: Int?
        var maxPositionEmbeddings: Int?

        enum CodingKeys: String, CodingKey {
            case hiddenSize = "hidden_size"
            case numAttentionHeads = "num_attention_heads"
            case numHiddenLayers = "num_hidden_layers"
            case numKeyValueHeads = "num_key_value_heads"
            case headDim = "head_dim"
            case numExpertsPerTok = "num_experts_per_tok"
            case numLocalExperts = "num_local_experts"
            case numExperts = "num_experts"
            case topKExperts = "top_k_experts"
            case expertsPerToken = "experts_per_token"
            case maxPositionEmbeddings = "max_position_embeddings"
        }
    }

    /// Reads and parses an MLX model directory's `config.json`.
    /// `configURL` should point at the file itself (typically
    /// `<model directory>/config.json`).
    static func read(from configURL: URL) throws -> MLXMetadata {
        try parse(Data(contentsOf: configURL))
    }

    /// The same parse over an in-memory copy — for the pre-download
    /// verdict path, where a `config.json` (always a few KB) arrives via
    /// `HFDownloader.fetchHeader` rather than from disk.
    static func parse(_ data: Data) throws -> MLXMetadata {
        let raw: RawConfig
        do {
            raw = try JSONDecoder().decode(RawConfig.self, from: data)
        } catch {
            throw MLXReadError.invalidJSON
        }

        // Top-level values first; a multimodal config's `text_config` fills in what the top level lacks.
        let text = raw.textConfig
        var result = MLXMetadata()
        result.modelType = raw.modelType
        result.hiddenLayers = raw.numHiddenLayers ?? text?.numHiddenLayers
        result.headCountKV = raw.numKeyValueHeads ?? text?.numKeyValueHeads
        result.numExpertsPerToken = raw.numExpertsPerTok ?? raw.topKExperts ?? raw.expertsPerToken
            ?? text?.numExpertsPerTok ?? text?.topKExperts ?? text?.expertsPerToken
        result.numLocalExperts = raw.numLocalExperts ?? raw.numExperts ?? text?.numLocalExperts ?? text?.numExperts
        result.trainedContext = raw.maxPositionEmbeddings ?? text?.maxPositionEmbeddings

        let hiddenSize = raw.hiddenSize ?? text?.hiddenSize
        let heads = raw.numAttentionHeads ?? text?.numAttentionHeads
        if let headDim = raw.headDim ?? text?.headDim {
            result.headDim = headDim
        } else if let hiddenSize, let heads, heads > 0 {
            result.headDim = hiddenSize / heads
        }

        if let layout = try? JSONDecoder().decode(LayoutConfig.self, from: data) {
            result.layout = layout.top.filled(from: layout.text ?? AttentionLayout())
        }

        let quantization = raw.quantization ?? raw.quantizationConfig
        result.quantBits = quantization?.bits
        result.quantGroupSize = quantization?.groupSize

        return result
    }
}
