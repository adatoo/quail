import Foundation
import Jinja
import Testing
@testable import QuailServerCore

@Suite("OrderedJSON")
struct OrderedJSONTests {
    private func keys(_ value: Value) -> [String] {
        guard case let .object(members) = value else { return [] }
        return members.keys.map { key in
            if case let .string(name) = key {
                name
            } else {
                "?"
            }
        }
    }

    @Test("object keys stay in the order they were sent, at every depth")
    func keepsKeyOrder() throws {
        let value = try OrderedJSON.parse(#"{"zebra":1,"apple":{"y":true,"b":false,"m":null},"mango":[{"z":1,"a":2}]}"#)
        #expect(keys(value) == ["zebra", "apple", "mango"])
        #expect(try keys(#require(value["apple"])) == ["y", "b", "m"])
        #expect(try keys(#require(value["mango"]?.arrayValue?.first)) == ["z", "a"])
        // The whole point: it serializes back in the same order.
        #expect(try OrderedJSON
            .serialize(value) == #"{"zebra":1,"apple":{"y":true,"b":false,"m":null},"mango":[{"z":1,"a":2}]}"#)
    }

    @Test("a repeated key keeps its first position and its last value")
    func duplicateKeys() throws {
        let value = try OrderedJSON.parse(#"{"a":1,"b":2,"a":3}"#)
        #expect(keys(value) == ["a", "b"])
        #expect(value["a"]?.intValue == 3)
    }

    @Test("numbers: integers stay integers, the rest are doubles")
    func numbers() throws {
        let value = try OrderedJSON.parse(#"[0,-7,42,1.5,-0.25,1e3,2E-2,9223372036854775807,9223372036854775808]"#)
        let items = try #require(value.arrayValue)
        #expect(items[0].intValue == 0)
        #expect(items[1].intValue == -7)
        #expect(items[2].intValue == 42)
        #expect(items[3].doubleValue == 1.5)
        #expect(items[4].doubleValue == -0.25)
        #expect(items[5].doubleValue == 1000)
        #expect(items[6].doubleValue == 0.02)
        #expect(items[7].intValue == Int.max)
        // One past Int.max doesn't fit an Int; it becomes a double rather than failing.
        if case .double = items[8] {} else {
            Issue.record("expected a double for 2^63")
        }
    }

    @Test("string escapes, including a surrogate pair")
    func stringEscapes() throws {
        let value = try OrderedJSON.parse(#"["a\"b\\c\/d\b\f\n\r\t","\u00e9\u65e5","\ud83d\udc26"]"#)
        let items = try #require(value.arrayValue)
        #expect(items[0].stringValue == "a\"b\\c/d\u{8}\u{c}\n\r\t")
        #expect(items[1].stringValue == "é日")
        #expect(items[2].stringValue == "🐦")
    }

    @Test("raw UTF-8 passes through")
    func utf8() throws {
        #expect(try OrderedJSON.parse("\"Écris « bonjour » 🐦\"").stringValue == "Écris « bonjour » 🐦")
    }

    @Test("empty containers and surrounding whitespace")
    func emptyAndWhitespace() throws {
        let value = try OrderedJSON.parse(" \n\t{ \"a\" : [ ] , \"b\" : { } } \r\n")
        #expect(value["a"]?.arrayValue?.isEmpty == true)
        #expect(try keys(#require(value["b"])).isEmpty)
    }

    @Test("malformed input is refused with a byte offset", arguments: [
        "", "{", "[1,]", "{\"a\":1,}", "{'a':1}", "[1 2]", "{\"a\" 1}", "tru", "nul", "01", "1.", "1e", "-", "+1",
        "NaN", "Infinity", "\"unterminated", "\"bad \\x escape\"", "\"\\u12\"", "\"\\ud800\"", "\"\\udc00\"",
        "\"\\ud800\\u0041\"", "\"tab\there\"", "{} extra", "[1] [2]", "// c\n1", "\"\u{0}\"",
    ])
    func rejectsMalformed(_ text: String) {
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(text) }
    }

    @Test("invalid UTF-8 in a string is refused")
    func invalidUTF8() {
        var bytes = Array("\"ab".utf8)
        bytes.append(0xFF)
        bytes.append(UInt8(ascii: "\""))
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data(bytes)) }
    }

    @Test("absurd nesting is refused instead of overflowing the stack")
    func depthLimit() {
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(deep) }
        let fine = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        #expect(throws: Never.self) { try OrderedJSON.parse(fine) }
    }

    @Test("a large body parses")
    func largeBody() throws {
        let items = (0 ..< 20000).map { "{\"id\":\($0),\"text\":\"item \($0)\"}" }.joined(separator: ",")
        let value = try OrderedJSON.parse("[\(items)]")
        #expect(value.arrayValue?.count == 20000)
    }
}
