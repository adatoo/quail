import Foundation
import Testing
@testable import Quail

/// Phase 3 step 7's speed check: the benchmark suite (`BenchmarkRunner`, as `quail bench` runs it) against
/// running servers named in `QUAIL_GATE_SERVERS` (`name=http://127.0.0.1:port,…`), for the model in
/// `QUAIL_GATE_MODEL`, a few rounds each, alternating servers and their order, results as JSON to
/// `QUAIL_GATE_OUT`. Passed to the tests with the `TEST_RUNNER_` prefix. Off unless set; see
/// `docs/IMPLEMENTATION_PLAN.md` step 7.
@Suite("Parity gate benchmark (servers from the environment)", .timeLimit(.minutes(180)))
struct ParityGateBench {
    private static let environment = ProcessInfo.processInfo.environment
    private static let servers: [(name: String, base: URL)] = (environment["QUAIL_GATE_SERVERS"] ?? "")
        .split(separator: ",").compactMap { item in
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let url = URL(string: parts[1]) else { return nil }
            return (parts[0], url)
        }

    private static let enabled = !servers.isEmpty && environment["QUAIL_GATE_MODEL"] != nil

    @Test(
        "run the suite on each server, alternating",
        .enabled(if: enabled && environment["QUAIL_GATE_CONNECT"] == nil)
    )
    func run() async throws {
        let model = try #require(Self.environment["QUAIL_GATE_MODEL"])
        let key = Self.environment["QUAIL_GATE_KEY"]
        let rounds = Int(Self.environment["QUAIL_GATE_ROUNDS"] ?? "") ?? 3
        // The Mac slows as it heats up: on a Mac mini under "heavy" thermal pressure a later run measured
        // up to 20% slower than an earlier one on the same server. So each turn waits for the machine to
        // cool back to nominal (then a few seconds' rest), and the order flips every other round, so
        // neither server always gets the cooler machine.
        let rest = Int(Self.environment["QUAIL_GATE_REST"] ?? "") ?? 10
        var results: [String: [BenchmarkResult.Measurements]] = [:]
        for round in 0 ..< rounds {
            for server in round.isMultiple(of: 2) ? Self.servers : Self.servers.reversed() {
                try await Self.waitUntilCool()
                try await Task.sleep(for: .seconds(rest))
                let runner = BenchmarkRunner(client: LlamaCppBenchmarkClient(base: server.base, apiKey: key))
                let output = try await runner.run(model: model) { _, _ in }
                results[server.name, default: []].append(output.measurements)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(results)
        if let path = Self.environment["QUAIL_GATE_OUT"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
        print(String(decoding: data, as: UTF8.self))
    }

    /// Waits (up to 15 minutes) for the system's thermal state to be nominal.
    private static func waitUntilCool() async throws {
        let deadline = ContinuousClock.now + .seconds(900)
        while ProcessInfo.processInfo.thermalState != .nominal, ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(5))
        }
    }

    /// Step 7's "every Connect Test passes": the Connect tab's own Test, for every bundled tool, on each server.
    /// Its own switch (`QUAIL_GATE_CONNECT`), so it never runs beside the timed suite.
    @Test("every Connect Test passes on each server", .enabled(if: enabled && environment["QUAIL_GATE_CONNECT"] != nil))
    func connectTests() async throws {
        let model = try #require(Self.environment["QUAIL_GATE_MODEL"])
        let key = Self.environment["QUAIL_GATE_KEY"]
        let integrations = Integration.bundled()
        #expect(!integrations.isEmpty)
        for server in Self.servers {
            let values = SnippetRenderer.Values(baseURL: server.base, apiKey: key, model: model, contextSize: nil)
            for integration in integrations {
                let outcome = await ConnectionTester.test(api: integration.api, values: values)
                print("connect \(server.name) \(integration.id) (\(integration.api.rawValue)): \(outcome)")
                if case let .failed(message) = outcome {
                    Issue.record("\(server.name): \(integration.name) failed: \(message)")
                }
            }
        }
    }
}
