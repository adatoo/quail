import Foundation

#if DEBUG
    /// A deterministic engine with no model behind it, for tests and for
    /// smoke-testing the server end to end (`quail-server --engine echo`).
    /// "Tokens" are UTF-8 bytes; generation replays the prompt, so a client sees
    /// its own words come back. Debug builds only.
    actor EchoEngine: Engine {
        private var loaded = false
        private let template: String?

        init(chatTemplate: String? = nil) {
            template = chatTemplate
        }

        func load(_: ModelEntry) async throws {
            loaded = true
        }

        func unload() async {
            loaded = false
        }

        func tokenize(_ text: String, addSpecial _: Bool, parseSpecial _: Bool) async throws -> [Int] {
            guard loaded else { throw EngineError.notLoaded }
            return text.utf8.map(Int.init)
        }

        func detokenize(_ tokens: [Int]) async throws -> String {
            guard loaded else { throw EngineError.notLoaded }
            return String(decoding: tokens.map { UInt8(truncatingIfNeeded: $0) }, as: UTF8.self)
        }

        func info() async -> EngineInfo {
            EngineInfo(contextSize: 4096, bosToken: "", eosToken: "")
        }

        func chatTemplate() async -> String? {
            template
        }

        nonisolated func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    let started = ContinuousClock.now
                    var produced = 0
                    for token in request.promptTokens.prefix(request.maxTokens) {
                        if Task.isCancelled {
                            break
                        }
                        let byte = UInt8(truncatingIfNeeded: token)
                        continuation.yield(.token(id: token, text: String(decoding: [byte], as: UTF8.self)))
                        produced += 1
                    }
                    let elapsed = started.duration(to: .now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    let reason: FinishReason = produced >= request.maxTokens ? .length : .stop
                    continuation.yield(.finished(reason, GenerationTimings(
                        promptTokens: request.promptTokens.count,
                        promptSeconds: 0,
                        generatedTokens: produced,
                        generatedSeconds: seconds
                    )))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
#endif
