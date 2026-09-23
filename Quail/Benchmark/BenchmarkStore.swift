import Foundation

/// Saved benchmark results: `Application Support/Quail/benchmarks.json`, a
/// JSON array of `BenchmarkResult`, newest first.
struct BenchmarkStore: Sendable {
    let fileURL: URL

    static var `default`: BenchmarkStore {
        BenchmarkStore(fileURL: Paths.applicationSupport.appendingPathComponent("benchmarks.json"))
    }

    /// Unreadable entries (a newer schema, a damaged file) are skipped, not
    /// fatal: one bad record mustn't hide the rest.
    func load() -> [BenchmarkResult] {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        let decoder = BenchmarkResult.decoder()
        return raw.compactMap { item in
            guard let itemData = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? decoder.decode(BenchmarkResult.self, from: itemData)
        }
        .sorted { $0.date > $1.date }
    }

    func save(_ results: [BenchmarkResult]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try BenchmarkResult.encoder().encode(results).write(to: fileURL, options: .atomic)
    }

    /// The newest measured generation speed per model id on this chip —
    /// what the Models pane shows in place of the estimate.
    static func latestGenerationSpeed(in results: [BenchmarkResult], chip: String?) -> [String: Double] {
        var speeds: [String: Double] = [:]
        for result in results.sorted(by: { $0.date > $1.date }) where result.hardware.chip == chip {
            if speeds[result.model.id] == nil, let speed = result.measurements.generation256?.median {
                speeds[result.model.id] = speed
            }
        }
        return speeds
    }
}
