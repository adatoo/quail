import Foundation
@testable import QuailServerCore

/// What a `ScriptedEngine` saw, readable from the test after the fact.
final class ScriptedWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [GenerationRequest] = []
    private var _cancelled = 0
    private var _tokenizations: [(text: String, addSpecial: Bool, parseSpecial: Bool)] = []

    var requests: [GenerationRequest] {
        lock.withLock { _requests }
    }

    var cancelled: Int {
        lock.withLock { _cancelled }
    }

    var tokenizations: [(text: String, addSpecial: Bool, parseSpecial: Bool)] {
        lock.withLock { _tokenizations }
    }

    func record(_ request: GenerationRequest) {
        lock.withLock { _requests.append(request) }
    }

    func recordCancel() {
        lock.withLock { _cancelled += 1 }
    }

    func record(tokenize text: String, addSpecial: Bool, parseSpecial: Bool) {
        lock.withLock { _tokenizations.append((text, addSpecial, parseSpecial)) }
    }
}

/// An engine that says what it's told to: one token per scripted piece, then a finish. Bytes are
/// tokens, so a test can predict tokenization. `endless` repeats the pieces until cancelled.
struct ScriptedEngine: Engine {
    var world: ScriptedWorld
    var pieces: [String] = ["Hello", ",", " world"]
    var endless = false
    var contextSize = 4096
    var template: String?
    var bos = "<s>"
    var eos = "</s>"
    var failFirstToken: String?
    var promptSeconds = 0.5
    var generatedSeconds = 0.25
    var cachedTokens = 0
    /// Time spent "processing the prompt" before the first token; a cancelled request cuts it short.
    var firstTokenDelay: Duration = .zero

    func load(_: ModelEntry) async throws {}
    func unload() async {}

    func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) async throws -> [Int] {
        world.record(tokenize: text, addSpecial: addSpecial, parseSpecial: parseSpecial)
        return text.utf8.map(Int.init)
    }

    func detokenize(_ tokens: [Int]) async throws -> String {
        String(decoding: tokens.map { UInt8(truncatingIfNeeded: $0) }, as: UTF8.self)
    }

    func info() async -> EngineInfo {
        EngineInfo(contextSize: contextSize, bosToken: bos, eosToken: eos)
    }

    func chatTemplate() async -> String? {
        template
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        world.record(request)
        let script = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let message = script.failFirstToken {
                    continuation.finish(throwing: EngineError.loadFailed(message))
                    return
                }
                if script.firstTokenDelay > .zero {
                    try? await Task.sleep(for: script.firstTokenDelay)
                    if Task.isCancelled {
                        return
                    }
                }
                var produced = 0
                var index = 0
                while !Task.isCancelled {
                    if produced >= request.maxTokens {
                        break
                    }
                    if index >= script.pieces.count {
                        if !script.endless {
                            break
                        }
                        index = 0
                    }
                    continuation.yield(.token(id: produced, text: script.pieces[index]))
                    produced += 1
                    index += 1
                    try? await Task.sleep(for: .milliseconds(1))
                }
                if Task.isCancelled {
                    return
                }
                let reason: FinishReason = produced >= request.maxTokens ? .length : .stop
                continuation.yield(.finished(reason, GenerationTimings(
                    promptTokens: request.promptTokens.count - script.cachedTokens,
                    promptSeconds: script.promptSeconds,
                    generatedTokens: produced,
                    generatedSeconds: script.generatedSeconds,
                    cachedTokens: script.cachedTokens
                )))
                continuation.finish()
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    world.recordCancel()
                }
                task.cancel()
            }
        }
    }
}
