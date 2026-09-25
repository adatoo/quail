import Foundation
import Jinja

/// `/v1/responses`, OpenAI's Responses API. Like `/v1/messages`, it is a translation onto the chat
/// pipeline; it is stateless, so a follow-up sends the whole conversation in `input`.
extension InferenceRoutes {
    func responses(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try jsonBody(request)
        let translated = try ResponsesRequest.chatBody(body)
        let settings = try GenerationSettings(translated)
        let chat = try ChatRequest(translated)
        let id = try await modelID(body: body, request: request)
        let run = try await startChat(chat, settings: settings, model: id)
        let created = Int(Date().timeIntervalSince1970)
        let responseID = InferenceJSON.randomID(prefix: "resp_")

        if !settings.stream {
            let reply = try await collect(run)
            var items: [[String: Any]] = []
            if !reply.reasoning.isEmpty {
                items.append(ResponsesJSON.reasoning(id: ResponsesJSON.newID("rs_"), text: reply.reasoning))
            }
            if !reply.content.isEmpty || reply.calls.isEmpty {
                items.append(ResponsesJSON.message(id: ResponsesJSON.newID("msg_"), text: reply.content))
            }
            for call in reply.calls {
                items.append(ResponsesJSON.functionCall(id: ResponsesJSON.newID("fc_"), call: call))
            }
            return Self.json(ResponsesJSON.response(
                id: responseID, model: id, created: created, items: items, reason: reply.reason, timings: reply.timings
            ))
        }

        let first = try await firstEvent(of: run)
        let stream = Locked(ResponsesStream(id: responseID, model: id, created: created))
        return streamResponse(
            first: first, pump: run.pump, lease: run.lease,
            opening: stream.withState { $0.opening() }, closing: nil,
            failure: { error in stream.withState { $0.failure(error.localizedDescription) } },
            encode: { event in stream.withState { $0.encode(event) } }
        )
    }
}

// MARK: Request

enum ResponsesRequest {
    /// The same request in chat-completions form.
    static func chatBody(_ body: Value) throws -> Value {
        if let previous = body["previous_response_id"], !previous.isNull {
            throw RequestError.invalid(
                "previous_response_id isn't supported: quail-server keeps no conversations, send them in \"input\""
            )
        }
        var messages: [Value] = []
        if let instructions = body["instructions"]?.stringValue, !instructions.isEmpty {
            messages.append(.record([("role", .string("system")), ("content", .string(instructions))]))
        }
        guard let input = body["input"], !input.isNull else { throw RequestError.invalid("'input' is required") }
        if let text = input.stringValue {
            messages.append(.record([("role", .string("user")), ("content", .string(text))]))
        } else if let items = input.arrayValue {
            for item in items {
                try append(item, to: &messages)
            }
        } else {
            throw RequestError.invalid("'input' must be a string or an array of items")
        }
        guard !messages.isEmpty else { throw RequestError.invalid("'input' must not be empty") }

        var members: [(String, Value?)] = [
            ("model", body["model"]), ("messages", .array(messages)), ("max_tokens", body["max_output_tokens"]),
        ]
        if let tools = try tools(body["tools"]) {
            members.append(("tools", tools))
        }
        members.append(("tool_choice", body["tool_choice"]))
        if let format = body["text"]?["format"], let type = format["type"]?.stringValue {
            // Responses puts the schema next to the type; chat completions nests it.
            let schema = format["schema"].map { Value.record([("name", format["name"]), ("schema", $0)]) }
            members.append(("response_format", .record([("type", .string(type)), ("json_schema", schema)])))
        }
        for key in ["stream", "temperature", "top_p", "top_k", "min_p", "seed", "cache_prompt"] {
            if let value = body[key], !value.isNull {
                members.append((key, value))
            }
        }
        return .record(members.filter { !($0.1?.isNull ?? true) })
    }

    private static func append(_ item: Value, to messages: inout [Value]) throws {
        let type = item["type"]?.stringValue ?? (item["role"] != nil ? "message" : nil)
        switch type {
        case "message":
            guard let role = item["role"]?.stringValue else { throw RequestError.invalid("a message needs a \"role\"") }
            let content = try text(of: item["content"], what: "a message")
            messages.append(.record([("role", .string(role)), ("content", .string(content))]))
        case "function_call":
            guard let name = item["name"]?.stringValue
            else { throw RequestError.invalid("a function_call needs a \"name\"") }
            let call = Value.record([
                ("id", item["call_id"] ?? item["id"]), ("type", .string("function")),
                ("function", .record([("name", .string(name)), ("arguments", item["arguments"] ?? .string("{}"))])),
            ])
            // A call belongs to the assistant turn just before it, if there is one.
            if case var .object(last)? = messages.last, last["role"]?.stringValue == "assistant" {
                var calls = last["tool_calls"]?.arrayValue ?? []
                calls.append(call)
                last["tool_calls"] = .array(calls)
                messages[messages.count - 1] = .object(last)
            } else {
                messages.append(.record([
                    ("role", .string("assistant")), ("content", .string("")), ("tool_calls", .array([call])),
                ]))
            }
        case "function_call_output":
            try messages.append(.record([
                ("role", .string("tool")),
                ("tool_call_id", item["call_id"]),
                ("content", .string(text(of: item["output"], what: "a function_call_output"))),
            ]))
        case "reasoning":
            break // the model's earlier thinking; templates drop it from history anyway
        default:
            throw RequestError.invalid("input item type '\(type ?? "")' is not supported")
        }
    }

    /// A string, or a list of `input_text`/`output_text` parts.
    private static func text(of value: Value?, what: String) throws -> String {
        guard let value, !value.isNull else { return "" }
        if let string = value.stringValue {
            return string
        }
        guard let parts = value.arrayValue else { throw RequestError.invalid("the content of \(what) is malformed") }
        return try parts.map { part in
            let type = part["type"]?.stringValue
            guard type == "input_text" || type == "output_text" || type == "text",
                  let text = part["text"]?.stringValue
            else {
                throw RequestError
                    .invalid("\(type ?? "") input is not supported yet; quail-server has no vision engine")
            }
            return text
        }.joined(separator: "\n")
    }

    /// Flat function tools become the nested OpenAI form; tools OpenAI runs itself are left out.
    private static func tools(_ value: Value?) throws -> Value? {
        guard let value, !value.isNull else { return nil }
        guard let list = value.arrayValue else { throw RequestError.invalid("'tools' must be an array") }
        let functions: [Value] = try list.compactMap { tool in
            guard tool["type"]?.stringValue == "function" else { return nil }
            guard let name = tool["name"]?.stringValue else { throw RequestError.invalid("a tool needs a \"name\"") }
            return .record([("type", .string("function")), ("function", .record([
                ("name", .string(name)), ("description", tool["description"]), ("parameters", tool["parameters"]),
            ]))])
        }
        return functions.isEmpty ? nil : .array(functions)
    }
}

// MARK: Response

enum ResponsesJSON {
    static func newID(_ prefix: String) -> String {
        InferenceJSON.randomID(prefix: prefix)
    }

    static func reasoning(id: String, text: String, done: Bool = true) -> [String: Any] {
        var parts: [[String: Any]] = []
        if done {
            parts.append(["type": "reasoning_text", "text": text])
        }
        return ["id": id, "type": "reasoning", "summary": [[String: Any]](), "content": parts]
    }

    static func message(id: String, text: String, done: Bool = true) -> [String: Any] {
        var parts: [[String: Any]] = []
        if done {
            parts.append(outputText(text))
        }
        return [
            "id": id, "type": "message", "role": "assistant", "status": done ? "completed" : "in_progress",
            "content": parts,
        ]
    }

    static func outputText(_ text: String) -> [String: Any] {
        ["type": "output_text", "text": text, "annotations": [Any](), "logprobs": [Any]()]
    }

    static func functionCall(id: String, call: ParsedToolCall, done: Bool = true) -> [String: Any] {
        [
            "id": id, "type": "function_call", "status": done ? "completed" : "in_progress",
            "call_id": "call_" + String(id.dropFirst("fc_".count)), "name": call.name,
            "arguments": done ? call.arguments : "",
        ]
    }

    static func usage(_ timings: GenerationTimings) -> [String: Any] {
        let input = timings.promptTokens + timings.cachedTokens
        return [
            "input_tokens": input, "output_tokens": timings.generatedTokens,
            "total_tokens": input + timings.generatedTokens,
            "input_tokens_details": ["cached_tokens": timings.cachedTokens],
        ]
    }

    /// The response object. A reply cut off by the token limit is "incomplete", as OpenAI reports it.
    static func response(
        id: String, model: String, created: Int, items: [[String: Any]],
        reason: FinishReason? = nil, timings: GenerationTimings? = nil
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": id, "object": "response", "created_at": created, "model": model, "output": items,
            "error": NSNull(), "incomplete_details": NSNull(),
            "status": reason == nil ? "in_progress" : (reason == .length ? "incomplete" : "completed"),
        ]
        if reason == .length {
            object["incomplete_details"] = ["reason": "max_output_tokens"]
        }
        if let timings {
            object["usage"] = usage(timings)
        }
        if reason != nil {
            object["completed_at"] = Int(Date().timeIntervalSince1970)
        }
        return object
    }
}

/// Turns chat events into the Responses stream: an output item opens, receives deltas, and closes
/// before the next opens. Every event carries a running `sequence_number`.
struct ResponsesStream {
    private enum Open {
        case reasoning(id: String, text: String)
        case message(id: String, text: String)
    }

    private let id: String
    private let model: String
    private let created: Int
    private var sequence = 0
    private var open: Open?
    private var items: [[String: Any]] = []

    init(id: String, model: String, created: Int) {
        self.id = id
        self.model = model
        self.created = created
    }

    mutating func opening() -> Data {
        let response = ResponsesJSON.response(id: id, model: model, created: created, items: [])
        return frame("response.created", ["response": response]) + frame("response.in_progress", ["response": response])
    }

    mutating func failure(_ message: String) -> Data {
        frame("error", ["code": "server_error", "message": message, "param": NSNull()])
    }

    mutating func encode(_ event: ChatEvent) -> Data {
        switch event {
        case let .delta(.reasoning(piece)):
            var out = Data()
            if case .reasoning = open {} else {
                out += close()
                let itemID = ResponsesJSON.newID("rs_")
                open = .reasoning(id: itemID, text: "")
                out += frame("response.output_item.added", [
                    "output_index": items.count, "item": ResponsesJSON.reasoning(id: itemID, text: "", done: false),
                ])
            }
            guard case let .reasoning(itemID, text)? = open else { return out }
            open = .reasoning(id: itemID, text: text + piece)
            return out + frame("response.reasoning_text.delta", [
                "item_id": itemID, "output_index": items.count, "content_index": 0, "delta": piece,
            ])
        case let .delta(.content(piece)):
            var out = Data()
            if case .message = open {} else {
                out += close()
                let itemID = ResponsesJSON.newID("msg_")
                open = .message(id: itemID, text: "")
                out += frame("response.output_item.added", [
                    "output_index": items.count, "item": ResponsesJSON.message(id: itemID, text: "", done: false),
                ])
                out += frame("response.content_part.added", [
                    "item_id": itemID, "output_index": items.count, "content_index": 0,
                    "part": ResponsesJSON.outputText(""),
                ])
            }
            guard case let .message(itemID, text)? = open else { return out }
            open = .message(id: itemID, text: text + piece)
            return out + frame("response.output_text.delta", [
                "item_id": itemID, "output_index": items.count, "content_index": 0, "delta": piece, "logprobs": [Any](),
            ])
        case let .delta(.toolCall(call)):
            // A call goes out whole: the item opens, gets its arguments in one delta, and closes.
            var out = close()
            let itemID = ResponsesJSON.newID("fc_")
            let index = items.count
            out += frame("response.output_item.added", [
                "output_index": index, "item": ResponsesJSON.functionCall(id: itemID, call: call, done: false),
            ])
            out += frame("response.function_call_arguments.delta", [
                "item_id": itemID, "output_index": index, "delta": call.arguments,
            ])
            out += frame("response.function_call_arguments.done", [
                "item_id": itemID, "output_index": index, "name": call.name, "arguments": call.arguments,
            ])
            let item = ResponsesJSON.functionCall(id: itemID, call: call)
            items.append(item)
            return out + frame("response.output_item.done", ["output_index": index, "item": item])
        case let .finished(reason, timings):
            var out = close()
            let response = ResponsesJSON.response(
                id: id, model: model, created: created, items: items, reason: reason, timings: timings
            )
            out += frame(reason == .length ? "response.incomplete" : "response.completed", ["response": response])
            return out
        }
    }

    private mutating func close() -> Data {
        guard let current = open else { return Data() }
        open = nil
        let index = items.count
        switch current {
        case let .reasoning(itemID, text):
            let item = ResponsesJSON.reasoning(id: itemID, text: text)
            items.append(item)
            return frame("response.reasoning_text.done", [
                "item_id": itemID, "output_index": index, "content_index": 0, "text": text,
            ]) + frame("response.output_item.done", ["output_index": index, "item": item])
        case let .message(itemID, text):
            let item = ResponsesJSON.message(id: itemID, text: text)
            items.append(item)
            return frame("response.output_text.done", [
                "item_id": itemID, "output_index": index, "content_index": 0, "text": text, "logprobs": [Any](),
            ])
                + frame("response.content_part.done", [
                    "item_id": itemID, "output_index": index, "content_index": 0,
                    "part": ResponsesJSON.outputText(text),
                ])
                + frame("response.output_item.done", ["output_index": index, "item": item])
        }
    }

    private mutating func frame(_ type: String, _ fields: [String: Any]) -> Data {
        defer { sequence += 1 }
        return InferenceJSON.sse(
            event: type,
            fields.merging(["type": type, "sequence_number": sequence]) { $1 }
        )
    }
}
