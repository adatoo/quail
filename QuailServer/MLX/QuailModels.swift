import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Quail's own copies of mlx-swift-lm model files (`Models/`, ADR D-066), put in front of the library's models for the
/// `model_type`s they cover.
enum QuailModels {
    static func register() async {
        await LLMTypeRegistry.shared.registerModelType("gemma4") { data in
            // A vision checkpoint's language model is its `text_config`.
            struct Wrapped: Decodable {
                let textConfig: MLXVLM.Gemma4TextConfiguration

                enum CodingKeys: String, CodingKey {
                    case textConfig = "text_config"
                }
            }
            let decoder = JSONDecoder()
            let config = try (try? decoder.decode(Wrapped.self, from: data))?.textConfig
                ?? decoder.decode(MLXVLM.Gemma4TextConfiguration.self, from: data)
            return QGemma4Model(config)
        }
        await LLMTypeRegistry.shared.registerModelType("qwen3_5") { data in
            try QQwen35Model(JSONDecoder().decode(QQwen35Configuration.self, from: data))
        }
        await LLMTypeRegistry.shared.registerModelType("qwen3_5_moe") { data in
            try QQwen35MoEModel(JSONDecoder().decode(QQwen35Configuration.self, from: data))
        }
        await LLMTypeRegistry.shared.registerModelType("qwen3_5_text") { data in
            try QQwen35TextModel(JSONDecoder().decode(QQwen35TextConfiguration.self, from: data))
        }
    }
}
