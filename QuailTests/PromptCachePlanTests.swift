import Foundation
import Testing
@testable import QuailServerCore

@Suite("MLX prompt-cache plan")
struct PromptCachePlanTests {
    private typealias Candidate = PromptCachePlan.Candidate
    private typealias Choice = PromptCachePlan.Choice

    @Test("a trimmable cache serves any shared prefix, leaving at least the last token to process")
    func trimmable() {
        let cache = Candidate(tokens: [1, 2, 3, 4, 5], trimmable: true)
        #expect(PromptCachePlan.choose([cache], for: [1, 2, 3, 9]) == Choice(index: 0, reuse: 3, fromCheckpoint: false))
        // Less than half of it: left for its own conversation.
        #expect(PromptCachePlan.choose([cache], for: [1, 2, 9]) == nil)
        #expect(PromptCachePlan.choose([cache], for: [1, 2, 3, 4, 5]) == Choice(index: 0, reuse: 4, fromCheckpoint: false))
        #expect(PromptCachePlan.choose([cache], for: [1, 2, 3, 4, 5, 6]) == Choice(index: 0, reuse: 5, fromCheckpoint: false))
        #expect(PromptCachePlan.choose([cache], for: [7, 1, 2]) == nil)
        #expect(PromptCachePlan.choose([cache], for: [1]) == nil)
        #expect(PromptCachePlan.choose([], for: [1, 2]) == nil)
    }

    @Test("an untrimmable cache serves a prompt that extends all of it, or its checkpoint, and nothing between")
    func untrimmable() {
        // The last request: prompt [1 2 3 4], reply [5 6], checkpointed at the end of the prompt.
        let cache = Candidate(tokens: [1, 2, 3, 4, 5, 6], trimmable: false, checkpoints: [4])
        // The next turn repeats the whole exchange: everything is reused.
        #expect(PromptCachePlan.choose([cache], for: [1, 2, 3, 4, 5, 6, 7]) == Choice(index: 0, reuse: 6, fromCheckpoint: false))
        // The next turn re-templates the reply: back to the end of the last prompt.
        #expect(PromptCachePlan.choose([cache], for: [1, 2, 3, 4, 9, 9, 9]) == Choice(index: 0, reuse: 4, fromCheckpoint: true))
        #expect(PromptCachePlan.choose([cache], for: [1, 2, 3, 4, 5, 9]) == Choice(index: 0, reuse: 4, fromCheckpoint: true))
        // Diverging before the checkpoint: the recurrent state can't be rewound.
        #expect(PromptCachePlan.choose([cache], for: [1, 2, 9, 9, 9]) == nil)
        // The same prompt again: the last token must be processed, so only the checkpoint is short enough...
        #expect(PromptCachePlan.choose([cache], for: [1, 2, 3, 4, 5, 6]) == Choice(index: 0, reuse: 4, fromCheckpoint: true))
        // ...and without a checkpoint nothing is.
        #expect(PromptCachePlan.choose([Candidate(tokens: [1, 2, 3], trimmable: false)], for: [1, 2, 3]) == nil)
    }

    @Test("with checkpoints along the way, a prompt that diverges midway resumes from the last one before it")
    func checkpointsAlongTheWay() {
        // A long shared instruction block, then a transcript that differs (a classifier asked twice).
        let cache = Candidate(tokens: Array(0 ..< 100), trimmable: false, checkpoints: [40, 80, 96])
        let prompt = Array(0 ..< 85) + [999, 998]
        #expect(PromptCachePlan.choose([cache], for: prompt) == Choice(index: 0, reuse: 80, fromCheckpoint: true))
        // The checkpoint at 40 is less than half of the cache: it's left for its own conversation.
        #expect(PromptCachePlan.choose([cache], for: Array(0 ..< 50) + [7]) == nil)
        #expect(PromptCachePlan.choose([cache], for: Array(0 ..< 30) + [7]) == nil)
    }

    @Test("the candidate holding the most wins; on a tie the more recent one")
    func best() {
        let a = Candidate(tokens: [1, 2, 3, 4], trimmable: true)
        let b = Candidate(tokens: [8, 8, 8], trimmable: true)
        let c = Candidate(tokens: [1, 2, 7], trimmable: true)
        #expect(PromptCachePlan.choose([a, b, c], for: [1, 2, 3, 4, 5])?.index == 0)
        #expect(PromptCachePlan.choose([a, b, c], for: [8, 8, 8, 1])?.index == 1)
        #expect(PromptCachePlan.choose([a, b, c], for: [1, 2, 9])?.index == 2)
    }

    @Test("two conversations sharing a system prompt's opening keep their own caches")
    func conversations() {
        // A: "You are helper A. <long system prompt>" and a reply; B differs from the fourth token.
        let a = Candidate(tokens: [1, 2, 3, 10] + Array(100 ..< 140), trimmable: true)
        let bTurn = [1, 2, 3, 20] + Array(100 ..< 130)
        #expect(PromptCachePlan.choose([a], for: bTurn) == nil)
        let b = Candidate(tokens: bTurn + [7, 7], trimmable: true)
        // A's next turn finds A's cache, B's finds B's.
        #expect(PromptCachePlan.choose([a, b], for: a.tokens + [5])?.index == 0)
        #expect(PromptCachePlan.choose([a, b], for: b.tokens + [5])?.index == 1)
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
