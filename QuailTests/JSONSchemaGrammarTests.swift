import Foundation
import Jinja
import Testing
@testable import QuailServerCore

@Suite("JSON schema to grammar")
struct JSONSchemaGrammarTests {
    private func grammar(_ schema: String) throws -> String {
        try JSONSchemaGrammar.gbnf(for: OrderedJSON.parse(schema))
    }

    private func rules(_ grammar: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in grammar.split(separator: "\n") {
            let parts = line.components(separatedBy: " ::= ")
            out[parts[0]] = parts.dropFirst().joined(separator: " ::= ")
        }
        return out
    }

    @Test("primitives are llama.cpp's rules, and the root is the primitive itself")
    func primitives() throws {
        let boolean = try rules(grammar(#"{"type":"boolean"}"#))
        #expect(boolean["root"] == "(\"true\" | \"false\")")
        #expect(boolean["space"] == "| \" \" | \"\\n\"{1,2} [ \\t]{0,20}")
        let integer = try rules(grammar(#"{"type":"integer"}"#))
        #expect(integer["root"] == "(\"-\"? integral-part)")
        #expect(integer["integral-part"] == "[0] | [1-9] [0-9]{0,15}")
        #expect(try rules(grammar(#"{"type":"string"}"#))["root"] == "\"\\\"\" char* \"\\\"\"")
    }

    @Test("an object lists required properties in order, then the optional ones")
    func object() throws {
        let g = try rules(grammar("""
        {"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"},"nick":{"type":"string"}},
         "required":["name","age"]}
        """))
        #expect(g["root"] == "\"{\" space name-kv \",\" space age-kv ( \",\" space ( nick-kv ) )? space \"}\"")
        #expect(g["name-kv"] == "\"\\\"name\\\"\" space \":\" space string")
    }

    @Test(
        "additionalProperties: false closes the object, a schema types the extras, none with no properties is any object"
    )
    func additional() throws {
        let closed =
            try rules(
                grammar(
                    #"{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"],"additionalProperties":false}"#
                )
            )
        #expect(closed["root"] == "\"{\" space id-kv space \"}\"")
        let typed =
            try rules(
                grammar(
                    #"{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"],"additionalProperties":{"type":"number"}}"#
                )
            )
        #expect(typed["additional-kv"]?.contains("number") == true)
        #expect(try rules(grammar(#"{"type":"object"}"#))["root"] == "object")
        #expect(JSONSchemaGrammar.anyObject["type"]?.stringValue == "object")
    }

    @Test("enum, const, union and type lists")
    func choices() throws {
        #expect(try rules(grammar(#"{"enum":["a",1,null]}"#))["root"] == "(\"\\\"a\\\"\" | \"1\" | \"null\")")
        #expect(try rules(grammar(#"{"const":{"k":true}}"#))["root"] == "\"{\\\"k\\\":true}\"")
        #expect(try rules(grammar(#"{"anyOf":[{"type":"integer"},{"type":"boolean"}]}"#))["root"] ==
            "integer | boolean")
        #expect(try rules(grammar(#"{"type":["string","null"]}"#))["root"] == "string | null")
    }

    @Test("arrays: bounds, items, tuples")
    func arrays() throws {
        let bounded = try rules(grammar(#"{"type":"array","items":{"type":"string"},"minItems":2,"maxItems":3}"#))
        #expect(bounded["root"] == "\"[\" space string (\",\" space string){1,2} space \"]\"")
        #expect(try rules(grammar(#"{"type":"array"}"#))["root"]?.hasPrefix("\"[\" space ( value") == true)
        let tuple = try rules(grammar(#"{"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}]}"#))
        #expect(tuple["root"] == "\"[\" space string \",\" space integer space \"]\"")
    }

    @Test("strings: length bounds and formats")
    func strings() throws {
        #expect(try rules(grammar(#"{"type":"string","minLength":3,"maxLength":5}"#))["root"] ==
            "\"\\\"\" char{3,5} \"\\\"\"")
        #expect(try rules(grammar(#"{"type":"string","format":"date"}"#))["root"] == "date-string")
        #expect(try rules(grammar(#"{"type":"string","format":"uuid"}"#))["root"]?.contains("[0-9a-fA-F]{8}") == true)
    }

    @Test("integer bounds become digit ranges")
    func integers() throws {
        let range = try #require(try rules(grammar(#"{"type":"integer","minimum":-5,"maximum":5}"#))["root"])
        #expect(range.hasPrefix("(\"-\" ("))
        // Every bounded form is a well-formed parenthesised alternative list.
        for schema in [
            #"{"type":"integer","minimum":3}"#,
            #"{"type":"integer","maximum":50}"#,
            #"{"type":"integer","minimum":100,"maximum":999}"#,
            #"{"type":"integer","exclusiveMinimum":0,"exclusiveMaximum":100}"#,
        ] {
            let root = try #require(try rules(grammar(schema))["root"])
            #expect(root.hasPrefix("(") && root.hasSuffix(")"), "\(schema): \(root)")
            #expect(root.filter { $0 == "(" }.count == root.filter { $0 == ")" }.count, "\(schema): \(root)")
        }
    }

    @Test("$ref into $defs, including a recursive one")
    func refs() throws {
        let g = try rules(grammar("""
        {"type":"object","properties":{"a":{"$ref":"#/$defs/p"},"b":{"$ref":"#/$defs/p"}},"required":["a","b"],
         "$defs":{"p":{"type":"object","properties":{"n":{"type":"string"}},"required":["n"]}}}
        """))
        #expect(g["a"] == "ref-defs-p")
        #expect(g["ref-defs-p"]?.contains("space") == true)
        let tree =
            try rules(
                grammar(
                    ##"{"type":"object","properties":{"kids":{"type":"array","items":{"$ref":"#"}}},"required":["kids"]}"##
                )
            )
        #expect(tree["ref"] != nil)
    }

    @Test("allOf merges its objects' properties")
    func allOf() throws {
        let g = try rules(grammar("""
        {"allOf":[{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]},
                  {"type":"object","properties":{"b":{"type":"integer"}},"required":["b"]}]}
        """))
        #expect(g["root"] == "\"{\" space a-kv \",\" space b-kv space \"}\"")
    }

    @Test("what it can't honour is refused by name, not loosened", arguments: [
        (#"{"type":"string","pattern":"^a+$"}"#, "pattern"),
        (#"{"not":{"type":"string"}}"#, "not"),
        (#"{"type":"object","properties":{"x":{"type":"array","uniqueItems":true}}}"#, "uniqueItems"),
        (#"{"type":"number","minimum":1}"#, "minimum"),
        (#"{"type":"object","minProperties":1}"#, "minProperties"),
        (#"{"$ref":"https://example.com/x.json"}"#, "$ref"),
        (#"{"type":"nope"}"#, "unrecognized type"),
    ])
    func refused(schema: String, mention: String) {
        do {
            _ = try grammar(schema)
            Issue.record("expected a failure for \(schema)")
        } catch let failure as JSONSchemaGrammar.Failure {
            #expect(failure.message.contains(mention), "\(failure.message)")
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test("names that collide with a built-in rule don't clobber it")
    func reservedNames() throws {
        let g =
            try rules(
                grammar(
                    #"{"type":"object","properties":{"string":{"type":"integer"},"space":{"type":"string"}},"required":["string","space"]}"#
                )
            )
        #expect(g["string"] != nil)
        #expect(g["space"] == "| \" \" | \"\\n\"{1,2} [ \\t]{0,20}")
    }
}
