import Foundation

/// The fixed benchmark, `quail-bench-1` (ADR D-023). Changing anything here
/// — sizes, run counts, the passage, request settings — makes results
/// incomparable with earlier ones, so it means a new `id`, never an edit.
enum BenchmarkSuite {
    static let id = "quail-bench-1"

    /// Prompt-processing sizes, in tokens. A size is skipped when the
    /// model's loaded context can't hold it plus one generated token.
    static let promptSizes = [512, 4096]
    /// Tokens generated for the generation test (`ignore_eos`, so exactly
    /// this many).
    static let generateTokens = 256
    /// The short prompt the generation test continues from.
    static let generationPromptTokens = 16
    /// Discarded runs first, so cold kernels and caches don't count.
    static let warmupRuns = 1
    static let measuredRuns = 3

    /// Every request: deterministic sampling, and no prompt cache —
    /// otherwise a repeated prompt is "processed" in no time.
    static var requestSettings: [String: Any] {
        ["temperature": 0, "seed": 42, "cache_prompt": false]
    }

    /// The source text for prompts. Tokenized per model (token ids are
    /// model-specific), then repeated and cut to exactly the size needed —
    /// prompts are sent as token ids, so the count is exact.
    static let passage = """
    The lighthouse keeper kept a log of every ship that passed the point, \
    noting the hour, the weather, the direction of the wind and the colour \
    of the water. Over forty years the entries grew into a record of the \
    coast itself: storms that moved the sandbars, winters when the harbour \
    froze, summers when the fishing boats came home early because the \
    shoals had gone somewhere else. Scientists later used the log to study \
    how the currents had shifted, and historians used it to date the \
    wrecks that divers found along the reef. The keeper never thought of \
    it as data. To him it was simply the day's work, written down in the \
    same careful hand each evening before he climbed the stairs to light \
    the lamp.
    """

    /// `count` tokens made by repeating `passageTokens`.
    static func promptTokens(from passageTokens: [Int], count: Int) -> [Int] {
        guard !passageTokens.isEmpty, count > 0 else { return [] }
        var tokens: [Int] = []
        tokens.reserveCapacity(count)
        while tokens.count < count {
            tokens.append(contentsOf: passageTokens.prefix(count - tokens.count))
        }
        return tokens
    }

    /// Whether a prompt of `size` fits a context of `contextSize`
    /// (with room for the one token generated after it).
    static func fits(_ size: Int, contextSize: Int?) -> Bool {
        guard let contextSize else { return true }
        return size + 1 <= contextSize
    }
}
