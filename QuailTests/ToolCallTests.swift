import Foundation
import Jinja
import Testing
@testable import QuailServerCore

@Suite("Tool calls")
struct ToolCallTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestFixtures")

    private struct Captured: Decodable {
        struct Call: Decodable, Equatable {
            let name: String
            let arguments: String
        }

        struct Request: Decodable {
            let tools: [Call2]?
        }

        struct Call2: Decodable {}

        let raw: String
        let content: String?
        let reasoning: String?
        let toolCalls: [Call]
        let finish: String
        let prompt: String?

        enum CodingKeys: String, CodingKey {
            case raw, content, reasoning, finish, prompt
            case toolCalls = "tool_calls"
        }
    }

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(path), encoding: .utf8)
    }

    private static func captured(_ file: String) throws -> [String: Captured] {
        try JSONDecoder().decode(
            [String: Captured].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("ToolCalls/\(file).json"))
        )
    }

    /// A captured request as the server sees it: parsed in order, never through `JSONSerialization`,
    /// which would scramble the keys the prompt depends on.
    private static func request(of file: String, case name: String) throws -> Value {
        let all = try OrderedJSON.parse(Data(contentsOf: fixtures.appendingPathComponent("ToolCalls/\(file).json")))
        return try #require(all[name]?["request"])
    }

    /// The tools a captured request offered.
    private static func tools(of file: String, case name: String) throws -> [Value] {
        try request(of: file, case: name)["tools"]?.arrayValue ?? []
    }

    private static let sampleTools: [Value] = (try? OrderedJSON.parse(#"""
    [{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"},"days":{"type":"integer"}}}}},
     {"type":"function","function":{"name":"add","parameters":{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"},"note":{"type":"string"}}}}}]
    """#).arrayValue) ?? []

    /// Runs `pieces` through the whole output parser.
    private func parse(
        _ pieces: [String], format: ToolCallFormat, tools: [Value] = ToolCallTests.sampleTools,
        startsInReasoning: Bool = false
    ) -> (content: String, reasoning: String, calls: [ParsedToolCall]) {
        var parser = ChatOutputParser(format: format, tools: tools, startsInReasoning: startsInReasoning)
        var content = "", reasoning = ""
        var calls: [ParsedToolCall] = []
        func take(_ deltas: [ChatDelta]) {
            for delta in deltas {
                switch delta {
                case let .content(text): content += text
                case let .reasoning(text): reasoning += text
                case let .toolCall(call): calls.append(call)
                }
            }
        }
        for piece in pieces {
            take(parser.push(piece))
        }
        take(parser.flush())
        return (content, reasoning, calls)
    }

    private func chunked(_ text: String, _ size: Int) -> [String] {
        stride(from: 0, to: text.count, by: size).map { start in
            let from = text.index(text.startIndex, offsetBy: start)
            return String(text[from ..< text.index(from, offsetBy: min(size, text.count - start))])
        }
    }

    // MARK: format detection

    @Test("a family's tool-call format is read from its template", arguments: [
        ("qwen3", ToolCallFormat.hermesJSON), ("qwen36", .qwenXML), ("llama3", .bareJSON),
        ("gptoss", .harmony), ("gemma3", ToolCallFormat.none), ("gemma4", .gemma4), ("gemma4-mlx", .gemma4),
    ])
    func detection(family: String, expected: ToolCallFormat) throws {
        #expect(try ToolCallFormat.detect(template: Self.text("ChatTemplates/templates/\(family).jinja")) == expected)
    }

    // MARK: real model output, against what llama-server made of it

    struct Model: Sendable, CustomTestStringConvertible {
        let file: String
        let family: String
        var bos = "<|endoftext|>"
        var eos = "<|im_end|>"
        var testDescription: String {
            file
        }
    }

    static let models = [
        Model(file: "qwen3-8b", family: "qwen3"), Model(file: "qwen3.6-35b", family: "qwen36"),
        Model(file: "gemma-4-26b", family: "gemma4", bos: "<bos>", eos: "<eos>"),
    ]

    @Test(
        "real output parses as llama-server parses it, however the tokens arrive",
        arguments: models,
        [1, 4, 17, 10000]
    )
    func matchesLlamaServer(model: Model, size: Int) throws {
        let (file, family) = (model.file, model.family)
        let templateText = try Self.text("ChatTemplates/templates/\(family).jinja")
        let format = ToolCallFormat.detect(template: templateText)
        for (name, capture) in try Self.captured(file) {
            let tools = try Self.tools(of: file, case: name)
            // Generation starts inside the reasoning when the template left it open.
            let opened = capture.prompt.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(format.reasoningTags.open)
            } ?? false
            let result = parse(chunked(capture.raw, size), format: format, tools: tools, startsInReasoning: opened)
            #expect(result.calls.map(\.name) == capture.toolCalls.map(\.name), "\(file)/\(name)")
            #expect(result.calls.map(\.arguments) == capture.toolCalls.map(\.arguments), "\(file)/\(name)")
            #expect(result.content == (capture.content ?? ""), "\(file)/\(name)")
            #expect(result.reasoning == (capture.reasoning ?? ""), "\(file)/\(name)")
            #expect(capture.finish == (result.calls.isEmpty ? "stop" : "tool_calls"), "\(file)/\(name)")
        }
    }

    @Test(
        "our rendering of the template gives llama-server's prompt for the tool conversations",
        arguments: models.filter { $0.family != "qwen3" } // captured before prompts were recorded
    )
    func promptsMatch(model: Model) throws {
        let template = try ChatTemplate(Self.text("ChatTemplates/templates/\(model.family).jinja"))
        for (name, capture) in try Self.captured(model.file) {
            let body = try Self.request(of: model.file, case: name)
            let kwargs: [String: Value] = if case let .object(members)? = body["chat_template_kwargs"] {
                Dictionary(uniqueKeysWithValues: members.compactMap { key, value in
                    if case let .string(name) = key {
                        (name, value)
                    } else {
                        nil
                    }
                })
            } else {
                [:]
            }
            var prompt = try template.render(.init(
                messages: body["messages"]?.arrayValue ?? [], tools: body["tools"]?.arrayValue,
                bosToken: model.bos, eosToken: model.eos, extra: kwargs
            ))
            // llama-server leaves out the BOS text Gemma 4's template starts with, and adds the token
            // itself; quail-server tokenizes that text as the BOS instead. The same tokens either way.
            if prompt.hasPrefix(model.bos) {
                prompt.removeFirst(model.bos.count)
            }
            #expect(prompt == capture.prompt, "\(model.file)/\(name)")
        }
    }

    // MARK: the Hermes and Qwen XML parsers

    @Test("a call is held until it's whole; the text before it streams out")
    func hermesStreaming() {
        var parser = ChatOutputParser(format: .hermesJSON, tools: Self.sampleTools, startsInReasoning: false)
        // Trailing whitespace is held: it might be the layout before a call, which isn't content.
        #expect(parser.push("Let me check. ") == [.content("Let me check.")])
        #expect(parser.push("\n<tool") == []) // whitespace, then what could be the tag
        #expect(parser.push("_call>\n{\"name\": \"get_weather\", ") == [])
        #expect(parser.push("\"arguments\": {\"city\": \"Paris\"}}\n</tool_call>") == [
            .toolCall(ParsedToolCall(name: "get_weather", arguments: #"{"city": "Paris"}"#)),
        ])
    }

    @Test("text before a call loses only the newline the model put there; two calls give two calls")
    func hermesLayout() {
        let raw = "Checking.\n<tool_call>\n{\"name\": \"add\", \"arguments\": {\"a\": 1, \"b\": 2}}\n</tool_call>\n<tool_call>\n{\"name\": \"add\", \"arguments\": {\"a\": 3, \"b\": 4}}\n</tool_call>"
        let result = parse([raw], format: .hermesJSON)
        #expect(result.content == "Checking.")
        #expect(result.calls.map(\.arguments) == [#"{"a": 1, "b": 2}"#, #"{"a": 3, "b": 4}"#])
    }

    @Test("a block that isn't a valid call is given back as text", arguments: [
        "<tool_call>\nnot json\n</tool_call>",
        "<tool_call>\n{\"name\": \"nonexistent\", \"arguments\": {}}\n</tool_call>", // not one of the offered tools
        "<tool_call>\n{\"arguments\": {}}\n</tool_call>",
        "<tool_call>\n{\"name\": \"add\", \"arguments\": \"{oops\"}\n</tool_call>",
    ])
    func invalidBlocks(raw: String) {
        let result = parse([raw], format: .hermesJSON)
        #expect(result.calls.isEmpty)
        #expect(result.content == raw)
    }

    @Test("a reply cut off inside a call has no call, only the text")
    func cutOff() {
        let result = parse(["Sure.\n<tool_call>\n{\"name\": \"add\", \"argum"], format: .hermesJSON)
        #expect(result.calls.isEmpty)
        #expect(result.content == "Sure.<tool_call>\n{\"name\": \"add\", \"argum")
    }

    @Test("arguments given as a JSON string are kept as that string")
    func stringArguments() {
        let raw = "<tool_call>{\"name\": \"add\", \"arguments\": \"{\\\"a\\\": 1}\"}</tool_call>"
        #expect(parse([raw], format: .hermesJSON).calls.first?.arguments == #"{"a": 1}"#)
    }

    @Test("without tools, or for a family with no known format, a call stays content")
    func inactive() {
        let raw = "<tool_call>\n{\"name\": \"add\", \"arguments\": {}}\n</tool_call>"
        #expect(parse([raw], format: .hermesJSON, tools: []).content == raw)
        #expect(parse([raw], format: ToolCallFormat.none).content == raw)
    }

    @Test("Qwen XML: parameters are typed by the tool's schema, and layout newlines dropped")
    func qwenXML() {
        let raw = "<tool_call>\n<function=add>\n<parameter=a>\n2.5\n</parameter>\n<parameter=b>\n4\n</parameter>\n<parameter=note>\n007\n</parameter>\n</function>\n</tool_call>"
        let result = parse([raw], format: .qwenXML)
        #expect(result.calls == [ParsedToolCall(name: "add", arguments: #"{"a":2.5,"b":4,"note":"007"}"#)])
        // A multi-line value keeps its inner newlines.
        let multi = "<tool_call><function=add><parameter=note>\nline one\nline two\n</parameter></function></tool_call>"
        #expect(parse([multi], format: .qwenXML).calls.first?.arguments == #"{"note":"line one\nline two"}"#)
        // An unknown function isn't a call.
        #expect(parse(["<tool_call><function=nope></function></tool_call>"], format: .qwenXML).calls.isEmpty)
    }

    // MARK: Gemma 4

    @Test("Gemma 4: its notation becomes JSON, nested values and all")
    func gemma4Arguments() {
        func arguments(_ call: String) -> String? {
            parse(["<|tool_call>call:\(call)<tool_call|>"], format: .gemma4).calls.first?.arguments
        }
        #expect(arguments(#"add{a:2.5,b:-4,note:<|"|>007<|"|>}"#) == #"{"a":2.5,"b":-4,"note":"007"}"#)
        #expect(arguments(#"add{note:<|"|>say "hi"\n{x:1}, <|tool_call> or [2]<|"|>}"#)
            == #"{"note":"say \"hi\"\\n{x:1}, <|tool_call> or [2]"}"#)
        #expect(arguments(#"add{ a : 1 , note : [ true , false , null , { } , [ ] , {k:<|"|><|"|>} ] }"#)
            == #"{"a":1,"note":[true,false,null,{},[],{"k":""}]}"#)
        #expect(arguments("add{}") == "{}")
        // Leniency that costs nothing: keys and strings quoted either way.
        #expect(arguments(#"add{<|"|>a<|"|>:1,"note":"x\"y"}"#) == #"{"a":1,"note":"x\"y"}"#)
    }

    @Test("Gemma 4: anything that isn't a well-formed call to an offered tool is given back as text", arguments: [
        #"<|tool_call>call:nope{a:1}<tool_call|>"#, // not an offered tool
        #"<|tool_call>get_weather{city:<|"|>Paris<|"|>}<tool_call|>"#, // no call:
        #"<|tool_call>call:get_weather{city:Paris}<tool_call|>"#, // a bare word isn't a value
        #"<|tool_call>call:get_weather{city:<|"|>Paris<|"|><tool_call|>"#, // unclosed brace
        #"<|tool_call>call:get_weather{city:<|"|>Paris<|"|>} extra<tool_call|>"#,
        #"<|tool_call>call:get_weather[1]<tool_call|>"#,
    ])
    func gemma4Invalid(raw: String) {
        let result = parse([raw], format: .gemma4)
        #expect(result.calls.isEmpty)
        #expect(result.content == raw)
    }

    @Test("Gemma 4: a string may hold the closing tag's text, and two calls are two calls", arguments: [1, 3, 10000])
    func gemma4Streaming(size: Int) {
        let raw = #"Checking.\#n<|tool_call>call:add{note:<|"|>a <tool_call|> b<|"|>}<tool_call|><|tool_call>call:add{a:1}<tool_call|>"#
        let result = parse(chunked(raw, size), format: .gemma4)
        #expect(result.content == "Checking.\n") // llama-server keeps Gemma 4's newline
        #expect(result.calls.map(\.arguments) == [#"{"note":"a <tool_call|> b"}"#, #"{"a":1}"#])
        // Cut off inside a string: no call.
        #expect(parse([#"<|tool_call>call:add{note:<|"|>a <tool_call|>"#], format: .gemma4).calls.isEmpty)
    }

    @Test("Gemma 4: the thought channel is reasoning wherever it comes; a stray closing tag is dropped")
    func gemma4Thoughts() {
        let empty = parse(["<|channel>thought\n<channel|>The weather is fine."], format: .gemma4)
        #expect(empty.reasoning == "" && empty.content == "The weather is fine.")
        let late = parse(chunked("Sure.<|channel>thought\nHm.<channel|> Done.<channel|>", 2), format: .gemma4)
        #expect(late.reasoning == "Hm." && late.content == "Sure.Done.")
        // Other families' markers are plain text here, and Gemma's are plain text elsewhere.
        #expect(parse(["<think>x</think>y"], format: .gemma4).content == "<think>x</think>y")
        #expect(parse(["a<channel|>b"], format: .hermesJSON).content == "a<channel|>b")
    }

    // MARK: Llama 3's bare JSON

    @Test("a reply that is exactly a call is a call; a reply that isn't stays text")
    func bareJSON() {
        let call = #"{"name": "get_weather", "parameters": {"city": "Paris"}}"#
        #expect(parse([call], format: .bareJSON).calls == [ParsedToolCall(
            name: "get_weather",
            arguments: #"{"city": "Paris"}"#
        )])
        #expect(parse(chunked("  " + call, 3), format: .bareJSON).calls.count == 1)
        // JSON that isn't a call to an offered tool, and ordinary text, are content.
        #expect(parse([#"{"name": "other", "parameters": {}}"#], format: .bareJSON)
            .content == #"{"name": "other", "parameters": {}}"#)
        #expect(parse(["It is sunny. {\"name\": \"add\"}"], format: .bareJSON)
            .content == "It is sunny. {\"name\": \"add\"}")
        // Text that merely contains a JSON-looking call isn't one; and plain text streams, not held.
        var parser = ChatOutputParser(format: .bareJSON, tools: Self.sampleTools, startsInReasoning: false)
        #expect(parser.push("Hello") == [.content("Hello")])
    }

    // MARK: Harmony

    private func harmony(
        _ raw: String,
        size: Int = 10000
    ) -> (content: String, reasoning: String, calls: [ParsedToolCall]) {
        parse(chunked(raw, size), format: .harmony)
    }

    @Test("Harmony: analysis is reasoning, final is the answer, however it's cut", arguments: [1, 3, 7, 10000])
    func harmonyMessages(size: Int) {
        let raw = "<|channel|>analysis<|message|>The user greets.<|end|><|start|>assistant<|channel|>final<|message|>Hello there!<|return|>"
        let result = harmony(raw, size: size)
        #expect(result.reasoning == "The user greets.")
        #expect(result.content == "Hello there!")
        #expect(result.calls.isEmpty)
    }

    @Test("Harmony: a commentary message to functions.NAME is a call, its body the arguments", arguments: [1, 5, 10000])
    func harmonyCall(size: Int) {
        let raw = "<|channel|>analysis<|message|>Need weather.<|end|><|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{\"city\":\"Paris\"}<|call|>"
        let result = harmony(raw, size: size)
        #expect(result.reasoning == "Need weather.")
        #expect(result.calls == [ParsedToolCall(name: "get_weather", arguments: #"{"city":"Paris"}"#)])
        #expect(result.content == "")
    }

    @Test("Harmony: the recipient can come before the channel, a preamble is content, unknown tools are text")
    func harmonyVariants() {
        let before = "<|start|>assistant to=functions.add<|channel|>commentary json<|message|>{\"a\":1,\"b\":2}<|call|>"
        #expect(harmony(before).calls.first?.name == "add")
        let preamble = "<|channel|>commentary<|message|>I'll look that up.<|end|>"
        #expect(harmony(preamble).content == "I'll look that up.")
        let unknown = "<|channel|>commentary to=functions.other<|message|>{\"x\":1}<|call|>"
        let result = harmony(unknown)
        #expect(result.calls.isEmpty)
        #expect(result.content == "{\"x\":1}")
        // A recipient named at <|start|> belongs to that message only.
        let two = "<|start|>assistant to=functions.add<|channel|>commentary json<|message|>{\"a\":1}<|call|><|channel|>final<|message|>Done<|return|>"
        #expect(harmony(two).calls.count == 1)
        #expect(harmony(two).content == "Done")
        // Invalid JSON arguments and a cut-off call are text.
        #expect(harmony("<|channel|>commentary to=functions.add<|message|>{oops<|call|>").calls.isEmpty)
        #expect(harmony("<|channel|>commentary to=functions.add<|message|>{\"a\":").calls.isEmpty)
    }
}
