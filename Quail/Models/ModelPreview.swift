import Foundation

/// Fit verdicts for the Models pane, in two flavours: models already on
/// disk (cheap — `GGUFMetadata` memory-maps, and the real 639 MB case is
/// measured at ~85 ms in the manual smoke suite) and models *not*
/// downloaded yet, which per docs/ARCHITECTURE.md §7 must still show a
/// verdict in the picker — the shape comes from a single ranged
/// `fetchHeader` of the file's first bytes (the metadata needed by the
/// formula all precedes the tensor section; the size comes from the
/// listing).
enum ModelPreview {
    /// A verdict for a catalog row that's installed on disk. `nil` when
    /// the model's shape can't be read (missing/corrupt file, or a
    /// format nothing can serve yet) — the UI shows "—" rather than
    /// guessing from size alone.
    static func installed(
        entry: InstalledModel,
        store: ModelStore,
        device: DeviceInfo,
        ggufRuntime: RuntimeID,
        bandwidthTable: [String: Double]
    ) -> FitEstimate? {
        switch entry.format {
        case .gguf:
            let url = store.ggufDirectory.appendingPathComponent("\(entry.id).gguf")
            guard let metadata = try? GGUFMetadata.read(from: url),
                  let shape = ModelShape.from(gguf: metadata, weightBytes: entry.bytes)
            else { return nil }
            return FitEstimator.estimate(
                model: shape,
                device: device,
                runtime: ggufRuntime,
                bandwidthTable: bandwidthTable
            )
        case .mlxSafetensors:
            let configURL = store.mlxDirectory
                .appendingPathComponent(entry.id, isDirectory: true)
                .appendingPathComponent("config.json")
            guard let metadata = try? MLXMetadata.read(from: configURL),
                  let shape = ModelShape.from(mlx: metadata, weightBytes: entry.bytes)
            else { return nil }
            return FitEstimator.estimate(model: shape, device: device, runtime: .omlx, bandwidthTable: bandwidthTable)
        }
    }

    /// A pre-download verdict for one not-yet-installed model. `files`
    /// is the repo's whole listing (an MLX model's weight bytes are the
    /// *directory's* total — §7 — not one file's). Throws whatever
    /// `fetchHeader` throws (a gated repo without a token, transport
    /// failure); a header that outgrows the fetch budget arrives
    /// truncated and surfaces as `nil`, meaning "no shape, no verdict".
    static func remote(
        repo: String,
        format: ModelFormat,
        listing: HFRepo,
        ggufFile: HFFile?,
        downloader: HFDownloader,
        device: DeviceInfo,
        ggufRuntime: RuntimeID,
        bandwidthTable: [String: Double],
        token: String? = nil
    ) async throws -> FitEstimate? {
        switch format {
        case .gguf:
            guard let file = ggufFile else { return nil }
            let header = try await downloader.fetchHeader(repo: repo, file: file, token: token)
            guard let metadata = try? GGUFMetadata.parse(header),
                  let shape = ModelShape.from(gguf: metadata, weightBytes: file.sizeBytes)
            else { return nil }
            return FitEstimator.estimate(
                model: shape,
                device: device,
                runtime: ggufRuntime,
                bandwidthTable: bandwidthTable
            )
        case .mlxSafetensors:
            guard let configFile = listing.files.first(where: { $0.localFilename == "config.json" }) else {
                return nil
            }
            let header = try await downloader.fetchHeader(repo: repo, file: configFile, token: token)
            guard let metadata = try? MLXMetadata.parse(header),
                  let shape = ModelShape.from(mlx: metadata, weightBytes: listing.files.reduce(0) { $0 + $1.sizeBytes })
            else { return nil }
            return FitEstimator.estimate(model: shape, device: device, runtime: .omlx, bandwidthTable: bandwidthTable)
        }
    }
}
