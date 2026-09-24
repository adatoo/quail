import Foundation
import Jinja

/// A model's own chat template, rendered with swift-jinja. The same renderer serves GGUF
/// and MLX models, so one model gets one prompt whichever format it's loaded from (ADR D-027).
///
/// The template text comes from the engine (`Engine.chatTemplate()`): a GGUF's
/// `tokenizer.chat_template`, or an MLX repo's `chat_template.jinja` / `tokenizer_config.json`.
struct ChatTemplate: Sendable {
    /// What a template can be told beyond the conversation. `bos_token` and `eos_token` are the
    /// model's own; `extra` is `chat_template_kwargs` (for example `enable_thinking`).
    struct Context: Sendable {
        var messages: [Value]
        var tools: [Value]?
        var addGenerationPrompt = true
        var bosToken = ""
        var eosToken = ""
        var extra: [String: Value] = [:]
    }

    enum RenderError: Error, Equatable, LocalizedError {
        /// The template text doesn't parse.
        case invalidTemplate(String)
        /// It parsed but rejected this conversation (`raise_exception`) or failed to run.
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case let .invalidTemplate(message): "the model's chat template is invalid: \(message)"
            case let .rejected(message): message
            }
        }
    }

    /// Names the server owns; `chat_template_kwargs` can't replace them.
    private static let reserved: Set<String> = ["messages", "tools", "add_generation_prompt", "bos_token", "eos_token"]

    private static let raiseName = "__quail_raise_exception"
    private static let nowName = "__quail_strftime_now"

    /// swift-jinja re-adds its own `raise_exception` and `strftime_now` after it copies a render's
    /// variables, so a context can't replace them: a template's `raise_exception("…")` would lose
    /// its message, and `strftime_now` couldn't be pinned in a test. Calls to those two names are
    /// pointed at ours instead (a call only: a bare mention of the name is left alone).
    private static func routeHostFunctions(_ source: String) -> String {
        source
            .replacing(/(^|[^\w.])raise_exception(?=\s*\()/) { "\($0.output.1)\(raiseName)" }
            .replacing(/(^|[^\w.])strftime_now(?=\s*\()/) { "\($0.output.1)\(nowName)" }
    }

    private let template: Template
    /// The clock behind `strftime_now`, so a test can pin the date a template prints.
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - source: the Jinja text.
    ///   - now: what "now" is for `strftime_now`.
    init(_ source: String, now: @escaping @Sendable () -> Date = { Date() }) throws {
        // transformers and llama.cpp's own engine both trim blocks and strip their leading
        // whitespace; without them templates written for those print stray newlines.
        do {
            template = try Template(Self.routeHostFunctions(source), with: .init(lstripBlocks: true, trimBlocks: true))
        } catch {
            throw RenderError.invalidTemplate(Self.describe(error))
        }
        self.now = now
    }

    func render(_ context: Context) throws -> String {
        var variables: [String: Value] = [
            "messages": .array(Self.prepared(context.messages)),
            "add_generation_prompt": .boolean(context.addGenerationPrompt),
            "bos_token": .string(context.bosToken),
            "eos_token": .string(context.eosToken),
            // The stock one keeps its message private; a client needs to be told why.
            Self.raiseName: .function { arguments, _, _ in
                throw RaisedByTemplate(message: arguments.first?.stringValue ?? "the chat template raised an exception")
            },
            Self.nowName: .function { [now] arguments, _, _ in
                guard arguments.count == 1, case let .string(format) = arguments[0] else {
                    throw JinjaError.runtime("strftime_now takes one format string")
                }
                return .string(Strftime.format(format, date: now()))
            },
        ]
        if let tools = context.tools, !tools.isEmpty {
            variables["tools"] = .array(tools)
        }
        for (name, value) in context.extra where !Self.reserved.contains(name) {
            variables[name] = value
        }
        do {
            return try template.render(variables)
        } catch let raised as RaisedByTemplate {
            throw RenderError.rejected(raised.message)
        } catch {
            throw RenderError.rejected(Self.describe(error))
        }
    }

    /// Templates read a tool call's `arguments` as an object (`arguments | items`,
    /// `arguments | tojson`), but the OpenAI wire shape is a JSON *string*. llama-server
    /// parses it before rendering, so this does too — keeping the key order the client sent.
    /// (The same pass gives a message with no content an empty one.)
    static func prepared(_ messages: [Value]) -> [Value] {
        messages.map { message in
            guard case var .object(members) = message else { return message }
            // An assistant turn that only calls tools is sent with `content: null`. llama.cpp
            // hands the template an empty string, and some templates (Gemma's) reject null.
            if members["content"] == nil || members["content"]?.isNull == true {
                members["content"] = .string("")
            }
            if case let .array(calls)? = members["tool_calls"] {
                members["tool_calls"] = .array(calls.map(preparedToolCall))
            }
            return .object(members)
        }
    }

    private static func preparedToolCall(_ call: Value) -> Value {
        guard case var .object(members) = call,
              case var .object(function)? = members["function"],
              case let .string(text)? = function["arguments"],
              let parsed = try? OrderedJSON.parse(text)
        else { return call }
        function["arguments"] = parsed
        members["function"] = .object(function)
        return .object(members)
    }

    private struct RaisedByTemplate: Error {
        let message: String
    }

    private static func describe(_ error: any Error) -> String {
        if let jinja = error as? JinjaError {
            switch jinja {
            case let .lexer(message), let .parser(message), let .runtime(message), let .syntax(message): return message
            }
        }
        return error.localizedDescription
    }
}

/// The subset of C `strftime` that chat templates use to print a date.
enum Strftime {
    static func format(_ pattern: String, date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: .current, from: date)
        func two(_ number: Int?) -> String {
            String(format: "%02d", number ?? 0)
        }
        let english = DateFormatter()
        english.locale = Locale(identifier: "en_US_POSIX")
        english.timeZone = .current

        var output = ""
        var iterator = pattern.makeIterator()
        while let character = iterator.next() {
            guard character == "%" else { output.append(character); continue }
            guard let code = iterator.next() else { output.append("%"); break }
            switch code {
            case "Y": output += String(parts.year ?? 0)
            case "y": output += two((parts.year ?? 0) % 100)
            case "m": output += two(parts.month)
            case "d": output += two(parts.day)
            case "H": output += two(parts.hour)
            case "M": output += two(parts.minute)
            case "S": output += two(parts.second)
            case "b": english.dateFormat = "MMM"; output += english.string(from: date)
            case "B": english.dateFormat = "MMMM"; output += english.string(from: date)
            case "a": english.dateFormat = "EEE"; output += english.string(from: date)
            case "A": english.dateFormat = "EEEE"; output += english.string(from: date)
            case "e": output += String(format: "%2d", parts.day ?? 0)
            case "p": english.dateFormat = "a"; output += english.string(from: date)
            case "%": output.append("%")
            default: output += "%" + String(code)
            }
        }
        return output
    }
}
