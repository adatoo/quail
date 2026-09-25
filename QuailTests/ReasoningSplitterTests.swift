import Foundation
import Testing
@testable import QuailServerCore

@Suite("ReasoningSplitter")
struct ReasoningSplitterTests {
    /// Runs `pieces` through a splitter and returns the reasoning and answer it produced.
    private func split(_ pieces: [String], startsInReasoning: Bool = false) -> (reasoning: String, content: String) {
        var splitter = ReasoningSplitter(startsInReasoning: startsInReasoning)
        var reasoning = "", content = ""
        func take(_ deltas: [ChatDelta]) {
            for delta in deltas {
                switch delta {
                case let .reasoning(text): reasoning += text
                case let .content(text): content += text
                case .toolCall: break // this splitter never produces one
                }
            }
        }
        for piece in pieces {
            take(splitter.push(piece))
        }
        take(splitter.flush())
        return (reasoning, content)
    }

    /// The same text cut into pieces of `size` characters.
    private func chunked(_ text: String, _ size: Int) -> [String] {
        stride(from: 0, to: text.count, by: size).map { start in
            let from = text.index(text.startIndex, offsetBy: start)
            let to = text.index(from, offsetBy: min(size, text.count - start))
            return String(text[from ..< to])
        }
    }

    @Test("reasoning and answer are separated, the tags and the whitespace after them dropped")
    func basic() {
        let result = split(["<think>\nLet me think.\n</think>\n\nHi!"])
        #expect(result.reasoning == "Let me think.\n") // trailing newline kept: llama-server keeps it
        #expect(result.content == "Hi!")
    }

    @Test("the result doesn't depend on where the pieces are cut", arguments: [1, 2, 3, 5, 7, 100])
    func chunkingInvariance(size: Int) {
        let raw = "<think>\nOkay, so 2 < 3 and </b> is not a tag.\n</think>\n\nThe answer is <think> literally."
        let whole = split([raw])
        #expect(split(chunked(raw, size)) == whole)
        #expect(whole.reasoning == "Okay, so 2 < 3 and </b> is not a tag.\n")
        #expect(whole.content == "The answer is <think> literally.")
    }

    @Test("no reasoning at all is all answer, whitespace and all")
    func plainAnswer() {
        let result = split(["  Hello", " there\n"])
        #expect(result.reasoning == "")
        #expect(result.content == "  Hello there\n")
    }

    @Test("a template that already opened <think> starts inside the reasoning")
    func forcedOpen() {
        let result = split(["\nReason", "ing</think>", "Answer"], startsInReasoning: true)
        #expect(result.reasoning == "Reasoning")
        #expect(result.content == "Answer")
    }

    @Test("a reply cut off inside its reasoning has no answer")
    func unterminated() {
        let result = split(["<think>\nStill thinking"])
        #expect(result.reasoning == "Still thinking")
        #expect(result.content == "")
    }

    @Test("something that only starts like a tag is released as the answer")
    func falseAlarm() {
        #expect(split(["<thi", "nking> hmm"]).content == "<thinking> hmm")
        #expect(split(["<thi"]).content == "<thi") // ends while holding a prefix
        #expect(split(["<"]).content == "<")
    }

    @Test("leading whitespace before the opening tag is skipped with it")
    func whitespaceBeforeTag() {
        let result = split(["\n  <think>", "x</think>y"])
        #expect(result.reasoning == "x")
        #expect(result.content == "y")
    }

    @Test("a closing tag with nothing after it is fine")
    func closeAtEnd() {
        let result = split(["<think>a</think>"])
        #expect(result.reasoning == "a")
        #expect(result.content == "")
    }

    @Test("pieces are emitted as they can be, not all at the end")
    func streams() {
        var splitter = ReasoningSplitter(startsInReasoning: false)
        #expect(splitter.push("<think>") == [])
        #expect(splitter.push("\nab") == [.reasoning("ab")])
        #expect(splitter.push("c</") == [.reasoning("c")]) // "</" could be the closing tag
        #expect(splitter.push("think>\n\nhi") == [.content("hi")])
        #expect(splitter.push(" there") == [.content(" there")])
    }

    // MARK: against a real model

    private struct Captured: Decodable {
        let raw: String
        let reasoning: String?
        let content: String
        let promptEndsWith: String

        enum CodingKeys: String, CodingKey {
            case raw, reasoning, content
            case promptEndsWith = "prompt_ends_with"
        }
    }

    /// Qwen3-0.6B's actual output, and what llama-server's chat route made of it
    /// (TestFixtures/Reasoning): the splitter must agree, however the tokens arrive.
    @Test(
        "real Qwen3 output splits exactly as llama-server splits it",
        arguments: ["think-short", "think-poem", "no-think"],
        [1, 3, 8, 1000]
    )
    func matchesLlamaServer(name: String, size: Int) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestFixtures/Reasoning/qwen3-0.6b.json")
        let all = try JSONDecoder().decode([String: Captured].self, from: Data(contentsOf: url))
        let captured = try #require(all[name])
        let result = split(chunked(captured.raw, size))
        #expect(result.reasoning == (captured.reasoning ?? ""))
        #expect(result.content == captured.content)
        // The prompt only opens the reasoning itself when thinking is forced; Qwen3's default doesn't.
        #expect(!captured.promptEndsWith.hasSuffix("<think>\n"))
    }
}
