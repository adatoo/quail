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

    /// No internet connection (ADR D-051): `AppState.loadCatalogVerdicts` stops asking once it sees
    /// this, and the Add Model sheet says it's offline.
    static let offline = RemoteFit.unknown("Offline — can't reach Hugging Face")
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
        token: String?,
        cache: ModelShapeCache = .shared
    ) async -> RemoteFit {
        let weights = files.filter { ModelAddPlan.isMainGGUF($0.localFilename) }
        guard let first = weights.first else { return .unknown("No matching GGUF file in the repo") }
        let key = ModelShapeCache.key(repo: repo, format: .gguf, file: first.remotePath)
        if let shape = cache.shape(for: key) {
            return estimateFit(shape, device: device, runtime: ggufRuntime, bandwidthTable: bandwidthTable)
        }
        // 8 MiB first (what `fetchHeader` defaults to); only if the
        // model's shape keys genuinely sit beyond that, one 32 MiB retry.
        var metadata: GGUFMetadata?
        for budget in [8, 32].map({ $0 * 1024 * 1024 }) {
            let header: Data
            do {
                header = try await downloader.fetchHeader(repo: repo, file: first, maxBytes: budget, token: token)
            } catch HFDownloadError.gatedRepoRequiresToken {
                return .unknown("Gated repo — add a Hugging Face token in Models")
            } catch HFDownloadError.offline {
                return .offline
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
        cache.store(shape, for: key)
        return estimateFit(shape, device: device, runtime: ggufRuntime, bandwidthTable: bandwidthTable)
    }

    private static func estimateFit(
        _ shape: ModelShape, device: DeviceInfo, runtime: RuntimeID, bandwidthTable: [String: Double]
    ) -> RemoteFit {
        guard let estimate = FitEstimator.estimate(
            model: shape, device: device, runtime: runtime, bandwidthTable: bandwidthTable
        ) else {
            return .unknown("Couldn't read this Mac's GPU memory")
        }
        return .estimate(estimate)
    }

    /// The MLX counterpart: the shape from the repo's `config.json`, the weights from the whole listing.
    static func remoteMLXFit(
        repo: String,
        listing: HFRepo,
        downloader: HFDownloader,
        device: DeviceInfo,
        bandwidthTable: [String: Double],
        token: String?,
        cache: ModelShapeCache = .shared
    ) async -> RemoteFit {
        let key = ModelShapeCache.key(repo: repo, format: .mlxSafetensors)
        if let shape = cache.shape(for: key) {
            return estimateFit(shape, device: device, runtime: .omlx, bandwidthTable: bandwidthTable)
        }
        guard let configFile = listing.files.first(where: { $0.localFilename == "config.json" }) else {
            return .unknown("The repo has no config.json")
        }
        let header: Data
        do {
            header = try await downloader.fetchHeader(repo: repo, file: configFile, token: token)
        } catch HFDownloadError.gatedRepoRequiresToken {
            return .unknown("Gated repo — add a Hugging Face token in Models")
        } catch HFDownloadError.offline {
            return .offline
        } catch {
            return .unknown("Couldn't reach Hugging Face")
        }
        guard let metadata = try? MLXMetadata.parse(header)
        else { return .unknown("Couldn't read this model's config.json") }
        guard let shape = ModelShape.from(mlx: metadata, weightBytes: listing.files.reduce(0) { $0 + $1.sizeBytes })
        else {
            return .unknown("Can't estimate \(metadata.modelType ?? "this") architecture yet")
        }
        cache.store(shape, for: key)
        return estimateFit(shape, device: device, runtime: .omlx, bandwidthTable: bandwidthTable)
    }

    /// `catalogFit` from the shape cache alone — no network — or `nil` when the family hasn't been
    /// looked up before. What the Add Model list shows for the rest once it knows it's offline.
    static func cachedCatalogFit(
        family: Catalog.Family,
        device: DeviceInfo,
        ggufRuntime: RuntimeID,
        bandwidthTable: [String: Double],
        cache: ModelShapeCache = .shared
    ) -> RemoteFit? {
        if let gguf = family.gguf {
            guard let quant = gguf.defaultQuant ?? gguf.quants.first,
                  let shape = cache.shape(for: catalogKey(repo: gguf.repo, quant: quant))
            else { return nil }
            return estimateFit(shape, device: device, runtime: ggufRuntime, bandwidthTable: bandwidthTable)
        }
        guard let mlx = family.mlx,
              let shape = cache.shape(for: ModelShapeCache.key(repo: mlx.repo, format: .mlxSafetensors))
        else { return nil }
        return estimateFit(shape, device: device, runtime: .omlx, bandwidthTable: bandwidthTable)
    }

    /// The Add-model list's per-family verdict: the catalog's default
    /// quant of the family's GGUF repo.
    static func catalogFit(
        family: Catalog.Family,
        downloader: HFDownloader,
        device: DeviceInfo,
        ggufRuntime: RuntimeID,
        bandwidthTable: [String: Double],
        token: String?,
        cache: ModelShapeCache = .shared
    ) async -> RemoteFit {
        guard let gguf = family.gguf else {
            guard let mlx = family.mlx else { return .unknown("No downloadable variant in the catalog") }
            if let shape = cache.shape(for: ModelShapeCache.key(repo: mlx.repo, format: .mlxSafetensors)) {
                return estimateFit(shape, device: device, runtime: .omlx, bandwidthTable: bandwidthTable)
            }
            do {
                let listing = try await downloader.listFiles(repo: mlx.repo, token: token)
                return await remoteMLXFit(
                    repo: mlx.repo, listing: listing, downloader: downloader, device: device,
                    bandwidthTable: bandwidthTable, token: token, cache: cache
                )
            } catch HFDownloadError.offline {
                return .offline
            } catch {
                return .unknown("Couldn't reach Hugging Face")
            }
        }
        // A family already looked up needs no listing either: its default quant's shape is cached.
        if let quant = gguf.defaultQuant ?? gguf.quants.first,
           let shape = cache.shape(for: catalogKey(repo: gguf.repo, quant: quant))
        {
            return estimateFit(shape, device: device, runtime: ggufRuntime, bandwidthTable: bandwidthTable)
        }
        let listing: HFRepo
        do {
            listing = try await downloader.listFiles(repo: gguf.repo, token: token)
        } catch HFDownloadError.gatedRepoRequiresToken {
            return .unknown("Gated repo — add a Hugging Face token in Models")
        } catch HFDownloadError.httpStatus(404) {
            return .unknown("Repo not found on Hugging Face")
        } catch HFDownloadError.offline {
            return .offline
        } catch {
            return .unknown("Couldn't reach Hugging Face")
        }
        guard let quant = gguf.defaultQuant ?? gguf.quants.first else {
            return .unknown("No quant listed in the catalog")
        }
        let files = ModelAddPlan.ggufFiles(for: listing, quant: quant, mmproj: nil)
        guard !files.isEmpty else { return .unknown("No \(quant) file in the repo") }
        let fit = await remoteGGUFFit(
            repo: gguf.repo, files: files, downloader: downloader, device: device,
            ggufRuntime: ggufRuntime, bandwidthTable: bandwidthTable, token: token, cache: cache
        )
        // Also under the family's quant, so the next lookup skips the listing too.
        if let first = files.first(where: { ModelAddPlan.isMainGGUF($0.localFilename) }),
           let shape = cache.shape(for: ModelShapeCache.key(repo: gguf.repo, format: .gguf, file: first.remotePath))
        {
            cache.store(shape, for: catalogKey(repo: gguf.repo, quant: quant))
        }
        return fit
    }

    private static func catalogKey(repo: String, quant: String) -> String {
        ModelShapeCache.key(repo: repo, format: .gguf, file: "quant:" + quant)
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
        guard let shape = installedShape(entry: entry, store: store) else { return nil }
        return FitEstimator.estimate(
            model: shape,
            device: device,
            runtime: entry.format == .gguf ? ggufRuntime : .omlx,
            // At the context the model will actually run at (ADR D-020),
            // not a fixed default.
            requestedContextSize: entry.effectiveContextSize,
            bandwidthTable: bandwidthTable
        )
    }

    /// An installed model's shape, read from its header / config.json.
    static func installedShape(entry: InstalledModel, store: ModelStore) -> ModelShape? {
        switch entry.format {
        case .gguf:
            let url = store.ggufDirectory.appendingPathComponent("\(entry.id).gguf")
            return (try? GGUFMetadata.read(from: url)).flatMap { ModelShape.from(gguf: $0, weightBytes: entry.bytes) }
        case .mlxSafetensors:
            let configURL = store.mlxDirectory
                .appendingPathComponent(entry.id, isDirectory: true)
                .appendingPathComponent("config.json")
            return (try? MLXMetadata.read(from: configURL))
                .flatMap { ModelShape.from(mlx: $0, weightBytes: entry.bytes) }
        }
    }

    /// The context picker's options for an installed model, each with its
    /// verdict on this Mac.
    static func contextChoices(
        entry: InstalledModel,
        store: ModelStore,
        device: DeviceInfo,
        ggufRuntime: RuntimeID
    ) -> [(tokens: Int, verdict: FitVerdict?)] {
        let shape = installedShape(entry: entry, store: store)
        return FitEstimator.contextOptions(trainedContext: entry.trainedContext ?? shape?.trainedContext)
            .map { tokens in
                var verdict = shape.flatMap {
                    FitEstimator.estimate(
                        model: $0, device: device, runtime: entry.format == .gguf ? ggufRuntime : .omlx,
                        requestedContextSize: tokens
                    )?.verdict
                }
                // `.tight(n)` means "fits under the full ceiling only up to n
                // tokens" — an option above n doesn't fit at its own size.
                if case let .tight(reduced)? = verdict, reduced < tokens {
                    verdict = .wontFit
                }
                return (tokens, verdict)
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
