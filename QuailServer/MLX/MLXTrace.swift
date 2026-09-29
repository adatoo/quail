import Foundation

/// How long the MLX serving loop spends on each thing it does, one JSON line per event, when `QUAIL_MLX_TRACE`
/// names a file: a diagnostic for tuning batching (#139), off otherwise. Times are wall-clock, so a lazily built
/// graph's cost lands on the call that waits for it (a step's `asArray`, the first token's `item`).
enum MLXTrace {
    private static let file: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["QUAIL_MLX_TRACE"], !path.isEmpty else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static var enabled: Bool {
        file != nil
    }

    /// Runs `body`, and records how long it took under `event` with `fields`.
    @discardableResult
    static func time<T>(_ event: String, _ fields: [String: Int] = [:], _ body: () -> T) -> T {
        guard file != nil else { return body() }
        let start = ContinuousClock.now
        let result = body()
        let elapsed = ContinuousClock.now - start
        var record: [String: Any] = fields
        record["ms"] = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        write(event, record)
        return result
    }

    /// Records `fields` under `event`, untimed.
    static func note(_ event: String, _ fields: [String: Int]) {
        guard file != nil else { return }
        write(event, fields)
    }

    private static func write(_ event: String, _ fields: [String: Any]) {
        var record = fields
        record["event"] = event
        record["t"] = Date().timeIntervalSince1970
        if let file, let data = try? JSONSerialization.data(withJSONObject: record) {
            file.write(data + Data("\n".utf8))
        }
    }
}
