import Foundation
import Testing
@testable import QuailServerCore

@Suite("GGUF parked sequences")
struct ParkedSequencesTests {
    @Test("the longest shared start wins, leaving the prompt's last token to decode")
    func best() {
        var parked = ParkedSequences<String>(budget: 100)
        parked.park(tokens: [1, 2, 3], state: "a", size: 10)
        parked.park(tokens: [1, 2, 9, 9], state: "b", size: 10)
        #expect(parked.best(for: [1, 2, 3, 4])?.index == 0)
        #expect(parked.best(for: [1, 2, 3, 4])?.shared == 3)
        #expect(parked.best(for: [1, 2, 9, 9, 5])?.shared == 4)
        // The whole prompt is parked: all but its last token.
        #expect(parked.best(for: [1, 2, 3])?.shared == 2)
        #expect(parked.best(for: [7, 1, 2]) == nil)
    }

    @Test("a tie goes to the more recently parked")
    func tie() {
        var parked = ParkedSequences<String>(budget: 100)
        parked.park(tokens: [1, 2, 3], state: "old", size: 10)
        parked.park(tokens: [1, 2, 4], state: "new", size: 10)
        let found = parked.best(for: [1, 2, 5])
        #expect(found?.shared == 2)
        #expect(found.map { parked.entries[$0.index].state } == "new")
    }

    @Test("the oldest go once the budget is passed, and one too big for it isn't kept")
    func budget() {
        var parked = ParkedSequences<String>(budget: 25)
        parked.park(tokens: [1], state: "a", size: 10)
        parked.park(tokens: [2], state: "b", size: 10)
        parked.park(tokens: [3], state: "c", size: 10)
        #expect(parked.entries.map(\.state) == ["b", "c"])
        parked.park(tokens: [4], state: "huge", size: 26)
        #expect(parked.entries.map(\.state) == ["b", "c"])
        #expect(parked.take(0).state == "b")
        #expect(parked.bytes == 10)
    }
}
