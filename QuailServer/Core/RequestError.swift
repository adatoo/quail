import Foundation
import Jinja

/// A request the server can't act on, with the status and OpenAI-style error type to send.
struct RequestError: Error, Equatable, LocalizedError {
    var status: Int
    var type: String
    var message: String

    var errorDescription: String? {
        message
    }

    static func invalid(_ message: String) -> RequestError {
        RequestError(status: 400, type: "invalid_request_error", message: message)
    }

    var response: HTTPResponse {
        .error(status, type: type, message: message)
    }
}

/// The sampling and length settings a completion request carries, in llama-server's field names
/// (plus the OpenAI aliases). Shared by every generation route.
struct GenerationSettings: Equatable, Sendable {
    var maxTokens: Int?
    var sampling = SamplingParameters()
    var ignoreEndOfSequence = false
    var cachePrompt = true
    var stop: [String] = []
    var stream = false
    var includeUsage = false

    init(_ body: Value) throws {
        // `max_tokens`, its newer OpenAI name, and llama.cpp's `n_predict`; -1 means no limit.
        for key in ["max_tokens", "max_completion_tokens", "n_predict"] {
            if let value = body[key], !value.isNull {
                guard let number = value.intValue else { throw RequestError.invalid("'\(key)' must be an integer") }
                maxTokens = number < 0 ? nil : number
                break
            }
        }
        if let value = try Self.number(body, "temperature") {
            sampling.temperature = max(0, value)
        }
        if let value = try Self.number(body, "top_p") {
            sampling.topP = value
        }
        if let value = try Self.number(body, "min_p") {
            sampling.minP = value
        }
        if let value = try Self.number(body, "repeat_penalty") {
            sampling.repeatPenalty = value
        }
        if let value = try Self.number(body, "presence_penalty") {
            sampling.presencePenalty = value
        }
        if let value = try Self.number(body, "frequency_penalty") {
            sampling.frequencyPenalty = value
        }
        if let value = try Self.integer(body, "top_k") {
            sampling.topK = value
        }
        // A negative seed means "pick one", like llama.cpp's default of -1.
        if let value = try Self.integer(body, "seed"), value >= 0 {
            sampling.seed = UInt64(value)
        }

        if let value = body["ignore_eos"], !value.isNull {
            guard let flag = value.boolValue else { throw RequestError.invalid("'ignore_eos' must be a boolean") }
            ignoreEndOfSequence = flag
        }
        if let value = body["cache_prompt"], !value.isNull {
            guard let flag = value.boolValue else { throw RequestError.invalid("'cache_prompt' must be a boolean") }
            cachePrompt = flag
        }
        if let value = body["stream"], !value.isNull {
            guard let flag = value.boolValue else { throw RequestError.invalid("'stream' must be a boolean") }
            stream = flag
        }
        includeUsage = body["stream_options"]?["include_usage"]?.boolValue ?? false

        if let value = body["n"], !value.isNull, value.intValue != 1 {
            throw RequestError.invalid("only n = 1 is supported")
        }
        if let value = body["stop"], !value.isNull {
            if let single = value.stringValue {
                stop = [single]
            } else if let list = value.arrayValue, list.allSatisfy({ $0.stringValue != nil }) {
                stop = list.compactMap(\.stringValue)
            } else {
                throw RequestError.invalid("'stop' must be a string or an array of strings")
            }
        }
    }

    private static func number(_ body: Value, _ key: String) throws -> Double? {
        guard let value = body[key], !value.isNull else { return nil }
        guard let number = value.doubleValue else { throw RequestError.invalid("'\(key)' must be a number") }
        return number
    }

    private static func integer(_ body: Value, _ key: String) throws -> Int? {
        guard let value = body[key], !value.isNull else { return nil }
        guard let number = value.intValue else { throw RequestError.invalid("'\(key)' must be an integer") }
        return number
    }
}

/// What a chat request adds to the generation settings.
struct ChatRequest: Sendable {
    var messages: [Value]
    var tools: [Value]?
    var toolsEnabled = true
    var templateKwargs: [String: Value] = [:]

    init(_ body: Value) throws {
        guard let messages = body["messages"] else { throw RequestError.invalid("'messages' is required") }
        guard let list = messages.arrayValue else { throw RequestError.invalid("Expected 'messages' to be an array") }
        guard !list.isEmpty else { throw RequestError.invalid("'messages' must not be empty") }
        self.messages = list
        if let tools = body["tools"], !tools.isNull {
            guard let list = tools.arrayValue else { throw RequestError.invalid("'tools' must be an array") }
            self.tools = list
        }
        // `tool_choice: "none"` means the model shouldn't be told about the tools at all.
        if body["tool_choice"]?.stringValue == "none" {
            toolsEnabled = false
        }
        if let kwargs = body["chat_template_kwargs"], !kwargs.isNull {
            guard case let .object(members) = kwargs else {
                throw RequestError.invalid("'chat_template_kwargs' must be an object")
            }
            for (key, value) in members {
                if case let .string(name) = key {
                    templateKwargs[name] = value
                }
            }
        }
        // A grammar-constrained reply needs the engine's sampler (Phase 3 step 5); saying so beats
        // quietly ignoring it and returning text that isn't JSON.
        if let format = body["response_format"]?["type"]?.stringValue, format != "text" {
            throw RequestError.invalid("response_format \"\(format)\" isn't supported yet")
        }
    }
}
