import Foundation

/// Images for MLX models (ADR D-047 amendment): which MLX architectures Quail can show an image, how an
/// image's place is written in their prompts, and how one placeholder becomes the image's share of
/// tokens. Kept here, beside the discovery that uses it, so it can be tested without MLX.
public enum MLXVision {
    /// The architectures whose vision half Quail loads (through mlx-swift-lm's `VLMModelFactory`) and
    /// whose image processor it drives, each with its own way of writing an image into the prompt.
    public enum Family: Sendable, Equatable {
        /// Qwen3.5, 3.6 and 3.8 (and fine-tunes such as MiMo 9B): a pad token per merged patch.
        case qwen35
        /// Gemma 4 26B-A4B and 31B: a fixed run of soft tokens between begin- and end-of-image.
        /// (Gemma 4 12B is `gemma4_unified`, which mlx-swift-lm doesn't load with its vision half.)
        case gemma4
        /// Muse Glimmer 30B: begin-of-image, a patch token per merged patch, end-of-image. mlx-swift-lm has only its
        /// vision model, so it's always loaded that way.
        case museGlimmer

        public init?(modelType: String) {
            switch modelType {
            case "qwen3_5", "qwen3_5_moe": self = .qwen35
            case "gemma4": self = .gemma4
            case "muse_glimmer": self = .museGlimmer
            default: return nil
            }
        }

        /// Where an image goes in the prompt: the chat template's own placeholder.
        public var placeholder: String {
            switch self {
            case .qwen35: "<|vision_start|><|image_pad|><|vision_end|>"
            case .gemma4: "<|image|>"
            case .museGlimmer: "<|patch|>"
            }
        }

        /// The one token of `placeholder` that becomes the image's run of tokens.
        public var imageToken: String {
            switch self {
            case .qwen35: "<|image_pad|>"
            case .gemma4: "<|image|>"
            case .museGlimmer: "<|patch|>"
            }
        }
    }

    public static var supportedModelTypes: Set<String> {
        ["qwen3_5", "qwen3_5_moe", "gemma4", "muse_glimmer"]
    }

    /// Whether the MLX model in `directory` can read images in Quail: its `config.json` has a
    /// `vision_config`, its `model_type` is supported, and its processor settings are there.
    public static func supports(directory: URL) -> Bool {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              config["vision_config"] != nil,
              let type = config["model_type"] as? String, Family(modelType: type) != nil
        else { return false }
        return ["preprocessor_config.json", "processor_config.json"].contains {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Replaces the `index`th `padID` in `tokens` with `counts[index]` copies of it: each image's pad
    /// token stands for as many positions as its patches after merging (Qwen3.5 family).
    public static func expand(_ tokens: [Int], padID: Int, counts: [Int]) throws -> [Int] {
        try expand(tokens, marker: padID, replacements: counts.map { Array(repeating: padID, count: max(1, $0)) })
    }

    /// Replaces the `index`th `marker` in `tokens` with `replacements[index]`. Throws when the prompt's
    /// placeholders and the images don't pair up.
    public static func expand(_ tokens: [Int], marker: Int, replacements: [[Int]]) throws -> [Int] {
        let counts = replacements
        let found = tokens.count(where: { $0 == marker })
        guard found == counts.count else {
            throw EngineError.invalidRequest(
                "the prompt has \(found) image placeholder(s) for \(counts.count) image(s)"
            )
        }
        var result: [Int] = []
        result.reserveCapacity(tokens.count + replacements.reduce(0) { $0 + $1.count })
        var next = 0
        for token in tokens {
            if token == marker {
                result.append(contentsOf: replacements[next])
                next += 1
            } else {
                result.append(token)
            }
        }
        return result
    }
}
