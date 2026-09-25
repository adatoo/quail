import Foundation

/// Reads gpt-oss's "Harmony" output: a sequence of messages, each `<|channel|>NAME [to=RECIPIENT]
/// [<|constrain|>json]<|message|>BODY` ended by `<|end|>`, `<|call|>` or `<|return|>`. The
/// `analysis` channel is the model's reasoning, `final` (or `commentary` with no recipient) is the
/// answer, and `commentary to=functions.NAME` is a tool call whose body is its JSON arguments.
///
/// This relies on the engine decoding the format's special tokens into the text, as llama.cpp does
/// for these models; it's written from the format's specification and its chat template, and has
/// not yet been run on a real gpt-oss model's output (ADR D-040).
struct HarmonyParser: Sendable {
    private enum Kind: Equatable {
        case reasoning
        case content
        case call(String)
        /// A recipient that isn't one of the request's tools: given back as content.
        case unknownCall(String)
    }

    private enum State: Equatable {
        case idle
        case header
        case body(Kind)
    }

    private static let start = "<|start|>", channel = "<|channel|>", message = "<|message|>"
    private static let end = "<|end|>", call = "<|call|>", returnTag = "<|return|>", constrain = "<|constrain|>"
    private static let tags = [start, channel, message, end, call, returnTag, constrain]

    private let toolNames: Set<String>
    private var state = State.idle
    private var pending = ""
    private var header = ""
    /// Text between `<|start|>` and the next tag: the role, and sometimes the recipient (`assistant to=functions.x`).
    private var startText = ""
    private var arguments = ""

    init(toolNames: Set<String>) {
        self.toolNames = toolNames
    }

    mutating func push(_ text: String) -> [ChatDelta] {
        pending += text
        return drain(final: false)
    }

    mutating func flush() -> [ChatDelta] {
        var out = drain(final: true)
        // Cut off inside a message: a half call isn't a call; give it back as text.
        if case let .body(kind) = state {
            switch kind {
            case .call, .unknownCall: if !arguments.isEmpty {
                    out.append(.content(arguments))
                }
            default: break
            }
        }
        state = .idle
        arguments = ""
        return out
    }

    private mutating func drain(final: Bool) -> [ChatDelta] {
        var out: [ChatDelta] = []
        func add(_ delta: ChatDelta) {
            switch (out.last, delta) {
            case let (.content(a)?, .content(b)): out[out.count - 1] = .content(a + b)
            case let (.reasoning(a)?, .reasoning(b)): out[out.count - 1] = .reasoning(a + b)
            default: out.append(delta)
            }
        }
        while true {
            // The earliest special token in what's pending.
            var found: (tag: String, range: Range<String.Index>)?
            for tag in Self.tags {
                if let range = pending.range(of: tag), found == nil || range.lowerBound < found!.range.lowerBound {
                    found = (tag, range)
                }
            }
            if let (tag, range) = found {
                consume(String(pending[..<range.lowerBound]), add: add)
                pending = String(pending[range.upperBound...])
                handle(tag, add: add)
                continue
            }
            let hold = final ? 0 : Self.partialSuffixLength(of: pending)
            consume(String(pending.dropLast(hold)), add: add)
            pending = String(pending.suffix(hold))
            return out
        }
    }

    private mutating func consume(_ text: String, add: (ChatDelta) -> Void) {
        guard !text.isEmpty else { return }
        switch state {
        case .idle: startText += text
        case .header: header += text
        case let .body(kind):
            switch kind {
            case .reasoning: add(.reasoning(text))
            case .content: add(.content(text))
            case .call, .unknownCall: arguments += text
            }
        }
    }

    private mutating func handle(_ tag: String, add: (ChatDelta) -> Void) {
        switch tag {
        case Self.start:
            finishBody(add: add)
            state = .idle
            startText = ""
        case Self.channel:
            finishBody(add: add)
            state = .header
            header = ""
        case Self.constrain:
            if state == .header {
                header += " "
            }
        case Self.message:
            if state == .header {
                state = .body(kind(forHeader: header + " " + startText))
            } else if state == .idle {
                state = .body(.content) // `<|start|>assistant<|message|>` with no channel
            }
            arguments = ""
        default: // end, call, return
            finishBody(add: add)
            state = .idle
            startText = ""
        }
    }

    private mutating func finishBody(add: (ChatDelta) -> Void) {
        guard case let .body(kind) = state else { return }
        switch kind {
        case let .call(name):
            let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if (try? OrderedJSON.parse(text)) != nil {
                add(.toolCall(ParsedToolCall(name: name, arguments: text)))
            } else {
                add(.content(arguments))
            }
        case .unknownCall:
            add(.content(arguments))
        default: break
        }
        arguments = ""
    }

    private func kind(forHeader header: String) -> Kind {
        let words = header.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let recipient = words.first(where: { $0.hasPrefix("to=") }) {
            let target = String(recipient.dropFirst(3))
            let name = target.hasPrefix("functions.") ? String(target.dropFirst("functions.".count)) : target
            return toolNames.contains(name) ? .call(name) : .unknownCall(name)
        }
        return words.first == "analysis" ? .reasoning : .content
    }

    private static func partialSuffixLength(of text: String) -> Int {
        var best = 0
        for tag in tags {
            var length = min(tag.count - 1, text.count)
            while length > best {
                if text.suffix(length) == tag.prefix(length) {
                    best = length
                    break
                }
                length -= 1
            }
        }
        return best
    }
}
