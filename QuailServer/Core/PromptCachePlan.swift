import Foundation

/// The MLX engine's prompt-cache bookkeeping (ADR D-055), kept free of MLX so it can be tested: which of the
/// caches kept from earlier requests a new prompt can reuse, how much of it, and which to let go.
///
/// A cache holds the keys and values (and, for hybrid models, the recurrent state) for a run of tokens. A cache
/// whose layers can all be cut back ("trimmed") can serve any prompt that shares a prefix with it. A hybrid
/// model's recurrent layers (Qwen3.5-family linear attention) and sliding-window layers can't be cut back, so
/// such a cache serves only a prompt that extends everything it holds, or one that extends one of the points
/// it was checkpointed at on the way: every few thousand tokens of the last prompt, and just short of its end,
/// which is where the next turn of a conversation usually picks up (the reply is often re-templated, a
/// reasoning block dropped, so the whole reply rarely matches).
public enum PromptCachePlan {
    public struct Candidate: Equatable, Sendable {
        /// The tokens the cache holds now.
        public var tokens: [Int]
        /// Whether every layer can be cut back to any shorter prefix.
        public var trimmable: Bool
        /// Shorter token counts the cache can also be put back to (copies of its untrimmable layers taken
        /// then).
        public var checkpoints: [Int]

        public init(tokens: [Int], trimmable: Bool, checkpoints: [Int] = []) {
            self.tokens = tokens
            self.trimmable = trimmable
            self.checkpoints = checkpoints
        }
    }

    public struct Choice: Equatable, Sendable {
        /// Which candidate.
        public var index: Int
        /// How many of the prompt's tokens it already holds.
        public var reuse: Int
        /// Whether that means going back to a checkpoint (the one at `reuse`) rather than cutting the cache
        /// back.
        public var fromCheckpoint: Bool

        public init(index: Int, reuse: Int, fromCheckpoint: Bool) {
            self.index = index
            self.reuse = reuse
            self.fromCheckpoint = fromCheckpoint
        }
    }

    /// The candidate that holds the most of `prompt`, or nil if none holds any. At least the prompt's last
    /// token is always left to process, since its logits pick the first token of the reply. On a tie the
    /// later candidate (the more recently used) wins. A candidate is passed over if the prompt would use
    /// less than half of it: taking it cuts it back for good, so a second conversation that shares only a
    /// system prompt's first few tokens would destroy the first one's cache to save a handful of tokens
    /// (llama-server's slot choice has the same threshold, `--slot-prompt-similarity 0.5`).
    public static func choose(_ candidates: [Candidate], for prompt: [Int]) -> Choice? {
        let limit = prompt.count - 1
        guard limit > 0 else { return nil }
        var best: Choice?
        for (index, candidate) in candidates.enumerated() {
            let common = commonPrefix(candidate.tokens, prompt, limit: limit)
            let choice: Choice? = if candidate.trimmable {
                Choice(index: index, reuse: common, fromCheckpoint: false)
            } else if common == candidate.tokens.count {
                Choice(index: index, reuse: common, fromCheckpoint: false)
            } else if let checkpoint = candidate.checkpoints.filter({ $0 > 0 && $0 <= common }).max() {
                Choice(index: index, reuse: checkpoint, fromCheckpoint: true)
            } else {
                nil
            }
            if let choice, choice.reuse > 0, choice.reuse * 2 >= candidate.tokens.count,
               choice.reuse >= (best?.reuse ?? 0)
            {
                best = choice
            }
        }
        return best
    }

    /// How many of the oldest caches to let go (`sizes` in bytes, oldest first) so that at most `maxEntries`
    /// remain and their total is at most `maxBytes`. The newest is always kept, however large.
    public static func evictions(sizes: [Int], maxEntries: Int, maxBytes: Int) -> Int {
        var drop = max(0, sizes.count - max(1, maxEntries))
        var total = sizes[drop...].reduce(0, +)
        while drop < sizes.count - 1, total > maxBytes {
            total -= sizes[drop]
            drop += 1
        }
        return drop
    }

    static func commonPrefix(_ a: [Int], _ b: [Int], limit: Int) -> Int {
        let end = min(a.count, b.count, limit)
        var index = 0
        while index < end, a[index] == b[index] {
            index += 1
        }
        return index
    }
}
