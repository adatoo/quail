import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import QuailServerCore

/// MLX prompt caches kept on disk once they leave memory (ADR D-055, Phase 3c step 5's disk tier): evicted from
/// `PromptCaches`, or all of them when the model is unloaded (a swap under `--models-max 1`, the server stopping).
/// A later prompt that one of them holds a good part of loads it back instead of reading its prompt again.
///
/// One folder per model, and per build of it (a changed model folder starts afresh), holding for each cache a
/// safetensors file (mlx-swift-lm's `savePromptCache`, recurrent state included) and a small JSON file with the
/// tokens it holds. Oldest out first, within `budgetBytes`. Everything here runs inside the model container's
/// serial access, like `PromptCaches`.
final class PromptDiskCache: @unchecked Sendable {
    private struct Sidecar: Codable {
        var tokens: [Int]
        var trimmable: Bool
    }

    private struct Stored {
        let name: String
        let tokens: [Int]
        let trimmable: Bool
        let bytes: Int
        let used: Date
    }

    let directory: URL
    let budgetBytes: Int
    /// Oldest first.
    private var stored: [Stored] = []

    /// At most 20 GB, and no more than a tenth of the disk's free space.
    static func defaultBudget(for directory: URL) -> Int {
        let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return Int(min(Int64(20) << 30, max(0, free / 10)))
    }

    /// nil when there's no folder to use (`--no-prompt-cache-disk`) or it can't be made.
    init?(root: URL?, entry: ModelEntry, weightBytes: Int, vision: Bool) {
        guard let root else { return nil }
        let model = entry.path.resolvingSymlinksInPath()
        let modified = (try? model.appendingPathComponent("config.json")
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?
            .timeIntervalSince1970 ?? 0
        // The vision load's caches are its language model's, laid out differently: a folder of their own.
        let identity = "\(model.path)|\(weightBytes)|\(modified)|\(vision ? "vision" : "text")"
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let safeID = entry.id.map { $0.isLetter || $0.isNumber || "-._".contains($0) ? $0 : "_" }
        directory = root.appendingPathComponent("\(String(safeID))-\(digest)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        budgetBytes = Self.defaultBudget(for: directory)
        stored = Self.scan(directory)
    }

    private static func scan(_ directory: URL) -> [Stored] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { json -> Stored? in
            let tensors = json.deletingPathExtension().appendingPathExtension("safetensors")
            guard let data = try? Data(contentsOf: json),
                  let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
                  let values = try? tensors.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize
            else {
                // Half a pair (an interrupted save): gone.
                try? FileManager.default.removeItem(at: json)
                try? FileManager.default.removeItem(at: tensors)
                return nil
            }
            return Stored(
                name: json.deletingPathExtension().lastPathComponent, tokens: sidecar.tokens,
                trimmable: sidecar.trimmable, bytes: size, used: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.used < $1.used }
    }

    /// How many of `prompt`'s tokens the best cache on disk holds (0 for none).
    func bestReuse(for prompt: [Int]) -> Int {
        choice(for: prompt)?.reuse ?? 0
    }

    private func choice(for prompt: [Int]) -> PromptCachePlan.Choice? {
        PromptCachePlan.choose(
            stored.map { PromptCachePlan.Candidate(tokens: $0.tokens, trimmable: $0.trimmable) }, for: prompt
        )
    }

    /// The best cache on disk for `prompt`, loaded and cut back to what it shares; its files are removed (it
    /// comes back here when it leaves memory again). nil if none holds any of it, or it can't be read.
    func take(for prompt: [Int]) -> (layers: [any KVCache], reused: Int)? {
        guard let choice = choice(for: prompt) else { return nil }
        let picked = stored.remove(at: choice.index)
        let tensors = directory.appendingPathComponent(picked.name + ".safetensors")
        defer {
            try? FileManager.default.removeItem(at: tensors)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(picked.name + ".json"))
        }
        guard let (layers, _) = try? loadPromptCache(url: tensors) else { return nil }
        for layer in layers where layer.isTrimmable && layer.offset > choice.reuse {
            layer.trim(layer.offset - choice.reuse)
        }
        return (layers, choice.reuse)
    }

    /// Writes a cache that holds `tokens`, then lets the oldest go until the folder is within budget.
    func save(_ layers: [any KVCache], tokens: [Int]) {
        guard !tokens.isEmpty, !layers.isEmpty else { return }
        // The same tokens again replace the older copy.
        if let same = stored.firstIndex(where: { $0.tokens == tokens }) {
            remove(at: same)
        }
        let name = UUID().uuidString
        let tensors = directory.appendingPathComponent(name + ".safetensors")
        let json = directory.appendingPathComponent(name + ".json")
        let trimmable = layers.allSatisfy(\.isTrimmable)
        do {
            try savePromptCache(url: tensors, cache: layers)
            try JSONEncoder().encode(Sidecar(tokens: tokens, trimmable: trimmable)).write(to: json, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: tensors)
            try? FileManager.default.removeItem(at: json)
            return
        }
        let size = (try? tensors.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        stored.append(Stored(name: name, tokens: tokens, trimmable: trimmable, bytes: size, used: Date()))
        let drop = PromptCachePlan.evictions(
            sizes: stored.map(\.bytes), maxEntries: Int.max, maxBytes: budgetBytes
        )
        for _ in 0 ..< drop {
            remove(at: 0)
        }
        // Over budget on its own (a disk nearly full): don't keep it either.
        if let last = stored.last, last.bytes > budgetBytes {
            remove(at: stored.count - 1)
        }
    }

    private func remove(at index: Int) {
        let gone = stored.remove(at: index)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(gone.name + ".safetensors"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(gone.name + ".json"))
    }
}
