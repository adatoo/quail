import Foundation
import Testing
@testable import Quail

/// Phase 3 step 7's speed check: the benchmark suite (`BenchmarkRunner`, as `quail bench` runs it) against
/// running servers named in `QUAIL_GATE_SERVERS` (`name=http://127.0.0.1:port,…`), for the model in
/// `QUAIL_GATE_MODEL`, a few rounds each, alternating servers, results as JSON to `QUAIL_GATE_OUT`. Passed
/// to the tests with the `TEST_RUNNER_` prefix. Off unless set; see `docs/IMPLEMENTATION_PLAN.md` step 7.
@Suite("Parity gate benchmark (servers from the environment)", .timeLimit(.minutes(60)))
struct ParityGateBench {
    private static let environment = ProcessInfo.processInfo.environment
    private static let servers: [(name: String, base: URL)] = (environment["QUAIL_GATE_SERVERS"] ?? "")
        .split(separator: ",").compactMap { item in
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let url = URL(string: parts[1]) else { return nil }
            return (parts[0], url)
        }

    private static let enabled = !servers.isEmpty && environment["QUAIL_GATE_MODEL"] != nil

    @Test("run the suite on each server, alternating", .enabled(if: enabled))
    func run() async throws {
        let model = try #require(Self.environment["QUAIL_GATE_MODEL"])
        let key = Self.environment["QUAIL_GATE_KEY"]
        let rounds = Int(Self.environment["QUAIL_GATE_ROUNDS"] ?? "") ?? 3
        var results: [String: [BenchmarkResult.Measurements]] = [:]
        for _ in 0 ..< rounds {
            for server in Self.servers {
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
}
