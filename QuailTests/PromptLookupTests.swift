import Foundation
import Testing
@testable import QuailServerCore

@Suite("Prompt lookup drafting")
struct PromptLookupTests {
    @Test("the tokens that followed the latest earlier occurrence of the last three are the draft")
    func trigram() {
        // "a b c d e ... a b c" → guess "d e".
        let history = [1, 2, 3, 4, 5, 9, 9, 1, 2, 3]
        #expect(PromptLookup.draft(history, maxTokens: 2) == [4, 5])
        #expect(PromptLookup.draft(history, maxTokens: 8) == [4, 5, 9, 9, 1, 2, 3])
    }

    @Test("the most recent occurrence wins, and a shorter n-gram is tried when the longer doesn't recur")
    func recencyAndBackoff() {
        let history = [7, 8, 1, 2, 3, 7, 8, 4, 2, 3]
        // [8, 2, 3] never recurs; [2, 3] last recurred at index 3, followed by 7, 8.
        #expect(PromptLookup.draft(history, maxTokens: 2) == [7, 8])
        let recent = [1, 2, 5, 1, 2, 6, 1, 2]
        #expect(PromptLookup.draft(recent, maxNgram: 2, maxTokens: 1) == [6])
    }

    @Test("nothing recurring, a short history, or no room gives no draft")
    func none() {
        #expect(PromptLookup.draft([1, 2, 3, 4, 5]).isEmpty)
        #expect(PromptLookup.draft([1]).isEmpty)
        #expect(PromptLookup.draft([]).isEmpty)
        #expect(PromptLookup.draft([1, 2, 1, 2], maxTokens: 0).isEmpty)
    }
}
