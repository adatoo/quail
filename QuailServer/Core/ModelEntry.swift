import Foundation

public enum ModelKind: String, Equatable, Sendable {
    case gguf
    case mlx
}

/// How a model's KV cache stores its elements: llama-server's `cache-type-k`/`cache-type-v` values, used by both
/// engines (ADR D-057). Smaller types hold a longer context in the same memory, at a small cost in accuracy.
public enum KVCacheType: String, Equatable, Sendable, CaseIterable {
    case f16
    case q8_0
    case q4_0

    /// Bits per element for MLX's affine quantization; nil for full precision.
    public var bits: Int? {
        switch self {
        case .f16: nil
        case .q8_0: 8
        case .q4_0: 4
        }
    }
}

/// A model the server can load: what a folder scan and the presets file say
/// about it. Nothing here touches the model itself.
public struct ModelEntry: Equatable, Sendable {
    public var id: String
    public var kind: ModelKind
    /// The `.gguf` file, or the MLX model directory.
    public var path: URL
    public var contextSize: Int?
    public var gpuLayers: Int?
    /// A vision model's `mmproj` companion (GGUF only).
    public var projector: URL?
    /// Requests decoded together (llama-server's `parallel`; for MLX, only families that batch, ADR D-056); nil
    /// takes the server's setting.
    public var parallel: Int?
    public var loadOnStartup = false
    /// Preset keys this server doesn't implement, so startup can say so once
    /// instead of silently dropping a setting.
    public var ignoredPresetKeys: [String] = []
    public var createdAt = Date(timeIntervalSince1970: 0)
    /// Bytes on disk (the file, or everything in the MLX folder), measured once at discovery, for the
    /// chat page's model picker. nil when the path can't be read.
    public var sizeBytes: Int64?
    /// An MLX model whose vision half Quail can load (`MLXVision.supports`), found at discovery.
    public var mlxVision = false
    /// Where this model's prompt caches may be kept on disk (the server's `--prompt-cache-dir`); nil for none.
    public var promptCacheDirectory: URL?
    /// The KV cache's key and value types (`cache-type-k`, `cache-type-v`); nil for the engine's full precision.
    public var cacheTypeK: KVCacheType?
    public var cacheTypeV: KVCacheType?
    /// llama.cpp's flash attention (`flash-attn`: on, off or auto); nil leaves it to llama.cpp, which a quantized
    /// V cache needs on.
    public var flashAttention: Bool?

    /// Bits per element for an MLX KV cache, which quantizes keys and values alike: set only when both are
    /// quantized, to the larger of the two.
    public var mlxKVBits: Int? {
        guard let k = cacheTypeK?.bits, let v = cacheTypeV?.bits else { return nil }
        return max(k, v)
    }

    /// Whether this model can read images in Quail: a GGUF with its projector, or a supported MLX one.
    public var supportsImages: Bool {
        projector != nil || (kind == .mlx && mlxVision)
    }
}

enum ModelDiscovery {
    /// The preset keys `quail-server` understands.
    static let knownPresetKeys: Set<String> = [
        "model",
        "n-gpu-layers",
        "ctx-size",
        "mmproj",
        "load-on-startup",
        "parallel",
        "np",
        "cache-type-k",
        "cache-type-v",
        "flash-attn",
    ]

    /// Scans the model folders, then lays the presets over the result. A preset
    /// that names a `model` is listed even if the file is missing (it fails when
    /// loaded, with the reason), like llama-server's router.
    static func discover(
        modelsDirectory: URL?,
        mlxDirectory: URL?,
        presets: [ModelPreset]
    ) -> [ModelEntry] {
        var byID: [String: ModelEntry] = [:]
        let fm = FileManager.default

        if let modelsDirectory,
           let files = try? fm.contentsOfDirectory(
               at: modelsDirectory,
               includingPropertiesForKeys: [.contentModificationDateKey]
           )
        {
            for file in files where file.pathExtension.lowercased() == "gguf" {
                let id = file.deletingPathExtension().lastPathComponent
                // A projector next to a model isn't a model (ModelStore.projectorFilename).
                if id.hasPrefix("mmproj") {
                    continue
                }
                var entry = ModelEntry(id: id, kind: .gguf, path: file, createdAt: modificationDate(file))
                let projector = file.deletingLastPathComponent().appendingPathComponent("mmproj-\(id).gguf")
                if fm.fileExists(atPath: projector.path) {
                    entry.projector = projector
                }
                byID[id] = entry
            }
        }

        if let mlxDirectory,
           let directories = try? fm.contentsOfDirectory(
               at: mlxDirectory,
               includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
           )
        {
            for directory in directories
                where fm.fileExists(atPath: directory.appendingPathComponent("config.json").path)
            {
                let id = directory.lastPathComponent
                byID[id] = ModelEntry(id: id, kind: .mlx, path: directory, createdAt: modificationDate(directory))
            }
        }

        for preset in presets {
            var entry: ModelEntry
            if let path = preset.string("model") {
                let url = URL(fileURLWithPath: path)
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                entry = byID[preset.id] ?? ModelEntry(
                    id: preset.id,
                    kind: isDirectory ? .mlx : .gguf,
                    path: url,
                    createdAt: modificationDate(url)
                )
                entry.path = url
                entry.kind = isDirectory ? .mlx : .gguf
            } else if let scanned = byID[preset.id] {
                entry = scanned
            } else {
                continue // a section that names no model and matches nothing on disk
            }
            if let contextSize = preset.int("ctx-size") {
                entry.contextSize = contextSize
            }
            if let gpuLayers = preset.int("n-gpu-layers") {
                entry.gpuLayers = gpuLayers
            }
            if let parallel = preset.int("parallel") ?? preset.int("np"), parallel >= 1 {
                entry.parallel = parallel
            }
            if let projector = preset.string("mmproj") {
                entry.projector = URL(fileURLWithPath: projector)
            }
            if let startup = preset.bool("load-on-startup") {
                entry.loadOnStartup = startup
            }
            var unknownValues: [String] = []
            for (key, path) in [("cache-type-k", \ModelEntry.cacheTypeK), ("cache-type-v", \ModelEntry.cacheTypeV)] {
                guard let text = preset.string(key) else { continue }
                if let type = KVCacheType(rawValue: text.lowercased()) {
                    entry[keyPath: path] = type == .f16 ? nil : type
                } else {
                    unknownValues.append("\(key)=\(text)")
                }
            }
            if let flash = preset.string("flash-attn")?.lowercased() {
                entry.flashAttention = ["on", "1", "true", "enabled"].contains(flash)
                    ? true : ["off", "0", "false", "disabled"].contains(flash) ? false : nil
            }
            entry.ignoredPresetKeys = (preset.values.keys.filter { !knownPresetKeys.contains($0) } + unknownValues)
                .sorted()
            byID[preset.id] = entry
        }

        return byID.values
            .map { entry in
                var entry = entry
                entry.sizeBytes = size(of: entry.path)
                entry.mlxVision = entry.kind == .mlx && MLXVision.supports(directory: entry.path)
                return entry
            }
            .sorted { $0.id < $1.id }
    }

    /// A file's size, or the total of the regular files under a folder; nil if nothing's there.
    static func size(of url: URL) -> Int64? {
        // A model kept elsewhere and linked into the store is measured where it is, not as a link.
        let url = url.resolvingSymlinksInPath()
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let files = fm.enumerator(at: url, includingPropertiesForKeys: keys) else { return nil }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? Date(timeIntervalSince1970: 0)
    }
}
