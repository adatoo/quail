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
        ("muse-glimmer", .museGlimmer), ("lfm25", .pythonic), ("minicpm5", .minicpmXML),
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
        /// llama-server passes `enable_thinking: true` to a template when a request doesn't say (b11564
        /// server-context.cpp); MiniCPM5's template adds nothing without it, so its prompts need that value.
        var thinksByDefault = false
        var testDescription: String {
            file
        }
    }

    static let models = [
        Model(file: "qwen3-8b", family: "qwen3"), Model(file: "qwen3.6-35b", family: "qwen36"),
        Model(file: "gemma-4-26b", family: "gemma4", bos: "<bos>", eos: "<eos>"),
        Model(file: "minicpm5-2b", family: "minicpm5", bos: "<s>", eos: "</s>", thinksByDefault: true),
        Model(file: "lfm2.5-24b", family: "lfm25", bos: "<|startoftext|>"),
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
            var kwargs: [String: Value] = if case let .object(members)? = body["chat_template_kwargs"] {
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
            if model.thinksByDefault, kwargs["enable_thinking"] == nil {
                kwargs["enable_thinking"] = .boolean(true)
            }
            var prompt = try template.render(.init(
                messages: body["messages"]?.arrayValue ?? [], tools: body["tools"]?.arrayValue,
                bosToken: model.bos, eosToken: model.eos, extra: kwargs
            ))
            // llama-server leaves out the BOS text Gemma 4's template starts with, and adds the token
            // itself; quail-server tokenizes that text as the BOS instead. The same tokens either way.
            if prompt.hasPrefix(model.bos), capture.prompt?.hasPrefix(model.bos) == false {
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

    @Test("Qwen XML: Python's True, False and None are read as the schema's boolean or null")
    func qwenXMLPythonLiterals() {
        let tools: [Value] = (try? OrderedJSON.parse(#"""
        [{"type":"function","function":{"name":"get","parameters":{"type":"object","properties":{
          "flag":{"type":"boolean"},"other":{"type":"boolean"},"limit":{"type":"integer"},"label":{"type":"string"}}}}}]
        """#).arrayValue) ?? []
        let raw = "<tool_call>\n<function=get>\n<parameter=flag>\nTrue\n</parameter>\n<parameter=other>\nFalse\n</parameter>\n<parameter=limit>\nNone\n</parameter>\n<parameter=label>\nTrue\n</parameter>\n</function>\n</tool_call>"
        #expect(parse([raw], format: .qwenXML, tools: tools).calls.first?.arguments
            == #"{"flag":true,"other":false,"limit":null,"label":"True"}"#)
        // A value that's neither JSON nor one of those stays text, as before.
        let odd = "<tool_call><function=get><parameter=flag>yes</parameter></function></tool_call>"
        #expect(parse([odd], format: .qwenXML, tools: tools).calls.first?.arguments == #"{"flag":"yes"}"#)
    }

    // MARK: LFM2's Python calls

    @Test("LFM2: a Python list of calls is calls, its literals read as JSON", arguments: [1, 4, 10000])
    func pythonic(size: Int) {
        let raw = #"Let me check.<|tool_call_start|>[get_weather(city='Paris', days=3), add(a=1.5, b=-2, note="it's \"ok\"\n")]<|tool_call_end|>"#
        let result = parse(chunked(raw, size), format: .pythonic)
        #expect(result.content == "Let me check.")
        #expect(result.calls == [
            ParsedToolCall(name: "get_weather", arguments: #"{"city":"Paris","days":3}"#),
            ParsedToolCall(name: "add", arguments: #"{"a":1.5,"b":-2,"note":"it's \"ok\"\n"}"#),
        ])
    }

    @Test("LFM2: True, False, None, lists, dicts and escapes; a string the schema types is read as that type")
    func pythonicLiterals() {
        let tools: [Value] = (try? OrderedJSON.parse(#"""
        [{"type":"function","function":{"name":"get","parameters":{"type":"object","properties":{
          "flag":{"type":"boolean"},"limit":{"type":"integer"},"tags":{"type":"array"},"opts":{"type":"object"},
          "label":{"type":"string"},"none":{"type":"string"}}}}}]
        """#).arrayValue) ?? []
        let raw = #"<|tool_call_start|>[get(flag=True, limit='10', tags=['a', "b",], opts={"x": [1, 2], 'y': None}, label='caf\u00e9\\', none=None)]<|tool_call_end|>"#
        #expect(parse([raw], format: .pythonic, tools: tools).calls.first?.arguments
            == #"{"flag":true,"limit":10,"tags":["a","b"],"opts":{"x":[1,2],"y":null},"label":"café\\","none":null}"#)
        // A call with no arguments, and one without the list's brackets.
        #expect(parse(["<|tool_call_start|>[get()]<|tool_call_end|>"], format: .pythonic, tools: tools).calls
            == [ParsedToolCall(name: "get", arguments: "{}")])
        #expect(parse(["<|tool_call_start|>get(limit=5)<|tool_call_end|>"], format: .pythonic, tools: tools).calls
            == [ParsedToolCall(name: "get", arguments: #"{"limit":5}"#)])
    }

    @Test("LFM2: JSON calls, which it writes when a system prompt asks, are calls too")
    func pythonicJSON() {
        let one = #"<|tool_call_start|>{"name": "add", "arguments": {"a": 1, "b": 2}}<|tool_call_end|>"#
        #expect(parse([one], format: .pythonic).calls == [ParsedToolCall(name: "add", arguments: #"{"a": 1, "b": 2}"#)])
        let list = #"<|tool_call_start|>[{"name": "add", "arguments": {"a": 1, "b": 2}}, {"name": "get_weather", "arguments": {"city": "Oslo"}}]<|tool_call_end|>"#
        #expect(parse([list], format: .pythonic).calls.map(\.name) == ["add", "get_weather"])
    }

    @Test("LFM2: anything that isn't calls to offered tools is given back as text", arguments: [
        "<|tool_call_start|>[nope(a=1)]<|tool_call_end|>",
        "<|tool_call_start|>[add(a=1]<|tool_call_end|>",
        "<|tool_call_start|>[add(1, 2)]<|tool_call_end|>", // positional arguments
        "<|tool_call_start|>[add(a='unterminated)]<|tool_call_end|>",
        "<|tool_call_start|>[add(a=1)] and more<|tool_call_end|>",
        "<|tool_call_start|>[]<|tool_call_end|>",
    ])
    func pythonicInvalid(raw: String) {
        let result = parse([raw], format: .pythonic)
        #expect(result.calls.isEmpty)
        #expect(result.content == raw)
    }

    @Test("LFM2.5: generation starts inside its reasoning, and a call follows it")
    func pythonicAfterReasoning() {
        let raw = "The user wants Paris.</think><|tool_call_start|>[get_weather(city='Paris')]<|tool_call_end|>"
        let result = parse(chunked(raw, 3), format: .pythonic, startsInReasoning: true)
        #expect(result.reasoning == "The user wants Paris.")
        #expect(result.content.isEmpty)
        #expect(result.calls == [ParsedToolCall(name: "get_weather", arguments: #"{"city":"Paris"}"#)])
    }

    // MARK: MiniCPM5

    @Test(
        "MiniCPM5: each <function name=…> is a call, typed by the schema; a CDATA value is kept whole",
        arguments: [1, 5, 10000]
    )
    func minicpm(size: Int) {
        let raw = #"Sure.\#n<function name="add"><param name="a">2.5</param><param name="note"><![CDATA[<b>&</function>\#nok]]></param></function>\#n<function name="get_weather"><param name="city">Oslo</param></function>"#
        let result = parse(chunked(raw, size), format: .minicpmXML)
        #expect(result.content == "Sure.\n") // llama-server keeps the newline before a call
        #expect(result.calls == [
            ParsedToolCall(name: "add", arguments: #"{"a":2.5,"note":"<b>&</function>\nok"}"#),
            ParsedToolCall(name: "get_weather", arguments: #"{"city":"Oslo"}"#),
        ])
    }

    @Test(
        "MiniCPM5: a list or dict written as Python is JSON's, and 40.0 for an integer is 40, as llama-server reads them"
    )
    func minicpmPythonValues() {
        let tools: [Value] = (try? OrderedJSON.parse(#"""
        [{"type":"function","function":{"name":"find","parameters":{"type":"object","properties":{
          "stops":{"type":"array"},"budget":{"type":"object"},"speed":{"type":"integer"},"label":{"type":"string"}}}}}]
        """#).arrayValue) ?? []
        let raw = #"<function name="find"><param name="stops">['Santa Barbara', "Monterey"]</param><param name="budget">{'min': 300000.0, 'max': None}</param><param name="speed">40.0</param><param name="label">['kept']</param></function>"#
        #expect(parse([raw], format: .minicpmXML, tools: tools).calls.first?.arguments
            ==
            #"{"stops":["Santa Barbara","Monterey"],"budget":{"min":300000.0,"max":null},"speed":40,"label":"['kept']"}"#)
    }

    @Test("MiniCPM5: anything that isn't a call to an offered tool is given back as text", arguments: [
        #"<function name="nope"><param name="a">1</param></function>"#,
        #"<function name="add"><param name="a">1</function>"#,
        #"<function name="add">junk<param name="a">1</param></function>"#,
    ])
    func minicpmInvalid(raw: String) {
        let result = parse([raw], format: .minicpmXML)
        #expect(result.calls.isEmpty)
        #expect(result.content == raw)
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

    @Test("Llama 3.1: <|python_tag|> starts a call, and calls joined by ; are each a call", arguments: [1, 4, 10000])
    func bareJSONPythonTag(size: Int) {
        // Llama 3.1 8B's real reply to a two-call request (bench, 2026-10-02); llama-server b11306 answers it with a
        // 500.
        let raw = #"<|python_tag|>{"name": "get_weather", "parameters": {"city": "Paris; France"}}; {"name": "add", "parameters": {"a": 1, "b": 2}}"#
        let result = parse(chunked(raw, size), format: .bareJSON)
        #expect(result.calls == [
            ParsedToolCall(name: "get_weather", arguments: #"{"city": "Paris; France"}"#),
            ParsedToolCall(name: "add", arguments: #"{"a": 1, "b": 2}"#),
        ])
        #expect(result.content == "")
        let one = parse(chunked(#"<|python_tag|>{"name": "add", "parameters": {"a": 1}}"#, size), format: .bareJSON)
        #expect(one.calls.count == 1 && one.content == "")
        // One part that isn't a call, or something after the last call, and it's all text.
        let bad = #"<|python_tag|>{"name": "add", "parameters": {}}; {"name": "other", "parameters": {}}"#
        #expect(parse([bad], format: .bareJSON).calls.isEmpty)
        #expect(parse([bad], format: .bareJSON).content == bad)
        #expect(parse([#"{"name": "add", "parameters": {}} and more"#], format: .bareJSON).calls.isEmpty)
        // A reply that merely starts like the tag streams as text once it isn't one.
        #expect(parse(chunked("<|pyth no", size), format: .bareJSON).content == "<|pyth no")
    }

    @Test("Llama 3.1: a value written as a string is read as the schema's type")
    func bareJSONSchemaTypes() {
        let tools: [Value] = (try? OrderedJSON.parse(#"""
        [{"type":"function","function":{"name":"convert","parameters":{"type":"object","properties":{
          "base":{"type":"integer"},"scale":{"type":"number"},"exact":{"type":"boolean"},"digits":{"type":"array"},
          "label":{"type":"string"},"unit":{"type":"integer"}}}}}]
        """#).arrayValue) ?? []
        // Llama 3.1 8B's way with numbers (bench, 2026-10-02): `"base": "10"` for an integer.
        let raw = #"<|python_tag|>{"name": "convert", "parameters": {"base": "10", "scale": "2.5", "exact": "true", "digits": "[1, 2]", "label": "10", "unit": "ten", "extra": "7"}}"#
        #expect(parse([raw], format: .bareJSON, tools: tools).calls.first?.arguments
            ==
            #"{"base": 10, "scale": 2.5, "exact": true, "digits": [1, 2], "label": "10", "unit": "ten", "extra": "7"}"#)
        // Values already of the right type are left as written.
        let typed = #"{"name": "convert", "parameters": {"base": 10, "exact": false}}"#
        #expect(parse([typed], format: .bareJSON, tools: tools).calls.first?
            .arguments == #"{"base": 10, "exact": false}"#)
    }

    @Test("Qwen XML: several functions in one block are several calls; a JSON body is the arguments")
    func qwenXMLVariants() {
        let two = "<tool_call>\n<function=get_weather>\n<parameter=city>\nParis\n</parameter>\n</function>\n"
            + "<function=add>\n<parameter=a>\n1\n</parameter>\n</function>\n</tool_call>"
        #expect(parse([two], format: .qwenXML).calls == [
            ParsedToolCall(name: "get_weather", arguments: #"{"city":"Paris"}"#),
            ParsedToolCall(name: "add", arguments: #"{"a":1}"#),
        ])
        // MiMo V2.6's real reply: JSON inside the function tag, two blocks (bench, 2026-10-02).
        let mimo = #"<tool_call><function=get_weather>{"city": "Paris", "days": 2}</function></tool_call>"#
            + #"<tool_call><function=add>{"a": 1, "b": 2}</function></tool_call>"#
        #expect(parse(chunked(mimo, 5), format: .qwenXML).calls == [
            ParsedToolCall(name: "get_weather", arguments: #"{"city":"Paris","days":2}"#),
            ParsedToolCall(name: "add", arguments: #"{"a":1,"b":2}"#),
        ])
        // Text around the functions, an unknown tool among them, or a JSON body that doesn't parse: not a call.
        #expect(parse(["<tool_call>hi <function=add></function></tool_call>"], format: .qwenXML).calls.isEmpty)
        #expect(parse(
            ["<tool_call><function=add>{\"a\": 1}</function><function=nope></function></tool_call>"],
            format: .qwenXML
        ).calls.isEmpty)
        #expect(parse(["<tool_call><function=add>{\"a\": </function></tool_call>"], format: .qwenXML).calls.isEmpty)
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
        // The engine ends generation at <|call|> and keeps the token, so a call usually ends with the output:
        // gpt-oss-20b's real reply (bench, 2026-10-02), which every call had come back from as text.
        let real = "<|channel|>analysis<|message|>We need to call function add.<|end|><|start|>assistant"
            + "<|channel|>commentary to=functions.add <|constrain|>json<|message|>{\"a\":1,\"b\":2}"
        for size in [1, 6, 10000] {
            let result = harmony(real, size: size)
            #expect(result.calls == [ParsedToolCall(name: "add", arguments: #"{"a":1,"b":2}"#)])
            #expect(result.content == "")
            #expect(result.reasoning == "We need to call function add.")
        }
        // Invalid JSON arguments and a cut-off call are text.
        #expect(harmony("<|channel|>commentary to=functions.add<|message|>{oops<|call|>").calls.isEmpty)
        #expect(harmony("<|channel|>commentary to=functions.add<|message|>{\"a\":").calls.isEmpty)
    }

    // MARK: Muse Glimmer

    private func muse(
        _ raw: String,
        size: Int = 10000
    ) -> (content: String, reasoning: String, calls: [ParsedToolCall]) {
        parse(chunked(raw, size), format: .museGlimmer)
    }

    @Test("Muse Glimmer: to=self is reasoning, to=user the answer, however it's cut", arguments: [1, 3, 7, 10000])
    func museMessages(size: Int) {
        // The generation prompt ends `<|start|>assistant`, so a reply begins in the first message's header.
        let raw = " to=self<|message|>The user greets.<|eom|><|start|>assistant to=user<|message|>Hello there!"
        let result = muse(raw, size: size)
        #expect(result.reasoning == "The user greets.")
        #expect(result.content == "Hello there!")
        #expect(result.calls.isEmpty)
    }

    @Test("Muse Glimmer: an ATEM block to a tool is a call, typed by the tool's schema", arguments: [1, 5, 10000])
    func museCall(size: Int) {
        let raw = """
         to=self<|message|>Need weather.<|eom|><|start|>assistant to=get_weather<|message|><atem:function_calls>
        <atem:invoke name="get_weather">
        <atem:parameter name="city"> New York</atem:parameter>
        <atem:parameter name="days">3</atem:parameter>
        </atem:invoke>
        </atem:function_calls>
        """
        let result = muse(raw, size: size)
        #expect(result.reasoning == "Need weather.")
        // A string keeps its spaces (the template says they aren't stripped); an integer is JSON.
        #expect(result.calls == [ParsedToolCall(name: "get_weather", arguments: #"{"city":" New York","days":3}"#)])
        #expect(result.content == "")
    }

    @Test("Muse Glimmer: several calls, multi-line strings, and what isn't a call")
    func museVariants() {
        let two = """
         to=add<|message|><atem:function_calls>
        <atem:invoke name="add">
        <atem:parameter name="a">1</atem:parameter>
        <atem:parameter name="b">2.5</atem:parameter>
        <atem:parameter name="note">line one
        "line" <two></atem:parameter>
        </atem:invoke>
        </atem:function_calls><|eom|><|start|>assistant to=get_weather<|message|><atem:function_calls>
        <atem:invoke name="get_weather"><atem:parameter name="city">Paris</atem:parameter></atem:invoke>
        </atem:function_calls>
        """
        #expect(muse(two).calls == [
            ParsedToolCall(name: "add", arguments: #"{"a":1,"b":2.5,"note":"line one\n\"line\" <two>"}"#),
            ParsedToolCall(name: "get_weather", arguments: #"{"city":"Paris"}"#),
        ])
        // A tool the request didn't offer, a malformed block and a cut-off call are given back as text.
        let unknown = #" to=other<|message|><atem:function_calls><atem:invoke name="other"></atem:invoke></atem:function_calls>"#
        #expect(muse(unknown).calls.isEmpty)
        #expect(muse(unknown).content.hasPrefix("<atem:function_calls>"))
        #expect(muse(" to=add<|message|><atem:function_calls>oops</atem:function_calls>").calls.isEmpty)
        let cut = muse(" to=add<|message|><atem:function_calls>\n<atem:invoke name=\"add\">")
        #expect(cut.calls.isEmpty)
        #expect(cut.content == "<atem:function_calls>\n<atem:invoke name=\"add\">")
        // No recipient is the answer; a reply that never opened a message is the answer too.
        #expect(muse("<|message|>Plain.").content == "Plain.")
        #expect(muse("Just text").content == "Just text")
    }
}
