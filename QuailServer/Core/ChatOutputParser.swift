import Foundation
import Jinja

/// Everything that turns a model's raw text into a chat reply's parts: reasoning, content and
/// tool calls, for whichever family the template says this is.
struct ChatOutputParser: Sendable {
    private var reasoning: ReasoningSplitter?
    private var tools: ToolCallParser
    private var harmony: HarmonyParser?

    init(format: ToolCallFormat, tools: [Value], startsInReasoning: Bool) {
        let parser = ToolCallParser(format: format, tools: tools)
        self.tools = parser
        if format == .harmony {
            let names = Set(tools.compactMap { $0["function"]?["name"]?.stringValue })
            harmony = HarmonyParser(toolNames: names)
            reasoning = nil
        } else {
            reasoning = ReasoningSplitter(startsInReasoning: startsInReasoning)
        }
    }

    mutating func push(_ text: String) -> [ChatDelta] {
        if harmony != nil {
            return harmony!.push(text)
        }
        return route(reasoning!.push(text))
    }

    mutating func flush() -> [ChatDelta] {
        if harmony != nil {
            return harmony!.flush()
        }
        var out = route(reasoning!.flush())
        out += tools.flush()
        return Self.merged(out)
    }

    /// Reasoning passes straight through; only the answer is searched for tool calls.
    private mutating func route(_ deltas: [ChatDelta]) -> [ChatDelta] {
        var out: [ChatDelta] = []
        for delta in deltas {
            if case let .content(text) = delta {
                out += tools.push(text)
            } else {
                out.append(delta)
            }
        }
        return Self.merged(out)
    }

    private static func merged(_ deltas: [ChatDelta]) -> [ChatDelta] {
        var out: [ChatDelta] = []
        for delta in deltas {
            switch (out.last, delta) {
            case let (.content(a)?, .content(b)): out[out.count - 1] = .content(a + b)
            case let (.reasoning(a)?, .reasoning(b)): out[out.count - 1] = .reasoning(a + b)
            default: out.append(delta)
            }
        }
        return out
    }
}
