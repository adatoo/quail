import Foundation
import Testing
@testable import Quail
@testable import QuailServerCore

@Suite("OpenAI /v1/responses", .timeLimit(.minutes(1)))
struct ResponsesRoutesTests {
    private let path = "/v1/responses"
    private let hi = #"{"model":"Alpha","input":"Hi"}"#
    private static let weatherTool = #"[{"type":"function","name":"get_weather","description":"Weather","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}]"#

    private func output(_ json: [String: Any]) -> [[String: Any]] {
        (json["output"] as? [[String: Any]]) ?? []
    }

    // MARK: whole replies

    @Test("a reply has the Responses shape")
    func shape() async throws {
        let harness = RouteHarness()
        let reply = await harness.json(path, hi)
        #expect(reply.status == 200)
        #expect(reply.json["object"] as? String == "response")
        #expect(reply.json["status"] as? String == "completed")
        #expect(reply.json["model"] as? String == "Alpha")
        #expect((reply.json["id"] as? String)?.hasPrefix("resp_") == true)
        let message = try #require(output(reply.json).first)
        #expect(output(reply.json).count == 1)
        #expect(message["type"] as? String == "message")
        #expect(message["role"] as? String == "assistant")
        #expect(message["status"] as? String == "completed")
        #expect((message["id"] as? String)?.hasPrefix("msg_") == true)
        let part = try #require((message["content"] as? [[String: Any]])?.first)
        #expect(part["type"] as? String == "output_text")
        #expect(part["text"] as? String == "Hello!")
        let usage = reply.json["usage"] as? [String: Any]
        #expect(usage?["output_tokens"] as? Int == 2)
        #expect(usage?["input_tokens"] as? Int == harness.prompt.utf8.count)
        #expect(usage?["total_tokens"] as? Int == harness.prompt.utf8.count + 2)
    }

    @Test("instructions become the system message and a string input the user's")
    func promptFromRequest() async {
        let harness = RouteHarness()
        _ = await harness.json(path, #"{"model":"Alpha","instructions":"Be terse.","input":"Hi"}"#)
        #expect(harness
            .prompt ==
            "<|im_start|>system\nBe terse.<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n")
    }

    @Test("input items: typed messages, function calls and their outputs")
    func inputItems() async {
        let harness = RouteHarness()
        _ = await harness.json(path, """
        {"model":"Alpha","tools":\(Self.weatherTool),"input":[
          {"type":"message","role":"user","content":[{"type":"input_text","text":"Weather?"}]},
          {"type":"reasoning","summary":[]},
          {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Checking."}]},
          {"type":"function_call","call_id":"call_1","name":"get_weather","arguments":"{\\"city\\": \\"Paris\\"}"},
          {"type":"function_call_output","call_id":"call_1","output":"18C"},
          {"role":"user","content":"Thanks"}]}
        """)
        #expect(harness.prompt.contains("<|im_start|>user\nWeather?<|im_end|>"))
        #expect(harness.prompt
            .contains("Checking.\n<tool_call>\n{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Paris\"}}"))
        #expect(harness.prompt.contains("<tool_response>\n18C\n</tool_response>"))
        #expect(harness.prompt.contains("<|im_start|>user\nThanks<|im_end|>"))
    }

    @Test("a tool call is a function_call item with a call_id and the arguments as JSON text")
    func functionCall() async throws {
        let harness = RouteHarness(pieces: RouteHarness.hermesCall)
        let reply = await harness.json(path, #"{"model":"Alpha","tools":\#(Self.weatherTool),"input":"Weather?"}"#)
        #expect(reply.json["status"] as? String == "completed")
        let items = output(reply.json)
        #expect(items.count == 1)
        let call = try #require(items.first)
        #expect(call["type"] as? String == "function_call")
        #expect(call["name"] as? String == "get_weather")
        #expect(call["arguments"] as? String == #"{"city": "Paris"}"#)
        #expect((call["call_id"] as? String)?.hasPrefix("call_") == true)
        #expect((call["id"] as? String)?.hasPrefix("fc_") == true)
        #expect(harness.prompt.contains(#"{"type": "function", "function": {"name": "get_weather""#))
    }

    @Test("reasoning is its own output item, before the message")
    func reasoning() async {
        let harness = RouteHarness(pieces: ["<think>", "\nHmm.\n", "</think>", "\n\n", "Hi"])
        let reply = await harness.json(path, hi)
        let items = output(reply.json)
        #expect(items.map { $0["type"] as? String } == ["reasoning", "message"])
        let content = items[0]["content"] as? [[String: Any]]
        #expect(content?.first?["type"] as? String == "reasoning_text")
        #expect(content?.first?["text"] as? String == "Hmm.\n")
    }

    @Test("a reply cut off by max_output_tokens is incomplete")
    func incomplete() async {
        let harness = RouteHarness(pieces: ["a", "b", "c", "d", "e"])
        let reply = await harness.json(path, #"{"model":"Alpha","max_output_tokens":3,"input":"Hi"}"#)
        #expect(reply.json["status"] as? String == "incomplete")
        #expect((reply.json["incomplete_details"] as? [String: Any])?["reason"] as? String == "max_output_tokens")
    }

    @Test("what can't be honoured is refused")
    func errors() async {
        let harness = RouteHarness()
        for body in [
            #"{"model":"Alpha"}"#,
            #"{"model":"Alpha","input":[]}"#,
            #"{"model":"Alpha","input":"x","previous_response_id":"resp_1"}"#,
            #"{"model":"Alpha","input":[{"type":"item_reference","id":"x"}]}"#,
            #"{"model":"Alpha","input":[{"role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,AQID"}]}]}"#,
            #"{"model":"Alpha","input":[{"role":"user","content":[{"type":"input_image","file_id":"file-1"}]}]}"#,
            #"{"model":"Alpha","input":"x","tools":\#(Self.weatherTool),"tool_choice":"required"}"#,
            #"{"model":"Alpha","input":"x","text":{"format":{"type":"json_schema"}}}"#,
            #"{"input":"x"}"#,
        ] {
            let reply = await harness.json(path, body)
            #expect(reply.status == 400, "\(body)")
            #expect((reply.json["error"] as? [String: Any])?["message"] is String, "\(body)")
        }
    }

    @Test("text.format carries its schema beside the type, and becomes a grammar")
    func structuredOutput() async {
        let harness = RouteHarness(grammar: true)
        let reply = await harness.json(path, """
        {"model":"Alpha","input":"x","text":{"format":{"type":"json_schema","name":"p","strict":true,
         "schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}}
        """)
        #expect(reply.status == 200)
        #expect(harness.world.requests.last?.grammar?.contains("city-kv") == true)

        _ = await harness.json(path, #"{"model":"Alpha","input":"x","text":{"format":{"type":"text"}}}"#)
        #expect(harness.world.requests.last?.grammar == nil)
        let refused = await RouteHarness().json(
            path,
            #"{"model":"Alpha","input":"x","text":{"format":{"type":"json_object"}}}"#
        )
        #expect(refused.status == 400)
    }

    @Test("tool_choice in Responses' flat form forces a call of that tool")
    func forcedToolChoice() async {
        let harness = RouteHarness(grammar: true)
        let reply = await harness.json(
            path,
            #"{"model":"Alpha","input":"x","tools":\#(Self.weatherTool),"tool_choice":{"type":"function","name":"get_weather"}}"#
        )
        #expect(reply.status == 200)
        #expect(harness.world.requests.last?.grammar?.contains("get_weather") == true)
        let unknown = await harness.json(
            path,
            #"{"model":"Alpha","input":"x","tools":\#(Self.weatherTool),"tool_choice":{"type":"function","name":"other"}}"#
        )
        #expect(unknown.status == 400)
    }

    @Test("input_image parts are images, as long as they are data: URLs")
    func images() async throws {
        let harness = RouteHarness(vision: true)
        let reply = await harness.json(path, """
        {"model":"Alpha","input":[{"role":"user","content":[
          {"type":"input_text","text":"Describe"},{"type":"input_image","image_url":"data:image/png;base64,AQID"}]}]}
        """)
        #expect(reply.status == 200)
        let request = try #require(harness.world.requests.last)
        #expect(request.media == [Data([1, 2, 3])])
        #expect(request.promptText?.contains("Describe\n<__media__>") == true)

        let remote = await harness.json(
            path,
            #"{"model":"Alpha","input":[{"role":"user","content":[{"type":"input_image","image_url":"https://example.com/a.png"}]}]}"#
        )
        #expect(remote.status == 400)
    }

    @Test("tools OpenAI runs itself are left out of the prompt")
    func hostedTools() async {
        let harness = RouteHarness()
        _ = await harness.json(path, #"{"model":"Alpha","input":"x","tools":[{"type":"web_search_preview"}]}"#)
        #expect(!harness.prompt.contains("web_search"))
    }

    // MARK: streaming

    @Test("a streamed reply walks response.created to response.completed, numbering every event")
    func streamText() async throws {
        let harness = RouteHarness()
        let stream = await harness.events(path, #"{"model":"Alpha","stream":true,"input":"Hi"}"#)
        #expect(stream.status == 200)
        #expect(stream.events.map(\.name) == [
            "response.created", "response.in_progress", "response.output_item.added", "response.content_part.added",
            "response.output_text.delta", "response.output_text.delta", "response.output_text.done",
            "response.content_part.done", "response.output_item.done", "response.completed",
        ])
        #expect(!stream.raw.contains("[DONE]"))
        #expect(stream.events.map { $0["sequence_number"] as? Int } == Array(0 ..< 10))
        #expect(stream.events.allSatisfy { $0["type"] as? String == $0.name })
        #expect((stream.events[0]["response"] as? [String: Any])?["status"] as? String == "in_progress")
        let itemID = stream.events[4]["item_id"] as? String
        #expect(itemID?.hasPrefix("msg_") == true)
        #expect(stream.events[5]["item_id"] as? String == itemID)
        #expect(stream.events[4]["delta"] as? String == "Hello")
        #expect(stream.events[6]["text"] as? String == "Hello!")
        let done = try #require(stream.events[9]["response"] as? [String: Any])
        #expect(done["status"] as? String == "completed")
        #expect(output(done).count == 1)
        #expect(output(done).first?["id"] as? String == itemID)
        #expect((done["usage"] as? [String: Any])?["output_tokens"] as? Int == 2)
    }

    @Test("a streamed tool call is one function_call item with its arguments in one delta")
    func streamFunctionCall() async throws {
        let harness = RouteHarness(pieces: RouteHarness.hermesCall)
        let stream = await harness.events(
            path,
            #"{"model":"Alpha","stream":true,"tools":\#(Self.weatherTool),"input":"W?"}"#
        )
        #expect(stream.events.map(\.name) == [
            "response.created", "response.in_progress", "response.output_item.added",
            "response.function_call_arguments.delta", "response.function_call_arguments.done",
            "response.output_item.done", "response.completed",
        ])
        let added = try #require(stream.events[2]["item"] as? [String: Any])
        #expect(added["type"] as? String == "function_call")
        #expect(added["arguments"] as? String == "")
        #expect(added["status"] as? String == "in_progress")
        #expect(stream.events[3]["delta"] as? String == #"{"city": "Paris"}"#)
        #expect(stream.events[4]["arguments"] as? String == #"{"city": "Paris"}"#)
        let done = try #require(stream.events[6]["response"] as? [String: Any])
        #expect(output(done).first?["call_id"] as? String == added["call_id"] as? String)
    }

    @Test("a streamed reasoning item closes before the message opens")
    func streamReasoning() async {
        let harness = RouteHarness(pieces: ["<think>", "\nHmm.\n", "</think>", "\n\n", "Hi"])
        let stream = await harness.events(path, #"{"model":"Alpha","stream":true,"input":"Hi"}"#)
        #expect(stream.events.map(\.name) == [
            "response.created", "response.in_progress",
            "response.output_item.added", "response.reasoning_text.delta", "response.reasoning_text.done",
            "response.output_item.done",
            "response.output_item.added", "response.content_part.added", "response.output_text.delta",
            "response.output_text.done", "response.content_part.done", "response.output_item.done",
            "response.completed",
        ])
        #expect(stream.events[3]["output_index"] as? Int == 0)
        #expect(stream.events[8]["output_index"] as? Int == 1)
    }

    @Test("a stream cut off by the token limit ends with response.incomplete")
    func streamIncomplete() async {
        let harness = RouteHarness(pieces: ["a", "b", "c", "d"])
        let stream = await harness.events(path, #"{"model":"Alpha","stream":true,"max_output_tokens":2,"input":"Hi"}"#)
        #expect(stream.events.last?.name == "response.incomplete")
    }
}
