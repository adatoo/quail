import Foundation

enum ChatEvent: Equatable, Sendable {
    case delta(ChatDelta)
    case finished(FinishReason, GenerationTimings)
}

enum ChatStream {
    /// The generated text, with reasoning and tool calls separated from the answer.
    static func events(
        from text: AsyncThrowingStream<TextEvent, any Error>,
        parser: ChatOutputParser
    ) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = parser
                var calledTools = false
                func send(_ deltas: [ChatDelta]) {
                    for delta in deltas {
                        if case .toolCall = delta {
                            calledTools = true
                        }
                        continuation.yield(.delta(delta))
                    }
                }
                do {
                    for try await event in text {
                        switch event {
                        case let .text(piece):
                            send(parser.push(piece))
                        case let .finished(reason, timings):
                            send(parser.flush())
                            // A reply that ends with a tool call is finished "tool_calls".
                            continuation.yield(.finished(reason == .stop && calledTools ? .toolCalls : reason, timings))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
