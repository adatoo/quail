import Foundation

/// llama-server's response shapes for generation routes.
enum InferenceJSON {
    static func timings(_ timings: GenerationTimings) -> Timings {
        Timings(timings)
    }

    struct Timings: Encodable {
        let cacheN: Int
        let promptN: Int
        let promptMs: Double
        let promptPerTokenMs: Double
        let promptPerSecond: Double
        let predictedN: Int
        let predictedMs: Double
        let predictedPerTokenMs: Double
        let predictedPerSecond: Double

        enum CodingKeys: String, CodingKey {
            case cacheN = "cache_n"
            case promptN = "prompt_n"
            case promptMs = "prompt_ms"
            case promptPerTokenMs = "prompt_per_token_ms"
            case promptPerSecond = "prompt_per_second"
            case predictedN = "predicted_n"
            case predictedMs = "predicted_ms"
            case predictedPerTokenMs = "predicted_per_token_ms"
            case predictedPerSecond = "predicted_per_second"
        }

        init(_ timings: GenerationTimings) {
            cacheN = timings.cachedTokens
            promptN = timings.promptTokens
            promptMs = timings.promptSeconds * 1000
            promptPerTokenMs = timings.promptTokens > 0 ? promptMs / Double(timings.promptTokens) : 0
            promptPerSecond = timings.promptTokensPerSecond
            predictedN = timings.generatedTokens
            predictedMs = timings.generatedSeconds * 1000
            predictedPerTokenMs = timings.generatedTokens > 0 ? predictedMs / Double(timings.generatedTokens) : 0
            predictedPerSecond = timings.generatedTokensPerSecond
        }
    }

    struct Usage: Encodable {
        struct Details: Encodable {
            let cachedTokens: Int

            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }
        }

        let completionTokens: Int
        let promptTokens: Int
        let totalTokens: Int
        let promptTokensDetails: Details

        enum CodingKeys: String, CodingKey {
            case completionTokens = "completion_tokens"
            case promptTokens = "prompt_tokens"
            case totalTokens = "total_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }

        init(_ timings: GenerationTimings) {
            completionTokens = timings.generatedTokens
            // Everything the model read, including what came from the cache.
            promptTokens = timings.promptTokens + timings.cachedTokens
            totalTokens = promptTokens + completionTokens
            promptTokensDetails = Details(cachedTokens: timings.cachedTokens)
        }
    }

    /// A `/v1/completions` response or stream chunk (`object` is `text_completion` for both).
    struct Completion: Encodable {
        struct Choice: Encodable {
            let text: String
            let index = 0
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case text, index, logprobs
                case finishReason = "finish_reason"
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(text, forKey: .text)
                try container.encode(index, forKey: .index)
                try container.encodeNil(forKey: .logprobs)
                try container.encode(finishReason, forKey: .finishReason)
            }
        }

        let choices: [Choice]
        let created: Int
        let model: String
        let systemFingerprint: String
        let object = "text_completion"
        let id: String
        var usage: Usage?
        var timings: Timings?

        enum CodingKeys: String, CodingKey {
            case choices, created, model, object, id, usage, timings
            case systemFingerprint = "system_fingerprint"
        }
    }

    static func finishReason(_ reason: FinishReason) -> String {
        reason.rawValue
    }

    /// `chatcmpl-` plus 32 letters and digits, like llama-server's ids.
    static func newID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return "chatcmpl-" + String((0 ..< 32).map { _ in alphabet.randomElement()! })
    }

    static func sse(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let json = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    /// An error after the stream has begun can't change the status line, so it travels as an event.
    static func sseError(message: String, type: String, code: Int) -> Data {
        struct Failure: Encodable {
            struct Detail: Encodable {
                let message: String
                let type: String
                let code: Int
            }

            let error: Detail
        }
        return sse(Failure(error: .init(message: message, type: type, code: code)))
    }

    static let done = Data("data: [DONE]\n\n".utf8)
}
