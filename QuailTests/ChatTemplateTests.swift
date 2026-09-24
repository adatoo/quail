import Foundation
import Jinja
import Testing
@testable import QuailServerCore

/// `ChatTemplate` against what llama.cpp's own Jinja engine renders from the same real templates
/// (TestFixtures/ChatTemplates/README.md). A prompt that differs by one byte is a different prompt.
@Suite("ChatTemplate")
struct ChatTemplateTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // QuailTests/
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("TestFixtures/ChatTemplates")

    private struct Oracle: Decodable {
        let bosToken: String
        let eosToken: String
        let now: String

        enum CodingKeys: String, CodingKey {
            case bosToken = "bos_token"
            case eosToken = "eos_token"
            case now
        }
    }

    struct Case: CustomTestStringConvertible {
        let family: String
        let name: String
        var testDescription: String {
            "\(family)/\(name)"
        }
    }

    private static let families = ["qwen3", "gemma3", "llama3", "gptoss"]
    private static let caseNames = ["plain", "multi-turn", "tools", "tool-roundtrip", "unicode"]
    static let allCases: [Case] = families.flatMap { family in caseNames.map { Case(family: family, name: $0) } }

    private static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func oracle() throws -> Oracle {
        try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: root.appendingPathComponent("oracle.json")))
    }

    private static func fixedDate(_ oracle: Oracle) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: oracle.now)!
    }

    private static func render(_ testCase: Case) throws -> String {
        let oracle = try oracle()
        let date = fixedDate(oracle)
        let template = try ChatTemplate(text("templates/\(testCase.family).jinja"), now: { date })
        let body = try OrderedJSON.parse(text("cases/\(testCase.name).json"))
        return try template.render(.init(
            messages: body["messages"]?.arrayValue ?? [],
            tools: body["tools"]?.arrayValue,
            bosToken: oracle.bosToken,
            eosToken: oracle.eosToken
        ))
    }

    @Test("renders byte-for-byte what llama.cpp renders", arguments: allCases)
    func matchesLlamaCpp(_ testCase: Case) throws {
        let base = "golden/\(testCase.family)/\(testCase.name)"
        if let expectedError = try? Self.text("\(base).error") {
            // The template rejects this conversation; llama.cpp's message names the reason.
            let reason = expectedError.components(separatedBy: "Jinja Exception: ").last ?? expectedError
            let error = #expect(throws: ChatTemplate.RenderError.self) { try Self.render(testCase) }
            #expect(
                error?.localizedDescription.contains(reason.trimmingCharacters(in: .whitespacesAndNewlines)) == true,
                "\(error?.localizedDescription ?? "nil") vs \(reason)"
            )
            return
        }
        #expect(try Self.render(testCase) == Self.text("\(base).txt"))
    }

    @Test("a tool schema's property order reaches the prompt as sent")
    func toolSchemaOrder() throws {
        // `unit` is sent before `city`; sorted keys would flip them.
        let prompt = try Self.render(Case(family: "llama3", name: "tools"))
        let properties = try #require(prompt.range(of: "\"properties\""))
        let tail = prompt[properties.upperBound...]
        let unit = try #require(tail.range(of: "\"unit\""))
        let city = try #require(tail.range(of: "\"city\""))
        #expect(unit.lowerBound < city.lowerBound)
    }

    @Test("tool-call arguments sent as a JSON string are parsed for the template, in the order sent")
    func argumentsAreParsed() throws {
        let messages = try #require(try OrderedJSON.parse(#"""
        [{"role":"assistant","content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"f","arguments":"{\"zeta\":1,\"alpha\":{\"y\":2,\"b\":3}}"}}]}]
        """#).arrayValue)
        let prepared = ChatTemplate.prepared(messages)
        let arguments = try #require(prepared[0]["tool_calls"]?.arrayValue?.first?["function"]?["arguments"])
        #expect(try OrderedJSON.serialize(arguments) == #"{"zeta":1,"alpha":{"y":2,"b":3}}"#)
    }

    @Test("arguments that are already an object, or not valid JSON, are left alone")
    func argumentsLeftAlone() throws {
        let messages = try #require(try OrderedJSON.parse(#"""
        [{"role":"assistant","tool_calls":[{"function":{"name":"f","arguments":{"a":1}}},{"function":{"name":"g","arguments":"not json"}}]}]
        """#).arrayValue)
        let calls = try #require(ChatTemplate.prepared(messages)[0]["tool_calls"]?.arrayValue)
        #expect(calls[0]["function"]?["arguments"]?["a"]?.intValue == 1)
        #expect(calls[1]["function"]?["arguments"]?.stringValue == "not json")
    }

    @Test("chat_template_kwargs reach the template, but can't replace the server's own variables")
    func extraVariables() throws {
        let template = try ChatTemplate("{{ flag }}|{{ messages | length }}|{{ bos_token }}")
        let output = try template.render(.init(
            messages: [.string("a")],
            bosToken: "<s>",
            extra: ["flag": .string("yes"), "messages": .array([]), "bos_token": .string("hijacked")]
        ))
        #expect(output == "yes|1|<s>")
    }

    @Test("Qwen3's enable_thinking switch works")
    func enableThinking() throws {
        let template = try ChatTemplate(Self.text("templates/qwen3.jinja"))
        let messages = try [OrderedJSON.parse(#"{"role":"user","content":"hi"}"#)]
        let on = try template.render(.init(messages: messages))
        let off = try template.render(.init(messages: messages, extra: ["enable_thinking": .boolean(false)]))
        #expect(!on.contains("<think>"))
        #expect(off.hasSuffix("<think>\n\n</think>\n\n"))
    }

    @Test("without a generation prompt the assistant turn isn't opened")
    func noGenerationPrompt() throws {
        let template = try ChatTemplate(Self.text("templates/qwen3.jinja"))
        let messages = try [OrderedJSON.parse(#"{"role":"user","content":"hi"}"#)]
        let with = try template.render(.init(messages: messages))
        let without = try template.render(.init(messages: messages, addGenerationPrompt: false))
        #expect(with.hasSuffix("<|im_start|>assistant\n"))
        #expect(!without.contains("<|im_start|>assistant"))
    }

    @Test("a template that doesn't parse is reported as the model's template being invalid")
    func invalidTemplate() {
        #expect(throws: ChatTemplate.RenderError.self) { try ChatTemplate("{% if %}") }
    }

    @Test("strftime_now prints the injected date")
    func strftime() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 in most zones
        let template = try ChatTemplate(#"{{ strftime_now("%Y-%m-%d|%d %b %Y|%B|%%") }}"#, now: { date })
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: .current, from: date)
        let english = DateFormatter()
        english.locale = Locale(identifier: "en_US_POSIX")
        english.dateFormat = "MMM"
        let month = english.string(from: date)
        english.dateFormat = "MMMM"
        let expected = try String(
            format: "%04d-%02d-%02d|%02d %@ %04d|%@|%%",
            #require(parts.year),
            #require(parts.month),
            #require(parts.day),
            #require(parts.day),
            month,
            #require(parts.year),
            english.string(from: date)
        )
        let output = try template.render(.init(messages: []))
        #expect(output == expected)
    }
}
