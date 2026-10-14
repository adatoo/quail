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
    /// Muse Glimmer's messages: `<|start|>assistant to=NAME<|message|><atem:function_calls>…` (`MuseGlimmerParser`).
    case museGlimmer
    /// `<|tool_call_start|>[NAME(key='text', n=1), …]<|tool_call_end|>`: Python calls (LFM2, LFM2.5; `PythonicCalls`).
    case pythonic
    /// `<function name="NAME"><param name="KEY">VALUE</param></function>`, untagged, a value with `<`, `&` or a
    /// newline in a CDATA section (MiniCPM5).
    case minicpmXML
    case none

    /// A family whose whole reply is read by its own parser (`ChatOutputParser`), reasoning included.
    var hasOwnParser: Bool {
        self == .harmony || self == .museGlimmer
    }

    static func detect(template: String) -> ToolCallFormat {
        // What llama.cpp looks for too (b11081 chat.cpp).
        if template.contains("'<|tool_call>call:'") {
            return .gemma4
        }
        if template.contains("<|channel|>"), template.contains("commentary") {
            return .harmony
        }
        if template.contains("<atem:function_calls>"), template.contains("to=self") {
            return .museGlimmer
        }
        if template.contains("<|tool_call_start|>") {
            return .pythonic
        }
        if template.contains("<function name=\"") {
            return .minicpmXML
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
    /// Right after a call: whitespace before the next call (or the end) isn't content, however it arrives.
    private var afterCall = false

    private let openTag: String
    private let closeTag: String
    /// Whether the newline a model writes before a call is layout, not content. llama-server keeps
    /// Gemma 4's and MiniCPM5's (checked on real output), so it's kept there too.
    private let trimsLayoutBeforeCall: Bool

    init(format: ToolCallFormat, tools: [Value]) {
        self.format = format
        (openTag, closeTag) = switch format {
        case .gemma4: ("<|tool_call>", "<tool_call|>")
        case .pythonic: ("<|tool_call_start|>", "<|tool_call_end|>")
        // The tag's start is the call's start: the rest of it, `NAME">`, is read with the body.
        case .minicpmXML: (Self.minicpmOpen, "</function>")
        default: ("<tool_call>", "</tool_call>")
        }
        trimsLayoutBeforeCall = format != .gemma4 && format != .minicpmXML
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
        guard isActive, !format.hasOwnParser else { return text.isEmpty ? [] : [.content(text)] }
        pending += text
        return drain(final: false)
    }

    mutating func flush() -> [ChatDelta] {
        guard isActive, !format.hasOwnParser else { return [] }
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
                if afterCall {
                    let rest = pending.drop(while: { $0.isWhitespace })
                    if rest.isEmpty {
                        if final {
                            pending = ""
                        }
                        break loop
                    }
                    pending = String(rest)
                    afterCall = false
                }
                if format == .bareJSON {
                    if !sawContent {
                        let body = pending.drop(while: { $0.isWhitespace })
                        if body.isEmpty {
                            if final {
                                content(pending); pending = ""
                            }
                            break loop
                        }
                        if body.hasPrefix("{") || body.hasPrefix(Self.pythonTag) {
                            state = .bareCandidate
                            continue loop
                        }
                        // The tag may still be arriving.
                        if !final, Self.pythonTag.hasPrefix(String(body)) {
                            break loop
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
                    if let calls = parseTagged(body) {
                        out += calls.map { .toolCall($0) }
                        afterCall = true
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
                if let calls = parseBare(pending) {
                    out += calls.map { .toolCall($0) }
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

    /// Where the call ends. Gemma 4's strings are written raw between `<|"|>` marks, and MiniCPM5's values
    /// in CDATA sections, so one could hold the closing tag's text; only a tag outside them counts.
    private func closeTagRange(in text: String) -> Range<String.Index>? {
        let quotes: (open: String, close: String)
        switch format {
        case .gemma4: quotes = (Gemma4Arguments.quote, Gemma4Arguments.quote)
        case .minicpmXML: quotes = (Self.cdataOpen, Self.cdataClose)
        default: return text.range(of: closeTag)
        }
        var from = text.startIndex
        while true {
            let close = text.range(of: closeTag, range: from ..< text.endIndex)
            guard let quote = text.range(of: quotes.open, range: from ..< text.endIndex),
                  close.map({ quote.lowerBound < $0.lowerBound }) ?? true
            else { return close }
            guard let end = text.range(of: quotes.close, range: quote.upperBound ..< text.endIndex)
            else { return nil } // inside a string that hasn't ended yet
            from = end.upperBound
        }
    }

    // MARK: Parsing

    /// The calls in one tagged block, or `nil` when it isn't a well-formed call to an offered tool.
    private func parseTagged(_ body: String) -> [ParsedToolCall]? {
        switch format {
        case .hermesJSON: Self.callFromJSON(body, allowed: toolNames).map { [$0] }
        case .qwenXML: parseXML(body)
        case .gemma4: parseGemma4(body).map { [$0] }
        case .pythonic: parsePythonic(body)
        case .minicpmXML: parseMiniCPM(body).map { [$0] }
        default: nil
        }
    }

    /// The list in `<|tool_call_start|>[…]<|tool_call_end|>`: Python calls with keyword arguments, or JSON
    /// calls (`{"name": …, "arguments": …}`, alone or in a list), which LFM2 writes when a system prompt asks.
    private func parsePythonic(_ body: String) -> [ParsedToolCall]? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            return Self.callFromJSON(text, allowed: toolNames, coercingTo: schemas).map { [$0] }
        }
        if text.hasPrefix("["), text.dropFirst().drop(while: { $0.isWhitespace }).hasPrefix("{") {
            guard case let .array(items)? = try? OrderedJSON.parse(text), !items.isEmpty else { return nil }
            var calls: [ParsedToolCall] = []
            for item in items {
                guard let json = try? OrderedJSON.serialize(item),
                      let call = Self.callFromJSON(json, allowed: toolNames, coercingTo: schemas)
                else { return nil }
                calls.append(call)
            }
            return calls
        }
        guard let parsed = PythonicCalls.parse(text), !parsed.isEmpty else { return nil }
        var calls: [ParsedToolCall] = []
        for (name, arguments) in parsed {
            guard toolNames.contains(name) else { return nil }
            var members = arguments
            for (key, member) in members {
                guard case let .string(parameter) = key else { continue }
                if case let .string(raw) = member {
                    members[key] = Self.typed(raw, as: schemas[name]?[parameter])
                } else {
                    members[key] = Self.narrowed(member, to: schemas[name]?[parameter])
                }
            }
            guard let json = try? OrderedJSON.serialize(.object(members)) else { return nil }
            calls.append(ParsedToolCall(name: name, arguments: json))
        }
        return calls
    }

    static let minicpmOpen = "<function name=\""
    static let cdataOpen = "<![CDATA["
    static let cdataClose = "]]>"

    /// `NAME">` then `<param name="KEY">VALUE</param>` blocks, the rest of a call after `<function name="`.
    /// A value is the text as written (or a CDATA section's), typed by the tool's schema as `qwenXML`'s are.
    private func parseMiniCPM(_ body: String) -> ParsedToolCall? {
        guard let nameEnd = body.range(of: "\">") else { return nil }
        let name = String(body[..<nameEnd.lowerBound])
        guard toolNames.contains(name) else { return nil }
        var arguments = OrderedDictionary<ObjectKey, Value>()
        var rest = body[nameEnd.upperBound...]
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            if rest.isEmpty {
                break
            }
            guard rest.hasPrefix("<param name=\""),
                  let keyEnd = rest.range(of: "\">")
            else { return nil }
            let key = String(rest[rest.index(rest.startIndex, offsetBy: 13) ..< keyEnd.lowerBound])
            rest = rest[keyEnd.upperBound...]
            let raw: String
            if rest.hasPrefix(Self.cdataOpen) {
                let inner = rest.dropFirst(Self.cdataOpen.count)
                guard let end = inner.range(of: Self.cdataClose) else { return nil }
                raw = String(inner[..<end.lowerBound])
                rest = inner[end.upperBound...]
                guard rest.hasPrefix("</param>") else { return nil }
            } else {
                guard let end = rest.range(of: "</param>") else { return nil }
                raw = String(rest[..<end.lowerBound])
                rest = rest[end.lowerBound...]
            }
            rest = rest.dropFirst("</param>".count)
            arguments[.string(key)] = Self.typed(raw, as: schemas[name]?[key])
        }
        guard let json = try? OrderedJSON.serialize(.object(arguments)) else { return nil }
        return ParsedToolCall(name: name, arguments: json)
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

    /// Llama 3.1 marks a call with `<|python_tag|>` and writes several as JSON objects joined by `;`:
    /// `<|python_tag|>{"name": "f", "parameters": {…}}; {"name": "f", …}`. Every one must be a call.
    static let pythonTag = "<|python_tag|>"

    private func parseBare(_ text: String) -> [ParsedToolCall]? {
        var rest = Substring(text).drop(while: { $0.isWhitespace })
        if rest.hasPrefix(Self.pythonTag) {
            rest = rest.dropFirst(Self.pythonTag.count)
        }
        var calls: [ParsedToolCall] = []
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            guard let object = Self.jsonObjectPrefix(of: rest),
                  let call = Self.callFromJSON(String(object), allowed: toolNames, coercingTo: schemas)
            else { return nil }
            calls.append(call)
            rest = rest[object.endIndex...].drop(while: { $0.isWhitespace })
            if rest.isEmpty {
                return calls
            }
            guard rest.first == ";" else { return nil }
            rest = rest.dropFirst()
        }
    }

    /// The balanced `{…}` at the start of `text`, strings and their escapes respected.
    static func jsonObjectPrefix(of text: Substring) -> Substring? {
        guard text.first == "{" else { return nil }
        var depth = 0, inString = false, escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 {
                    return text[...index]
                }
            default: break
            }
        }
        return nil
    }

    /// `{"name": "f", "arguments": {…}}` (Hermes) or `"parameters"` (Llama 3); `arguments` may itself
    /// be a JSON string. The name must be one of the tools the request offered.
    ///
    /// With `schemas`, a value written as a string where the tool's schema asks for another type is read
    /// as that type, as `qwenXML` reads its values: Llama 3.1 writes `"base": "10"` for an integer.
    static func callFromJSON(
        _ text: String, allowed: Set<String>, coercingTo schemas: [String: [String: String]]? = nil
    ) -> ParsedToolCall? {
        guard let value = try? OrderedJSON.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let name = value["name"]?.stringValue, allowed.contains(name)
        else { return nil }
        var arguments = value["arguments"] ?? value["parameters"] ?? .object([:])
        if let string = arguments.stringValue {
            guard (try? OrderedJSON.parse(string)) != nil else { return nil }
            return ParsedToolCall(name: name, arguments: string)
        }
        guard case var .object(members) = arguments else { return nil }
        if let types = schemas?[name] {
            for (key, member) in members {
                if case let .string(parameter) = key, case let .string(raw) = member {
                    members[key] = typed(raw, as: types[parameter])
                }
            }
            arguments = .object(members)
        }
        guard let json = try? OrderedJSON.serialize(arguments, spaced: true) else { return nil }
        return ParsedToolCall(name: name, arguments: json)
    }

    /// Each `<function=NAME>…</function>` in the block: one or more, as some models put several calls in one
    /// `<tool_call>`. Anything else in the block but whitespace makes it not a call.
    private func parseXML(_ body: String) -> [ParsedToolCall]? {
        var calls: [ParsedToolCall] = []
        var rest = Substring(body)
        while let open = rest.range(of: "<function=") {
            guard rest[..<open.lowerBound].allSatisfy(\.isWhitespace),
                  let close = rest.range(of: "</function>", range: open.upperBound ..< rest.endIndex),
                  let call = parseFunction(rest[open.lowerBound ..< close.upperBound])
            else { return nil }
            calls.append(call)
            rest = rest[close.upperBound...]
        }
        guard !calls.isEmpty, rest.allSatisfy(\.isWhitespace) else { return nil }
        return calls
    }

    /// `<function=NAME>` then `<parameter=KEY>` blocks; a value is a string unless the tool's schema
    /// says otherwise and it parses as that. A body that is a JSON object instead (MiMo V2.6 writes
    /// `<function=f>{"a": 1}</function>`) is the arguments as written.
    private func parseFunction(_ block: Substring) -> ParsedToolCall? {
        let body = String(block)
        guard let open = body.range(of: "<function="),
              let nameEnd = body.range(of: ">", range: open.upperBound ..< body.endIndex),
              let close = body.range(of: "</function>", range: nameEnd.upperBound ..< body.endIndex)
        else { return nil }
        let name = String(body[open.upperBound ..< nameEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard toolNames.contains(name) else { return nil }

        let inner = body[nameEnd.upperBound ..< close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasPrefix("{"), !inner.contains("<parameter=") {
            guard let value = try? OrderedJSON.parse(inner), case .object = value,
                  let json = try? OrderedJSON.serialize(value) else { return nil }
            return ParsedToolCall(name: name, arguments: json)
        }

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
            arguments[.string(key)] = Self.typed(raw, as: schemas[name]?[key])
            rest = rest[end.upperBound...]
        }
        guard let json = try? OrderedJSON.serialize(.object(arguments)) else { return nil }
        return ParsedToolCall(name: name, arguments: json)
    }

    /// `raw` as the schema's `type`: a string unless the type is another and `raw` parses (as JSON, or as
    /// Python's literals) to a value.
    private static func typed(_ raw: String, as type: String?) -> Value {
        if type == "string" || type == nil {
            return .string(raw)
        }
        if let value = try? OrderedJSON.parse(raw) {
            return narrowed(value, to: type)
        }
        // MiniCPM5 writes a list or dict parameter as Python: `['a', 'b']`, `{'min': 1.0}`. llama-server reads
        // them as JSON's, as its grammar would have had them written.
        let trimmed = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.first == "[" || trimmed.first == "{" {
            var rest = trimmed
            if let value = PythonicCalls.value(&rest, depth: 0), rest.allSatisfy(\.isWhitespace) {
                return value
            }
        }
        // Qwen writes Python's True, False and None as often as JSON's. llama-server never sees them: its grammar
        // holds a typed parameter to JSON. The schema says what was meant, so read them as it does.
        switch (raw.trimmingCharacters(in: .whitespacesAndNewlines), type) {
        case ("True", "boolean"): return .boolean(true)
        case ("False", "boolean"): return .boolean(false)
        case ("None", _): return .null
        default: return .string(raw)
        }
    }

    /// A whole number written with a decimal point (`40.0`) for an integer parameter is that integer, as
    /// llama-server reads it.
    static func narrowed(_ value: Value, to type: String?) -> Value {
        if type == "integer", case let .double(number) = value, number.rounded() == number, abs(number) < 1e15 {
            return .int(Int(number))
        }
        return value
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

/// LFM2's calls: a Python list of calls with keyword arguments, `[f(city='Paris', days=3), g()]`. Its template
/// writes a string argument in single quotes, escaped as Python does, and anything else as JSON, so a value is
/// read as a Python literal: a quoted string (either quote), a number, `True`/`False`/`None` (or JSON's spelling),
/// or a list or dict of them. The list's brackets may be left out.
enum PythonicCalls {
    /// Each call's name and arguments, in order; nil unless the whole text is calls.
    static func parse(_ text: String) -> [(name: String, arguments: OrderedDictionary<ObjectKey, Value>)]? {
        var rest = Substring(text).drop(while: { $0.isWhitespace })
        let bracketed = take("[", from: &rest)
        var calls: [(name: String, arguments: OrderedDictionary<ObjectKey, Value>)] = []
        repeat {
            rest = rest.drop(while: { $0.isWhitespace })
            let name = rest.prefix(while: { $0.isLetter || $0.isNumber || "_.-".contains($0) })
            guard !name.isEmpty else { return nil }
            rest = rest.dropFirst(name.count)
            guard take("(", from: &rest) else { return nil }
            var arguments = OrderedDictionary<ObjectKey, Value>()
            if !take(")", from: &rest) {
                repeat {
                    rest = rest.drop(while: { $0.isWhitespace })
                    let key = rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
                    guard !key.isEmpty else { return nil }
                    rest = rest.dropFirst(key.count)
                    guard take("=", from: &rest), let value = value(&rest, depth: 0) else { return nil }
                    arguments[.string(String(key))] = value
                } while take(",", from: &rest)
                guard take(")", from: &rest) else {
                    return nil
                }
            }
            calls.append((String(name), arguments))
        } while take(",", from: &rest)
        if bracketed, !take("]", from: &rest) {
            return nil
        }
        return rest.allSatisfy(\.isWhitespace) ? calls : nil
    }

    /// One Python literal from the start of `text`, which is left just after it.
    static func value(_ text: inout Substring, depth: Int) -> Value? {
        guard depth < OrderedJSON.maxDepth else { return nil }
        text = text.drop(while: { $0.isWhitespace })
        guard let first = text.first else { return nil }
        if first == "'" || first == "\"" {
            return string(&text).map { .string($0) }
        }
        if take("[", from: &text) {
            var items: [Value] = []
            if take("]", from: &text) {
                return .array(items)
            }
            repeat {
                if !items.isEmpty, peek("]", in: text) {
                    break // a trailing comma
                }
                guard let item = value(&text, depth: depth + 1) else { return nil }
                items.append(item)
            } while take(",", from: &text)
            return take("]", from: &text) ? .array(items) : nil
        }
        if take("{", from: &text) {
            var members = OrderedDictionary<ObjectKey, Value>()
            if take("}", from: &text) {
                return .object(members)
            }
            repeat {
                if !members.isEmpty, peek("}", in: text) {
                    break
                }
                text = text.drop(while: { $0.isWhitespace })
                guard let key = string(&text), take(":", from: &text),
                      let member = value(&text, depth: depth + 1)
                else { return nil }
                members[.string(key)] = member
            } while take(",", from: &text)
            return take("}", from: &text) ? .object(members) : nil
        }
        let token = text.prefix(while: { $0.isLetter || $0.isNumber || "+-.".contains($0) })
        let scalar: Value? = switch token {
        case "True", "true": .boolean(true)
        case "False", "false": .boolean(false)
        case "None", "null": .null
        default: try? OrderedJSON.parse(String(token))
        }
        guard let scalar else { return nil }
        text = text.dropFirst(token.count)
        return scalar
    }

    /// A string in single or double quotes, with Python's escapes.
    private static func string(_ text: inout Substring) -> String? {
        guard let quote = text.first, quote == "'" || quote == "\"" else { return nil }
        var result = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == quote {
                text = text[text.index(after: index)...]
                return result
            }
            if character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { return nil }
                switch text[index] {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "0": result.append("\0")
                case "u":
                    let digits = text[text.index(after: index)...].prefix(4)
                    guard digits.count == 4, let code = UInt32(digits, radix: 16),
                          let scalar = Unicode.Scalar(code) else { return nil }
                    result.unicodeScalars.append(scalar)
                    index = text.index(index, offsetBy: 4)
                default: result.append(text[index]) // \\, \', \" and anything else: the character itself
                }
            } else {
                result.append(character)
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Skips whitespace, then `mark` if it's next.
    private static func take(_ mark: Character, from text: inout Substring) -> Bool {
        text = text.drop(while: { $0.isWhitespace })
        guard text.first == mark else { return false }
        text = text.dropFirst()
        return true
    }

    private static func peek(_ mark: Character, in text: Substring) -> Bool {
        text.drop(while: { $0.isWhitespace }).first == mark
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
