import Foundation

/// `quail eval tools` (ADR D-065): does tool calling work, end to end, for a model on a server? Sixteen
/// hand-written requests in six kinds, each checked against the call it should produce, in the shape BFCL's
/// checker uses: the tool's name, every required parameter present and of its schema's type, and each value one
/// of the accepted answers. It's a quick check of the whole path (template, parser, server), the one that found
/// gpt-oss's and Llama 3.1's calls coming back as text, not a score to compare models with: BFCL's 200 cases on
/// the bench Mac are that (ADR D-070).
enum ToolEval {
    static let id = "quail-tools-1"

    enum Kind: String, Codable, Sendable, CaseIterable {
        /// One tool offered, one call.
        case simple
        /// Several tools offered, the right one called.
        case choose
        /// The same tool called twice.
        case parallel
        /// Two different tools called.
        case parallelMultiple = "parallel-multiple"
        /// No tool fits: answer without calling one.
        case irrelevance
        /// After a tool's result: answer from it, without calling again.
        case followUp = "follow-up"

        var title: String {
            switch self {
            case .simple: "One call"
            case .choose: "Choosing a tool"
            case .parallel: "Two calls"
            case .parallelMultiple: "Two tools"
            case .irrelevance: "No tool fits"
            case .followUp: "After a result"
            }
        }
    }

    /// What a value must be.
    enum Expect: Sendable, Equatable {
        /// A string equal to one of these, ignoring case and surrounding space.
        case oneOf([String])
        /// A string containing this, ignoring case.
        case contains(String)
        /// A JSON integer.
        case integer(Int)
        /// A JSON number.
        case number(Double)
        case boolean(Bool)
        /// An array of these numbers, in any order.
        case numbers([Double])
    }

    struct Call: Sendable, Equatable {
        var name: String
        var arguments: [String: Expect]
    }

    struct Case: Sendable {
        var id: String
        var kind: Kind
        /// Names from `tools`.
        var offered: [String]
        /// The conversation, as JSON messages.
        var messages: String
        /// The calls it should make, in any order; empty means it should answer in text.
        var calls: [Call]
        /// For a text answer: what it should mention.
        var mentions: String?
    }

    /// The tools the cases offer, in OpenAI's shape.
    static let tools: [String: String] = [
        "get_weather": #"""
        {"type":"function","function":{"name":"get_weather","description":"Current weather for a city.","parameters":{"type":"object","properties":{"city":{"type":"string","description":"City name"},"unit":{"type":"string","enum":["celsius","fahrenheit"]}},"required":["city","unit"]}}}
        """#,
        "set_timer": #"""
        {"type":"function","function":{"name":"set_timer","description":"Start a countdown timer.","parameters":{"type":"object","properties":{"minutes":{"type":"integer","description":"Length in whole minutes"},"label":{"type":"string","description":"What the timer is for"}},"required":["minutes"]}}}
        """#,
        "convert_currency": #"""
        {"type":"function","function":{"name":"convert_currency","description":"Convert an amount between currencies.","parameters":{"type":"object","properties":{"amount":{"type":"number"},"from":{"type":"string","description":"ISO 4217 code, such as EUR"},"to":{"type":"string","description":"ISO 4217 code, such as USD"}},"required":["amount","from","to"]}}}
        """#,
        "search_flights": #"""
        {"type":"function","function":{"name":"search_flights","description":"Search for flights.","parameters":{"type":"object","properties":{"origin":{"type":"string","description":"IATA airport code"},"destination":{"type":"string","description":"IATA airport code"},"date":{"type":"string","description":"YYYY-MM-DD"},"nonstop":{"type":"boolean"}},"required":["origin","destination","date"]}}}
        """#,
        "add_numbers": #"""
        {"type":"function","function":{"name":"add_numbers","description":"Add a list of numbers.","parameters":{"type":"object","properties":{"numbers":{"type":"array","items":{"type":"number"}}},"required":["numbers"]}}}
        """#,
        "send_email": #"""
        {"type":"function","function":{"name":"send_email","description":"Send an email.","parameters":{"type":"object","properties":{"to":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string"}},"required":["to","subject","body"]}}}
        """#,
    ]

    private static let all = [
        "get_weather",
        "set_timer",
        "convert_currency",
        "search_flights",
        "add_numbers",
        "send_email",
    ]

    private static func user(_ text: String) -> String {
        #"[{"role":"user","content":"\#(text)"}]"#
    }

    static let cases: [Case] = [
        Case(
            id: "weather",
            kind: .simple,
            offered: ["get_weather"],
            messages: user("What's the weather in Paris right now, in celsius?"),
            calls: [Call(name: "get_weather", arguments: ["city": .oneOf(["Paris"]), "unit": .oneOf(["celsius"])])]
        ),
        Case(
            id: "timer",
            kind: .simple,
            offered: ["set_timer"],
            messages: user("Set a timer for 25 minutes called tea."),
            calls: [Call(name: "set_timer", arguments: ["minutes": .integer(25), "label": .oneOf(["tea"])])]
        ),
        Case(
            id: "currency",
            kind: .simple,
            offered: ["convert_currency"],
            messages: user("Convert 120.5 euros to US dollars."),
            calls: [Call(name: "convert_currency", arguments: [
                "amount": .number(120.5), "from": .oneOf(["EUR"]), "to": .oneOf(["USD"]),
            ])]
        ),
        Case(
            id: "flights",
            kind: .simple,
            offered: ["search_flights"],
            messages: user("Find nonstop flights from LHR to JFK on 2026-11-03."),
            calls: [Call(name: "search_flights", arguments: [
                "origin": .oneOf(["LHR"]), "destination": .oneOf(["JFK"]), "date": .oneOf(["2026-11-03"]),
                "nonstop": .boolean(true),
            ])]
        ),
        Case(
            id: "sum",
            kind: .simple,
            offered: ["add_numbers"],
            messages: user("Use the tool to add up 3, 4.5 and 10."),
            calls: [Call(name: "add_numbers", arguments: ["numbers": .numbers([3, 4.5, 10])])]
        ),

        Case(
            id: "choose-timer",
            kind: .choose,
            offered: all,
            messages: user("Start a 10 minute timer, please."),
            calls: [Call(name: "set_timer", arguments: ["minutes": .integer(10)])]
        ),
        Case(
            id: "choose-email",
            kind: .choose,
            offered: all,
            messages: user("Email bob@example.com with the subject Lunch, saying I'll see him at noon."),
            calls: [Call(name: "send_email", arguments: [
                "to": .oneOf(["bob@example.com"]), "subject": .oneOf(["Lunch"]), "body": .contains("noon"),
            ])]
        ),
        Case(
            id: "choose-weather",
            kind: .choose,
            offered: all,
            messages: user("Is it raining in Tokyo? Give me the temperature in fahrenheit."),
            calls: [Call(
                name: "get_weather",
                arguments: ["city": .oneOf(["Tokyo"]), "unit": .oneOf(["fahrenheit"])]
            )]
        ),

        Case(
            id: "two-cities",
            kind: .parallel,
            offered: ["get_weather"],
            messages: user("What's the weather in Rome and in Madrid, both in celsius?"),
            calls: [
                Call(name: "get_weather", arguments: ["city": .oneOf(["Rome"]), "unit": .oneOf(["celsius"])]),
                Call(name: "get_weather", arguments: ["city": .oneOf(["Madrid"]), "unit": .oneOf(["celsius"])]),
            ]
        ),
        Case(
            id: "two-timers",
            kind: .parallel,
            offered: ["set_timer"],
            messages: user("Set two timers: 5 minutes for eggs and 12 minutes for pasta."),
            calls: [
                Call(name: "set_timer", arguments: ["minutes": .integer(5), "label": .oneOf(["eggs"])]),
                Call(name: "set_timer", arguments: ["minutes": .integer(12), "label": .oneOf(["pasta"])]),
            ]
        ),

        Case(
            id: "timer-and-weather",
            kind: .parallelMultiple,
            offered: all,
            messages: user("Set a 3 minute timer, and tell me the weather in Oslo in celsius."),
            calls: [
                Call(name: "set_timer", arguments: ["minutes": .integer(3)]),
                Call(name: "get_weather", arguments: ["city": .oneOf(["Oslo"]), "unit": .oneOf(["celsius"])]),
            ]
        ),
        Case(
            id: "convert-and-email",
            kind: .parallelMultiple,
            offered: all,
            messages: user(
                "Convert 50 USD to GBP, and also email ann@example.com with the subject Rate and the body Done."
            ),
            calls: [
                Call(name: "convert_currency", arguments: [
                    "amount": .number(50), "from": .oneOf(["USD"]), "to": .oneOf(["GBP"]),
                ]),
                Call(name: "send_email", arguments: [
                    "to": .oneOf(["ann@example.com"]), "subject": .oneOf(["Rate"]), "body": .contains("done"),
                ]),
            ]
        ),

        Case(
            id: "haiku",
            kind: .irrelevance,
            offered: ["get_weather"],
            messages: user("Write a haiku about autumn leaves."),
            calls: []
        ),
        Case(
            id: "author",
            kind: .irrelevance,
            offered: ["set_timer", "convert_currency"],
            messages: user("Who wrote Pride and Prejudice?"),
            calls: [],
            mentions: "Austen"
        ),
        Case(
            id: "arithmetic",
            kind: .irrelevance,
            offered: ["search_flights"],
            messages: user("What is 7 times 8?"),
            calls: [],
            mentions: "56"
        ),

        Case(
            id: "after-weather",
            kind: .followUp,
            offered: ["get_weather"],
            messages: #"""
            [{"role":"user","content":"What's the weather in Paris, in celsius?"},
             {"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\",\"unit\":\"celsius\"}"}}]},
             {"role":"tool","tool_call_id":"call_1","content":"{\"temperature\":18,\"conditions\":\"cloudy\"}"}]
            """#,
            calls: [],
            mentions: "18"
        ),
    ]

    /// A call as the server returned it.
    struct ReturnedCall: Codable, Sendable, Equatable {
        var name: String
        /// The `arguments` string as sent.
        var arguments: String
    }

    struct CaseResult: Codable, Sendable, Equatable {
        var id: String
        var kind: Kind
        var passed: Bool
        /// Why it failed, in words.
        var reason: String?
        var calls: [ReturnedCall]
        var content: String
    }

    /// The whole run, as `--json` prints it.
    struct Result: Codable, Sendable, Equatable {
        var suite = ToolEval.id
        var date: Date
        var url: String
        var model: String
        var cases: [CaseResult]

        var passed: Int {
            cases.filter(\.passed).count
        }
    }

    // MARK: Checking

    /// Whether a reply is the one `expected` asks for; the reason when it isn't.
    static func check(_ expected: Case, calls: [ReturnedCall], content: String) -> String? {
        if expected.calls.isEmpty {
            if let call = calls.first {
                return "called \(call.name) when it should have answered"
            }
            if let mention = expected.mentions, !content.localizedCaseInsensitiveContains(mention) {
                return "the answer doesn't mention \(mention)"
            }
            return nil
        }
        if calls.isEmpty {
            return content.isEmpty ? "no call and no answer" : "answered in text instead of calling a tool"
        }
        if calls.count != expected.calls.count {
            return "made \(calls.count) call\(calls.count == 1 ? "" : "s"), not \(expected.calls.count)"
        }
        // Each expected call matched by a different returned call, in any order.
        var unmatched = calls
        var firstProblem: String?
        for call in expected.calls {
            var problems: [String] = []
            let index = unmatched.firstIndex { returned in
                let problem = mismatch(call, returned)
                if let problem {
                    problems.append(problem)
                }
                return problem == nil
            }
            if let index {
                unmatched.remove(at: index)
            } else {
                firstProblem = firstProblem ?? problems.first ?? "no call to \(call.name)"
            }
        }
        return firstProblem
    }

    /// Why `returned` isn't `expected`, or nil.
    static func mismatch(_ expected: Call, _ returned: ReturnedCall) -> String? {
        guard returned.name == expected.name else { return "called \(returned.name), not \(expected.name)" }
        guard let object = try? JSONSerialization.jsonObject(with: Data(returned.arguments.utf8)) as? [String: Any]
        else { return "\(returned.name)'s arguments aren't a JSON object" }
        let schema = parameters(of: expected.name)
        for key in object.keys where schema[key] == nil {
            return "\(returned.name) was given \(key), which it doesn't take"
        }
        for (key, expect) in expected.arguments.sorted(by: { $0.key < $1.key }) {
            guard let value = object[key] else { return "\(returned.name) is missing \(key)" }
            if let problem = mismatch(expect, value) {
                return "\(returned.name)'s \(key) \(problem)"
            }
        }
        return nil
    }

    private static func mismatch(_ expect: Expect, _ value: Any) -> String? {
        func number(_ value: Any) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }
        switch expect {
        case let .oneOf(options):
            guard let text = value as? String else { return "isn't a string" }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return options.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ? nil : "is \"\(text)\""
        case let .contains(part):
            guard let text = value as? String else { return "isn't a string" }
            return text.localizedCaseInsensitiveContains(part) ? nil : "doesn't mention \(part)"
        case let .integer(want):
            guard let got = number(value)
            else { return value is String ? "is a string, not an integer" : "isn't an integer" }
            guard got == got.rounded() else { return "isn't a whole number" }
            return Int(got) == want ? nil : "is \(Int(got)), not \(want)"
        case let .number(want):
            guard let got = number(value)
            else { return value is String ? "is a string, not a number" : "isn't a number" }
            return abs(got - want) < 1e-9 ? nil : "is \(got), not \(want)"
        case let .boolean(want):
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                return "isn't true or false"
            }
            return number.boolValue == want ? nil : "is \(number.boolValue)"
        case let .numbers(want):
            guard let array = value as? [Any] else { return "isn't a list" }
            let got = array.compactMap(number)
            guard got.count == array.count else { return "has an item that isn't a number" }
            return got.sorted() == want.sorted() ? nil : "is \(got)"
        }
    }

    /// The parameter names a tool takes.
    private static func parameters(of name: String) -> [String: Any] {
        guard let text = tools[name],
              let tool = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let function = tool["function"] as? [String: Any],
              let parameters = function["parameters"] as? [String: Any],
              let properties = parameters["properties"] as? [String: Any]
        else { return [:] }
        return properties
    }

    // MARK: Running

    /// The request body for a case: its tools, its conversation, deterministic sampling, room to think.
    static func body(for testCase: Case, model: String) throws -> Data {
        let tools = try testCase.offered.map { name -> Any in
            try JSONSerialization.jsonObject(with: Data((Self.tools[name] ?? "{}").utf8))
        }
        let messages = try JSONSerialization.jsonObject(with: Data(testCase.messages.utf8))
        let body: [String: Any] = [
            "model": model, "messages": messages, "tools": tools, "tool_choice": "auto",
            "temperature": 0, "seed": 42, "max_tokens": 4096, "stream": false,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// The calls and text of a non-streamed reply.
    static func reply(from data: Data) throws -> (calls: [ReturnedCall], content: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        else { throw URLBenchmarkError.badResponse("no message in the reply") }
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> ReturnedCall? in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else {
                return nil
            }
            let arguments = function["arguments"] as? String
                ?? (function["arguments"].flatMap { try? JSONSerialization.data(withJSONObject: $0) })
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return ReturnedCall(name: name, arguments: arguments)
        }
        return (calls, message["content"] as? String ?? "")
    }

    /// Runs every case on `model` through `send` (a request body in, the response body out).
    static func run(
        model: String, url: String, date: Date = .init(),
        send: @Sendable (Data) async throws -> Data,
        progress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> Result {
        var results: [CaseResult] = []
        for (index, testCase) in cases.enumerated() {
            await progress(index, cases.count)
            let (calls, content) = try await reply(from: send(body(for: testCase, model: model)))
            let reason = check(testCase, calls: calls, content: content)
            results.append(CaseResult(
                id: testCase.id, kind: testCase.kind, passed: reason == nil, reason: reason, calls: calls,
                content: content
            ))
        }
        return Result(date: date, url: url, model: model, cases: results)
    }
}
