import Foundation

/// Models other apps already downloaded, found on first run and offered for moving into Quail's store
/// (Phase 4 step 2, ADR D-059): llama.cpp's download cache, LM Studio's models folder, the Hugging Face cache
/// and oMLX's models folder. They're moved, never copied or linked: a model on disk twice wastes gigabytes,
/// and llama-server's folder scan and MLX's loaders both treat links inconsistently.
struct ImportCandidate: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable, CaseIterable {
        case llamaCpp = "llama.cpp"
        case lmStudio = "LM Studio"
        case huggingFace = "Hugging Face cache"
        case omlx = "oMLX"
    }

    /// One file to move: where it is (a Hugging Face snapshot's link is resolved to its blob) and where it goes,
    /// relative to the model's place in the store.
    struct File: Equatable, Sendable {
        var source: URL
        var destination: String
        /// A link to remove once its target has moved (a Hugging Face snapshot entry).
        var link: URL?
    }

    /// The model's id in the store: the GGUF file's name, or the MLX folder's (`owner--repo`).
    let id: String
    let format: ModelFormat
    let source: Source
    /// Where it was found, for showing.
    let location: URL
    let files: [File]
    let bytes: Int64
}

enum ModelImporter {
    // MARK: Finding

    /// Every model in the four places under `home` that isn't in `store` already, largest first.
    static func scan(home: URL, store: ModelStore) -> [ImportCandidate] {
        var found: [ImportCandidate] = []
        found += llamaCppCache(home.appendingPathComponent(".cache/llama.cpp"))
        found += lmStudio(home.appendingPathComponent(".lmstudio/models"))
        found += huggingFaceCache(home.appendingPathComponent(".cache/huggingface/hub"))
        found += omlx(home.appendingPathComponent(".omlx/models"))
        let fm = FileManager.default
        var seen: Set<String> = []
        return found
            .filter { candidate in
                let existing = candidate.format == .gguf
                    ? store.ggufDirectory.appendingPathComponent("\(candidate.id).gguf")
                    : store.mlxDirectory.appendingPathComponent(candidate.id)
                return !fm.fileExists(atPath: existing.path) && seen.insert(candidate.id).inserted
            }
            .sorted { $0.bytes > $1.bytes }
    }

    /// llama.cpp's `-hf` cache: flat `owner_repo_file.gguf` files, a projector named with `mmproj` beside its
    /// model.
    private static func llamaCppCache(_ folder: URL) -> [ImportCandidate] {
        ggufCandidates(in: folder, source: .llamaCpp)
    }

    /// LM Studio: `models/<publisher>/<repo>/`, holding GGUF files or an MLX model.
    private static func lmStudio(_ folder: URL) -> [ImportCandidate] {
        var result: [ImportCandidate] = []
        for publisher in children(of: folder) where isDirectory(publisher) {
            for repo in children(of: publisher) where isDirectory(repo) {
                if let mlx = mlxCandidate(
                    repo, id: "\(publisher.lastPathComponent)--\(repo.lastPathComponent)", source: .lmStudio
                ) {
                    result.append(mlx)
                } else {
                    result += ggufCandidates(in: repo, source: .lmStudio)
                }
            }
        }
        return result
    }

    /// The Hugging Face cache: `models--owner--name/snapshots/<revision>/`, whose files are links into the repo's
    /// `blobs/`. The revision `refs/main` names, or else the newest.
    private static func huggingFaceCache(_ folder: URL) -> [ImportCandidate] {
        var result: [ImportCandidate] = []
        for repo in children(of: folder) where repo.lastPathComponent.hasPrefix("models--") {
            let snapshots = repo.appendingPathComponent("snapshots")
            let main = (try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let revisions = children(of: snapshots).filter(isDirectory)
            guard let snapshot = revisions.first(where: { $0.lastPathComponent == main })
                ?? revisions.max(by: { modified($0) < modified($1) })
            else { continue }
            let id = String(repo.lastPathComponent.dropFirst("models--".count))
            if let mlx = mlxCandidate(snapshot, id: id, source: .huggingFace) {
                result.append(mlx)
            } else {
                result += ggufCandidates(in: snapshot, source: .huggingFace)
            }
        }
        return result
    }

    /// oMLX: one folder per MLX model.
    private static func omlx(_ folder: URL) -> [ImportCandidate] {
        children(of: folder).compactMap { mlxCandidate($0, id: $0.lastPathComponent, source: .omlx) }
    }

    /// Each GGUF model file in `folder`, with the folder's projector when it's the only model there (or, in
    /// llama.cpp's flat cache, the projector whose name starts like the model's).
    private static func ggufCandidates(in folder: URL, source: ImportCandidate.Source) -> [ImportCandidate] {
        let ggufs = children(of: folder).filter { $0.pathExtension.lowercased() == "gguf" && isFile($0) }
        let projectors = ggufs.filter { $0.lastPathComponent.lowercased().contains("mmproj") }
        let models = ggufs.filter { !projectors.contains($0) }
        return models.map { model in
            let id = model.deletingPathExtension().lastPathComponent
            var files = [file(model, to: "\(id).gguf")]
            let projector = source == .llamaCpp
                ? projectors.first { $0.lastPathComponent.hasPrefix(repoPrefix(of: model.lastPathComponent)) }
                : (models.count == 1 ? projectors.first : nil)
            if let projector {
                files.append(file(projector, to: ModelStore.projectorFilename(forModelID: id)))
            }
            return ImportCandidate(
                id: id, format: .gguf, source: source, location: model, files: files,
                bytes: files.reduce(0) { $0 + size($1.source) }
            )
        }
    }

    /// `owner_repo_` of llama.cpp's `owner_repo_file.gguf`.
    private static func repoPrefix(of name: String) -> String {
        let parts = name.split(separator: "_", maxSplits: 2)
        return parts.count == 3 ? "\(parts[0])_\(parts[1])_" : name
    }

    /// An MLX model: a folder with `config.json` and safetensors weights (flat, as MLX repos are).
    private static func mlxCandidate(_ folder: URL, id: String, source: ImportCandidate.Source) -> ImportCandidate? {
        let contents = children(of: folder)
        guard contents.contains(where: { $0.lastPathComponent == "config.json" }),
              contents.contains(where: { $0.pathExtension == "safetensors" })
        else { return nil }
        // A download that didn't finish (a Hugging Face snapshot missing a shard) isn't a model yet.
        let names = Set(contents.filter { isFile($0) }.map(\.lastPathComponent))
        if let index = try? Data(contentsOf: folder.appendingPathComponent("model.safetensors.index.json")),
           let json = try? JSONSerialization.jsonObject(with: index) as? [String: Any],
           let map = json["weight_map"] as? [String: String],
           !Set(map.values).isSubset(of: names)
        {
            return nil
        }
        let files = contents.filter { isFile($0) }.map { file($0, to: $0.lastPathComponent) }
        return ImportCandidate(
            id: id, format: .mlxSafetensors, source: source, location: folder, files: files,
            bytes: files.reduce(0) { $0 + size($1.source) }
        )
    }

    private static func file(_ url: URL, to destination: String) -> ImportCandidate.File {
        let resolved = url.resolvingSymlinksInPath()
        return .init(source: resolved, destination: destination, link: resolved == url ? nil : url)
    }

    // MARK: Moving

    enum ImportError: Error, Equatable, CustomStringConvertible {
        case alreadyInStore(String)
        case failed(String, String)

        var description: String {
            switch self {
            case let .alreadyInStore(id): "\(id) is already in Quail's models folder"
            case let .failed(id, reason): "Couldn't move \(id): \(reason)"
            }
        }
    }

    /// Moves one model into the store, all or nothing. Its files first go into a staging folder in the store:
    /// renamed there when they're on the same disk, copied when they aren't. Then the staging folder takes the
    /// model's place, and only then are the originals (and any Hugging Face links to them) removed. A failure
    /// part-way puts renamed files back and leaves copied-from ones where they were.
    static func move(
        _ candidate: ImportCandidate, into store: ModelStore, progress: @Sendable (Int64) -> Void = { _ in }
    ) throws {
        let fm = FileManager.default
        try store.ensureDirectoriesExist()
        let target = candidate.format == .gguf ? store.ggufDirectory : store.mlxDirectory.appendingPathComponent(
            candidate.id, isDirectory: true
        )
        let finals = candidate.files.map { target.appendingPathComponent($0.destination) }
        if candidate.format == .gguf ? finals.contains(where: { fm.fileExists(atPath: $0.path) })
            : fm.fileExists(atPath: target.path)
        {
            throw ImportError.alreadyInStore(candidate.id)
        }
        let staging = store.partialDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var renamed: [(from: URL, to: URL)] = []
        var placed: [(staged: URL, final: URL)] = []
        var moved: Int64 = 0
        do {
            for file in candidate.files {
                let staged = staging.appendingPathComponent(file.destination)
                if sameVolume(file.source, store.rootURL) {
                    try fm.moveItem(at: file.source, to: staged)
                    renamed.append((file.source, staged))
                } else {
                    try fm.copyItem(at: file.source, to: staged)
                }
                moved += size(staged)
                progress(moved)
            }
            if candidate.format == .gguf {
                for (file, final) in zip(candidate.files, finals) {
                    let staged = staging.appendingPathComponent(file.destination)
                    try fm.moveItem(at: staged, to: final)
                    placed.append((staged, final))
                }
            } else {
                try fm.moveItem(at: staging, to: target)
            }
        } catch {
            for (staged, final) in placed.reversed() {
                try? fm.moveItem(at: final, to: staged)
            }
            for (from, to) in renamed.reversed() {
                try? fm.moveItem(at: to, to: from)
            }
            throw ImportError.failed(candidate.id, error.localizedDescription)
        }
        // In place: the originals go.
        let renamedSources = Set(renamed.map(\.from))
        for file in candidate.files {
            if !renamedSources.contains(file.source) {
                try? fm.removeItem(at: file.source)
            }
            if let link = file.link {
                try? fm.removeItem(at: link)
            }
        }
        if candidate.format == .mlxSafetensors, candidate.source != .huggingFace,
           (try? fm.contentsOfDirectory(atPath: candidate.location.path))?.isEmpty == true
        {
            try? fm.removeItem(at: candidate.location)
        }
    }

    // MARK: Files

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func isFile(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }

    private static func size(_ url: URL) -> Int64 {
        Int64((try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let first = volume(a), let second = volume(b) else { return false }
        return first.isEqual(second)
    }
}
