import Foundation

/// Something in the store that no model uses — shown by the Models pane's
/// "Clean Up…" for the user to delete. Never removed automatically: these
/// are the user's files, and a "leftover" can be one they meant to keep.
struct StoreLeftover: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        /// An `mmproj-*.gguf` not named for any installed model — its model
        /// was deleted (e.g. in Finder), or it predates per-model naming
        /// (`mmproj-F16.gguf`), so no preset references it.
        case unlinkedProjector
        /// An abandoned download's bytes under `.partial/<owner--repo>/`.
        case partialDownload
    }

    var kind: Kind
    var url: URL
    var bytes: Int64

    var id: String {
        url.path
    }

    var title: String {
        switch kind {
        case .unlinkedProjector: url.lastPathComponent
        case .partialDownload: url.lastPathComponent.replacingOccurrences(of: "--", with: "/")
        }
    }
}

extension ModelStore {
    /// Unlinked projectors and partial downloads. `activeRepo` is a
    /// download in flight — its partial bytes are in use, not leftover.
    func leftovers(activeRepo: String? = nil) -> [StoreLeftover] {
        let fm = FileManager.default
        var result: [StoreLeftover] = []

        let linked = Set(installedGGUFFiles().map {
            Self.projectorFilename(forModelID: $0.deletingPathExtension().lastPathComponent)
        })
        let ggufContents = (try? fm.contentsOfDirectory(at: ggufDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in ggufContents where file.lastPathComponent.hasPrefix("mmproj-")
            && file.pathExtension.lowercased() == "gguf"
            && !linked.contains(file.lastPathComponent)
        {
            result.append(StoreLeftover(kind: .unlinkedProjector, url: file, bytes: fileSize(of: file)))
        }

        let activeDir = activeRepo?.replacingOccurrences(of: "/", with: "--")
        let partials = (try? fm.contentsOfDirectory(
            at: partialDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for dir in partials where dir.lastPathComponent != activeDir {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            result.append(StoreLeftover(kind: .partialDownload, url: dir, bytes: directorySize(of: dir)))
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    /// Names and sizes of everything directly in `gguf/` and `mlx/` — what
    /// `StoreWatcher` compares to tell when a Finder copy has finished.
    func contentSnapshot() -> [String: Int64] {
        let fm = FileManager.default
        var snapshot: [String: Int64] = [:]
        for dir in [ggufDirectory, mlxDirectory] {
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                snapshot[url.path] = isDir ? directorySize(of: url) : fileSize(of: url)
            }
        }
        return snapshot
    }

    /// What a running router was started with: the generated
    /// `presets.ini`, line by line — models, projectors and context sizes.
    /// Compared against the current file to decide "restart to apply" —
    /// confirmed against the real router that it never rescans: a model
    /// added later isn't listed (loading it 404s), a deleted one stays,
    /// and a changed `ctx-size` only applies to a fresh start.
    func presetSignature() -> [String] {
        ((try? String(contentsOf: presetsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}
