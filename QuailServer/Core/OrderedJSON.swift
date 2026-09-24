import Foundation
import Jinja

/// A JSON parser that keeps object keys in the order they were sent.
///
/// `JSONSerialization` and `JSONDecoder` both sort or scramble keys, and a chat template
/// prints a tool's JSON schema into the prompt: `properties` reordered means a different
/// prompt from the one llama.cpp builds, and a model that answers a little worse for no
/// visible reason (ADR D-027). Parsing into Jinja's own `Value` also means a request body can
/// go straight into a template, with no conversion step to reorder anything.
///
/// Strict RFC 8259: no comments, no trailing commas, no NaN or Infinity, valid UTF-8 only.
/// A repeated key keeps its first position and its last value, like a Python `dict`.
enum OrderedJSON {
    struct ParseError: Error, Equatable, LocalizedError {
        let message: String
        let offset: Int

        var errorDescription: String? {
            "invalid JSON at byte \(offset): \(message)"
        }
    }

    /// Nesting past this is refused, so a hostile body can't exhaust the stack.
    static let maxDepth = 256

    static func parse(_ data: Data) throws -> Value {
        var parser = Parser(bytes: Array(data))
        return try parser.parseDocument()
    }

    static func parse(_ text: String) throws -> Value {
        try parse(Data(text.utf8))
    }

    /// `json.dumps` formatting (what Jinja's `tojson` writes), without escaping non-ASCII.
    static func serialize(_ value: Value) throws -> String {
        try JSON.dumps(value, options: .init(ensureASCII: false, separators: (",", ":")))
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func parseDocument() throws -> Value {
            skipWhitespace()
            let value = try parseValue(depth: 0)
            skipWhitespace()
            if position < bytes.count {
                throw fail("unexpected data after the JSON value")
            }
            return value
        }

        private func fail(_ message: String) -> ParseError {
            ParseError(message: message, offset: position)
        }

        private mutating func skipWhitespace() {
            while position < bytes.count {
                switch bytes[position] {
                case 0x20, 0x09, 0x0A, 0x0D: position += 1
                default: return
                }
            }
        }

        private mutating func parseValue(depth: Int) throws -> Value {
            guard depth <= OrderedJSON.maxDepth else { throw fail("nested more than \(OrderedJSON.maxDepth) levels") }
            guard position < bytes.count else { throw fail("unexpected end of input") }
            switch bytes[position] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return try .string(parseString())
            case UInt8(ascii: "t"): try expect("true"); return .boolean(true)
            case UInt8(ascii: "f"): try expect("false"); return .boolean(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"): return try parseNumber()
            default: throw fail("unexpected character")
            }
        }

        private mutating func expect(_ word: String) throws {
            let literal = Array(word.utf8)
            guard position + literal.count <= bytes.count,
                  Array(bytes[position ..< position + literal.count]) == literal
            else { throw fail("expected \(word)") }
            position += literal.count
        }

        private mutating func parseObject(depth: Int) throws -> Value {
            position += 1 // {
            var object = OrderedDictionary<ObjectKey, Value>()
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
                position += 1
                return .object(object)
            }
            while true {
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else {
                    throw fail("expected a string key")
                }
                let key = try parseString()
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                position += 1
                skipWhitespace()
                object[.string(key)] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard position < bytes.count else { throw fail("unterminated object") }
                if bytes[position] == UInt8(ascii: ",") {
                    position += 1
                } else if bytes[position] == UInt8(ascii: "}") {
                    position += 1
                    return .object(object)
                } else {
                    throw fail("expected ',' or '}'")
                }
            }
        }

        private mutating func parseArray(depth: Int) throws -> Value {
            position += 1 // [
            var items: [Value] = []
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
                position += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                try items.append(parseValue(depth: depth + 1))
                skipWhitespace()
                guard position < bytes.count else { throw fail("unterminated array") }
                if bytes[position] == UInt8(ascii: ",") {
                    position += 1
                } else if bytes[position] == UInt8(ascii: "]") {
                    position += 1
                    return .array(items)
                } else {
                    throw fail("expected ',' or ']'")
                }
            }
        }

        private mutating func parseNumber() throws -> Value {
            let start = position
            if bytes[position] == UInt8(ascii: "-") {
                position += 1
            }
            guard position < bytes.count else { throw fail("truncated number") }
            if bytes[position] == UInt8(ascii: "0") {
                position += 1
            } else if (UInt8(ascii: "1") ... UInt8(ascii: "9")).contains(bytes[position]) {
                consumeDigits()
            } else {
                throw fail("expected a digit")
            }
            var isInteger = true
            if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
                isInteger = false
                position += 1
                guard consumeDigits() > 0 else { throw fail("expected digits after '.'") }
            }
            if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
                isInteger = false
                position += 1
                if position < bytes.count,
                   bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-")
                {
                    position += 1
                }
                guard consumeDigits() > 0 else { throw fail("expected exponent digits") }
            }
            let text = String(decoding: bytes[start ..< position], as: UTF8.self)
            if isInteger, let integer = Int(text) {
                return .int(integer)
            }
            guard let double = Double(text), double.isFinite else { throw fail("number out of range") }
            return .double(double)
        }

        @discardableResult
        private mutating func consumeDigits() -> Int {
            let start = position
            while position < bytes.count, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[position]) {
                position += 1
            }
            return position - start
        }

        private mutating func parseString() throws -> String {
            position += 1 // opening quote
            var scalars: [UInt8] = []
            while true {
                guard position < bytes.count else { throw fail("unterminated string") }
                let byte = bytes[position]
                switch byte {
                case UInt8(ascii: "\""):
                    position += 1
                    guard let text = String(bytes: scalars, encoding: .utf8) else {
                        throw fail("invalid UTF-8 in string")
                    }
                    return text
                case UInt8(ascii: "\\"):
                    position += 1
                    guard position < bytes.count else { throw fail("unterminated escape") }
                    let escape = bytes[position]
                    position += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append(0x22)
                    case UInt8(ascii: "\\"): scalars.append(0x5C)
                    case UInt8(ascii: "/"): scalars.append(0x2F)
                    case UInt8(ascii: "b"): scalars.append(0x08)
                    case UInt8(ascii: "f"): scalars.append(0x0C)
                    case UInt8(ascii: "n"): scalars.append(0x0A)
                    case UInt8(ascii: "r"): scalars.append(0x0D)
                    case UInt8(ascii: "t"): scalars.append(0x09)
                    case UInt8(ascii: "u"): try scalars.append(contentsOf: parseUnicodeEscape())
                    default: position -= 1; throw fail("invalid escape")
                    }
                case 0 ..< 0x20:
                    throw fail("unescaped control character in string")
                default:
                    scalars.append(byte)
                    position += 1
                }
            }
        }

        /// `\uXXXX`, joining a UTF-16 surrogate pair into one scalar. A lone surrogate is an
        /// error, since it can't be written as UTF-8.
        private mutating func parseUnicodeEscape() throws -> [UInt8] {
            let first = try parseHex4()
            var scalarValue = first
            if (0xD800 ... 0xDBFF).contains(first) {
                guard position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"),
                      bytes[position + 1] == UInt8(ascii: "u")
                else { throw fail("a high surrogate needs a following low surrogate") }
                position += 2
                let second = try parseHex4()
                guard (0xDC00 ... 0xDFFF).contains(second) else { throw fail("invalid low surrogate") }
                scalarValue = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            } else if (0xDC00 ... 0xDFFF).contains(first) {
                throw fail("unpaired low surrogate")
            }
            guard let scalar = Unicode.Scalar(scalarValue) else { throw fail("invalid code point") }
            return Array(String(Character(scalar)).utf8)
        }

        private mutating func parseHex4() throws -> UInt32 {
            guard position + 4 <= bytes.count else { throw fail("truncated \\u escape") }
            var value: UInt32 = 0
            for _ in 0 ..< 4 {
                let byte = bytes[position]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A") ... UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw fail("invalid \\u escape")
                }
                value = value << 4 | digit
                position += 1
            }
            return value
        }
    }
}

// MARK: Reading a parsed request

extension Value {
    /// An object member, or `nil` when this isn't an object or has no such key.
    subscript(key: String) -> Value? {
        guard case let .object(members) = self else { return nil }
        return members[.string(key)]
    }

    var stringValue: String? {
        if case let .string(text) = self {
            text
        } else {
            nil
        }
    }

    var arrayValue: [Value]? {
        if case let .array(items) = self {
            items
        } else {
            nil
        }
    }

    var intValue: Int? {
        switch self {
        case let .int(number): number
        case let .double(number) where number == number.rounded() && abs(number) < 1e15: Int(number)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .double(number): number
        case let .int(number): Double(number)
        default: nil
        }
    }

    var boolValue: Bool? {
        if case let .boolean(flag) = self {
            flag
        } else {
            nil
        }
    }

    var isNull: Bool {
        if case .null = self {
            true
        } else {
            false
        }
    }
}
