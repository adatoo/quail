import Foundation

public enum ModelKind: String, Equatable, Sendable {
    case gguf
    case mlx
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
    /// Requests decoded together by a GGUF model (llama-server's `parallel`); nil takes the server's setting.
    public var parallel: Int?
    public var loadOnStartup = false
    /// Preset keys this server doesn't implement, so startup can say so once
    /// instead of silently dropping a setting.
    public var ignoredPresetKeys: [String] = []
    public var createdAt = Date(timeIntervalSince1970: 0)
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
            entry.ignoredPresetKeys = preset.values.keys.filter { !knownPresetKeys.contains($0) }.sorted()
            byID[preset.id] = entry
        }

        return byID.values.sorted { $0.id < $1.id }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? Date(timeIntervalSince1970: 0)
    }
}
