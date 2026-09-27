import Foundation
import Testing
@testable import QuailServerCore

@Suite("MLX prompt-cache plan")
struct PromptCachePlanTests {
    private typealias Candidate = PromptCachePlan.Candidate

    private func pick(_ candidates: [Candidate], _ prompt: [Int]) -> PromptCachePlan.Choice? {
        PromptCachePlan.choose(candidates, for: prompt)
    }

    /// A choice of candidate `index`, reusing `reuse` tokens, from a checkpoint or not.
    private func choice(_ index: Int, _ reuse: Int, checkpoint: Bool = false) -> PromptCachePlan.Choice {
        PromptCachePlan.Choice(index: index, reuse: reuse, fromCheckpoint: checkpoint)
    }

    @Test("a trimmable cache serves any shared prefix, leaving at least the last token to process")
    func trimmable() {
        let cache = Candidate(tokens: [1, 2, 3, 4, 5], trimmable: true)
        #expect(pick([cache], [1, 2, 3, 9]) == choice(0, 3))
        // Less than half of it: left for its own conversation.
        #expect(pick([cache], [1, 2, 9]) == nil)
        #expect(pick([cache], [1, 2, 3, 4, 5]) == choice(0, 4))
        #expect(pick([cache], [1, 2, 3, 4, 5, 6]) == choice(0, 5))
        #expect(pick([cache], [7, 1, 2]) == nil)
        #expect(pick([cache], [1]) == nil)
        #expect(pick([], [1, 2]) == nil)
    }

    @Test("an untrimmable cache serves a prompt that extends all of it, or its checkpoint, and nothing between")
    func untrimmable() {
        // The last request: prompt [1 2 3 4], reply [5 6], checkpointed at the end of the prompt.
        let cache = Candidate(tokens: [1, 2, 3, 4, 5, 6], trimmable: false, checkpoints: [4])
        // The next turn repeats the whole exchange: everything is reused.
        #expect(pick([cache], [1, 2, 3, 4, 5, 6, 7]) == choice(0, 6))
        // The next turn re-templates the reply: back to the end of the last prompt.
        #expect(pick([cache], [1, 2, 3, 4, 9, 9, 9]) == choice(0, 4, checkpoint: true))
        #expect(pick([cache], [1, 2, 3, 4, 5, 9]) == choice(0, 4, checkpoint: true))
        // Diverging before the checkpoint: the recurrent state can't be rewound.
        #expect(pick([cache], [1, 2, 9, 9, 9]) == nil)
        // The same prompt again: the last token must be processed, so only the checkpoint is short enough...
        #expect(pick([cache], [1, 2, 3, 4, 5, 6]) == choice(0, 4, checkpoint: true))
        // ...and without a checkpoint nothing is.
        #expect(pick([Candidate(tokens: [1, 2, 3], trimmable: false)], [1, 2, 3]) == nil)
    }

    @Test("with checkpoints along the way, a prompt that diverges midway resumes from the last one before it")
    func checkpointsAlongTheWay() {
        // A long shared instruction block, then a transcript that differs (a classifier asked twice).
        let cache = Candidate(tokens: Array(0 ..< 100), trimmable: false, checkpoints: [40, 80, 96])
        let prompt = Array(0 ..< 85) + [999, 998]
        #expect(pick([cache], prompt) == choice(0, 80, checkpoint: true))
        // The checkpoint at 40 is less than half of the cache: it's left for its own conversation.
        #expect(pick([cache], Array(0 ..< 50) + [7]) == nil)
        #expect(pick([cache], Array(0 ..< 30) + [7]) == nil)
    }

    @Test("the candidate holding the most wins; on a tie the more recent one")
    func best() {
        let a = Candidate(tokens: [1, 2, 3, 4], trimmable: true)
        let b = Candidate(tokens: [8, 8, 8], trimmable: true)
        let c = Candidate(tokens: [1, 2, 7], trimmable: true)
        #expect(pick([a, b, c], [1, 2, 3, 4, 5])?.index == 0)
        #expect(pick([a, b, c], [8, 8, 8, 1])?.index == 1)
        #expect(pick([a, b, c], [1, 2, 9])?.index == 2)
    }

    @Test("two conversations sharing a system prompt's opening keep their own caches")
    func conversations() {
        // A: "You are helper A. <long system prompt>" and a reply; B differs from the fourth token.
        let a = Candidate(tokens: [1, 2, 3, 10] + Array(100 ..< 140), trimmable: true)
        let bTurn = [1, 2, 3, 20] + Array(100 ..< 130)
        #expect(pick([a], bTurn) == nil)
        let b = Candidate(tokens: bTurn + [7, 7], trimmable: true)
        // A's next turn finds A's cache, B's finds B's.
        #expect(pick([a, b], a.tokens + [5])?.index == 0)
        #expect(pick([a, b], b.tokens + [5])?.index == 1)
    }

    @Test("eviction keeps the newest entries within the count and byte budgets, and always the newest")
    func evictions() {
        #expect(PromptCachePlan.evictions(sizes: [], maxEntries: 4, maxBytes: 100) == 0)
        #expect(PromptCachePlan.evictions(sizes: [10, 10, 10], maxEntries: 4, maxBytes: 100) == 0)
        #expect(PromptCachePlan.evictions(sizes: [10, 10, 10, 10, 10], maxEntries: 4, maxBytes: 100) == 1)
        #expect(PromptCachePlan.evictions(sizes: [60, 30, 30], maxEntries: 4, maxBytes: 100) == 1)
        #expect(PromptCachePlan.evictions(sizes: [60, 30, 300], maxEntries: 4, maxBytes: 100) == 2)
        #expect(PromptCachePlan.evictions(sizes: [10, 10], maxEntries: 0, maxBytes: 100) == 1)
    }
}
