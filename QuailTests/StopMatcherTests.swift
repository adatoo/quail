import Testing
@testable import QuailServerCore

@Suite("StopMatcher")
struct StopMatcherTests {
    private func run(_ stops: [String], _ pieces: [String]) -> (text: String, stopped: Bool) {
        var matcher = StopMatcher(stops)
        var text = ""
        for piece in pieces {
            let result = matcher.push(piece)
            text += result.emit
            if result.stopped {
                return (text, true)
            }
        }
        return (text + matcher.flush(), false)
    }

    @Test("with no stops, text passes straight through")
    func noStops() {
        var matcher = StopMatcher([])
        #expect(matcher.push("abc").emit == "abc")
        #expect(matcher.flush() == "")
    }

    @Test("a stop inside one piece cuts the text there and is not emitted")
    func insidePiece() {
        #expect(run(["END"], ["one END two"]) == ("one ", true))
    }

    @Test("a stop split across pieces is still found, and only its start was held back")
    func acrossPieces() {
        #expect(run(["<|end|>"], ["hi <", "|en", "d|>", " more"]) == ("hi ", true))
    }

    @Test("held-back text that never became a stop is released")
    func falseStart() {
        #expect(run(["<|end|>"], ["a <|en", "gine"]) == ("a <|engine", false))
        // and at the very end of generation
        #expect(run(["STOP"], ["ST", "O"]) == ("STO", false))
    }

    @Test("text is emitted as soon as it can no longer start a stop")
    func emitsEarly() {
        var matcher = StopMatcher(["</tool>"])
        #expect(matcher.push("hello ").emit == "hello ")
        #expect(matcher.push("<").emit == "")
        #expect(matcher.push("b>").emit == "<b>")
    }

    @Test("with several stops the earliest match wins")
    func earliest() {
        #expect(run(["world", "lo w"], ["hello world"]) == ("hel", true))
    }

    @Test("empty stops are ignored and Unicode is compared by scalar")
    func edgeCases() {
        #expect(run([""], ["abc"]) == ("abc", false))
        #expect(run(["日本"], ["こんにちは日", "本語"]) == ("こんにちは", true))
        #expect(run(["🐦"], ["fly 🐦 away"]) == ("fly ", true))
    }

    @Test("a stop that is a prefix of a longer stop still stops")
    func prefixStops() {
        #expect(run(["ab", "abc"], ["xabcx"]) == ("x", true))
    }
}
