import Foundation
import Testing
@testable import Quail
@testable import QuailServerCore

@Suite("Anthropic /v1/messages", .timeLimit(.minutes(1)))
struct MessagesRoutesTests {
    private let path = "/v1/messages"
    private let hi = #"{"model":"Alpha","max_tokens":100,"messages":[{"role":"user","content":"Hi"}]}"#
    private static let weatherTool = #"[{"name":"get_weather","description":"Weather","input_schema":{"type":"object","properties":{"city":{"type":"string"}}}}]"#

    private func blocks(_ json: [String: Any]) -> [[String: Any]] {
        (json["content"] as? [[String: Any]]) ?? []
    }

    // MARK: whole replies

    @Test("a reply has Anthropic's message shape")
    func shape() async {
        let harness = RouteHarness()
        let reply = await harness.json(path, hi, headers: ["anthropic-version": "2023-06-01"])
        #expect(reply.status == 200)
        #expect(reply.json["type"] as? String == "message")
        #expect(reply.json["role"] as? String == "assistant")
        #expect((reply.json["id"] as? String)?.hasPrefix("msg_") == true)
        #expect(reply.json["model"] as? String == "Alpha")
        #expect(reply.json["stop_reason"] as? String == "end_turn")
        #expect(reply.json["stop_sequence"] is NSNull)
        #expect(blocks(reply.json).count == 1)
        #expect(blocks(reply.json).first?["type"] as? String == "text")
        #expect(blocks(reply.json).first?["text"] as? String == "Hello!")
        let usage = reply.json["usage"] as? [String: Any]
        #expect(usage?["output_tokens"] as? Int == 2)
        #expect(usage?["input_tokens"] as? Int == harness.prompt.utf8.count)
    }

    @Test("system, as a string or as text blocks, and the messages build the prompt")
    func promptFromRequest() async {
        let harness = RouteHarness()
        _ = await harness.json(
            path,
            #"{"model":"Alpha","max_tokens":9,"system":"Be terse.","messages":[{"role":"user","content":"Hi"}]}"#
        )
        #expect(harness
            .prompt ==
            "<|im_start|>system\nBe terse.<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n")

        _ = await harness.json(path, """
        {"model":"Alpha","max_tokens":9,
         "system":[{"type":"text","text":"One."},{"type":"text","text":"Two.","cache_control":{"type":"ephemeral"}}],
         "messages":[{"role":"user","content":[{"type":"text","text":"Hi"}]},{"role":"assistant","content":"Hello"},{"role":"user","content":"Again"}]}
        """)
        #expect(harness.prompt.contains("<|im_start|>system\nOne.\n\nTwo.<|im_end|>"))
        #expect(harness.prompt.contains("<|im_start|>assistant\nHello<|im_end|>\n<|im_start|>user\nAgain"))
    }

    @Test("reasoning comes back as a thinking block before the text")
    func thinking() async {
        let harness = RouteHarness(pieces: ["<think>", "\nHmm.\n", "</think>", "\n\n", "Hi"])
        let reply = await harness.json(path, hi)
        let blocks = blocks(reply.json)
        #expect(blocks.map { $0["type"] as? String } == ["thinking", "text"])
        #expect(blocks[0]["thinking"] as? String == "Hmm.\n")
        #expect(blocks[0]["signature"] as? String == "")
        #expect(blocks[1]["text"] as? String == "Hi")
    }

    @Test("a tool call is answered with tool_use, and the tools reach the template")
    func toolCall() async throws {
        let harness = RouteHarness(pieces: RouteHarness.hermesCall)
        let reply = await harness.json(
            path,
            #"{"model":"Alpha","max_tokens":99,"tools":\#(Self.weatherTool),"messages":[{"role":"user","content":"Weather?"}]}"#
        )
        #expect(reply.json["stop_reason"] as? String == "tool_use")
        let call = try #require(blocks(reply.json).first)
        #expect(blocks(reply.json).count == 1)
        #expect(call["type"] as? String == "tool_use")
        #expect(call["name"] as? String == "get_weather")
        #expect((call["id"] as? String)?.hasPrefix("toolu_") == true)
        #expect((call["input"] as? [String: Any])?["city"] as? String == "Paris")
        #expect(harness.prompt.contains(#"{"type": "function", "function": {"name": "get_weather""#))
    }

    @Test("tool_use and tool_result blocks in the history render as the model's own tool turns")
    func toolRoundTrip() async {
        let harness = RouteHarness()
        _ = await harness.json(path, """
        {"model":"Alpha","max_tokens":9,"tools":\(Self.weatherTool),"messages":[
          {"role":"user","content":"Weather?"},
          {"role":"assistant","content":[{"type":"text","text":"Checking."},{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"Paris"}}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"18C"}]},{"type":"text","text":"Thanks"}]}]}
        """)
        #expect(harness.prompt
            .contains("Checking.\n<tool_call>\n{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Paris\"}}"))
        #expect(harness.prompt.contains("<tool_response>\n18C\n</tool_response>"))
        #expect(harness.prompt.contains("<|im_start|>user\nThanks<|im_end|>"))
    }

    @Test("a reply cut off by max_tokens says so")
    func maxTokens() async {
        let harness = RouteHarness(pieces: ["a", "b", "c", "d", "e"])
        let reply = await harness.json(
            path,
            #"{"model":"Alpha","max_tokens":3,"messages":[{"role":"user","content":"Hi"}]}"#
        )
        #expect(reply.json["stop_reason"] as? String == "max_tokens")
        #expect(blocks(reply.json).first?["text"] as? String == "abc")
    }

    @Test("stop_sequences end the reply")
    func stopSequences() async {
        let harness = RouteHarness(pieces: ["Hel", "lo", " wor", "ld"])
        let reply = await harness.json(
            path,
            #"{"model":"Alpha","max_tokens":9,"stop_sequences":["wor"],"messages":[{"role":"user","content":"Hi"}]}"#
        )
        #expect(blocks(reply.json).first?["text"] as? String == "Hello ")
    }

    @Test("server tools are left out, and tool_choice none hides the rest")
    func toolFiltering() async {
        let harness = RouteHarness()
        let tools = #"[{"type":"web_search_20250305","name":"web_search"},{"name":"get_weather","input_schema":{"type":"object"}}]"#
        _ = await harness.json(
            path,
            #"{"model":"Alpha","max_tokens":9,"tools":\#(tools),"messages":[{"role":"user","content":"x"}]}"#
        )
        #expect(harness.prompt.contains("get_weather"))
        #expect(!harness.prompt.contains("web_search"))
        _ = await harness.json(
            path,
            #"{"model":"Alpha","max_tokens":9,"tools":\#(tools),"tool_choice":{"type":"none"},"messages":[{"role":"user","content":"x"}]}"#
        )
        #expect(!harness.prompt.contains("get_weather"))
    }

    // MARK: errors

    @Test("tool_choice any and tool force a call, and a named tool keeps its name")
    func forcedToolChoice() async {
        let tools = #"[{"name":"get_weather","input_schema":{"type":"object","properties":{"city":{"type":"string"}}}},{"name":"get_time","input_schema":{"type":"object"}}]"#
        let any = RouteHarness(grammar: true)
        _ = await any.json(
            path,
            #"{"model":"Alpha","max_tokens":9,"tool_choice":{"type":"any"},"tools":\#(tools),"messages":[{"role":"user","content":"x"}]}"#
        )
        let anyGrammar = any.world.requests.last?.grammar ?? ""
        #expect(anyGrammar.contains("get_weather") && anyGrammar.contains("get_time"))

        let named = RouteHarness(grammar: true)
        _ = await named.json(
            path,
            #"{"model":"Alpha","max_tokens":9,"tool_choice":{"type":"tool","name":"get_time"},"tools":\#(tools),"messages":[{"role":"user","content":"x"}]}"#
        )
        let namedGrammar = named.world.requests.last?.grammar ?? ""
        #expect(namedGrammar.contains("get_time") && !namedGrammar.contains("get_weather"))

        let nameless = await named.json(
            path,
            #"{"model":"Alpha","max_tokens":9,"tool_choice":{"type":"tool"},"tools":\#(tools),"messages":[{"role":"user","content":"x"}]}"#
        )
        #expect(nameless.status == 400)
    }

    @Test("errors use Anthropic's shape")
    func errors() async {
        let harness = RouteHarness()
        for body in [
            #"{"model":"Alpha","max_tokens":9}"#,
            #"{"model":"Alpha","max_tokens":9,"messages":[]}"#,
            #"{"max_tokens":9,"messages":[{"role":"user","content":"x"}]}"#,
            #"{"model":"Nope","max_tokens":9,"messages":[{"role":"user","content":"x"}]}"#,
            #"{"model":"Alpha","max_tokens":9,"messages":[{"role":"user","content":[{"type":"image","source":{}}]}]}"#,
            #"{"model":"Alpha","max_tokens":9,"tool_choice":{"type":"any"},"tools":\#(Self.weatherTool),"messages":[{"role":"user","content":"x"}]}"#,
        ] {
            let reply = await harness.json(path, body)
            #expect(reply.status == 400, "\(body)")
            #expect(reply.json["type"] as? String == "error", "\(body)")
            let error = reply.json["error"] as? [String: Any]
            #expect(error?["type"] as? String == "invalid_request_error", "\(body)")
            #expect((error?["message"] as? String)?.isEmpty == false, "\(body)")
        }
    }

    @Test("the key may come as x-api-key, as Anthropic clients send it")
    func apiKey() async {
        let harness = RouteHarness(apiKey: "sekret")
        #expect(await harness.json(path, hi).status == 401)
        #expect(await harness.json(path, hi, headers: ["x-api-key": "sekret"]).status == 200)
    }

    // MARK: count_tokens

    @Test("count_tokens gives the prompt's token count without generating")
    func countTokens() async {
        let harness = RouteHarness()
        let reply = await harness.json(
            "/v1/messages/count_tokens",
            #"{"model":"Alpha","system":"Be terse.","messages":[{"role":"user","content":"Hi"}]}"#
        )
        #expect(reply.status == 200)
        let expected = "<|im_start|>system\nBe terse.<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n"
            .utf8.count
        #expect(reply.json["input_tokens"] as? Int == expected)
        #expect(harness.world.requests.isEmpty)
    }

    // MARK: streaming

    @Test("a streamed reply is message_start, one block with deltas, message_delta, message_stop")
    func streamText() async {
        let harness = RouteHarness()
        let stream = await harness.events(
            path,
            #"{"model":"Alpha","max_tokens":9,"stream":true,"messages":[{"role":"user","content":"Hi"}]}"#
        )
        #expect(stream.status == 200)
        #expect(stream.events.map(\.name) == [
            "message_start", "content_block_start", "content_block_delta", "content_block_delta",
            "content_block_stop", "message_delta", "message_stop",
        ])
        #expect(!stream.raw.contains("[DONE]"))
        #expect(stream.events.allSatisfy { $0["type"] as? String == $0.name })
        let start = stream.events[0]["message"] as? [String: Any]
        #expect(start?["id"] is String)
        #expect(start?["stop_reason"] is NSNull)
        #expect((start?["usage"] as? [String: Any])?["input_tokens"] as? Int == harness.prompt.utf8.count)
        #expect((stream.events[1]["content_block"] as? [String: Any])?["type"] as? String == "text")
        let deltas = stream.events[2 ... 3].compactMap { ($0["delta"] as? [String: Any])?["text"] as? String }
        #expect(deltas == ["Hello", "!"])
        let end = stream.events[5]
        #expect((end["delta"] as? [String: Any])?["stop_reason"] as? String == "end_turn")
        #expect((end["usage"] as? [String: Any])?["output_tokens"] as? Int == 2)
    }

    @Test("a thinking block is closed, with its signature, before the text block opens")
    func streamThinking() async {
        let harness = RouteHarness(pieces: ["<think>", "\nHmm.\n", "</think>", "\n\n", "Hi"])
        let stream = await harness.events(
            path,
            #"{"model":"Alpha","max_tokens":9,"stream":true,"messages":[{"role":"user","content":"Hi"}]}"#
        )
        func kind(_ event: RouteHarness.Event) -> String {
            let inner = (event["content_block"] ?? event["delta"]) as? [String: Any]
            return "\(event.name):\(event["index"] ?? "-"):\(inner?["type"] ?? "")"
        }
        #expect(stream.events.map(kind) == [
            "message_start:-:", "content_block_start:0:thinking", "content_block_delta:0:thinking_delta",
            "content_block_delta:0:signature_delta", "content_block_stop:0:",
            "content_block_start:1:text", "content_block_delta:1:text_delta", "content_block_stop:1:",
            "message_delta:-:", "message_stop:-:",
        ])
    }

    @Test("a streamed tool call is a tool_use block with its whole input in one delta")
    func streamToolUse() async throws {
        let harness = RouteHarness(pieces: RouteHarness.hermesCall)
        let stream = await harness.events(
            path,
            #"{"model":"Alpha","max_tokens":99,"stream":true,"tools":\#(Self.weatherTool),"messages":[{"role":"user","content":"W?"}]}"#
        )
        #expect(stream.events.map(\.name) == [
            "message_start", "content_block_start", "content_block_delta", "content_block_stop", "message_delta",
            "message_stop",
        ])
        let block = try #require(stream.events[1]["content_block"] as? [String: Any])
        #expect(block["type"] as? String == "tool_use")
        #expect(block["name"] as? String == "get_weather")
        #expect((block["input"] as? [String: Any])?.isEmpty == true)
        let delta = try #require(stream.events[2]["delta"] as? [String: Any])
        #expect(delta["type"] as? String == "input_json_delta")
        #expect(delta["partial_json"] as? String == #"{"city": "Paris"}"#)
        #expect((stream.events[4]["delta"] as? [String: Any])?["stop_reason"] as? String == "tool_use")
    }

    @Test("a failure to start is an HTTP error, not an event")
    func streamStartFailure() async {
        let harness = RouteHarness()
        let stream = await harness.events(
            path,
            #"{"model":"Nope","max_tokens":9,"stream":true,"messages":[{"role":"user","content":"x"}]}"#
        )
        #expect(stream.status == 400)
    }
}
