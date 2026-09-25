import Foundation
import Jinja

/// A tool call a model wrote, in the OpenAI shape: `arguments` is a JSON string.
struct ParsedToolCall: Equatable, Sendable {
    var name: String
    var arguments: String
}

/// How a model family writes its tool calls, told apart by what its chat template renders for
/// them (the format a model is trained to emit is the one its template puts into a conversation's
/// history). A family with no known format keeps its calls as plain content, like llama-server does
/// for templates it can't read (Gemma's has no tool support at all).
enum ToolCallFormat: Equatable, Sendable {
    /// `<tool_call>{"name": …, "arguments": {…}}</tool_call>` (Hermes, Qwen 2.5 and 3).
    case hermesJSON
    /// `<tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>` (Qwen3-Coder, Qwen 3.5+).
    case qwenXML
    /// A bare `{"name": …, "parameters": {…}}` as the whole reply (Llama 3.1/3.2).
    case bareJSON
    /// gpt-oss's channels: `<|channel|>commentary to=functions.NAME<|message|>{…}<|call|>`.
    case harmony
    case none

    static func detect(template: String) -> ToolCallFormat {
        if template.contains("<|channel|>"), template.contains("commentary") {
            return .harmony
        }
        if template.contains("<function=") {
            return .qwenXML
        }
        if template.contains("<tool_call>") {
            return .hermesJSON
        }
        if template.contains("<|python_tag|>") || template.contains("Environment: ipython") {
            return .bareJSON
        }
        return .none
    }
}

/// Reads tool calls out of a model's text as it streams. The text before a call is content, the
/// call itself is held until it's complete (a call's arguments are only useful whole), and a block
/// that turns out not to be a valid call is given back as the content it was.
struct ToolCallParser: Sendable {
    private let format: ToolCallFormat
    private let schemas: [String: [String: String]] // tool name → parameter name → JSON type
    private let toolNames: Set<String>

    private enum State {
        case text
        case inCall
        /// `bareJSON`: the reply started with `{`, so the whole reply is held to see if it's a call.
        case bareCandidate
    }

    private var state = State.text
    private var pending = ""
    /// Set once real (non-whitespace) content has been seen, so a later `{` isn't a bare call.
    private var sawContent = false

    static let openTag = "<tool_call>"
    static let closeTag = "</tool_call>"

    init(format: ToolCallFormat, tools: [Value]) {
        self.format = format
        var schemas: [String: [String: String]] = [:]
        for tool in tools {
            guard let name = tool["function"]?["name"]?.stringValue else { continue }
            var types: [String: String] = [:]
            if case let .object(properties)? = tool["function"]?["parameters"]?["properties"] {
                for (key, value) in properties {
                    if case let .string(parameter) = key, let type = value["type"]?.stringValue {
                        types[parameter] = type
                    }
                }
            }
            schemas[name] = types
        }
        self.schemas = schemas
        toolNames = Set(schemas.keys)
    }

    /// Whether this parser can do anything: without tools, or with an unknown format, text passes.
    var isActive: Bool {
        format != .none && !toolNames.isEmpty
    }

    mutating func push(_ text: String) -> [ChatDelta] {
        guard isActive, format != .harmony else { return text.isEmpty ? [] : [.content(text)] }
        pending += text
        return drain(final: false)
    }

    mutating func flush() -> [ChatDelta] {
        guard isActive, format != .harmony else { return [] }
        return drain(final: true)
    }

    // MARK: State machine

    private mutating func drain(final: Bool) -> [ChatDelta] {
        var out: [ChatDelta] = []
        func content(_ text: String) {
            guard !text.isEmpty else { return }
            if case let .content(previous)? = out.last {
                out[out.count - 1] = .content(previous + text)
            } else {
                out.append(.content(text))
            }
        }

        loop: while true {
            switch state {
            case .text:
                if format == .bareJSON {
                    if !sawContent {
                        let body = pending.drop(while: { $0.isWhitespace })
                        if body.isEmpty {
                            if final {
                                content(pending); pending = ""
                            }
                            break loop
                        }
                        if body.hasPrefix("{") {
                            state = .bareCandidate
                            continue loop
                        }
                    }
                    sawContent = true
                    content(pending)
                    pending = ""
                    break loop
                }
                if let range = pending.range(of: Self.openTag) {
                    content(String(pending[..<range.lowerBound]).trimmingTrailingWhitespace(whenCallFollows: true))
                    pending = String(pending[range.upperBound...])
                    state = .inCall
                    continue loop
                }
                // Hold back what could still be the start of a call: a partial tag, and the whitespace
                // in front of it (the layout newline before a call isn't content).
                var hold = 0
                if !final {
                    let partial = Self.partialSuffixLength(of: pending, for: Self.openTag)
                    let head = pending.dropLast(partial)
                    let whitespace = head.count - head.trimmingTrailingWhitespace(whenCallFollows: true).count
                    hold = partial + whitespace
                }
                content(String(pending.dropLast(hold)))
                pending = String(pending.suffix(hold))
                break loop
            case .inCall:
                if let range = pending.range(of: Self.closeTag) {
                    let body = String(pending[..<range.lowerBound])
                    pending = String(pending[range.upperBound...])
                    state = .text
                    if let call = parseTagged(body) {
                        out.append(.toolCall(call))
                        // Whitespace between consecutive calls isn't content.
                        pending = String(pending.drop(while: { $0.isWhitespace }))
                    } else {
                        content(Self.openTag + body + Self.closeTag)
                    }
                    continue loop
                }
                if final {
                    content(Self.openTag + pending) // cut off mid-call: it was never a call
                    pending = ""
                }
                break loop
            case .bareCandidate:
                guard final else { break loop }
                if let call = parseBare(pending) {
                    out.append(.toolCall(call))
                } else {
                    content(pending)
                }
                pending = ""
                state = .text
                sawContent = true
                break loop
            }
        }
        return out
    }

    // MARK: Parsing

    private func parseTagged(_ body: String) -> ParsedToolCall? {
        switch format {
        case .hermesJSON: Self.callFromJSON(body, allowed: toolNames)
        case .qwenXML: parseXML(body)
        default: nil
        }
    }

    private func parseBare(_ text: String) -> ParsedToolCall? {
        Self.callFromJSON(text, allowed: toolNames)
    }

    /// `{"name": "f", "arguments": {…}}` (Hermes) or `"parameters"` (Llama 3); `arguments` may itself
    /// be a JSON string. The name must be one of the tools the request offered.
    static func callFromJSON(_ text: String, allowed: Set<String>) -> ParsedToolCall? {
        guard let value = try? OrderedJSON.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let name = value["name"]?.stringValue, allowed.contains(name)
        else { return nil }
        let arguments = value["arguments"] ?? value["parameters"] ?? .object([:])
        if let string = arguments.stringValue {
            guard (try? OrderedJSON.parse(string)) != nil else { return nil }
            return ParsedToolCall(name: name, arguments: string)
        }
        guard case .object = arguments,
              let json = try? OrderedJSON.serialize(arguments, spaced: true) else { return nil }
        return ParsedToolCall(name: name, arguments: json)
    }

    /// `<function=NAME>` then `<parameter=KEY>` blocks; a value is a string unless the tool's schema
    /// says otherwise and it parses as that.
    private func parseXML(_ body: String) -> ParsedToolCall? {
        guard let open = body.range(of: "<function="),
              let nameEnd = body.range(of: ">", range: open.upperBound ..< body.endIndex),
              let close = body.range(of: "</function>", range: nameEnd.upperBound ..< body.endIndex)
        else { return nil }
        let name = String(body[open.upperBound ..< nameEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard toolNames.contains(name) else { return nil }

        var arguments = OrderedDictionary<ObjectKey, Value>()
        var rest = body[nameEnd.upperBound ..< close.lowerBound]
        while let start = rest.range(of: "<parameter=") {
            guard let keyEnd = rest.range(of: ">", range: start.upperBound ..< rest.endIndex),
                  let end = rest.range(of: "</parameter>", range: keyEnd.upperBound ..< rest.endIndex)
            else { return nil }
            let key = String(rest[start.upperBound ..< keyEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // One newline after the opening tag and one before the closing tag are layout.
            var raw = String(rest[keyEnd.upperBound ..< end.lowerBound])
            if raw.hasPrefix("\n") {
                raw.removeFirst()
            }
            if raw.hasSuffix("\n") {
                raw.removeLast()
            }
            arguments[.string(key)] = typed(raw, as: schemas[name]?[key])
            rest = rest[end.upperBound...]
        }
        guard let json = try? OrderedJSON.serialize(.object(arguments)) else { return nil }
        return ParsedToolCall(name: name, arguments: json)
    }

    private func typed(_ raw: String, as type: String?) -> Value {
        if type == "string" || type == nil {
            return .string(raw)
        }
        return (try? OrderedJSON.parse(raw)) ?? .string(raw)
    }

    private static func partialSuffixLength(of text: String, for tag: String) -> Int {
        var length = min(tag.count - 1, text.count)
        while length > 0 {
            if text.suffix(length) == tag.prefix(length) {
                return length
            }
            length -= 1
        }
        return 0
    }
}

private extension StringProtocol {
    /// Text right before a tool call usually ends in a newline the model put there for layout.
    func trimmingTrailingWhitespace(whenCallFollows: Bool) -> String {
        guard whenCallFollows else { return String(self) }
        var text = String(self)
        while let last = text.last, last.isWhitespace {
            text.removeLast()
        }
        return text
    }
}
