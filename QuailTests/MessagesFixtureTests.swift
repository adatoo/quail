import Foundation
import Testing
@testable import Quail
@testable import QuailServerCore

/// quail-server's replies must carry every field llama-server's do (TestFixtures/Messages).
@Suite("Messages and Responses against llama-server's shapes", .timeLimit(.minutes(1)))
struct MessagesFixtureTests {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestFixtures/Messages")

    private static func fixture(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private static func object(_ name: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(fixture(name).utf8)) as? [String: Any])
    }

    /// Keys `theirs` has that `ours` lacks, as paths. Lists are compared by their first element;
    /// `ignoring` names keys that are llama-server's own extras.
    private static func missing(
        _ ours: Any?, from theirs: Any, path: String = "", ignoring: Set<String> = ["timings"]
    ) -> [String] {
        if let theirs = theirs as? [String: Any] {
            guard let ours = ours as? [String: Any] else { return [path.isEmpty ? "<root>" : path] }
            return theirs.flatMap { key, value -> [String] in
                ignoring.contains(key) ? [] : missing(
                    ours[key],
                    from: value,
                    path: "\(path)/\(key)",
                    ignoring: ignoring
                )
            }
        }
        if let theirs = (theirs as? [Any])?.first {
            guard let ours = (ours as? [Any])?.first else { return [] } // an empty list is as good as theirs
            return missing(ours, from: theirs, path: path + "[0]", ignoring: ignoring)
        }
        return ours == nil ? [path] : []
    }

    /// An event's name and the `type`s nested in it, to match an event to the same kind of event.
    private static func kind(_ event: RouteHarness.Event) -> String {
        let nested = ["delta", "content_block", "item", "part"].compactMap {
            (event[$0] as? [String: Any])?["type"] as? String
        }
        return ([event.name] + nested).joined(separator: "/")
    }

    private func check(theirs fixture: String, ours: [RouteHarness.Event]) throws {
        let theirs = try RouteHarness.parseEvents(Self.fixture(fixture))
        #expect(!theirs.isEmpty)
        for event in theirs {
            let kind = Self.kind(event)
            guard let match = ours.first(where: { Self.kind($0) == kind }) else {
                Issue.record("\(fixture): no \(kind) event")
                continue
            }
            let lacking = Self.missing(match.data, from: event.data)
            #expect(lacking.isEmpty, "\(fixture) \(kind) lacks \(lacking)")
        }
    }

    private static let thinkingReply = ["<think>", "\nHmm.\n", "</think>", "\n\n", "Hi"]

    @Test("a streamed /v1/messages text reply", arguments: [
        ("anthropic-text.sse", thinkingReply, ""),
        (
            "anthropic-tool.sse",
            thinkingReply.dropLast() + RouteHarness.hermesCall,
            #""tools":[{"name":"get_weather","input_schema":{"type":"object"}}],"#
        ),
    ])
    func anthropicStream(fixture: String, pieces: [String], extra: String) async throws {
        let harness = RouteHarness(pieces: Array(pieces))
        let stream = await harness.events(
            "/v1/messages",
            #"{"model":"Alpha","max_tokens":99,"stream":true,\#(extra)"messages":[{"role":"user","content":"Hi"}]}"#
        )
        try check(theirs: fixture, ours: stream.events)
    }

    @Test("a streamed /v1/responses reply", arguments: [
        ("responses-text.sse", ["Hello", "!"], ""),
        (
            "responses-tool.sse",
            RouteHarness.hermesCall,
            #""tools":[{"type":"function","name":"get_weather","parameters":{}}],"#
        ),
    ])
    func responsesStream(fixture: String, pieces: [String], extra: String) async throws {
        let harness = RouteHarness(pieces: pieces)
        let stream = await harness.events("/v1/responses", #"{"model":"Alpha","stream":true,\#(extra)"input":"Hi"}"#)
        try check(theirs: fixture, ours: stream.events)
    }

    @Test("a whole /v1/messages tool reply")
    func anthropicWhole() async throws {
        let harness = RouteHarness(pieces: Self.thinkingReply.dropLast() + RouteHarness.hermesCall)
        let reply = await harness.json(
            "/v1/messages",
            #"{"model":"Alpha","max_tokens":99,"tools":[{"name":"get_weather","input_schema":{"type":"object"}}],"messages":[{"role":"user","content":"Hi"}]}"#
        )
        #expect(try Self.missing(reply.json, from: Self.object("anthropic-tool.json")).isEmpty)
    }

    @Test("a whole /v1/responses reply, with text and with a call", arguments: [
        ("responses-text.json", ["Hello", "!"], ""),
        (
            "responses-tool.json",
            RouteHarness.hermesCall,
            #""tools":[{"type":"function","name":"get_weather","parameters":{}}],"#
        ),
    ])
    func responsesWhole(fixture: String, pieces: [String], extra: String) async throws {
        let harness = RouteHarness(pieces: pieces)
        let reply = await harness.json("/v1/responses", #"{"model":"Alpha",\#(extra)"input":"Hi"}"#)
        let lacking = try Self.missing(reply.json, from: Self.object(fixture))
        #expect(lacking.isEmpty, "\(fixture) lacks \(lacking)")
    }
}
