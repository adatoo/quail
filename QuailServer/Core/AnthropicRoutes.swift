import Foundation
import Jinja

/// `/v1/messages`, the Anthropic Messages API (what Claude Code speaks). A request is translated
/// into the OpenAI-shaped one the chat pipeline takes, and the reply is translated back, so the
/// template, reasoning split and tool-call parsing are the ones chat completions uses.
extension InferenceRoutes {
    func messages(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try jsonBody(request)
        let translated = try AnthropicRequest.chatBody(body)
        let settings = try GenerationSettings(translated)
        let chat = try ChatRequest(translated)
        let id = try await modelID(body: body, request: request)
        let run = try await startChat(chat, settings: settings, model: id)
        let messageID = InferenceJSON.randomID(prefix: "msg_", length: 24)

        if !settings.stream {
            let reply = try await collect(run)
            var blocks: [[String: Any]] = []
            if !reply.reasoning.isEmpty {
                blocks.append(["type": "thinking", "thinking": reply.reasoning, "signature": ""])
            }
            if !reply.content.isEmpty || reply.calls.isEmpty {
                blocks.append(["type": "text", "text": reply.content])
            }
            for call in reply.calls {
                blocks.append(AnthropicJSON.toolUse(call))
            }
            return Self.json([
                "id": messageID, "type": "message", "role": "assistant", "content": blocks, "model": id,
                "stop_reason": AnthropicJSON.stopReason(reply.reason), "stop_sequence": NSNull(),
                "usage": AnthropicJSON.usage(reply.timings),
            ])
        }

        let first = try await firstEvent(of: run)
        let stream = Locked(AnthropicStream())
        let opening = AnthropicJSON.frame("message_start", ["message": [
            "id": messageID, "type": "message", "role": "assistant", "content": [Any](), "model": id,
            "stop_reason": NSNull(), "stop_sequence": NSNull(),
            "usage": [
                "input_tokens": run.promptTokens,
                "output_tokens": 0,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
            ],
        ] as [String: Any]])
        return streamResponse(
            first: first, pump: run.pump, lease: run.lease, opening: opening, closing: nil,
            failure: { error in
                AnthropicJSON.frame("error", ["error": ["type": "api_error", "message": error.localizedDescription]])
            },
            encode: { event in stream.withState { $0.encode(event) } }
        )
    }

    /// `/v1/messages/count_tokens`: how many tokens the same request would take as a prompt.
    func countTokens(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try jsonBody(request)
        let chat = try ChatRequest(AnthropicRequest.chatBody(body))
        let id = try await modelID(body: body, request: request)
        return try await router.withEngine(id) { engine in
            let info = await engine.info()
            let tokens = try await promptTokens(for: chat, engine: engine, info: info)
            return Self.json(["input_tokens": tokens.ids.count])
        }
    }
}

extension InferenceRoutes.ErrorStyle {
    func response(_ error: RequestError) -> HTTPResponse {
        switch self {
        case .openAI:
            return error.response
        case .anthropic:
            let type = switch error.status {
            case 404: "not_found_error"
            case 503: "overloaded_error"
            case 500...: "api_error"
            default: "invalid_request_error"
            }
            return HTTPResponse(
                status: error.status,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: .data(InferenceJSON.jsonData([
                    "type": "error", "error": ["type": type, "message": error.message],
                ]))
            )
        }
    }
}

// MARK: Request

enum AnthropicRequest {
    /// The same request in chat-completions form.
    static func chatBody(_ body: Value) throws -> Value {
        var messages: [Value] = []
        var systemParts: [String] = []
        if let system = body["system"], !system.isNull {
            let text = try text(of: system, what: "system")
            if !text.isEmpty {
                systemParts.append(text)
            }
        }
        guard let list = body["messages"]?.arrayValue else { throw RequestError.invalid("'messages' is required") }
        guard !list.isEmpty else { throw RequestError.invalid("'messages' must not be empty") }
        for message in list {
            // Claude Code puts some of its instructions (the environment, for one) in a `system` message among
            // the others. Chat templates mostly allow one system message, first, so its text joins the system
            // prompt, in order.
            if message["role"]?.stringValue == "system" {
                guard let content = message["content"], !content.isNull else {
                    throw RequestError.invalid("each message needs \"content\"")
                }
                let text = try text(of: content, what: "a system message")
                if !text.isEmpty {
                    systemParts.append(text)
                }
                continue
            }
            try messages += convert(message)
        }
        if !systemParts.isEmpty {
            messages.insert(
                .record([("role", .string("system")), ("content", .string(systemParts.joined(separator: "\n\n")))]),
                at: 0
            )
        }

        var members: [(String, Value?)] = [("model", body["model"]), ("messages", .array(messages))]
        if let tools = try tools(body["tools"]) {
            members.append(("tools", tools))
        }
        if let choice = try toolChoice(body["tool_choice"]) {
            members.append(("tool_choice", choice))
        }
        if body["tool_choice"]?["disable_parallel_tool_use"]?.boolValue == true {
            members.append(("parallel_tool_calls", .boolean(false)))
        }
        if let stops = body["stop_sequences"], !stops.isNull {
            members.append(("stop", stops))
        }
        for key in passedThrough {
            if let value = body[key], !value.isNull {
                members.append((key, value))
            }
        }
        return .record(members)
    }

    /// Sampling and length fields that mean the same in both APIs.
    private static let passedThrough = [
        "max_tokens", "stream", "temperature", "top_p", "top_k", "min_p", "seed",
        "repeat_penalty", "presence_penalty", "frequency_penalty", "ignore_eos", "cache_prompt",
    ]

    /// A string, or a list of `text` blocks (`cache_control` and the like are ignored).
    private static func text(of value: Value, what: String) throws -> String {
        if let string = value.stringValue {
            return string
        }
        guard let blocks = value.arrayValue else {
            throw RequestError.invalid("'\(what)' must be a string or an array of text blocks")
        }
        return try blocks.map { block in
            guard block["type"]?.stringValue == "text", let text = block["text"]?.stringValue else {
                throw notSupported(block["type"]?.stringValue, in: what)
            }
            return text
        }.joined(separator: "\n\n")
    }

    private static func notSupported(_ type: String?, in what: String) -> RequestError {
        switch type {
        case "document":
            .invalid("document input is not supported")
        case "image":
            .invalid("images are only read from a user message's content blocks")
        default:
            .invalid("content block type '\(type ?? "")' is not supported in '\(what)'")
        }
    }

    /// One Anthropic message as one or more chat messages: a `tool_result` block becomes its own
    /// `tool` message, in the order it appears.
    private static func convert(_ message: Value) throws -> [Value] {
        guard let role = message["role"]?.stringValue, role == "user" || role == "assistant" else {
            throw RequestError.invalid("each message needs a \"role\" of \"user\", \"assistant\" or \"system\"")
        }
        guard let content = message["content"], !content.isNull else {
            throw RequestError.invalid("each message needs \"content\"")
        }
        if let string = content.stringValue {
            return [.record([("role", .string(role)), ("content", .string(string))])]
        }
        guard let blocks = content.arrayValue else {
            throw RequestError.invalid("message content must be a string or an array of blocks")
        }
        return role == "user" ? try userMessages(blocks) : try [assistantMessage(blocks)]
    }

    private static func userMessages(_ blocks: [Value]) throws -> [Value] {
        var out: [Value] = []
        // Text and image parts of the user turn being built.
        var pending: [Value] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let hasImage = pending.contains { $0["type"]?.stringValue == "image_url" }
            let content: Value = hasImage
                ? .array(pending)
                : .string(pending.compactMap { $0["text"]?.stringValue }.joined(separator: "\n"))
            out.append(.record([("role", .string("user")), ("content", content)]))
            pending = []
        }
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                pending.append(.record([
                    ("type", .string("text")),
                    ("text", .string(block["text"]?.stringValue ?? "")),
                ]))
            case "image":
                try pending.append(imagePart(block))
            case "tool_result":
                flush()
                let result = try block["content"].map { try text(of: $0, what: "tool_result") } ?? ""
                out.append(.record([
                    ("role", .string("tool")),
                    ("tool_call_id", block["tool_use_id"]),
                    ("content", .string(result)),
                ]))
            default:
                throw notSupported(block["type"]?.stringValue, in: "a user message")
            }
        }
        flush()
        return out
    }

    /// An Anthropic `image` block as a chat completions image part. Only base64 sources: a `url` source
    /// would make the server fetch it.
    private static func imagePart(_ block: Value) throws -> Value {
        guard let source = block["source"] else { throw RequestError.invalid("an image block needs a \"source\"") }
        switch source["type"]?.stringValue {
        case "base64":
            guard let data = source["data"]?.stringValue else {
                throw RequestError.invalid("a base64 image source needs \"data\"")
            }
            let mediaType = source["media_type"]?.stringValue ?? "image/png"
            return ImageInput.part(url: "data:\(mediaType);base64,\(data)")
        case "url":
            throw RequestError.invalid("quail-server doesn't fetch image URLs; send the image as a base64 source")
        default:
            throw RequestError.invalid("an image source must be base64")
        }
    }

    private static func assistantMessage(_ blocks: [Value]) throws -> Value {
        var texts: [String] = []
        var thinking: [String] = []
        var calls: [Value] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                texts.append(block["text"]?.stringValue ?? "")
            case "thinking":
                thinking.append(block["thinking"]?.stringValue ?? "")
            case "redacted_thinking":
                break
            case "tool_use":
                guard let name = block["name"]?.stringValue else {
                    throw RequestError.invalid("a tool_use block needs a \"name\"")
                }
                calls.append(.record([
                    ("id", block["id"]), ("type", .string("function")),
                    ("function", .record([("name", .string(name)), ("arguments", block["input"] ?? .record([]))])),
                ]))
            default:
                throw notSupported(block["type"]?.stringValue, in: "an assistant message")
            }
        }
        let reasoning = thinking.joined(separator: "\n")
        return .record([
            ("role", .string("assistant")),
            ("content", .string(texts.joined(separator: "\n"))),
            ("reasoning_content", reasoning.isEmpty ? nil : .string(reasoning)),
            ("tool_calls", calls.isEmpty ? nil : .array(calls)),
        ])
    }

    /// `{name, description, input_schema}` becomes the OpenAI function form. Tools Anthropic runs
    /// itself (web search and so on) are left out: a local model has nothing to call them with.
    private static func tools(_ value: Value?) throws -> Value? {
        guard let value, !value.isNull else { return nil }
        guard let list = value.arrayValue else { throw RequestError.invalid("'tools' must be an array") }
        let functions: [Value] = try list.compactMap { tool in
            if let type = tool["type"]?.stringValue, type != "custom" {
                return nil
            }
            guard let name = tool["name"]?.stringValue else { throw RequestError.invalid("a tool needs a \"name\"") }
            return .record([("type", .string("function")), ("function", .record([
                ("name", .string(name)),
                ("description", tool["description"]),
                ("parameters", tool["input_schema"] ?? .record([("type", .string("object"))])),
            ]))])
        }
        return functions.isEmpty ? nil : .array(functions)
    }

    /// `auto` and `none` carry over; `any` is `required`, and a named tool keeps its name.
    private static func toolChoice(_ value: Value?) throws -> Value? {
        guard let value, !value.isNull else { return nil }
        switch value["type"]?.stringValue {
        case "auto": return .string("auto")
        case "none": return .string("none")
        case "any": return .string("required")
        case "tool":
            guard let name = value["name"]?.stringValue
            else { throw RequestError.invalid("tool_choice \"tool\" needs a name") }
            return .record([("type", .string("function")), ("function", .record([("name", .string(name))]))])
        default: throw RequestError.invalid("unknown tool_choice")
        }
    }
}

// MARK: Response

enum AnthropicJSON {
    static func stopReason(_ reason: FinishReason) -> String {
        switch reason {
        case .stop: "end_turn"
        case .length: "max_tokens"
        case .toolCalls: "tool_use"
        }
    }

    /// Anthropic counts the input that wasn't read from the cache; llama-server does the same.
    static func usage(_ timings: GenerationTimings) -> [String: Any] {
        [
            "input_tokens": timings.promptTokens, "output_tokens": timings.generatedTokens,
            "cache_read_input_tokens": timings.cachedTokens, "cache_creation_input_tokens": 0,
        ]
    }

    static func newToolUseID() -> String {
        InferenceJSON.randomID(prefix: "toolu_", length: 24)
    }

    /// A call's `arguments` is JSON text; Anthropic sends the object itself.
    static func input(of call: ParsedToolCall) -> Any {
        let parsed = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8), options: [.fragmentsAllowed])
        return parsed is [String: Any] ? parsed! : [String: Any]()
    }

    static func toolUse(_ call: ParsedToolCall) -> [String: Any] {
        ["type": "tool_use", "id": newToolUseID(), "name": call.name, "input": input(of: call)]
    }

    /// A stream event: `event: <type>` with the type repeated in the data, as Anthropic writes it.
    static func frame(_ type: String, _ fields: [String: Any]) -> Data {
        InferenceJSON.sse(event: type, fields.merging(["type": type]) { $1 })
    }
}

/// Turns chat events into Anthropic's stream: content blocks that open, receive deltas, and close
/// before the next one opens.
struct AnthropicStream {
    private enum Block {
        case thinking
        case text
        case toolUse
    }

    private var open: Block?
    private var index = -1

    mutating func encode(_ event: ChatEvent) -> Data {
        switch event {
        case let .delta(.reasoning(piece)):
            begin(.thinking, ["type": "thinking", "thinking": ""])
                + delta(["type": "thinking_delta", "thinking": piece])
        case let .delta(.content(piece)):
            begin(.text, ["type": "text", "text": ""]) + delta(["type": "text_delta", "text": piece])
        case let .delta(.toolCall(call)):
            // A call goes out whole: a block that opens, gets all its arguments in one delta, and closes.
            begin(
                .toolUse,
                ["type": "tool_use", "id": AnthropicJSON.newToolUseID(), "name": call.name, "input": [String: Any]()]
            )
                + delta(["type": "input_json_delta", "partial_json": call.arguments])
                + close()
        case let .finished(reason, timings):
            close() + AnthropicJSON.frame("message_delta", [
                "delta": ["stop_reason": AnthropicJSON.stopReason(reason), "stop_sequence": NSNull()],
                "usage": ["output_tokens": timings.generatedTokens],
            ]) + AnthropicJSON.frame("message_stop", [:])
        }
    }

    /// Opens a block of this kind, closing the current one first unless it's the same kind.
    private mutating func begin(_ block: Block, _ start: [String: Any]) -> Data {
        if open == block {
            return Data()
        }
        let previous = close()
        open = block
        index += 1
        return previous + AnthropicJSON.frame("content_block_start", ["index": index, "content_block": start])
    }

    private func delta(_ fields: [String: Any]) -> Data {
        AnthropicJSON.frame("content_block_delta", ["index": index, "delta": fields])
    }

    private mutating func close() -> Data {
        guard let block = open else { return Data() }
        open = nil
        // A thinking block ends with its signature; a local model has none to give.
        let signature = block == .thinking ? delta(["type": "signature_delta", "signature": ""]) : Data()
        return signature + AnthropicJSON.frame("content_block_stop", ["index": index])
    }
}
