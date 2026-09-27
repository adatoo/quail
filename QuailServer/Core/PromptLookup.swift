import Foundation

/// Prompt-lookup drafting for speculative decoding (ADR D-055, Phase 3c step 6), kept free of MLX so it can be
/// tested: when the text so far ends with a few tokens that appeared earlier (in the prompt or the reply), guess
/// that what followed them then follows them again. A model editing a file, quoting a document or repeating a
/// tool's output does this a lot; the engine checks every guess in one forward pass, so a wrong one costs little.
public enum PromptLookup {
    /// Up to `maxTokens` tokens that followed the most recent earlier occurrence of the history's last
    /// `maxNgram` tokens, else of its last `maxNgram - 1`, down to `minNgram`; empty when none recurs.
    public static func draft(_ history: [Int], maxNgram: Int = 3, minNgram: Int = 2, maxTokens: Int = 8) -> [Int] {
        guard maxTokens > 0, minNgram > 0 else { return [] }
        for n in stride(from: min(maxNgram, history.count - 1), through: minNgram, by: -1) {
            let suffixStart = history.count - n
            // The latest earlier start whose n tokens match the suffix, and that leaves something to follow.
            var start = suffixStart - 1
            while start >= 0 {
                var matches = true
                for offset in 0 ..< n where history[start + offset] != history[suffixStart + offset] {
                    matches = false
                    break
                }
                if matches {
                    let from = start + n
                    return Array(history[from ..< min(from + maxTokens, history.count)])
                }
                start -= 1
            }
        }
        return []
    }
}
