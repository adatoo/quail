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
    /// What the reply must follow: llama-server's `grammar` and `json_schema`, or OpenAI's
    /// `response_format` (ADR D-045). Only some engines can honour it.
    var constraint: Constraint?

    enum Constraint: Equatable, Sendable {
        /// GBNF as the client wrote it, applied from the first token.
        case grammar(String)
        /// A JSON schema, kept as text; the grammar is built once the prompt's template is known.
        case schema(String)

        /// The grammar to sample under. A schema's is preceded by the model's thinking block when the
        /// chat template has one (`reasoning`).
        func gbnf(reasoning: JSONSchemaGrammar.Reasoning) throws -> String {
            switch self {
            case let .grammar(text):
                return text
            case let .schema(text):
                do {
                    return try JSONSchemaGrammar.gbnf(for: OrderedJSON.parse(text), reasoning: reasoning)
                } catch let failure as JSONSchemaGrammar.Failure {
                    throw RequestError.invalid("the JSON schema can't be used: \(failure.message)")
                } catch {
                    throw RequestError.invalid("the JSON schema can't be used: \(error.localizedDescription)")
                }
            }
        }
    }

    init(_ body: Value) throws {
        constraint = try Self.constraint(body)
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
        if let value = try Self.number(body, "dry_multiplier") {
            sampling.dryMultiplier = max(0, value)
        }
        if let value = try Self.number(body, "dry_base") {
            sampling.dryBase = value
        }
        if let value = try Self.integer(body, "dry_allowed_length") {
            sampling.dryAllowedLength = value
        }
        if let value = try Self.integer(body, "dry_penalty_last_n") {
            sampling.dryPenaltyLastN = value
        }
        if let value = body["dry_sequence_breakers"], !value.isNull {
            guard let list = value.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                throw RequestError.invalid("'dry_sequence_breakers' must be an array of strings")
            }
            sampling.drySequenceBreakers = list.compactMap(\.stringValue)
        }
        if let value = try Self.number(body, "xtc_probability") {
            sampling.xtcProbability = min(max(0, value), 1)
        }
        if let value = try Self.number(body, "xtc_threshold") {
            sampling.xtcThreshold = value
        }
        // llama-server's name is `typical_p`; `typ_p` is the older spelling.
        if let value = try Self.number(body, "typical_p") ?? Self.number(body, "typ_p") {
            sampling.typicalP = value
        }
        if let value = try Self.number(body, "top_n_sigma") {
            sampling.topNSigma = value
        }
        if let value = try Self.integer(body, "mirostat") {
            guard (0 ... 2).contains(value) else { throw RequestError.invalid("'mirostat' must be 0, 1 or 2") }
            sampling.mirostat = value
        }
        if let value = try Self.number(body, "mirostat_tau") {
            sampling.mirostatTau = value
        }
        if let value = try Self.number(body, "mirostat_eta") {
            sampling.mirostatEta = value
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

    private static func constraint(_ body: Value) throws -> Constraint? {
        /// Checks the schema converts (so a bad one is a 400 now, before a model loads), and keeps its text.
        func schema(_ value: Value) throws -> Constraint {
            let text = try OrderedJSON.serialize(value)
            let constraint = Constraint.schema(text)
            _ = try constraint.gbnf(reasoning: .none)
            return constraint
        }
        if let value = body["grammar"], !value.isNull {
            guard let text = value.stringValue else { throw RequestError.invalid("'grammar' must be a string") }
            if !text.isEmpty {
                return .grammar(text)
            }
        }
        if let value = body["json_schema"], !value.isNull {
            return try schema(value)
        }
        guard let format = body["response_format"], !format.isNull else { return nil }
        switch format["type"]?.stringValue {
        case nil, "text":
            return nil
        case "json_object":
            // llama-server reads a bare json_object as "an object", and takes an optional `schema`.
            let given = format["schema"]
            return try schema(given
                .map { $0.objectIsEmptyForSchema ? JSONSchemaGrammar.anyObject : $0 } ?? JSONSchemaGrammar.anyObject)
        case "json_schema":
            guard let given = format["json_schema"]?["schema"] ?? format["schema"] else {
                throw RequestError.invalid("response_format \"json_schema\" needs a json_schema.schema")
            }
            return try schema(given)
        case let other?:
            throw RequestError.invalid("response_format \"\(other)\" isn't supported")
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
    var toolChoice = ToolChoice.auto
    /// llama-server's default is one call at a time; OpenAI's is several.
    var parallelToolCalls = false
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
        toolChoice = try Self.toolChoice(body["tool_choice"])
        // `tool_choice: "none"` means the model shouldn't be told about the tools at all.
        toolsEnabled = toolChoice != .none
        if let value = body["parallel_tool_calls"], !value.isNull {
            guard let flag = value.boolValue
            else { throw RequestError.invalid("'parallel_tool_calls' must be a boolean") }
            parallelToolCalls = flag
        }
        if toolChoice.forcesCall {
            let names = (tools ?? []).compactMap { $0["function"]?["name"]?.stringValue }
            if names.isEmpty {
                throw RequestError.invalid("tool_choice forces a tool call, but 'tools' has none")
            }
            if case let .named(name) = toolChoice, !names.contains(name) {
                throw RequestError.invalid("tool_choice names \"\(name)\", which isn't in 'tools'")
            }
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
    }
}

extension ChatRequest {
    /// `auto`, `none`, `required`, or a named function in chat completions' nesting or Responses' flat form.
    private static func toolChoice(_ value: Value?) throws -> ToolChoice {
        guard let value, !value.isNull else { return .auto }
        if let text = value.stringValue {
            switch text {
            case "auto": return .auto
            case "none": return .none
            case "required": return .required
            default: throw RequestError.invalid("tool_choice \"\(text)\" isn't supported")
            }
        }
        guard value["type"]?.stringValue == "function",
              let name = value["function"]?["name"]?.stringValue ?? value["name"]?.stringValue
        else { throw RequestError.invalid("tool_choice with a specific function needs its name") }
        return .named(name)
    }
}

private extension Value {
    /// `{}` is what a client sends for "no particular schema".
    var objectIsEmptyForSchema: Bool {
        if case let .object(members) = self {
            return members.isEmpty
        }
        return false
    }
}
