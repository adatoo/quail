import Foundation

enum ChatEvent: Equatable, Sendable {
    case delta(ChatDelta)
    case finished(FinishReason, GenerationTimings)
}

enum ChatStream {
    /// The generated text, with reasoning separated from the answer.
    static func events(
        from text: AsyncThrowingStream<TextEvent, any Error>,
        startsInReasoning: Bool
    ) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = ReasoningSplitter(startsInReasoning: startsInReasoning)
                do {
                    for try await event in text {
                        switch event {
                        case let .text(piece):
                            for delta in splitter.push(piece) {
                                continuation.yield(.delta(delta))
                            }
                        case let .finished(reason, timings):
                            for delta in splitter.flush() {
                                continuation.yield(.delta(delta))
                            }
                            continuation.yield(.finished(reason, timings))
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
