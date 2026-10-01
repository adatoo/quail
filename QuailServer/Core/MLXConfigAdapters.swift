import Foundation

/// Rewrites of an MLX checkpoint's `config.json` for keys a newer checkpoint names differently from what
/// the pinned mlx-swift-lm reads, so the library's own model class still loads it. Kept here, apart from
/// MLX, so it can be tested without it.
public enum MLXConfigAdapters {
    /// Nemotron-H (`model_type: nemotron_h`): Nemotron 3 Nano writes its layer layout as
    /// `hybrid_override_pattern`, one character a layer ("MEM*E…"); Nemotron 3.5 writes only
    /// `layers_block_type`, a word a layer ("mamba", "moe", "attention"), and mlx-swift-lm 0dcfe2f8a's
    /// `NemotronHConfiguration` refuses a config without the pattern. This adds the pattern from the words,
    /// with mlx-lm's own mapping (ml-explore/mlx-lm#1857), and leaves a config that has one unchanged.
    ///
    /// Returns `data` unchanged when there's nothing to add; throws on a layer type the mapping doesn't know,
    /// rather than guess at a layout. The keys are spliced in after the opening brace rather than the object
    /// re-serialized: these configs are JSON5 as mlx-swift-lm reads them, and Nemotron 3 Nano's has an
    /// `Infinity` that `JSONSerialization` can read but not write.
    public static func nemotronH(_ data: Data) throws -> Data {
        guard let config = (try? JSONSerialization.jsonObject(with: data, options: .json5Allowed)) as? [String: Any],
              config["hybrid_override_pattern"] == nil,
              let types = (config["layers_block_type"] ?? config["layer_types"]) as? [String],
              let brace = data.firstIndex(of: UInt8(ascii: "{"))
        else { return data }
        let pattern = try hybridPattern(types)
        var added = ["\"hybrid_override_pattern\": \"\(pattern)\""]
        // transformers leaves the layer count out when the list gives it.
        if config["num_hidden_layers"] == nil {
            added.append("\"num_hidden_layers\": \(types.count)")
        }
        var adapted = data
        adapted.insert(contentsOf: Data((added.joined(separator: ", ") + ", ").utf8), at: brace + 1)
        return adapted
    }

    /// `["mamba", "moe", "attention", "mlp"]` → `"ME*-"`.
    static func hybridPattern(_ layerTypes: [String]) throws -> String {
        try String(layerTypes.map { type -> Character in
            switch type {
            case "mamba", "linear_attention", "conv": "M"
            case "moe": "E"
            case "attention", "full_attention": "*"
            case "mlp": "-"
            default: throw UnknownLayerType(type: type)
            }
        })
    }

    struct UnknownLayerType: Error, CustomStringConvertible {
        let type: String
        var description: String {
            "Nemotron-H layer type \"\(type)\" isn't one Quail knows (mamba, conv, moe, attention, mlp)"
        }
    }
}
