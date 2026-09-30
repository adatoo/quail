import Foundation

/// What the routes consume: the engine's tokens turned into text, with stop strings applied.
enum TextEvent: Equatable, Sendable {
    case text(String)
    case finished(FinishReason, GenerationTimings)
}

enum TextGenerator {
    /// Streams an engine's output as text. Ending consumption — the client went away, or a stop
    /// string matched — stops the engine.
    ///
    /// `activity`, if given, follows the request from here to its end (`GET /slots`) and is ended with the stream.
    /// `interrupter`, if given, can stop it: the stream then ends with a 503 saying why (ADR D-068).
    static func stream(
        engine: any Engine,
        request: GenerationRequest,
        stop: [String],
        activity: ActivityTicket? = nil,
        interrupter: RequestInterrupter? = nil
    ) -> AsyncThrowingStream<TextEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                defer { activity?.end() }
                activity?.accepted(promptTokens: request.promptTokens.count)
                var matcher = StopMatcher(stop)
                let started = ContinuousClock.now
                var firstToken: Duration?
                var generated = 0
                do {
                    for try await event in engine.generate(request) {
                        switch event {
                        case let .promptProgress(done, total, cached):
                            activity?.promptProgress(done: done, total: total, cached: cached)
                        case let .token(_, piece):
                            activity?.token()
                            if firstToken == nil {
                                firstToken = started.duration(to: .now)
                            }
                            generated += 1
                            let (emit, stopped) = matcher.push(piece)
                            if !emit.isEmpty {
                                continuation.yield(.text(emit))
                            }
                            if stopped {
                                // The engine never gets to say how long it took, so time it here:
                                // the wait for the first token is the prompt, the rest is generation.
                                let total = started.duration(to: .now)
                                let prompt = firstToken ?? total
                                continuation.yield(.finished(.stop, GenerationTimings(
                                    promptTokens: request.promptTokens.count,
                                    promptSeconds: prompt.seconds,
                                    generatedTokens: generated,
                                    generatedSeconds: max(0, (total - prompt).seconds)
                                )))
                                continuation.finish()
                                return
                            }
                        case let .finished(reason, timings):
                            let rest = matcher.flush()
                            if !rest.isEmpty {
                                continuation.yield(.text(rest))
                            }
                            continuation.yield(.finished(reason, timings))
                            continuation.finish()
                            return
                        }
                    }
                    // The engine ended without saying why; treat it as a stop.
                    let rest = matcher.flush()
                    if !rest.isEmpty {
                        continuation.yield(.text(rest))
                    }
                    continuation.yield(.finished(.stop, GenerationTimings(
                        promptTokens: request.promptTokens.count, promptSeconds: 0,
                        generatedTokens: generated, generatedSeconds: 0
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // The error goes out before the cancellation, so the reader sees why rather than a cancellation.
            let token = interrupter?.register { reason in
                continuation.finish(throwing: RequestError(
                    status: 503, type: "unavailable_error", message: "Stopped: \(reason)."
                ))
                task.cancel()
            }
            continuation.onTermination = { _ in
                task.cancel()
                activity?.end()
                if let token {
                    interrupter?.remove(token)
                }
            }
        }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
