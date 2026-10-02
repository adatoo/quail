import Foundation
import Testing
@testable import Quail

@Suite("quail eval tools")
struct ToolEvalTests {
    private typealias Returned = ToolEval.ReturnedCall

    private func testCase(_ id: String) throws -> ToolEval.Case {
        try #require(ToolEval.cases.first { $0.id == id })
    }

    @Test("every case's tools exist, its conversation and its request body are valid JSON, and its ids are unique")
    func casesAreWellFormed() throws {
        #expect(Set(ToolEval.cases.map(\.id)).count == ToolEval.cases.count)
        for kind in ToolEval.Kind.allCases {
            #expect(ToolEval.cases.contains { $0.kind == kind }, "no case of kind \(kind)")
        }
        for testCase in ToolEval.cases {
            for name in testCase.offered {
                #expect(ToolEval.tools[name] != nil, "\(testCase.id) offers \(name)")
            }
            for call in testCase.calls {
                #expect(testCase.offered.contains(call.name), "\(testCase.id) expects \(call.name), not offered")
            }
            let body = try ToolEval.body(for: testCase, model: "m")
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect((object["tools"] as? [Any])?.count == testCase.offered.count)
        }
    }

    @Test("a right call passes, whatever the case of its strings, with its integer written as 25 or 25.0")
    func rightCallPasses() throws {
        let timer = try testCase("timer")
        #expect(ToolEval.check(
            timer,
            calls: [Returned(name: "set_timer", arguments: #"{"minutes": 25, "label": "Tea"}"#)],
            content: ""
        ) == nil)
        #expect(ToolEval.check(
            timer,
            calls: [Returned(name: "set_timer", arguments: #"{"minutes": 25.0, "label": " tea "}"#)],
            content: ""
        ) == nil)
    }

    @Test("wrong types, values, names and extra parameters fail with a reason")
    func wrongCallsFail() throws {
        let timer = try testCase("timer")
        #expect(ToolEval.check(
            timer,
            calls: [Returned(name: "set_timer", arguments: #"{"minutes": "25", "label": "tea"}"#)],
            content: ""
        ) == "set_timer's minutes is a string, not an integer")
        #expect(ToolEval.check(
            timer,
            calls: [Returned(name: "set_timer", arguments: #"{"minutes": 20, "label": "tea"}"#)],
            content: ""
        ) == "set_timer's minutes is 20, not 25")
        #expect(ToolEval.check(timer, calls: [Returned(name: "set_alarm", arguments: "{}")], content: "")
            == "called set_alarm, not set_timer")
        #expect(ToolEval.check(
            timer,
            calls: [Returned(name: "set_timer", arguments: #"{"minutes": 25, "label": "tea", "sound": "bell"}"#)],
            content: ""
        ) == "set_timer was given sound, which it doesn't take")
        #expect(ToolEval
            .check(timer, calls: [], content: "Done, timer set.") == "answered in text instead of calling a tool")
        let flights = try testCase("flights")
        #expect(ToolEval.check(flights, calls: [Returned(
            name: "search_flights",
            arguments: #"{"origin":"LHR","destination":"JFK","date":"2026-11-03","nonstop":"true"}"#
        )], content: "") == "search_flights's nonstop isn't true or false")
    }

    @Test("two expected calls match two returned ones in either order, each used once")
    func parallelInAnyOrder() throws {
        let cities = try testCase("two-cities")
        let rome = Returned(name: "get_weather", arguments: #"{"city":"Rome","unit":"celsius"}"#)
        let madrid = Returned(name: "get_weather", arguments: #"{"city":"Madrid","unit":"celsius"}"#)
        #expect(ToolEval.check(cities, calls: [madrid, rome], content: "") == nil)
        #expect(ToolEval.check(cities, calls: [rome, rome], content: "") != nil)
        #expect(ToolEval.check(cities, calls: [rome], content: "") == "made 1 call, not 2")
    }

    @Test("where no tool fits, any call fails; the answer must mention what it should")
    func irrelevanceAndFollowUp() throws {
        let author = try testCase("author")
        #expect(ToolEval.check(author, calls: [], content: "Jane Austen wrote it.") == nil)
        #expect(ToolEval.check(author, calls: [], content: "I don't know.") == "the answer doesn't mention Austen")
        #expect(ToolEval.check(author, calls: [Returned(name: "set_timer", arguments: #"{"minutes":1}"#)], content: "")
            == "called set_timer when it should have answered")
        let after = try testCase("after-weather")
        #expect(ToolEval.check(after, calls: [], content: "It's 18°C and cloudy in Paris.") == nil)
    }

    @Test("a reply's calls are read whether arguments come as a string or an object")
    func readsReplies() throws {
        let data = Data(#"""
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"a","type":"function","function":{"name":"set_timer","arguments":"{\"minutes\":3}"}},
          {"id":"b","type":"function","function":{"name":"get_weather","arguments":{"city":"Oslo","unit":"celsius"}}}]}}]}
        """#.utf8)
        let reply = try ToolEval.reply(from: data)
        #expect(reply.calls.map(\.name) == ["set_timer", "get_weather"])
        #expect(reply.calls[0].arguments == #"{"minutes":3}"#)
        #expect(try ToolEval.check(testCase("timer-and-weather"), calls: reply.calls, content: reply.content) == nil)
    }

    @Test("a run sends every case and tallies what passed")
    func runs() async throws {
        let result = try await ToolEval.run(model: "m", url: "http://127.0.0.1:1") { _ in
            Data(#"{"choices":[{"message":{"role":"assistant","content":"I can't help with that."}}]}"#.utf8)
        }
        #expect(result.cases.count == ToolEval.cases.count)
        // Answering in text passes only where no call was wanted and nothing had to be mentioned.
        #expect(result.passed == 1)
        #expect(result.cases.first { $0.passed }?.id == "haiku")
    }
}
