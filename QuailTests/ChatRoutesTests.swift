import Foundation
import Testing
@testable import Quail
@testable import QuailServerCore

@Suite("Chat completions", .timeLimit(.minutes(1)))
struct ChatRoutesTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestFixtures/ChatTemplates/templates")

    private static func template(_ name: String) -> String {
        (try? String(contentsOf: fixtures.appendingPathComponent("\(name).jinja"), encoding: .utf8)) ?? ""
    }

    private struct Harness {
        let routes: ServerRoutes
        let router: ModelRouter
        let world = ScriptedWorld()

        init(
            pieces: [String] = ["Hello", "!"],
            template: String? = ChatRoutesTests.template("qwen3"),
            bos: String = "",
            apiKey: String? = nil,
            configure: @escaping @Sendable (inout ScriptedEngine) -> Void = { _ in }
        ) {
            let world = world
            let log = ServerLog(toStandardError: false)
            router = ModelRouter(
                entries: [.fake("Alpha")],
                modelsMax: 1,
                makeEngine: { _ in
                    var engine = ScriptedEngine(world: world)
                    engine.pieces = pieces
                    engine.template = template
                    engine.bos = bos
                    engine.eos = "<|im_end|>"
                    configure(&engine)
                    return engine
                },
                log: log
            )
            routes = ServerRoutes(router: router, apiKey: apiKey, log: log, buildLabel: "quail-server test")
        }

        func send(_ body: String, method: String = "POST", headers: [String: String] = [:]) async -> HTTPResponse {
            await routes.handle(HTTPRequest(
                method: method, target: "/v1/chat/completions", headers: headers, body: Data(body.utf8)
            ))
        }

        func json(_ body: String) async -> (status: Int, json: [String: Any]) {
            let response = await send(body)
            guard case let .data(data) = response.body else { return (response.status, [:]) }
            return (response.status, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
        }

        func frames(_ body: String) async -> (status: Int, frames: [String]) {
            let response = await send(body)
            guard case let .stream(chunks) = response.body else { return (response.status, []) }
            var text = ""
            for await chunk in chunks {
                text += String(decoding: chunk, as: UTF8.self)
            }
            return (response.status, text.components(separatedBy: "\n\n").compactMap {
                $0.hasPrefix("data: ") ? String($0.dropFirst(6)) : nil
            })
        }

        /// The prompt text the engine was handed (its "tokens" are UTF-8 bytes).
        var prompt: String {
            String(
                decoding: (world.requests.last?.promptTokens ?? []).map { UInt8(truncatingIfNeeded: $0) },
                as: UTF8.self
            )
        }
    }

    private func object(_ text: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:]
    }

    private func message(_ json: [String: Any]) -> [String: Any] {
        ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
    }

    private func delta(_ frame: String) -> [String: Any] {
        ((object(frame)["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]) ?? [:]
    }

    private let hi = #"{"model":"Alpha","messages":[{"role":"user","content":"Hi"}]}"#

    // MARK: shape

    @Test("a reply comes back in llama-server's shape")
    func shape() async {
        let harness = Harness()
        let reply = await harness.json(hi)
        #expect(reply.status == 200)
        #expect(reply.json["object"] as? String == "chat.completion")
        #expect(reply.json["model"] as? String == "Alpha")
        #expect((reply.json["id"] as? String)?.hasPrefix("chatcmpl-") == true)
        let choice = (reply.json["choices"] as? [[String: Any]])?.first
        #expect(choice?["finish_reason"] as? String == "stop")
        #expect(choice?["index"] as? Int == 0)
        let message = message(reply.json)
        #expect(message["role"] as? String == "assistant")
        #expect(message["content"] as? String == "Hello!")
        #expect(message["reasoning_content"] == nil)
        #expect((reply.json["usage"] as? [String: Any])?["completion_tokens"] as? Int == 2)
        #expect((reply.json["timings"] as? [String: Any])?["predicted_n"] as? Int == 2)
    }

    @Test("the model's own template builds the prompt the engine sees")
    func promptFromTemplate() async {
        let harness = Harness()
        _ = await harness
            .json(
                #"{"model":"Alpha","messages":[{"role":"system","content":"Be terse."},{"role":"user","content":"Hi"}]}"#
            )
        #expect(harness
            .prompt ==
            "<|im_start|>system\nBe terse.<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n")
        // Tokenized as special-token-aware text, with no BOS asked for (this template has none, and the
        // engine adds one only if its vocabulary wants it).
        #expect(harness.world.tokenizations.last?.parseSpecial == true)
    }

    @Test("a model with no template gets llama.cpp's ChatML fallback")
    func chatMLFallback() async {
        let harness = Harness(template: nil)
        _ = await harness.json(hi)
        #expect(harness.prompt == "<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n")
    }

    @Test("a prompt that already starts with the BOS text isn't given a second one")
    func noDoubleBOS() async {
        let bosTemplate = "{{ bos_token }}{% for m in messages %}{{ m['content'] }}{% endfor %}"
        let withBOS = Harness(template: bosTemplate, bos: "<s>")
        _ = await withBOS.json(hi)
        #expect(withBOS.world.tokenizations.last?.addSpecial == false)
        let without = Harness(template: "{% for m in messages %}{{ m['content'] }}{% endfor %}", bos: "<s>")
        _ = await without.json(hi)
        #expect(without.world.tokenizations.last?.addSpecial == true)
    }

    @Test("sampling settings, stop strings and max_tokens work as they do for completions")
    func settings() async {
        let harness = Harness(pieces: ["one", " two", " three"])
        let reply = await harness
            .json(
                #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"stop":[" two"],"temperature":0,"seed":7,"max_tokens":50}"#
            )
        #expect(message(reply.json)["content"] as? String == "one")
        let request = harness.world.requests.last
        #expect(request?.sampling.temperature == 0)
        #expect(request?.sampling.seed == 7)
        #expect(request?.maxTokens == 50)

        let short = await harness
            .json(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"max_completion_tokens":1}"#)
        #expect((short.json["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "length")
    }

    // MARK: reasoning

    @Test("reasoning goes to reasoning_content and the answer to content")
    func reasoning() async {
        let harness = Harness(pieces: ["<think>", "\nHmm,", " ok.\n", "</think>", "\n\n", "Hi", "!"])
        let reply = await harness.json(hi)
        #expect(message(reply.json)["reasoning_content"] as? String == "Hmm, ok.\n")
        #expect(message(reply.json)["content"] as? String == "Hi!")
    }

    @Test("a template that leaves <think> open makes generation start in the reasoning")
    func forcedThinking() async {
        let open = "{% for m in messages %}{{ m['content'] }}{% endfor %}{% if add_generation_prompt %}<think>\n{% endif %}"
        let harness = Harness(pieces: ["Because", "</think>", "Done"], template: open)
        let reply = await harness.json(hi)
        #expect(message(reply.json)["reasoning_content"] as? String == "Because")
        #expect(message(reply.json)["content"] as? String == "Done")
    }

    @Test("enable_thinking:false reaches Qwen3's template and no reasoning is opened")
    func enableThinking() async {
        let harness = Harness()
        _ = await harness
            .json(
                #"{"model":"Alpha","messages":[{"role":"user","content":"Hi"}],"chat_template_kwargs":{"enable_thinking":false}}"#
            )
        #expect(harness.prompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }

    // MARK: streaming

    @Test("a stream opens with the role, then deltas, then a finish chunk with timings, then [DONE]")
    func streaming() async throws {
        let harness = Harness(pieces: ["<think>", "a", "</think>", "b", "c"])
        let (status, frames) = await harness
            .frames(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"stream":true}"#)
        #expect(status == 200)
        #expect(frames.last == "[DONE]")
        let chunks = frames.dropLast()
        let first = try delta(#require(chunks.first))
        #expect(first["role"] as? String == "assistant")
        #expect(first.keys.contains("content"))
        #expect(first["content"] is NSNull)

        let deltas = chunks.dropFirst().dropLast().map(delta)
        #expect(deltas.compactMap { $0["reasoning_content"] as? String }.joined() == "a")
        #expect(deltas.compactMap { $0["content"] as? String }.joined() == "bc")

        let last = try object(#require(chunks.last))
        let choice = (last["choices"] as? [[String: Any]])?.first
        #expect(choice?["finish_reason"] as? String == "stop")
        #expect((choice?["delta"] as? [String: Any])?.isEmpty == true)
        #expect((last["timings"] as? [String: Any])?["predicted_n"] as? Int == 5)
        #expect(last["usage"] == nil) // only when asked for
        #expect(try object(#require(chunks.first))["object"] as? String == "chat.completion.chunk")
        #expect(Set(chunks.compactMap { object($0)["id"] as? String }).count == 1)
        #expect(await harness.router.leaseCount("Alpha") == 0)
    }

    @Test("stream_options.include_usage adds a final chunk with no choices and the usage")
    func includeUsage() async {
        let harness = Harness()
        let (_, frames) = await harness
            .frames(
                #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"stream":true,"stream_options":{"include_usage":true}}"#
            )
        let last = object(frames[frames.count - 2])
        #expect((last["choices"] as? [Any])?.isEmpty == true)
        #expect((last["usage"] as? [String: Any])?["completion_tokens"] as? Int == 2)
        #expect(last["timings"] != nil)
    }

    @Test("`quail chat`'s own SSE parser reads the stream unchanged: reasoning, deltas, timings, done")
    func quailChatParser() async {
        let harness = Harness(pieces: ["<think>", "why", "</think>", "Hel", "lo"])
        let (_, frames) = await harness
            .frames(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"stream":true}"#)
        let events = frames.flatMap { ChatStreamParser.events(fromLine: "data: \($0)") }
        #expect(events.contains(.reasoning("why")))
        #expect(events.compactMap {
            if case let .delta(text) = $0 {
                text
            } else {
                nil
            }
        }.joined() == "Hello")
        #expect(events.contains {
            if case .timings(_, _, 5?) = $0 {
                true
            } else {
                false
            }
        })
        #expect(events.last == .done)
    }

    // MARK: tools and messages

    @Test("tools reach the template; tool_choice none hides them")
    func tools() async throws {
        let tools = #"[{"type":"function","function":{"name":"get_weather","description":"Weather","parameters":{"type":"object","properties":{"unit":{"type":"string"},"city":{"type":"string"}}}}}]"#
        let harness = Harness()
        _ = await harness.json(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"tools":\#(tools)}"#)
        #expect(harness.prompt.contains("<tools>"))
        #expect(harness.prompt.contains(#"{"type": "function", "function": {"name": "get_weather""#))
        // Order preserved: unit before city.
        #expect(try #require(harness.prompt.range(of: #""unit""#)?.lowerBound) < harness.prompt.range(of: #""city""#)!
            .lowerBound)

        _ = await harness
            .json(
                #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"tools":\#(tools),"tool_choice":"none"}"#
            )
        #expect(!harness.prompt.contains("<tools>"))
    }

    private static let weatherTools = #"[{"type":"function","function":{"name":"get_weather","description":"Weather","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}]"#
    private static let hermesCall = [
        "<tool_call>\n",
        #"{"name": "get_weather", "arguments": {"city": "Paris"}}"#,
        "\n</tool_call>",
    ]

    @Test("a tool call comes back as message.tool_calls, with finish_reason tool_calls and empty content")
    func toolCallReply() async throws {
        let harness = Harness(pieces: Self.hermesCall)
        let reply = await harness
            .json(#"{"model":"Alpha","messages":[{"role":"user","content":"Weather?"}],"tools":\#(Self.weatherTools)}"#)
        #expect(reply.status == 200)
        let choice = (reply.json["choices"] as? [[String: Any]])?.first
        #expect(choice?["finish_reason"] as? String == "tool_calls")
        let message = try #require(choice?["message"] as? [String: Any])
        #expect(message["content"] as? String == "")
        let calls = try #require(message["tool_calls"] as? [[String: Any]])
        #expect(calls.count == 1)
        #expect(calls[0]["type"] as? String == "function")
        #expect((calls[0]["id"] as? String)?.count == 32)
        #expect((calls[0]["function"] as? [String: Any])?["name"] as? String == "get_weather")
        #expect((calls[0]["function"] as? [String: Any])?["arguments"] as? String == #"{"city": "Paris"}"#)
    }

    @Test("a streamed tool call is one delta with its index, id and whole arguments, then finish tool_calls")
    func toolCallStream() async {
        let twoCalls = Self.hermesCall + ["\n"] + Self.hermesCall
        let harness = Harness(pieces: twoCalls)
        let (_, frames) = await harness
            .frames(
                #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"tools":\#(Self.weatherTools),"stream":true}"#
            )
        let chunks = frames.dropLast().map(object)
        let calls = chunks
            .compactMap {
                (($0["choices"] as? [[String: Any]])?
                    .first?["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
            }.flatMap(\.self)
        #expect(calls.count == 2)
        #expect(calls.map { $0["index"] as? Int } == [0, 1])
        #expect(calls.allSatisfy { ($0["id"] as? String)?.count == 32 && $0["type"] as? String == "function" })
        #expect(calls.compactMap { ($0["function"] as? [String: Any])?["arguments"] as? String } == [
            #"{"city": "Paris"}"#,
            #"{"city": "Paris"}"#,
        ])
        let finish = (chunks.last?["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String
        #expect(finish == "tool_calls")
        // Content stays empty: nothing but the calls.
        #expect(!chunks
            .contains { (($0["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] is String
            })
    }

    @Test("text before a tool call is content; without tools in the request a call stays text")
    func toolCallContent() async {
        let harness = Harness(pieces: ["Looking it up.\n"] + Self.hermesCall)
        let with = await harness
            .json(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"tools":\#(Self.weatherTools)}"#)
        #expect(message(with.json)["content"] as? String == "Looking it up.")
        let without = await harness.json(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}]}"#)
        #expect(message(without.json)["tool_calls"] == nil)
        #expect((message(without.json)["content"] as? String)?.contains("<tool_call>") == true)
    }

    @Test("reasoning and a tool call in one reply are both kept")
    func reasoningThenCall() async {
        let harness = Harness(pieces: ["<think>\nNeed weather.\n</think>\n\n"] + Self.hermesCall)
        let reply = await harness
            .json(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"tools":\#(Self.weatherTools)}"#)
        #expect(message(reply.json)["reasoning_content"] as? String == "Need weather.\n")
        #expect((message(reply.json)["tool_calls"] as? [Any])?.count == 1)
    }

    @Test("auto and none are accepted; forcing a call needs an engine with a grammar sampler")
    func toolChoice() async {
        func request(_ choice: String) -> String {
            #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"tools":\#(Self.weatherTools),"tool_choice":\#(choice)}"#
        }
        let harness = Harness()
        #expect(await harness.json(request(#""auto""#)).status == 200)
        #expect(await harness.json(request(#""none""#)).status == 200)
        for choice in [#""required""#, #"{"type":"function","function":{"name":"get_weather"}}"#] {
            let reply = await harness.json(request(choice))
            #expect(reply.status == 400)
            #expect((reply.json["error"] as? [String: Any])?["message"] as? String ==
                "the engine serving this model can't constrain its output yet (response_format, json_schema, grammar, tool_choice)")
        }
    }

    @Test("a forced call becomes a grammar in the model's own call format")
    func forcedCall() async {
        let two = #"[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}},{"type":"function","function":{"name":"get_time"}}]"#
        func grammar(_ template: String, _ extra: String, tools: String = two) async -> String {
            let harness = Harness(template: Self.template(template)) { $0.capabilities = .init(grammar: true) }
            let reply = await harness.json(
                #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"tools":\#(tools),\#(extra)}"#
            )
            #expect(reply.status == 200, "\(template) \(extra)")
            return harness.world.requests.last?.grammar ?? ""
        }

        let required = await grammar("qwen3", #""tool_choice":"required""#)
        #expect(required.contains("\"<tool_call>\" tool-space"))
        #expect(required.contains("get_weather") && required.contains("get_time"))
        #expect(required.contains("\"<think>\"")) // Qwen3 thinks first
        #expect(!required.contains(")+"))

        let named = await grammar("qwen3", #""tool_choice":{"type":"function","function":{"name":"get_time"}}"#)
        #expect(named.contains("get_time") && !named.contains("get_weather"))

        #expect(await grammar("qwen3", #""tool_choice":"required","parallel_tool_calls":true"#).contains(")+"))

        let bare = await grammar("llama3", #""tool_choice":"required""#)
        #expect(bare.contains("parameters") && !bare.contains("<tool_call>") && !bare.contains("think"))
    }

    @Test("a call that can't be forced is a 400 that says why", arguments: [
        (
            "qwen3",
            #""tool_choice":{"type":"function","function":{"name":"nope"}}"#,
            "tool_choice names \"nope\", which isn't in 'tools'"
        ),
        (
            "qwen3",
            #""tool_choice":"required","response_format":{"type":"json_object"}"#,
            "tool_choice can't be combined with response_format, json_schema or grammar"
        ),
        ("qwen3", #""tool_choice":"required","parallel_tool_calls":"yes""#, "'parallel_tool_calls' must be a boolean"),
        ("qwen3", #""tool_choice":"sometimes""#, "tool_choice \"sometimes\" isn't supported"),
        ("qwen3", #""tool_choice":{"type":"function"}"#, "tool_choice with a specific function needs its name"),
        (
            "qwen36",
            #""tool_choice":"required""#,
            "forcing a tool call isn't supported for this model's chat format (Qwen XML) yet"
        ),
        (
            "gptoss",
            #""tool_choice":"required""#,
            "forcing a tool call isn't supported for this model's chat format (Harmony) yet"
        ),
    ])
    func forcedCallRefused(template: String, extra: String, message: String) async {
        let harness = Harness(template: Self.template(template)) { $0.capabilities = .init(grammar: true) }
        let reply = await harness.json(
            #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"tools":\#(Self.weatherTools),\#(extra)}"#
        )
        #expect(reply.status == 400)
        #expect((reply.json["error"] as? [String: Any])?["message"] as? String == message)
        #expect(harness.world.requests.isEmpty)
    }

    @Test("forcing a call with no tools is a 400")
    func forcedCallWithoutTools() async {
        let harness = Harness { $0.capabilities = .init(grammar: true) }
        let reply = await harness
            .json(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"tool_choice":"required"}"#)
        #expect(reply.status == 400)
    }

    @Test("a tool-call round trip renders the arguments as an object")
    func toolRoundTrip() async {
        let harness = Harness()
        _ = await harness.json("""
        {"model":"Alpha","messages":[
          {"role":"user","content":"Weather?"},
          {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"get_weather","arguments":"{\\"city\\": \\"Paris\\"}"}}]},
          {"role":"tool","tool_call_id":"c1","content":"18 and cloudy"}]}
        """)
        #expect(harness.prompt
            .contains(#"<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}"#.replacingOccurrences(
                of: "\\n",
                with: "\n"
            )))
        #expect(harness.prompt.contains("<tool_response>\n18 and cloudy\n</tool_response>"))
    }

    @Test("text parts are joined with a newline for templates that want a string")
    func contentParts() async {
        let harness = Harness()
        _ = await harness
            .json(
                #"{"model":"Alpha","messages":[{"role":"user","content":[{"type":"text","text":"AAA"},{"type":"text","text":"BBB"}]}]}"#
            )
        #expect(harness.prompt.contains("AAA\nBBB"))
    }

    @Test("a template that only handles typed parts is given them")
    func typedContent() async {
        let typedOnly = "{% for m in messages %}{% for part in m['content'] %}[{{ part['text'] }}]{% endfor %}{% endfor %}"
        let harness = Harness(template: typedOnly)
        _ = await harness
            .json(
                #"{"model":"Alpha","messages":[{"role":"user","content":[{"type":"text","text":"AAA"},{"type":"text","text":"BBB"}]}]}"#
            )
        #expect(harness.prompt == "[AAA][BBB]")
    }

    @Test("developer becomes system, unless the template knows the role")
    func developerRole() async {
        let plain = Harness()
        _ = await plain
            .json(
                #"{"model":"Alpha","messages":[{"role":"developer","content":"Be terse"},{"role":"user","content":"hi"}]}"#
            )
        #expect(plain.prompt.hasPrefix("<|im_start|>system\nBe terse"))

        let harmony = Harness(template: Self.template("gptoss"))
        _ = await harmony
            .json(
                #"{"model":"Alpha","messages":[{"role":"developer","content":"Be terse"},{"role":"user","content":"hi"}]}"#
            )
        #expect(harmony.prompt.contains("<|start|>developer<|message|># Instructions\n\nBe terse"))
    }

    // MARK: errors

    @Test("bad chat requests are 400s", arguments: [
        (#"{"model":"Alpha"}"#, "'messages' is required"),
        (#"{"model":"Alpha","messages":"hi"}"#, "Expected 'messages' to be an array"),
        (#"{"model":"Alpha","messages":[]}"#, "'messages' must not be empty"),
        (#"{"model":"Alpha","messages":[{"content":"x"}]}"#, "each message needs a \"role\""),
        (#"{"model":"Alpha","messages":[5]}"#, "each message needs a \"role\""),
        (
            #"{"model":"Alpha","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:x"}}]}]}"#,
            "image_url input is not supported yet; quail-server has no vision engine"
        ),
        (
            #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"response_format":{"type":"xml"}}"#,
            "response_format \"xml\" isn't supported"
        ),
        (
            #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"response_format":{"type":"json_object"}}"#,
            "the engine serving this model can't constrain its output yet (response_format, json_schema, grammar, tool_choice)"
        ),
        (
            #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"response_format":{"type":"json_schema"}}"#,
            "response_format \"json_schema\" needs a json_schema.schema"
        ),
        (
            #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"grammar":5}"#,
            "'grammar' must be a string"
        ),
        (
            #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"json_schema":{"type":"string","pattern":"a+"}}"#,
            "the JSON schema can't be used: the JSON schema keyword \"pattern\" isn't supported yet (at #)"
        ),
        (#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"tools":5}"#, "'tools' must be an array"),
        (
            #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"chat_template_kwargs":[]}"#,
            "'chat_template_kwargs' must be an object"
        ),
    ])
    func badRequests(body: String, message: String) async {
        let reply = await Harness().json(body)
        #expect(reply.status == 400)
        #expect((reply.json["error"] as? [String: Any])?["message"] as? String == message)
    }

    @Test("a conversation the template rejects is a 400 with its own explanation")
    func templateRejects() async {
        let harness = Harness(template: Self.template("gemma3"))
        let reply = await harness
            .json(#"{"model":"Alpha","messages":[{"role":"user","content":"a"},{"role":"user","content":"b"}]}"#)
        #expect(reply.status == 400)
        #expect(((reply.json["error"] as? [String: Any])?["message"] as? String)?
            .contains("Conversation roles must alternate") == true)
        #expect(harness.world.requests.isEmpty) // nothing was generated
        #expect(await harness.router.leaseCount("Alpha") == 0)
    }

    @Test("the response_format text type is accepted")
    func responseFormatText() async {
        let reply = await Harness()
            .json(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"response_format":{"type":"text"}}"#)
        #expect(reply.status == 200)
    }

    @Test("response_format, json_schema and grammar become a grammar for an engine that can use one")
    func constrainedOutput() async {
        let schema = #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#
        let bodies = [
            #""response_format":{"type":"json_object"}"#,
            #""response_format":{"type":"json_schema","json_schema":{"name":"x","schema":\#(schema)}}"#,
            #""json_schema":\#(schema)"#,
        ]
        for fields in bodies {
            let harness = Harness(template: Self.template("llama3")) { $0.capabilities = .init(grammar: true) }
            let reply = await harness.json(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],\#(fields)}"#)
            #expect(reply.status == 200)
            let grammar = harness.world.requests.last?.grammar ?? ""
            #expect(grammar.contains("root ::="), "\(fields)")
            #expect(!grammar.contains("think"), "a template without thinking gets a plain grammar")
        }

        let named = Harness(template: Self.template("llama3")) { $0.capabilities = .init(grammar: true) }
        _ = await named.json(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"json_schema":\#(schema)}"#)
        #expect(named.world.requests.last?.grammar?.contains("name-kv") == true)

        let raw = Harness { $0.capabilities = .init(grammar: true) }
        _ = await raw
            .json(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"grammar":"root ::= \"yes\""}"#)
        #expect(raw.world.requests.last?.grammar == #"root ::= "yes""#, "a client's own grammar is passed through")

        let plain = Harness { $0.capabilities = .init(grammar: true) }
        _ = await plain.json(#"{"model":"Alpha","messages":[{"role":"user","content":"x"}]}"#)
        #expect(plain.world.requests.last?.grammar == nil)
    }

    @Test("a template that thinks gets a grammar that lets the thinking block come first")
    func constrainedOutputAfterThinking() async {
        let harness = Harness(template: Self.template("qwen3")) { $0.capabilities = .init(grammar: true) }
        _ = await harness.json(
            #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"response_format":{"type":"json_object"}}"#
        )
        let grammar = harness.world.requests.last?.grammar ?? ""
        #expect(grammar.contains("\"<think>\" think-0 \"</think>\""))
        #expect(grammar.contains("json-root"))
    }

    @Test("constrained output isn't offered for the Harmony format yet")
    func constrainedHarmony() async {
        let harness = Harness(template: Self.template("gptoss")) { $0.capabilities = .init(grammar: true) }
        let reply = await harness.json(
            #"{"model":"Alpha","messages":[{"role":"user","content":"x"}],"response_format":{"type":"json_object"}}"#
        )
        #expect(reply.status == 400)
        #expect((reply.json["error"] as? [String: Any])?["message"] as? String
            == "constrained output isn't supported for this model's chat format (Harmony) yet")
        #expect(harness.world.requests.isEmpty)
    }

    @Test("wrong method is a 405 and the API key is required")
    func methodAndAuth() async {
        let harness = Harness(apiKey: "k")
        #expect(await harness.send(hi).status == 401)
        #expect(await harness.send("", method: "GET", headers: ["authorization": "Bearer k"]).status == 405)
        #expect(await harness.send(hi, headers: ["authorization": "Bearer k"]).status == 200)
    }

    @Test("the unprefixed /chat/completions works too, as in llama-server")
    func unprefixed() async {
        let harness = Harness()
        let response = await harness.routes.handle(HTTPRequest(
            method: "POST", target: "/chat/completions", headers: [:], body: Data(hi.utf8)
        ))
        #expect(response.status == 200)
    }
}
