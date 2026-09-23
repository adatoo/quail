import Foundation

/// A fit verdict for a not-yet-downloaded model, or why there isn't one.
/// Found by live testing: most Add-model rows showed nothing at all
/// (never looked up, or the lookup failed silently) — which reads as
/// "broken", not "unknown". Every row now shows one of these.
enum RemoteFit: Sendable, Equatable {
    case checking
    case estimate(FitEstimate)
    /// A short, user-facing reason ("Gated — add a Hugging Face token").
    case unknown(String)
}

/// Fit verdicts for the Models pane, in two flavours: models already on
/// disk (cheap — `GGUFMetadata` memory-maps, and the real 639 MB case is
/// measured at ~85 ms in the manual smoke suite) and models *not*
/// downloaded yet, which per docs/ARCHITECTURE.md §7 must still show a
/// verdict in the picker — the shape comes from a single ranged
/// `fetchHeader` of the file's first bytes (the metadata needed by the
/// formula all precedes the tensor section; the size comes from the
/// listing).
enum ModelPreview {
    /// The GGUF half of `remote`, with reasons instead of `nil`/throws.
    /// `files` are the pick's main GGUF files (all shards; an mmproj
    /// companion is ignored) — weights are their *total*, not the first
    /// shard's, so a split model isn't underestimated.
    static func remoteGGUFFit(
        repo: String,
        files: [HFFile],
        downloader: HFDownloader,
        device: DeviceInfo,
        ggufRuntime: RuntimeID,
        bandwidthTable: [String: Double],
        token: String?
    ) async -> RemoteFit {
        let weights = files.filter { ModelAddPlan.isMainGGUF($0.localFilename) }
        guard let first = weights.first else { return .unknown("No matching GGUF file in the repo") }
        // 8 MiB first (what `fetchHeader` defaults to); only if the
        // model's shape keys genuinely sit beyond that, one 32 MiB retry.
        var metadata: GGUFMetadata?
        for budget in [8, 32].map({ $0 * 1024 * 1024 }) {
            let header: Data
            do {
                header = try await downloader.fetchHeader(repo: repo, file: first, maxBytes: budget, token: token)
            } catch HFDownloadError.gatedRepoRequiresToken {
                return .unknown("Gated repo — add a Hugging Face token in Models")
            } catch {
                return .unknown("Couldn't reach Hugging Face")
            }
            do {
                metadata = try GGUFMetadata.parsePrefix(header)
                break
            } catch GGUFMetadata.GGUFReadError.truncated {
                continue
            } catch {
                return .unknown("Unreadable GGUF header")
            }
        }
        guard let metadata else { return .unknown("Model header too large to preview") }
        let weightBytes = weights.reduce(0) { $0 + $1.sizeBytes }
        guard let shape = ModelShape.from(gguf: metadata, weightBytes: weightBytes) else {
            return .unknown("Can't estimate \(metadata.architecture ?? "this") architecture yet")
        }
        guard let estimate = FitEstimator.estimate(
            model: shape, device: device, runtime: ggufRuntime, bandwidthTable: bandwidthTable
        ) else {
            return .unknown("Couldn't read this Mac's GPU memory")
        }
        return .estimate(estimate)
    }

    /// The Add-model list's per-family verdict: the catalog's default
    /// quant of the family's GGUF repo.
    static func catalogFit(
        family: Catalog.Family,
        downloader: HFDownloader,
        device: DeviceInfo,
        ggufRuntime: RuntimeID,
        bandwidthTable: [String: Double],
        token: String?
    ) async -> RemoteFit {
        guard let gguf = family.gguf else { return .unknown("MLX only — not servable until MLX support lands") }
        let listing: HFRepo
        do {
            listing = try await downloader.listFiles(repo: gguf.repo, token: token)
        } catch HFDownloadError.gatedRepoRequiresToken {
            return .unknown("Gated repo — add a Hugging Face token in Models")
        } catch HFDownloadError.httpStatus(404) {
            return .unknown("Repo not found on Hugging Face")
        } catch {
            return .unknown("Couldn't reach Hugging Face")
        }
        guard let quant = gguf.defaultQuant ?? gguf.quants.first else {
            return .unknown("No quant listed in the catalog")
        }
        let files = ModelAddPlan.ggufFiles(for: listing, quant: quant, mmproj: nil)
        guard !files.isEmpty else { return .unknown("No \(quant) file in the repo") }
        return await remoteGGUFFit(
            repo: gguf.repo, files: files, downloader: downloader, device: device,
            ggufRuntime: ggufRuntime, bandwidthTable: bandwidthTable, token: token
        )
    }

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
            guard let metadata = try? GGUFMetadata.parsePrefix(header),
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
