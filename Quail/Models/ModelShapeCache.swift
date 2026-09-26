import Foundation

/// Model shapes read from Hugging Face (a GGUF header's first megabytes, an MLX `config.json`), kept on disk
/// so the Add Model list's fit badges appear at once instead of after a round of downloads every time the
/// sheet opens. A shape is a property of the repo's files, not of this Mac, so the verdict is still worked
/// out fresh from it (device, runtime, context). Entries last 30 days; a repo that changed its files in that
/// time gets a slightly stale estimate, which the verdict's own approximations dwarf.
final class ModelShapeCache: @unchecked Sendable {
    static let shared = ModelShapeCache(
        url: Paths.applicationSupport.appendingPathComponent("Cache/model-shapes.json", isDirectory: false)
    )

    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    private struct Entry: Codable {
        var shape: ModelShape
        var fetchedAt: Date
    }

    private let url: URL?
    private let lock = NSLock()
    private var entries: [String: Entry]?
    private let now: @Sendable () -> Date

    /// `url` nil keeps it in memory only (tests).
    init(url: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    static func key(repo: String, format: ModelFormat, file: String? = nil) -> String {
        [format.rawValue, repo, file].compactMap(\.self).joined(separator: "|")
    }

    func shape(for key: String) -> ModelShape? {
        lock.withLock {
            loadIfNeeded()
            guard let entry = entries?[key],
                  now().timeIntervalSince(entry.fetchedAt) < Self.lifetime else { return nil }
            return entry.shape
        }
    }

    func store(_ shape: ModelShape, for key: String) {
        let snapshot: [String: Entry]? = lock.withLock {
            loadIfNeeded()
            entries?[key] = Entry(shape: shape, fetchedAt: now())
            return entries
        }
        guard let url, let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else {
            entries = [:]
            return
        }
        entries = decoded
    }
}
