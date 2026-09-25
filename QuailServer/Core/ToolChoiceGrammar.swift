import Foundation
import Jinja

/// What a request's `tool_choice` asks of the model.
enum ToolChoice: Equatable, Sendable {
    case auto
    /// The model isn't told about the tools at all.
    case none
    /// The reply must be a tool call, of any listed tool.
    case required
    /// The reply must be a call of this tool.
    case named(String)

    var forcesCall: Bool {
        switch self {
        case .required, .named: true
        case .auto, .none: false
        }
    }
}

extension JSONSchemaGrammar {
    /// A grammar that makes the reply a call (or, with `parallel`, one or more calls) of `name`, or of any
    /// of `tools` if there is no name, written the way the model's family writes them (`format`), with
    /// the arguments held to the tool's own parameter schema.
    static func toolCalls(
        tools: [Value],
        name: String?,
        format: ToolCallFormat,
        parallel: Bool,
        reasoning: Reasoning
    ) throws -> String {
        let argumentsKey: String
        var frame: Frame?
        switch format {
        case .hermesJSON:
            argumentsKey = "arguments"
            frame = Frame(
                prefix: "\"<tool_call>\" tool-space",
                suffix: "\"</tool_call>\" tool-space",
                rules: ["tool-space": "\"\\n\"?"],
                repeats: parallel
            )
        case .bareJSON:
            // The whole reply is one call; there is nothing to repeat.
            argumentsKey = "parameters"
        case .qwenXML, .harmony, .none:
            throw RequestError.invalid(
                "forcing a tool call isn't supported for this model's chat format (\(format.label)) yet"
            )
        }

        var calls: [Value] = []
        for tool in tools {
            guard let function = tool["function"], let toolName = function["name"]?.stringValue else { continue }
            if let name, name != toolName {
                continue
            }
            let parameters = function["parameters"].flatMap { $0.isNull ? nil : $0 }
                ?? Value.record([
                    ("type", .string("object")), ("properties", .record([])), ("additionalProperties", .boolean(false)),
                ])
            calls.append(.record([
                ("type", .string("object")),
                ("properties", .record([
                    ("name", .record([("const", .string(toolName))])),
                    (argumentsKey, parameters),
                ])),
                ("required", .array([.string("name"), .string(argumentsKey)])),
            ]))
        }
        guard !calls.isEmpty else {
            throw RequestError.invalid("tool_choice names \"\(name ?? "")\", which isn't in 'tools'")
        }
        let schema = calls.count == 1 ? calls[0] : .record([("anyOf", .array(calls))])
        do {
            return try gbnf(for: schema, reasoning: reasoning, frame: frame)
        } catch let failure as Failure {
            throw RequestError.invalid("a tool's parameters can't be used to force a call: \(failure.message)")
        }
    }
}

extension ToolCallFormat {
    var label: String {
        switch self {
        case .hermesJSON: "Hermes JSON"
        case .qwenXML: "Qwen XML"
        case .bareJSON: "bare JSON"
        case .harmony: "Harmony"
        case .none: "no tool-call format"
        }
    }
}
