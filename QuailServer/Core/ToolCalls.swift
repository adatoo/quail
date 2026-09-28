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
/// for templates it can't read (Gemma 3's has no tool support at all).
enum ToolCallFormat: Equatable, Sendable {
    /// `<tool_call>{"name": …, "arguments": {…}}</tool_call>` (Hermes, Qwen 2.5 and 3).
    case hermesJSON
    /// `<tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>` (Qwen3-Coder, Qwen 3.5+).
    case qwenXML
    /// A bare `{"name": …, "parameters": {…}}` as the whole reply (Llama 3.1/3.2).
    case bareJSON
    /// gpt-oss's channels: `<|channel|>commentary to=functions.NAME<|message|>{…}<|call|>`.
    case harmony
    /// `<|tool_call>call:NAME{key:<|"|>text<|"|>,n:1}<tool_call|>`: Gemma 4's own notation (`Gemma4Arguments`).
    case gemma4
    case none

    static func detect(template: String) -> ToolCallFormat {
        // What llama.cpp looks for too (b11081 chat.cpp).
        if template.contains("'<|tool_call>call:'") {
            return .gemma4
        }
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

    private let openTag: String
    private let closeTag: String
    /// Whether the newline a model writes before a call is layout, not content. llama-server keeps
    /// Gemma 4's (checked on real output), so it's kept there too.
    private let trimsLayoutBeforeCall: Bool

    init(format: ToolCallFormat, tools: [Value]) {
        self.format = format
        (openTag, closeTag) = format == .gemma4 ? ("<|tool_call>", "<tool_call|>") : ("<tool_call>", "</tool_call>")
        trimsLayoutBeforeCall = format != .gemma4
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
                if let range = pending.range(of: openTag) {
                    content(String(pending[..<range.lowerBound])
                        .trimmingTrailingWhitespace(whenCallFollows: trimsLayoutBeforeCall))
                    pending = String(pending[range.upperBound...])
                    state = .inCall
                    continue loop
                }
                // Hold back what could still be the start of a call: a partial tag, and the whitespace
                // in front of it (the layout newline before a call isn't content).
                var hold = 0
                if !final {
                    let partial = Self.partialSuffixLength(of: pending, for: openTag)
                    let head = pending.dropLast(partial)
                    let whitespace = head.count
                        - head.trimmingTrailingWhitespace(whenCallFollows: trimsLayoutBeforeCall).count
                    hold = partial + whitespace
                }
                content(String(pending.dropLast(hold)))
                pending = String(pending.suffix(hold))
                break loop
            case .inCall:
                if let range = closeTagRange(in: pending) {
                    let body = String(pending[..<range.lowerBound])
                    pending = String(pending[range.upperBound...])
                    state = .text
                    if let call = parseTagged(body) {
                        out.append(.toolCall(call))
                        // Whitespace between consecutive calls isn't content.
                        pending = String(pending.drop(while: { $0.isWhitespace }))
                    } else {
                        content(openTag + body + closeTag)
                    }
                    continue loop
                }
                if final {
                    content(openTag + pending) // cut off mid-call: it was never a call
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

    /// Where the call ends. Gemma 4's strings are written raw between `<|"|>` marks, so one could hold
    /// the closing tag's text; only a tag outside them counts.
    private func closeTagRange(in text: String) -> Range<String.Index>? {
        guard format == .gemma4 else { return text.range(of: closeTag) }
        var from = text.startIndex
        while true {
            let close = text.range(of: closeTag, range: from ..< text.endIndex)
            guard let quote = text.range(of: Gemma4Arguments.quote, range: from ..< text.endIndex),
                  close.map({ quote.lowerBound < $0.lowerBound }) ?? true
            else { return close }
            guard let end = text.range(of: Gemma4Arguments.quote, range: quote.upperBound ..< text.endIndex)
            else { return nil } // inside a string that hasn't ended yet
            from = end.upperBound
        }
    }

    // MARK: Parsing

    private func parseTagged(_ body: String) -> ParsedToolCall? {
        switch format {
        case .hermesJSON: Self.callFromJSON(body, allowed: toolNames)
        case .qwenXML: parseXML(body)
        case .gemma4: parseGemma4(body)
        default: nil
        }
    }

    /// `call:NAME{…}`, the arguments in Gemma 4's notation, written out as compact JSON (as llama-server does).
    private func parseGemma4(_ body: String) -> ParsedToolCall? {
        var text = Substring(body).drop(while: { $0.isWhitespace })
        guard text.hasPrefix("call:"), let brace = text.firstIndex(of: "{") else { return nil }
        let name = text[text.index(text.startIndex, offsetBy: 5) ..< brace].trimmingCharacters(in: .whitespaces)
        guard toolNames.contains(name) else { return nil }
        text = text[brace...]
        guard let arguments = Gemma4Arguments.parse(&text), case .object = arguments,
              text.allSatisfy(\.isWhitespace),
              let json = try? OrderedJSON.serialize(arguments)
        else { return nil }
        return ParsedToolCall(name: name, arguments: json)
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

/// Gemma 4's notation for a call's arguments, which its template writes and the model copies: JSON with
/// bare keys and strings between `<|"|>` marks, nothing escaped inside them. Numbers, `true`, `false` and
/// `null` are JSON's. Read leniently where it costs nothing: a key or string may also be quoted either way.
enum Gemma4Arguments {
    static let quote = "<|\"|>"

    /// One value from the start of `text`, which is left just after it; nil if it isn't well formed.
    static func parse(_ text: inout Substring, depth: Int = 0) -> Value? {
        guard depth < OrderedJSON.maxDepth else { return nil }
        text = text.drop(while: { $0.isWhitespace })
        if let string = quoted(&text) {
            return .string(string)
        }
        if take("{", from: &text) {
            var members = OrderedDictionary<ObjectKey, Value>()
            if take("}", from: &text) {
                return .object(members)
            }
            repeat {
                text = text.drop(while: { $0.isWhitespace })
                guard let key = quoted(&text) ?? bareKey(&text) else { return nil }
                text = text.drop(while: { $0.isWhitespace })
                guard take(":", from: &text), let value = parse(&text, depth: depth + 1) else { return nil }
                members[.string(key)] = value
            } while take(",", from: &text)
            return take("}", from: &text) ? .object(members) : nil
        }
        if take("[", from: &text) {
            var items: [Value] = []
            if take("]", from: &text) {
                return .array(items)
            }
            repeat {
                guard let item = parse(&text, depth: depth + 1) else { return nil }
                items.append(item)
            } while take(",", from: &text)
            return take("]", from: &text) ? .array(items) : nil
        }
        let token = text.prefix(while: { !$0.isWhitespace && !",}]".contains($0) })
        guard let scalar = try? OrderedJSON.parse(String(token)) else { return nil }
        text = text.dropFirst(token.count)
        return scalar
    }

    /// Skips whitespace, then `mark` if it's next.
    private static func take(_ mark: Character, from text: inout Substring) -> Bool {
        text = text.drop(while: { $0.isWhitespace })
        guard text.first == mark else { return false }
        text = text.dropFirst()
        return true
    }

    /// `<|"|>text<|"|>`, or a JSON string.
    private static func quoted(_ text: inout Substring) -> String? {
        if text.hasPrefix(quote) {
            let inner = text.dropFirst(quote.count)
            guard let end = inner.range(of: quote) else { return nil }
            text = inner[end.upperBound...]
            return String(inner[..<end.lowerBound])
        }
        guard text.first == "\"" else { return nil }
        var escaped = false
        for index in text.indices.dropFirst() {
            if escaped {
                escaped = false
            } else if text[index] == "\\" {
                escaped = true
            } else if text[index] == "\"" {
                let end = text.index(after: index)
                guard let string = try? OrderedJSON.parse(String(text[..<end])).stringValue else { return nil }
                text = text[end...]
                return string
            }
        }
        return nil
    }

    /// A key as the template writes it: everything up to the colon (llama.cpp reads `[^:}]+`).
    private static func bareKey(_ text: inout Substring) -> String? {
        let key = text.prefix(while: { $0 != ":" && $0 != "}" && $0 != "," })
        let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        text = text.dropFirst(key.count)
        return name
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
