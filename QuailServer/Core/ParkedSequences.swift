import Foundation

/// Idle sequences moved out of the GGUF engine's shared KV cache into ordinary memory (#138, ADR D-048
/// amendment), kept free of llama.cpp so it can be tested.
///
/// The slots share one pool of cells (a unified cache), and every chunk of a prompt attends over the pool's used
/// range, whoever's cells they are. An idle slot's conversation left in the pool so its next turn can reuse it
/// made every other prompt slower: on a Mac mini, after eight requests at once, Qwen3 8B read a 4,096-token prompt
/// in 11.5–11.7 s with their conversations left in the pool and 10.2–10.9 s with them moved out (llama-server:
/// 10.3–10.5 s). llama-server moves idle slots out when a new request starts (`--cache-idle-slots`, into its
/// `--cache-ram` prompt cache), and this does the same: the state is copied out and the slot emptied, and a later
/// prompt that starts the same way copies it back.
///
/// Least recently parked go first once the total passes `budget`.
public struct ParkedSequences<State> {
    public struct Entry {
        public var tokens: [Int32]
        public var state: State
        public var bytes: Int
    }

    public let budget: Int
    public private(set) var entries: [Entry] = []

    public init(budget: Int) {
        self.budget = budget
    }

    public var bytes: Int {
        entries.reduce(0) { $0 + $1.bytes }
    }

    /// Keeps a sequence, dropping the oldest until everything fits; one larger than the budget isn't kept.
    public mutating func park(tokens: [Int32], state: State, size: Int) {
        guard size <= budget, !tokens.isEmpty else { return }
        entries.append(Entry(tokens: tokens, state: state, bytes: size))
        while bytes > budget {
            entries.removeFirst()
        }
    }

    /// The parked sequence sharing the longest start with `prompt`, and how many of its tokens that is, leaving the
    /// prompt's last token to decode (its logits are needed); nil if none shares any.
    public func best(for prompt: [Int32]) -> (index: Int, shared: Int)? {
        var best: (index: Int, shared: Int)?
        for (index, entry) in entries.enumerated() {
            let limit = min(entry.tokens.count, prompt.count - 1)
            var shared = 0
            while shared < limit, entry.tokens[shared] == prompt[shared] {
                shared += 1
            }
            if shared > 0, shared >= best?.shared ?? 0 {
                best = (index, shared)
            }
        }
        return best
    }

    /// Takes a parked sequence out, to go back into the cache.
    public mutating func take(_ index: Int) -> Entry {
        entries.remove(at: index)
    }

    public mutating func removeAll() {
        entries = []
    }
}
