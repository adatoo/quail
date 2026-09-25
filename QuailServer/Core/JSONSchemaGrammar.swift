import Foundation
import Jinja
import OrderedCollections

/// JSON Schema to GBNF, the grammar language `llama_sampler_init_grammar` reads (ADR D-045).
///
/// A port of llama.cpp's own converter (`common/json-schema-to-grammar.cpp`, b11081), which libllama
/// doesn't include: the same rules for whitespace, strings, numbers, objects and arrays, so a
/// constrained reply can only differ from llama-server's by the sampling around it, not by what the
/// grammar allows. What it doesn't port, it refuses by name (`pattern`, `not`, `if`, …) instead of
/// quietly loosening the constraint.
enum JSONSchemaGrammar {
    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    /// llama-server reads `response_format: {"type": "json_object"}` as "an object".
    static let anyObject = Value.record([("type", .string("object"))])

    /// A reasoning model writes its thinking before the answer; a grammar that started at the first token
    /// would forbid that and push the model off what it was trained to do (its JSON comes out worse and
    /// often runs away), so the answer's grammar can be preceded by the thinking block.
    enum Reasoning: Equatable, Sendable {
        /// No thinking block: the answer starts at the first token.
        case none
        /// The model writes `<think>…</think>` first, or goes straight to the answer.
        case optional
        /// The template already opened `<think>`, so the reply continues the thinking and then closes it.
        case open
    }

    /// A GBNF grammar whose start rule is `root` and which accepts exactly what `schema` describes,
    /// after the thinking block, if `reasoning` says there is one.
    static func gbnf(for schema: Value, reasoning: Reasoning = .none) throws -> String {
        var converter = Converter(root: schema)
        _ = try converter.visit(schema, name: "", path: "#")
        if reasoning != .none {
            converter.rules["json-root"] = converter.rules.removeValue(forKey: "root")
            let thinking = reasoning == .optional
                ? "(\"<think>\" think-0 \"</think>\" think-space)? json-root"
                : "think-0 \"</think>\" think-space json-root"
            converter.rules["root"] = thinking
            converter.rules["think-space"] = "[\\n]{0,2}"
            // Any text that doesn't contain "</think>": one rule per prefix of the tag matched so far, and
            // a "<" always restarts the match, so the closing tag is recognised wherever it comes.
            let tag = Array("</think>")
            converter.rules["think-0"] = "| [^<] think-0 | \"<\" think-1"
            for matched in 1 ..< tag.count {
                let next = tag[matched]
                var rule = "| \"<\" think-1"
                rule += " | [^<\(next)] think-0"
                if matched == tag.count - 1 {
                    rule = "| \"<\" think-1 | [^<>] think-0"
                } else if matched == 1 {
                    rule = "| \"<\" think-1 | [^</] think-0 | \"/\" think-2"
                } else {
                    rule += " | \"\(next)\" think-\(matched + 1)"
                }
                converter.rules["think-\(matched)"] = rule
            }
        }
        return converter.grammar()
    }

    /// Keywords that constrain a value and that this converter doesn't implement.
    static let unsupported: Set<String> = [
        "pattern", "not", "if", "then", "else", "patternProperties", "propertyNames", "dependentRequired",
        "dependentSchemas", "dependencies", "contains", "minContains", "maxContains", "multipleOf",
        "minProperties", "maxProperties", "unevaluatedProperties", "unevaluatedItems",
    ]
}

private let spaceRule = "| \" \" | \"\\n\"{1,2} [ \\t]{0,20}"

private struct Builtin {
    let content: String
    let deps: [String]
}

private let primitiveRules: [String: Builtin] = [
    "boolean": Builtin(content: "(\"true\" | \"false\")", deps: []),
    "decimal-part": Builtin(content: "[0-9]{1,16}", deps: []),
    "integral-part": Builtin(content: "[0] | [1-9] [0-9]{0,15}", deps: []),
    "number": Builtin(
        content: "(\"-\"? integral-part) (\".\" decimal-part)? ([eE] [-+]? integral-part)?",
        deps: ["integral-part", "decimal-part"]
    ),
    "integer": Builtin(content: "(\"-\"? integral-part)", deps: ["integral-part"]),
    "value": Builtin(
        content: "object | array | string | number | boolean | null",
        deps: ["object", "array", "string", "number", "boolean", "null"]
    ),
    "object": Builtin(
        content: "\"{\" space ( string \":\" space value (\",\" space string \":\" space value)* )? space \"}\"",
        deps: ["string", "value"]
    ),
    "array": Builtin(content: "\"[\" space ( value (\",\" space value)* )? space \"]\"", deps: ["value"]),
    "uuid": Builtin(
        content: "\"\\\"\" [0-9a-fA-F]{8} \"-\" [0-9a-fA-F]{4} \"-\" [0-9a-fA-F]{4} \"-\" [0-9a-fA-F]{4} \"-\" [0-9a-fA-F]{12} \"\\\"\"",
        deps: []
    ),
    "char": Builtin(content: "[^\"\\\\\\x7F\\x00-\\x1F] | [\\\\] ([\"\\\\bfnrt] | \"u\" [0-9a-fA-F]{4})", deps: []),
    "string": Builtin(content: "\"\\\"\" char* \"\\\"\"", deps: ["char"]),
    "null": Builtin(content: "\"null\"", deps: []),
]

private let stringFormatRules: [String: Builtin] = [
    "date": Builtin(
        content: "[0-9]{4} \"-\" ( \"0\" [1-9] | \"1\" [0-2] ) \"-\" ( \"0\" [1-9] | [1-2] [0-9] | \"3\" [0-1] )",
        deps: []
    ),
    "time": Builtin(
        content: "([01] [0-9] | \"2\" [0-3]) \":\" [0-5] [0-9] \":\" [0-5] [0-9] ( \".\" [0-9]{3} )? ( \"Z\" | ( \"+\" | \"-\" ) ( [01] [0-9] | \"2\" [0-3] ) \":\" [0-5] [0-9] )",
        deps: []
    ),
    "date-time": Builtin(content: "date \"T\" time", deps: ["date", "time"]),
    "date-string": Builtin(content: "\"\\\"\" date \"\\\"\"", deps: ["date"]),
    "time-string": Builtin(content: "\"\\\"\" time \"\\\"\"", deps: ["time"]),
    "date-time-string": Builtin(content: "\"\\\"\" date-time \"\\\"\"", deps: ["date-time"]),
]

private let reservedNames: Set<String> = Set(["root"]).union(primitiveRules.keys).union(stringFormatRules.keys)

/// A quoted GBNF literal for `text` (which is already JSON, or plain text).
private func formatLiteral(_ text: String) -> String {
    var out = "\""
    for character in text {
        switch character {
        case "\r": out += "\\r"
        case "\n": out += "\\n"
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        default: out.append(character)
        }
    }
    return out + "\""
}

private func repetition(_ item: String, min: Int, max: Int?, separator: String = "") -> String {
    if max == 0 {
        return ""
    }
    if min == 0, max == 1 {
        return item + "?"
    }
    if separator.isEmpty {
        if min == 1, max == nil {
            return item + "+"
        }
        if min == 0, max == nil {
            return item + "*"
        }
        return item + "{\(min),\(max.map(String.init) ?? "")}"
    }
    var result = item + " " + repetition(
        "(" + separator + " " + item + ")", min: min == 0 ? 0 : min - 1, max: max.map { $0 - 1 }
    )
    if min == 0 {
        result = "(" + result + ")?"
    }
    return result
}

private struct Converter {
    let root: Value
    var rules: [String: String] = ["space": spaceRule]
    var refsBeingResolved: Set<String> = []

    // MARK: Rules

    mutating func addRule(_ name: String, _ rule: String) -> String {
        let escaped = name.replacingOccurrences(of: "[^a-zA-Z0-9-]+", with: "-", options: .regularExpression)
        if rules[escaped] == nil || rules[escaped] == rule {
            rules[escaped] = rule
            return escaped
        }
        var index = 0
        while let existing = rules[escaped + String(index)], existing != rule {
            index += 1
        }
        let key = escaped + String(index)
        rules[key] = rule
        return key
    }

    mutating func addPrimitive(_ name: String, _ rule: Builtin) -> String {
        let added = addRule(name, rule.content)
        for dependency in rule.deps where rules[dependency] == nil {
            if let known = primitiveRules[dependency] ?? stringFormatRules[dependency] {
                _ = addPrimitive(dependency, known)
            }
        }
        return added
    }

    func grammar() -> String {
        rules.keys.sorted().map { "\($0) ::= \(rules[$0]!)\n" }.joined()
    }

    func fail(_ path: String, _ message: String) -> JSONSchemaGrammar.Failure {
        JSONSchemaGrammar.Failure(message: "\(message) (at \(path))")
    }

    // MARK: Schema

    mutating func visit(_ schema: Value, name: String, path: String) throws -> String {
        guard case let .object(members) = schema else { throw fail(path, "a schema must be an object") }
        for key in JSONSchemaGrammar.unsupported where members[.string(key)] != nil {
            throw fail(path, "the JSON schema keyword \"\(key)\" isn't supported yet")
        }
        if let unique = schema["uniqueItems"], unique.boolValue != false, !unique.isNull {
            throw fail(path, "the JSON schema keyword \"uniqueItems\" isn't supported yet")
        }
        let ruleName = reservedNames.contains(name) ? name + "-" : (name.isEmpty ? "root" : name)
        let subName = name + (name.isEmpty ? "" : "-")

        if let ref = schema["$ref"] {
            return try addRule(ruleName, resolveRef(ref, path: path))
        }
        if let alternatives = schema["oneOf"] ?? schema["anyOf"] {
            let key = schema["oneOf"] != nil ? "oneOf" : "anyOf"
            return try addRule(ruleName, union(alternatives, name: name, path: path + "/" + key))
        }

        var typeName = ""
        if let type = schema["type"], !type.isNull {
            if let list = type.arrayValue {
                guard !list.isEmpty else { throw fail(path, "type must not be empty") }
                // {"type": ["a", "b"], …} is {"anyOf": [{"type": "a", …}, {"type": "b", …}]}
                var alternatives: [Value] = []
                for entry in list {
                    guard case var .object(copy) = schema else { break }
                    copy[.string("type")] = entry
                    alternatives.append(.object(copy))
                }
                return try addRule(ruleName, union(.array(alternatives), name: name, path: path + "/type"))
            }
            guard let text = type.stringValue else { throw fail(path, "type must be a string or an array of strings") }
            typeName = text
        }
        if let constant = schema["const"] {
            return try addRule(ruleName, formatLiteral(OrderedJSON.serialize(constant)))
        }
        if let values = schema["enum"] {
            guard let list = values.arrayValue,
                  !list.isEmpty else { throw fail(path, "enum must be a non-empty array") }
            let literals = try list.map { try formatLiteral(OrderedJSON.serialize($0)) }
            return addRule(ruleName, "(" + literals.joined(separator: " | ") + ")")
        }

        let hasProperties = schema["properties"] != nil
            || (schema["additionalProperties"] != nil && schema["additionalProperties"]?.boolValue != true)
        if typeName.isEmpty {
            // Without a type the structural keywords decide, in llama.cpp's order.
            if hasProperties {
                return try visitObject(schema, ruleName: ruleName, name: name, path: path)
            }
            if let parts = schema["allOf"] {
                return try visitAllOf(parts, name: name, ruleName: ruleName, path: path + "/allOf")
            }
            if schema["items"] != nil || schema["prefixItems"] != nil {
                return try visitArray(schema, ruleName: ruleName, subName: subName, path: path)
            }
            if try schema["minLength"] != nil || schema["maxLength"] != nil || format(of: schema, path: path) != nil {
                return try visitString(schema, ruleName: ruleName, path: path)
            }
            return addRule(ruleName, addPrimitive("value", primitiveRules["value"]!))
        }
        switch typeName {
        case "object":
            if !hasProperties, let parts = schema["allOf"] {
                return try visitAllOf(parts, name: name, ruleName: ruleName, path: path + "/allOf")
            }
            return try visitObject(schema, ruleName: ruleName, name: name, path: path)
        case "string":
            if let parts = schema["allOf"] {
                return try visitAllOf(parts, name: name, ruleName: ruleName, path: path + "/allOf")
            }
            return try visitString(schema, ruleName: ruleName, path: path)
        case "array":
            return try visitArray(schema, ruleName: ruleName, subName: subName, path: path)
        case "integer":
            return try visitInteger(schema, ruleName: ruleName, path: path)
        case "number":
            for key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] where schema[key] != nil {
                throw fail(path, "the JSON schema keyword \"\(key)\" is only supported on integers")
            }
            return primitive(ruleName, "number")
        case "boolean":
            return primitive(ruleName, "boolean")
        case "null":
            return primitive(ruleName, "null")
        default:
            throw fail(path, "unrecognized type \(typeName)")
        }
    }

    mutating func primitive(_ ruleName: String, _ type: String) -> String {
        addPrimitive(ruleName == "root" ? "root" : type, primitiveRules[type]!)
    }

    mutating func union(_ alternatives: Value, name: String, path: String) throws -> String {
        guard let list = alternatives.arrayValue else { throw fail(path, "expected an array of schemas") }
        var rules: [String] = []
        for (index, alternative) in list.enumerated() {
            try rules.append(visit(
                alternative, name: name + (name.isEmpty ? "alternative-" : "-") + String(index),
                path: path + "/" + String(index)
            ))
        }
        return rules.joined(separator: " | ")
    }

    // MARK: $ref

    mutating func resolveRef(_ ref: Value, path: String) throws -> String {
        guard let text = ref.stringValue else { throw fail(path, "$ref must be a string") }
        guard text.hasPrefix("#") else {
            throw fail(path, "unsupported $ref \(text), only references into the same document are supported")
        }
        let fragment = String(text.dropFirst())
        let refName = "ref" + fragment.replacingOccurrences(
            of: "[^a-zA-Z0-9-]+",
            with: "-",
            options: .regularExpression
        )
        if rules[refName] == nil, !refsBeingResolved.contains(text) {
            refsBeingResolved.insert(text)
            let target = try pointer(fragment, path: path)
            let resolved = try visit(target, name: refName, path: text)
            refsBeingResolved.remove(text)
            return resolved
        }
        return refName
    }

    func pointer(_ fragment: String, path: String) throws -> Value {
        var node = root
        for token in fragment.split(separator: "/", omittingEmptySubsequences: true) {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let list = node.arrayValue, let index = Int(key), list.indices.contains(index) {
                node = list[index]
            } else if let next = node[key] {
                node = next
            } else {
                throw fail(path, "cannot resolve $ref #\(fragment): \(key) not found")
            }
        }
        return node
    }

    // MARK: Objects

    mutating func visitObject(_ schema: Value, ruleName: String, name: String, path: String) throws -> String {
        var required = Set<String>()
        if let list = schema["required"]?.arrayValue {
            for entry in list {
                if let text = entry.stringValue {
                    required.insert(text)
                }
            }
        }
        var properties: [(String, Value)] = []
        if let value = schema["properties"] {
            guard case let .object(members) = value else { throw fail(path, "properties must be an object") }
            for (key, property) in members {
                if case let .string(text) = key {
                    properties.append((text, property))
                }
            }
        }
        // `additionalProperties`: true/absent (with no properties) is "any", false/absent is closed.
        var additional: Value?
        var additionalIsAny = false
        if let value = schema["additionalProperties"] {
            if let flag = value.boolValue {
                additionalIsAny = flag
                if flag {
                    additional = Value.record([])
                }
            } else if case .object = value {
                additional = value
            } else {
                throw fail(path, "additionalProperties must be a boolean or a schema")
            }
        } else if schema["properties"] == nil {
            additionalIsAny = true
            additional = Value.record([])
        }
        if properties.isEmpty, additionalIsAny {
            return addRule(ruleName, addPrimitive("object", primitiveRules["object"]!))
        }
        return try addRule(ruleName, buildObjectRule(
            properties, required: required, name: name, additional: additional, additionalIsAny: additionalIsAny,
            path: path
        ))
    }

    mutating func buildObjectRule(
        _ properties: [(String, Value)], required: Set<String>, name: String, additional: Value?,
        additionalIsAny: Bool, path: String
    ) throws -> String {
        var requiredProps: [String] = []
        var optionalProps: [String] = []
        var kvRules: [String: String] = [:]
        var names: [String] = []
        for (propName, schema) in properties {
            let ruleName = try visit(
                schema,
                name: name + (name.isEmpty ? "" : "-") + propName,
                path: path + "/properties/" + propName
            )
            let literal = try formatLiteral(OrderedJSON.serialize(.string(propName)))
            kvRules[propName] = addRule(
                name + (name.isEmpty ? "" : "-") + propName + "-kv",
                literal + " space \":\" space " + ruleName
            )
            if required.contains(propName) {
                requiredProps.append(propName)
            } else {
                optionalProps.append(propName)
            }
            names.append(propName)
        }
        if let additional {
            let subName = name + (name.isEmpty ? "" : "-") + "additional"
            let valueRule = additionalIsAny
                ? addPrimitive("value", primitiveRules["value"]!)
                : try visit(additional, name: subName + "-value", path: path + "/additionalProperties")
            let keyRule = names.isEmpty
                ? addPrimitive("string", primitiveRules["string"]!)
                : addRule(subName + "-k", notStrings(names))
            kvRules["*"] = addRule(subName + "-kv", keyRule + " \":\" space " + valueRule)
            optionalProps.append("*")
        }
        if requiredProps.isEmpty, optionalProps.isEmpty {
            return "\"{\" space \"}\""
        }

        var rule = "\"{\" space "
        for (index, key) in requiredProps.enumerated() {
            if index > 0 {
                rule += " \",\" space "
            }
            rule += kvRules[key]!
        }
        if !optionalProps.isEmpty {
            rule += " ("
            if !requiredProps.isEmpty {
                rule += " \",\" space ( "
            }
            func recursive(_ keys: ArraySlice<String>, firstIsOptional: Bool, converter: inout Converter) -> String {
                guard let key = keys.first else { return "" }
                let kvName = kvRules[key]!
                let commaRef = "( \",\" space " + kvName + " )"
                var result: String = if firstIsOptional {
                    commaRef + (key == "*" ? "*" : "?")
                } else {
                    kvName + (key == "*" ? " " + commaRef + "*" : "")
                }
                if keys.count > 1 {
                    let rest = recursive(keys.dropFirst(), firstIsOptional: true, converter: &converter)
                    result += " " + converter.addRule(name + (name.isEmpty ? "" : "-") + key + "-rest", rest)
                }
                return result
            }
            for index in optionalProps.indices {
                if index > 0 {
                    rule += " | "
                }
                rule += recursive(optionalProps[index...], firstIsOptional: false, converter: &self)
            }
            if !requiredProps.isEmpty {
                rule += " )"
            }
            rule += " )?"
        }
        return rule + " space \"}\""
    }

    /// A JSON string that is none of `strings`: `"` ( [a] char+ | [^"a] char* )? `"`, as a trie.
    mutating func notStrings(_ strings: [String]) -> String {
        final class Node {
            var children: [UInt32: Node] = [:]
            var terminal = false
        }
        let root = Node()
        for string in strings {
            var node = root
            for scalar in string.unicodeScalars {
                if let child = node.children[scalar.value] {
                    node = child
                } else {
                    let child = Node()
                    node.children[scalar.value] = child
                    node = child
                }
            }
            node.terminal = true
        }
        let charRule = addPrimitive("char", primitiveRules["char"]!)
        var out = "[\"] ( "
        func visitNode(_ node: Node) {
            var rejects = ""
            var first = true
            for (code, child) in node.children.sorted(by: { $0.key < $1.key }) {
                let text = String(Character(Unicode.Scalar(code)!))
                rejects += text
                if first {
                    first = false
                } else {
                    out += " | "
                }
                out += "[" + text + "]"
                if !child.children.isEmpty {
                    out += " ("
                    visitNode(child)
                    out += ")"
                } else {
                    out += " " + charRule + "+"
                }
            }
            if !node.children.isEmpty {
                out += " | [^\"" + rejects + "] " + charRule + "*"
            }
        }
        visitNode(root)
        out += " )"
        if !root.terminal {
            out += "?"
        }
        return out + " [\"]"
    }

    mutating func visitAllOf(_ parts: Value, name: String, ruleName: String, path: String) throws -> String {
        guard let list = parts.arrayValue else { throw fail(path, "allOf must be an array") }
        var required = Set<String>()
        var properties: [(String, Value)] = []
        var enumCounts: [String: Int] = [:]

        func addComponent(_ component: Value, isRequired: Bool) throws {
            if let ref = component["$ref"] {
                guard let text = ref.stringValue, text.hasPrefix("#") else {
                    throw fail(path, "unsupported $ref inside allOf")
                }
                try addComponent(pointer(String(text.dropFirst()), path: path), isRequired: isRequired)
            } else if let values = component["enum"]?.arrayValue {
                for value in values {
                    try enumCounts[formatLiteral(OrderedJSON.serialize(value)), default: 0] += 1
                }
            } else if case let .object(members)? = component["properties"] {
                var componentRequired = Set<String>()
                for entry in component["required"]?.arrayValue ?? [] {
                    if let text = entry.stringValue {
                        componentRequired.insert(text)
                    }
                }
                for (key, property) in members {
                    if case let .string(text) = key {
                        properties.append((text, property))
                        if isRequired, componentRequired.contains(text) {
                            required.insert(text)
                        }
                    }
                }
            }
        }
        for child in list {
            if let alternatives = (child["anyOf"] ?? child["oneOf"])?.arrayValue {
                for alternative in alternatives {
                    try addComponent(alternative, isRequired: false)
                }
            } else {
                try addComponent(child, isRequired: true)
            }
        }
        let common = enumCounts.filter { $0.value == list.count }.keys.sorted()
        if !common.isEmpty {
            return addRule(ruleName, "(" + common.joined(separator: " | ") + ")")
        }
        return try addRule(ruleName, buildObjectRule(
            properties, required: required, name: name, additional: nil, additionalIsAny: false, path: path
        ))
    }

    // MARK: Arrays, strings, integers

    mutating func visitArray(_ schema: Value, ruleName: String, subName: String, path: String) throws -> String {
        let minItems = try count(schema, "minItems", path: path) ?? 0
        let maxItems = try count(schema, "maxItems", path: path)
        let key = schema["items"] != nil ? "items" : "prefixItems"
        if let items = schema[key]?.arrayValue {
            var rule = "\"[\" space "
            for (index, item) in items.enumerated() {
                if index > 0 {
                    rule += " \",\" space "
                }
                rule += try visit(item, name: subName + "tuple-" + String(index), path: path + "/\(key)/\(index)")
            }
            return addRule(ruleName, rule + " space \"]\"")
        }
        let itemsSchema = schema[key] ?? Value.record([])
        let itemIsAny = schema[key] == nil || (itemsSchema.objectIsEmpty)
        if itemIsAny, minItems == 0, maxItems == nil {
            return primitive(ruleName, "array")
        }
        let itemRule = try visit(itemsSchema, name: subName + "item", path: path + "/\(key)")
        return addRule(
            ruleName,
            "\"[\" space " + repetition(itemRule, min: minItems, max: maxItems, separator: "\",\" space") + " space \"]\""
        )
    }

    func count(_ schema: Value, _ key: String, path: String) throws -> Int? {
        guard let value = schema[key], !value.isNull else { return nil }
        guard let number = value.intValue,
              number >= 0 else { throw fail(path, "\(key) must be a non-negative integer") }
        return number
    }

    func format(of schema: Value, path: String) throws -> String? {
        guard let value = schema["format"], !value.isNull else { return nil }
        guard let text = value.stringValue else { throw fail(path, "format must be a string") }
        switch text {
        case "date", "time", "date-time": return text
        case "uuid", "uuid1", "uuid2", "uuid3", "uuid4", "uuid5": return "uuid"
        default: return nil // an unknown format constrains nothing
        }
    }

    mutating func visitString(_ schema: Value, ruleName: String, path: String) throws -> String {
        if let format = try format(of: schema, path: path) {
            if format == "uuid" {
                return primitive(ruleName, "uuid")
            }
            let primitiveName = format + "-string"
            return addRule(ruleName, addPrimitive(primitiveName, stringFormatRules[primitiveName]!))
        }
        let minLength = try count(schema, "minLength", path: path) ?? 0
        let maxLength = try count(schema, "maxLength", path: path)
        if minLength > 0 || maxLength != nil {
            let charRule = addPrimitive("char", primitiveRules["char"]!)
            return addRule(ruleName, "\"\\\"\" " + repetition(charRule, min: minLength, max: maxLength) + " \"\\\"\"")
        }
        return primitive(ruleName, "string")
    }

    mutating func visitInteger(_ schema: Value, ruleName: String, path: String) throws -> String {
        func bound(_ key: String, roundUp: Bool) throws -> Int64? {
            guard let value = schema[key], !value.isNull else { return nil }
            if case let .int(number) = value {
                return Int64(number)
            }
            guard let number = value.doubleValue else { throw fail(path, "\(key) must be a number") }
            return Int64(roundUp ? number.rounded(.up) : number.rounded(.down))
        }
        var minimum: Int64?
        var maximum: Int64?
        if let value = try bound("minimum", roundUp: true) {
            minimum = value
        } else if let value = try bound("exclusiveMinimum", roundUp: false) {
            minimum = value + 1
        }
        if let value = try bound("maximum", roundUp: false) {
            maximum = value
        } else if let value = try bound("exclusiveMaximum", roundUp: true) {
            maximum = value - 1
        }
        if minimum == nil, maximum == nil {
            return primitive(ruleName, "integer")
        }
        var out = "("
        IntegerRange.build(minimum, maximum, into: &out)
        out += ")"
        return addRule(ruleName, out)
    }
}

private extension Value {
    var objectIsEmpty: Bool {
        if case let .object(members) = self {
            return members.isEmpty
        }
        return false
    }
}

/// Integer ranges as a grammar: llama.cpp's `build_min_max_int`, digit by digit.
private enum IntegerRange {
    static func build(
        _ minValue: Int64?, _ maxValue: Int64?, into out: inout String, decimalsLeft: Int = 16, topLevel: Bool = true
    ) {
        func digitRange(_ from: Character, _ to: Character) {
            out += from == to ? "[\(from)]" : "[\(from)-\(to)]"
        }
        func moreDigits(_ minDigits: Int, _ maxDigits: Int) {
            out += "[0-9]"
            if minDigits == maxDigits, minDigits == 1 {
                return
            }
            out += "{\(minDigits)"
            if maxDigits != minDigits {
                out += ","
                out += String(maxDigits)
            }
            out += "}"
        }
        func char(_ scalar: UInt8) -> Character {
            Character(Unicode.Scalar(scalar))
        }
        func uniformRange(_ from: [UInt8], _ to: [UInt8]) {
            var i = 0
            while i < from.count, i < to.count, from[i] == to[i] {
                i += 1
            }
            if i > 0 {
                out += "\"" + String(decoding: from[..<i], as: UTF8.self) + "\""
            }
            guard i < from.count, i < to.count else { return }
            if i > 0 {
                out += " "
            }
            let subLength = from.count - i - 1
            if subLength > 0 {
                let fromSub = Array(from[(i + 1)...])
                let toSub = Array(to[(i + 1)...])
                let subZeros = [UInt8](repeating: UInt8(ascii: "0"), count: subLength)
                let subNines = [UInt8](repeating: UInt8(ascii: "9"), count: subLength)
                var toReached = false
                out += "("
                if fromSub == subZeros {
                    digitRange(char(from[i]), char(to[i] - 1))
                    out += " "
                    moreDigits(subLength, subLength)
                } else {
                    out += "[" + String(char(from[i])) + "] ("
                    uniformRange(fromSub, subNines)
                    out += ")"
                    if from[i] < to[i] - 1 {
                        out += " | "
                        if toSub == subNines {
                            digitRange(char(from[i] + 1), char(to[i]))
                            toReached = true
                        } else {
                            digitRange(char(from[i] + 1), char(to[i] - 1))
                        }
                        out += " "
                        moreDigits(subLength, subLength)
                    }
                }
                if !toReached {
                    out += " | "
                    digitRange(char(to[i]), char(to[i]))
                    out += " "
                    uniformRange(subZeros, toSub)
                }
                out += ")"
            } else {
                out += "[\(char(from[i]))-\(char(to[i]))]"
            }
        }

        if let lower = minValue, let upper = maxValue {
            if lower < 0, upper < 0 {
                out += "\"-\" ("
                build(-upper, -lower, into: &out, decimalsLeft: decimalsLeft, topLevel: true)
                out += ")"
                return
            }
            var lower = lower
            if lower < 0 {
                out += "\"-\" ("
                build(0, -lower, into: &out, decimalsLeft: decimalsLeft, topLevel: true)
                out += ") | "
                lower = 0
            }
            var minText = Array(String(lower).utf8)
            let maxText = Array(String(upper).utf8)
            var digits = minText.count
            while digits < maxText.count {
                uniformRange(minText, [UInt8](repeating: UInt8(ascii: "9"), count: digits))
                minText = Array(("1" + String(repeating: "0", count: digits)).utf8)
                out += " | "
                digits += 1
            }
            uniformRange(minText, maxText)
            return
        }

        let lessDecimals = max(decimalsLeft - 1, 1)
        if let lower = minValue {
            if lower < 0 {
                out += "\"-\" ("
                build(nil, -lower, into: &out, decimalsLeft: decimalsLeft, topLevel: false)
                out += ") | [0] | [1-9] "
                moreDigits(0, decimalsLeft - 1)
            } else if lower == 0 {
                if topLevel {
                    out += "[0] | [1-9] "
                    moreDigits(0, lessDecimals)
                } else {
                    moreDigits(1, decimalsLeft)
                }
            } else if lower <= 9 {
                let c = char(UInt8(ascii: "0") + UInt8(lower))
                let rangeStart: Character = topLevel ? "1" : "0"
                if c > rangeStart {
                    digitRange(rangeStart, Character(Unicode.Scalar(c.asciiValue! - 1)))
                    out += " "
                    moreDigits(1, lessDecimals)
                    out += " | "
                }
                digitRange(c, "9")
                out += " "
                moreDigits(0, lessDecimals)
            } else {
                let text = Array(String(lower).utf8)
                let c = text[0]
                if c > UInt8(ascii: "1") {
                    digitRange(topLevel ? "1" : "0", char(c - 1))
                    out += " "
                    moreDigits(text.count, lessDecimals)
                    out += " | "
                }
                digitRange(char(c), char(c))
                out += " ("
                build(
                    Int64(String(decoding: text[1...], as: UTF8.self)) ?? 0,
                    nil,
                    into: &out,
                    decimalsLeft: lessDecimals,
                    topLevel: false
                )
                out += ")"
                if c < UInt8(ascii: "9") {
                    out += " | "
                    digitRange(char(c + 1), "9")
                    out += " "
                    moreDigits(text.count - 1, lessDecimals)
                }
            }
            return
        }
        if let upper = maxValue {
            if upper >= 0 {
                if topLevel {
                    out += "\"-\" [1-9] "
                    moreDigits(0, lessDecimals)
                    out += " | "
                }
                build(0, upper, into: &out, decimalsLeft: decimalsLeft, topLevel: true)
            } else {
                out += "\"-\" ("
                build(-upper, nil, into: &out, decimalsLeft: decimalsLeft, topLevel: false)
                out += ")"
            }
        }
    }
}
