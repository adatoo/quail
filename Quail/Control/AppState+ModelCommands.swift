import Foundation

/// CLI v2's model commands (docs/IMPLEMENTATION_PLAN.md Phase 2b step 5):
/// `pull`, `rm`, `default`, `ctx` and `config` — each the same action the
/// Settings UI takes, so the two can't disagree.
extension AppState {
    // MARK: - Resolving names

    /// An installed model by exact id, then case-insensitive id, then a
    /// unique case-insensitive prefix (`quail rm qwen3-0.6b`).
    func installedEntry(named name: String) -> Result<InstalledModel, ControlError> {
        let entries = modelStore.loadCatalog().entries
        if let exact = entries.first(where: { $0.id == name }) {
            return .success(exact)
        }
        if let loose = entries.first(where: { $0.id.caseInsensitiveCompare(name) == .orderedSame }) {
            return .success(loose)
        }
        let matches = entries.filter { $0.id.lowercased().hasPrefix(name.lowercased()) }
        switch matches.count {
        case 1: return .success(matches[0])
        case 0: return .failure(ControlError("No installed model named '\(name)'. See `quail list`."))
        default:
            return .failure(ControlError(
                "'\(name)' matches \(matches.map(\.id).joined(separator: ", ")) — be more specific."
            ))
        }
    }

    // MARK: - pull

    func pullModel(_ raw: String) async -> ControlResponse {
        guard !installs.isDownloading else {
            return .failure(
                "A download is already running — see `quail pull` progress, or cancel it in Settings → Models."
            )
        }
        let spec: PullSpec
        do {
            spec = try PullSpec.parse(raw, catalog: catalog)
        } catch {
            return .failure(String(describing: error))
        }

        let listing: HFRepo
        do {
            listing = try await installs.downloader.listFiles(repo: spec.repo, token: hfToken)
        } catch let error as HFDownloadError {
            return .failure("\(spec.repo): \(ModelInstallController.describe(error))")
        } catch {
            return .failure("\(spec.repo): \(error)")
        }
        guard spec.family != nil || ModelAddPlan.format(guessing: listing) == .gguf else {
            return .failure("\(spec.repo) has no GGUF files — Quail can only serve GGUF models so far.")
        }

        let mmproj = spec.family?.gguf?.mmproj
        let labels = spec.family?.gguf?.quants ?? ModelAddPlan.quants(in: listing)
        let available = labels.filter { !ModelAddPlan.ggufFiles(for: listing, quant: $0, mmproj: mmproj).isEmpty }
        guard let quant = PullSpec.chooseQuant(
            requested: spec.quant, available: available, familyDefault: spec.family?.gguf?.defaultQuant
        ) else {
            return .failure(spec.quant.map {
                "\(spec.repo) has no \($0) file. Available: \(available.joined(separator: ", "))."
            } ?? "\(spec.repo) has no GGUF files Quail can use.")
        }

        let installed = modelStore.loadCatalog().entries
        let existing = spec.family.flatMap {
            InstalledLookup.entry(for: $0, format: .gguf, quant: quant, in: installed)
        } ?? InstalledLookup.entry(forRepo: spec.repo, format: .gguf, quant: quant, in: installed)
        if let existing {
            return ControlResponse(ok: true, message: "\(existing.id) is already installed.")
        }

        let files = ModelAddPlan.ggufFiles(for: listing, quant: quant, mmproj: mmproj)
        if spec.family == nil {
            addUserCatalogRepo(spec.repo, format: .gguf)
        }
        guard let task = installs.install(
            repo: spec.repo, files: files, format: .gguf, quant: quant, family: spec.family?.id
        ) else {
            return .failure("Couldn't start the download.")
        }
        await task.value

        switch installs.phase {
        case let .installed(id):
            installs.acknowledgeFinished()
            var message = "Installed \(id)."
            if serverController.phase == .ready {
                message += " `quail restart` to serve it."
            }
            return ControlResponse(ok: true, message: message)
        case let .failed(reason):
            installs.acknowledgeFinished()
            return .failure(reason)
        default:
            return .failure("Download cancelled — run the same command again to resume.")
        }
    }

    var pullProgressInfo: PullProgress {
        if case let .downloading(written, total, file) = installs.phase {
            return PullProgress(
                running: true, repo: installs.target?.repo, quant: installs.target?.quant,
                bytesWritten: written, totalBytes: total, currentFile: file
            )
        }
        return PullProgress(running: false, bytesWritten: 0, totalBytes: 0)
    }

    func catalogInfo() -> [CatalogEntryInfo] {
        let recommended = Set(Recommender.candidates(catalog: catalog, device: DeviceInfo.current()).prefix(5)
            .map(\.id))
        let installed = modelStore.loadCatalog().entries
        return catalog.families.filter { $0.gguf != nil }.map { family in
            let quants = family.gguf?.quants ?? []
            return CatalogEntryInfo(
                id: family.id,
                name: family.name,
                paramsB: family.paramsB,
                role: family.role,
                ggufRepo: family.gguf?.repo,
                quants: quants,
                defaultQuant: family.gguf?.defaultQuant,
                recommended: recommended.contains(family.id),
                installed: quants.filter {
                    InstalledLookup.entry(for: family, format: .gguf, quant: $0, in: installed) != nil
                }
            )
        }
    }

    // MARK: - rm, default, ctx

    func removeModel(_ name: String) async -> ControlResponse {
        switch installedEntry(named: name) {
        case let .failure(error):
            return .failure(error.message)
        case let .success(entry):
            do {
                try await deleteInstalledModel(id: entry.id)
                return ControlResponse(ok: true, message: "Deleted \(entry.id).")
            } catch {
                return .failure("Couldn't delete \(entry.id): \(error)")
            }
        }
    }

    func defaultModelCommand(name: String?, clear: Bool) -> ControlResponse {
        if clear {
            setDefaultModel(nil)
            return ControlResponse(ok: true, message: "No default model — models load on first request.")
        }
        guard let name else {
            return ControlResponse(
                ok: true,
                message: config.defaultModelID.map { "Default model: \($0)" }
                    ?? "No default model."
            )
        }
        switch installedEntry(named: name) {
        case let .failure(error):
            return .failure(error.message)
        case let .success(entry):
            guard entry.format == .gguf else {
                return .failure("\(entry.id) is an MLX model — only GGUF models can be the default so far.")
            }
            setDefaultModel(entry.id)
            var message = "Default model: \(entry.id) — loads on Start."
            if serverController.phase == .ready {
                message += " `quail restart` to apply."
            }
            return ControlResponse(ok: true, message: message)
        }
    }

    func contextCommand(name: String, tokens: Int?, automatic: Bool) async -> ControlResponse {
        let entry: InstalledModel
        switch installedEntry(named: name) {
        case let .failure(error): return .failure(error.message)
        case let .success(found): entry = found
        }
        let store = modelStore
        let runtime = config.runtimeID
        let choices = await Task.detached(priority: .userInitiated) {
            ModelPreview.contextChoices(entry: entry, store: store, device: DeviceInfo.current(), ggufRuntime: runtime)
        }.value

        if !automatic, tokens == nil {
            return ControlResponse(ok: true, contextOptions: ContextOptionsInfo(
                model: entry.id,
                current: entry.effectiveContextSize,
                isAutomatic: entry.userContextSize == nil,
                automatic: entry.contextSize,
                options: choices.map { .init(tokens: $0.tokens, fit: $0.verdict.map(Self.contextFitLabel)) }
            ))
        }
        if let tokens {
            guard let choice = choices.first(where: { $0.tokens == tokens }) else {
                let sizes = choices.map { RemoteFitBadge.contextLabel($0.tokens) }.joined(separator: ", ")
                return .failure("\(entry.id) can run at: \(sizes), or auto.")
            }
            if choice.verdict == .wontFit {
                return .failure("\(RemoteFitBadge.contextLabel(tokens)) won't fit on this Mac for \(entry.id).")
            }
        }
        await setContextSize(automatic ? nil : tokens, forModel: entry.id)
        let updated = modelStore.loadCatalog().entries.first { $0.id == entry.id }
        let size = RemoteFitBadge.contextLabel(updated?.effectiveContextSize ?? tokens ?? 0)
        var message = "\(entry.id): \(automatic ? "Automatic (\(size))" : size) context."
        if serverController.phase == .ready {
            message += " `quail restart` to apply."
        }
        return ControlResponse(ok: true, message: message)
    }

    private static func runtimeName(_ id: RuntimeID) -> String {
        switch id {
        case .llamaCpp: "llama.cpp"
        case .omlx: "oMLX"
        case .rapidMLX: "Rapid-MLX"
        }
    }

    private static func contextFitLabel(_ verdict: FitVerdict) -> String {
        switch verdict {
        case .comfortable: "Comfortable"
        case .tight: "Tight"
        case .wontFit: "Won't fit"
        }
    }

    // MARK: - config

    var configInfo: ConfigInfo {
        ConfigInfo(
            version: AppInfo.version,
            runtime: Self.runtimeName(config.runtimeID),
            host: config.host,
            port: config.port,
            baseURL: endpointInfo.baseURL,
            apiKeyEnabled: config.apiKeyEnabled,
            apiKey: endpointInfo.apiKey,
            modelsMax: config.modelsMax,
            defaultModel: config.defaultModelID,
            modelsDirectory: modelStore.rootURL.path,
            logFile: Paths.logFile(for: config.runtimeID).path,
            configFile: Paths.configFile.path,
            openAtLogin: config.openAtLogin,
            autoStartServer: config.autoStartServer,
            running: serverController.phase == .ready
        )
    }
}

struct ControlError: Error, Equatable {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
