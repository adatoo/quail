import Foundation

/// Parses an OpenAI-style `/v1/chat/completions` SSE stream line by line:
/// content deltas, and llama-server's own `timings` (prompt/generation
/// speed) on the final chunk. Shared by `quail chat`; pure, so it's tested
/// without a server.
struct ChatStreamParser: Sendable {
    enum Event: Sendable, Equatable {
        case delta(String)
        /// A reasoning model's thinking (llama-server's `reasoning_content`).
        case reasoning(String)
        case timings(promptPerSecond: Double?, predictedPerSecond: Double?, predictedTokens: Int?)
        case done
    }

    /// Events carried by one SSE line (`data: {...}`); other lines yield none.
    static func events(fromLine line: String) -> [Event] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return [.done]
        }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var events: [Event] = []
        if let choices = object["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any]
        {
            if let thinking = delta["reasoning_content"] as? String, !thinking.isEmpty {
                events.append(.reasoning(thinking))
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(.delta(content))
            }
        }
        if let timings = object["timings"] as? [String: Any] {
            events.append(.timings(
                promptPerSecond: timings["prompt_per_second"] as? Double,
                predictedPerSecond: timings["predicted_per_second"] as? Double,
                predictedTokens: timings["predicted_n"] as? Int
            ))
        }
        return events
    }
}
