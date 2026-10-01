import Foundation
import Jinja
import OrderedCollections

/// Reads Muse Glimmer's replies: a run of messages, each `<|start|>assistant to=RECIPIENT<|message|>BODY` ended by
/// `<|eom|>` (more to come) or `<|eot|>` (end of turn). The generation prompt already wrote the first
/// `<|start|>assistant`, so a reply starts in that message's header. `to=self` is the model's reasoning, `to=user`
/// (or no recipient) the answer, and `to=NAME` a tool call whose body is an ATEM block:
///
///     <atem:function_calls>
///     <atem:invoke name="NAME">
///     <atem:parameter name="KEY">VALUE</atem:parameter>
///     </atem:invoke>
///     </atem:function_calls>
///
/// Values aren't escaped, and may run over several lines: a string parameter is taken exactly as written, anything
/// else the tool's schema types is read as JSON. Only the protocol's own tags are structural, as in mlx-swift-lm's
/// `ATEMToolCallParser` (0dcfe2f8a) and Meta's chat template. A call that doesn't parse, or names a tool the request
/// didn't offer, is given back as content.
///
/// This relies on the engine decoding the format's special tokens into the text, as llama.cpp does.
struct MuseGlimmerParser: Sendable {
    private enum Kind: Equatable {
        case reasoning
        case content
        case call
    }

    private enum State: Equatable {
        case header
        case body(Kind)
    }

    private static let start = "<|start|>", message = "<|message|>", endOfMessage = "<|eom|>", endOfTurn = "<|eot|>"
    private static let tags = [start, message, endOfMessage, endOfTurn]

    /// Tool name → parameter name → its schema's JSON types.
    private let schemas: [String: [String: Set<String>]]
    private var state = State.header
    private var pending = ""
    private var header = ""
    private var body = ""

    init(tools: [Value]) {
        var schemas: [String: [String: Set<String>]] = [:]
        for tool in tools {
            guard let name = tool["function"]?["name"]?.stringValue else { continue }
            var types: [String: Set<String>] = [:]
            if case let .object(properties)? = tool["function"]?["parameters"]?["properties"] {
                for (key, value) in properties {
                    guard case let .string(parameter) = key else { continue }
                    if let type = value["type"]?.stringValue {
                        types[parameter] = [type]
                    } else if let list = value["type"]?.arrayValue {
                        types[parameter] = Set(list.compactMap(\.stringValue))
                    }
                }
            }
            schemas[name] = types
        }
        self.schemas = schemas
    }

    mutating func push(_ text: String) -> [ChatDelta] {
        pending += text
        return drain(final: false)
    }

    mutating func flush() -> [ChatDelta] {
        var out = drain(final: true)
        out += finishMessage()
        // A reply cut off in a header wrote no message: whatever it wrote is the answer.
        if state == .header, !Self.looksLikeHeader(header) {
            out.append(.content(header))
        }
        state = .header
        header = ""
        return Self.merged(out)
    }

    // MARK: State machine

    private mutating func drain(final: Bool) -> [ChatDelta] {
        var out: [ChatDelta] = []
        while true {
            var found: (tag: String, range: Range<String.Index>)?
            for tag in Self.tags {
                if let range = pending.range(of: tag), found == nil || range.lowerBound < found!.range.lowerBound {
                    found = (tag, range)
                }
            }
            if let (tag, range) = found {
                out += consume(String(pending[..<range.lowerBound]))
                pending = String(pending[range.upperBound...])
                out += handle(tag)
                continue
            }
            let hold = final ? 0 : Self.partialSuffixLength(of: pending)
            out += consume(String(pending.dropLast(hold)))
            pending = String(pending.suffix(hold))
            return Self.merged(out)
        }
    }

    private mutating func consume(_ text: String) -> [ChatDelta] {
        guard !text.isEmpty else { return [] }
        switch state {
        case .header:
            header += text
            return []
        case .body(.reasoning):
            return [.reasoning(text)]
        case .body(.content):
            return [.content(text)]
        case .body(.call):
            body += text
            return []
        }
    }

    private mutating func handle(_ tag: String) -> [ChatDelta] {
        switch tag {
        case Self.message:
            guard state == .header else {
                return consume(tag) // a stray tag inside a body is part of it
            }
            state = .body(kind(forHeader: header))
            header = ""
            body = ""
            return []
        default: // start, eom, eot
            let out = finishMessage()
            state = .header
            header = ""
            return out
        }
    }

    /// The end of a message: a call's body is parsed now that it's whole.
    private mutating func finishMessage() -> [ChatDelta] {
        guard case .body(.call) = state else { return [] }
        defer { body = "" }
        if let calls = parseCalls(body) {
            return calls.map { .toolCall($0) }
        }
        return body.isEmpty ? [] : [.content(body)]
    }

    private func kind(forHeader header: String) -> Kind {
        let words = header.split(whereSeparator: \.isWhitespace)
        guard let recipient = words.first(where: { $0.hasPrefix("to=") })?.dropFirst(3) else { return .content }
        switch recipient {
        case "self": return .reasoning
        case "user": return .content
        default: return .call
        }
    }

    private static func looksLikeHeader(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "assistant" || trimmed.hasPrefix("to=")
            || trimmed.hasPrefix("assistant to=")
    }

    // MARK: ATEM

    private static let callsOpen = "<atem:function_calls>", callsClose = "</atem:function_calls>"
    private static let invokeOpen = "<atem:invoke", invokeClose = "</atem:invoke>"
    private static let parameterOpen = "<atem:parameter", parameterClose = "</atem:parameter>"

    /// Every invoke in a message's `<atem:function_calls>` block, or nil if any of it isn't a call to one of the
    /// request's tools.
    private func parseCalls(_ text: String) -> [ParsedToolCall]? {
        guard let open = text.range(of: Self.callsOpen),
              let close = text.range(of: Self.callsClose, options: .backwards),
              open.upperBound <= close.lowerBound,
              text[..<open.lowerBound].allSatisfy(\.isWhitespace),
              text[close.upperBound...].allSatisfy(\.isWhitespace)
        else { return nil }
        var rest = text[open.upperBound ..< close.lowerBound]
        var calls: [ParsedToolCall] = []
        while let invoke = Self.element(Self.invokeOpen, closing: Self.invokeClose, in: rest) {
            guard rest[..<invoke.whole.lowerBound].allSatisfy(\.isWhitespace),
                  let name = Self.attribute("name", in: invoke.openTag), let parameters = schemas[name],
                  let arguments = arguments(invoke.body, schema: parameters)
            else { return nil }
            calls.append(ParsedToolCall(name: name, arguments: arguments))
            rest = rest[invoke.whole.upperBound...]
        }
        guard !calls.isEmpty, rest.allSatisfy(\.isWhitespace) else { return nil }
        return calls
    }

    private func arguments(_ text: Substring, schema: [String: Set<String>]) -> String? {
        var members = OrderedDictionary<ObjectKey, Value>()
        var rest = text
        while let parameter = Self.element(Self.parameterOpen, closing: Self.parameterClose, in: rest) {
            guard rest[..<parameter.whole.lowerBound].allSatisfy(\.isWhitespace),
                  let key = Self.attribute("name", in: parameter.openTag), members[.string(key)] == nil
            else { return nil }
            members[.string(key)] = Self.value(String(parameter.body), types: schema[key])
            rest = rest[parameter.whole.upperBound...]
        }
        guard rest.allSatisfy(\.isWhitespace) else { return nil }
        return try? OrderedJSON.serialize(.object(members))
    }

    /// A string parameter as written, spaces and all (the template says they aren't stripped); a typed one as JSON
    /// when it reads as JSON, else as the text it is.
    private static func value(_ raw: String, types: Set<String>?) -> Value {
        guard let types, !types.subtracting(["null"]).isSubset(of: ["string"]) else { return .string(raw) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? OrderedJSON.parse(trimmed)) ?? .string(raw)
    }

    /// The first `<prefix …>body</closing>` in `text`, where `prefix` is followed by a space or `>`.
    private static func element(
        _ prefix: String, closing: String, in text: Substring
    ) -> (whole: Range<String.Index>, openTag: Substring, body: Substring)? {
        var from = text.startIndex
        while let candidate = text.range(of: prefix, range: from ..< text.endIndex) {
            from = candidate.upperBound
            guard candidate.upperBound < text.endIndex,
                  text[candidate.upperBound].isWhitespace || text[candidate.upperBound] == ">"
            else { continue }
            guard let tagEnd = text[candidate.upperBound...].firstIndex(of: ">"),
                  let end = text.range(of: closing, range: text.index(after: tagEnd) ..< text.endIndex)
            else { return nil }
            return (
                candidate.lowerBound ..< end.upperBound,
                text[candidate.lowerBound ... tagEnd],
                text[text.index(after: tagEnd) ..< end.lowerBound]
            )
        }
        return nil
    }

    /// `name="value"` (or single quotes) in a tag.
    private static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let key = tag.range(of: " \(name)="), key.upperBound < tag.endIndex else { return nil }
        let quote = tag[key.upperBound]
        guard quote == "\"" || quote == "'" else { return nil }
        let valueStart = tag.index(after: key.upperBound)
        guard let valueEnd = tag[valueStart...].firstIndex(of: quote) else { return nil }
        let value = String(tag[valueStart ..< valueEnd])
        return value.isEmpty ? nil : value
    }

    // MARK: Helpers

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
