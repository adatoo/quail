import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import QuailServerCore

/// A small model of the same family that drafts tokens for a larger one to check (ADR D-055, Phase 3c: draft-model
/// speculation), named by a model's `model-draft` preset. It drafts greedily from its own cache, which it keeps
/// between requests and cuts back to whatever the next text shares with it, so it acts as its own prompt cache.
///
/// Used only inside the target model's serial access, so nothing here is shared between threads at once.
final class DraftModel: @unchecked Sendable {
    private let model: any LanguageModel
    private var cache: [any KVCache]
    /// The tokens `cache` holds.
    private var fed: [Int] = []
    private let step: Int

    private init(model: any LanguageModel, cache: [any KVCache], step: Int) {
        self.model = model
        self.cache = cache
        self.step = step
    }

    /// The model at `path`, if it loads, its cache can be cut back (no recurrent or sliding-window layers), and
    /// its tokenizer splits text as the target's does; nil otherwise, with the reason on standard error (the
    /// server's log), since the target runs fine without it.
    static func load(from path: URL, matching tokenizer: any MLXLMCommon.Tokenizer) async -> DraftModel? {
        func skip(_ reason: String) -> DraftModel? {
            FileHandle.standardError.write(Data("draft model \(path.lastPathComponent) not used: \(reason)\n".utf8))
            return nil
        }
        let directory = path.resolvingSymlinksInPath()
        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TokenizerBridgeLoader())
        } catch {
            return skip(error.localizedDescription)
        }
        let sample = "The lighthouse keeper wrote `let x = 42` in the log, 1905-07-12 — 灯台守."
        let draftTokenizer = await container.tokenizer
        guard draftTokenizer.encode(text: sample, addSpecialTokens: false)
            == tokenizer.encode(text: sample, addSpecialTokens: false)
        else { return skip("its tokenizer isn't the target's") }
        let loaded = await container.perform { context in
            UncheckedModel(model: context.model, cache: context.model.newCache(parameters: nil))
        }
        guard loaded.cache.allSatisfy({ $0.isTrimmable && $0.maxSize == nil }) else {
            return skip("its cache can't be cut back")
        }
        return DraftModel(model: loaded.model, cache: loaded.cache, step: 512)
    }

    private struct UncheckedModel: @unchecked Sendable {
        let model: any LanguageModel
        let cache: [any KVCache]
    }

    /// Up to `count` tokens the draft model expects after `history`, drafted greedily.
    func propose(after history: [Int], count: Int) -> [Int] {
        guard count > 0, !history.isEmpty else { return [] }
        // Keep what the cache shares with this text; feed the rest.
        var common = 0
        let limit = min(fed.count, history.count - 1)
        while common < limit, fed[common] == history[common] {
            common += 1
        }
        if common < fed.count {
            for layer in cache {
                layer.trim(fed.count - common)
            }
            fed.removeLast(fed.count - common)
        }
        var missing = Array(history[common...])
        while missing.count > step {
            _ = model(tokens(Array(missing.prefix(step))), cache: cache, state: nil)
            eval(cache)
            fed += missing.prefix(step)
            missing.removeFirst(step)
        }
        var logits = model(tokens(missing), cache: cache, state: nil).logits
        fed += missing
        var drafted: [Int] = []
        while true {
            let next = argMax(logits[0, -1], axis: -1).item(Int.self)
            drafted.append(next)
            guard drafted.count < count else { break }
            logits = model(tokens([next]), cache: cache, state: nil).logits
            fed.append(next)
        }
        return drafted
    }

    private func tokens(_ ids: [Int]) -> LMInput.Text {
        LMInput.Text(tokens: MLXArray(ids.map { Int32(truncatingIfNeeded: $0) }).expandedDimensions(axis: 0))
    }
}
