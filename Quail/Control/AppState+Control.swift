import Foundation

/// The `quail` CLI's requests, answered by the app — which owns the server,
/// the store and the settings (ADR D-003). See `ControlProtocol.swift`.
extension AppState {
    func handleControl(_ request: ControlRequest) async -> ControlResponse {
        switch request.command {
        case .status:
            return ControlResponse(ok: true, status: statusInfo)
        case .start:
            guard hasServableModel else {
                return .failure("No model installed — add one in Quail → Settings → Models.")
            }
            if canStart {
                await start()
            }
            return phaseResponse()
        case .stop:
            if canStop {
                await stop()
            }
            return ControlResponse(ok: true, status: statusInfo)
        case .restart:
            await restart()
            return phaseResponse()
        case .list:
            return await ControlResponse(ok: true, models: modelInfos())
        case .ps:
            await refreshServedModels()
            let loaded = await modelInfos().filter { ["loaded", "loading"].contains($0.status ?? "") }
            return ControlResponse(ok: true, models: loaded)
        case .endpoint:
            return ControlResponse(ok: true, endpoint: endpointInfo)
        case .launch:
            return launchResponse(tool: request.tool ?? "", model: request.model)
        case .logs:
            let lines = await logStore.recentLines.suffix(request.lines ?? 50).map { line in
                "\(line.timestamp.formatted(date: .omitted, time: .standard))  \(line.text)"
            }
            return ControlResponse(ok: true, logLines: Array(lines))
        case .bench:
            guard let model = request.model ?? config.defaultModelID else {
                return .failure("No model given and no default set. See `quail list`.")
            }
            do {
                return try await ControlResponse(ok: true, benchmark: runBenchmark(model: model))
            } catch {
                return .failure((error as? BenchmarkError)?.description ?? error.localizedDescription)
            }
        case .benchProgress:
            return ControlResponse(ok: true, benchProgress: BenchProgress(
                running: benchmarks.isRunning,
                model: benchmarks.runningModel,
                step: benchmarks.step,
                fraction: benchmarks.fraction
            ))
        case .benchHistory:
            return ControlResponse(ok: true, benchmarks: benchmarks.results)
        case .service:
            if let enabled = request.enabled {
                setOpenAtLogin(enabled)
                setAutoStartServer(enabled)
            }
            return ControlResponse(
                ok: true,
                service: ServiceInfo(openAtLogin: config.openAtLogin, autoStartServer: config.autoStartServer)
            )
        }
    }

    private func phaseResponse() -> ControlResponse {
        if case let .failed(reason) = serverController.phase {
            return ControlResponse(ok: false, error: "The server failed to start: \(reason)", status: statusInfo)
        }
        return ControlResponse(ok: true, status: statusInfo)
    }

    var statusInfo: StatusInfo {
        let phase = switch serverController.phase {
        case .stopped: "stopped"
        case .starting: "starting"
        case .ready: "ready"
        case .stopping: "stopping"
        case .failed: "failed"
        }
        var failure: String?
        if case let .failed(reason) = serverController.phase {
            failure = reason
        }
        return StatusInfo(
            phase: phase,
            label: statusLabel,
            detail: modelStatusLine,
            baseURL: serverController.phase == .ready ? localBaseURL?.absoluteString : nil,
            defaultModel: config.defaultModelID,
            modelsChangedSinceStart: modelsChangedSinceStart,
            failure: failure
        )
    }

    /// Where a client on this Mac reaches the endpoint: the launched
    /// address while running, else the configured one.
    var localBaseURL: URL? {
        if let launched = serverController.baseURL, let host = launched.host(), let port = launched.port {
            return EndpointAddress.localBase(host: host, port: port)
        }
        return EndpointAddress.localBase(host: config.host, port: config.port)
    }

    var endpointInfo: EndpointInfo {
        let running = serverController.phase == .ready
        return EndpointInfo(
            baseURL: localBaseURL?.absoluteString ?? "http://127.0.0.1:\(config.port)",
            // What the running server was launched with; else what Start will use.
            apiKey: running ? serverController.apiKey : (config.apiKeyEnabled ? apiKey : nil),
            defaultModel: config.defaultModelID,
            running: running
        )
    }

    func modelInfos() async -> [ModelInfo] {
        await reconcileStore()
        let store = modelStore
        let device = DeviceInfo.current()
        let runtime = config.runtimeID
        let bandwidth = ChipBandwidthTable.loadFromBundle()
        let entries = store.loadCatalog().entries
        let fits: [String: FitVerdict] = await Task.detached(priority: .utility) {
            var result: [String: FitVerdict] = [:]
            for entry in entries {
                if let verdict = ModelPreview.installed(
                    entry: entry, store: store, device: device, ggufRuntime: runtime, bandwidthTable: bandwidth
                )?.verdict {
                    result[entry.id] = verdict
                }
            }
            return result
        }.value
        let statuses = Dictionary(
            servedModels.map { ($0.id, $0.status.value) },
            uniquingKeysWith: { first, _ in first }
        )
        return entries.map { entry in
            ModelInfo(
                id: entry.id,
                format: entry.format == .gguf ? "GGUF" : "MLX",
                bytes: entry.bytes,
                context: entry.effectiveContextSize,
                contextIsAutomatic: entry.userContextSize == nil,
                fit: fits[entry.id].map(Self.fitLabel),
                isDefault: entry.id == config.defaultModelID,
                status: statuses[entry.id]
            )
        }
    }

    private static func fitLabel(_ verdict: FitVerdict) -> String {
        switch verdict {
        case .comfortable: "Comfortable"
        case .tight: "Tight"
        case .wontFit: "Won't fit"
        }
    }

    /// A tool's launch recipe from `integrations.json`, filled in with this
    /// endpoint's address, key and model — plus warnings (context too small,
    /// model not yet known to the running server).
    func launchResponse(tool: String, model requested: String?) -> ControlResponse {
        let integrations = Integration.bundled().filter { $0.launch != nil }
        let key = tool.lowercased()
        guard let integration = integrations.first(where: { $0.id == key || ($0.launch?.aliases ?? []).contains(key) }),
              let recipe = integration.launch
        else {
            let names = integrations.map { $0.launch?.aliases?.first ?? $0.id }.joined(separator: ", ")
            return .failure("Unknown tool '\(tool)'. quail launch supports: \(names).")
        }
        let installed = modelStore.loadCatalog().entries
        guard let model = requested ?? config.defaultModelID ?? installed.first?.id else {
            return .failure("No model installed — add one in Quail → Settings → Models.")
        }
        guard let entry = installed.first(where: { $0.id == model }) else {
            return .failure("No installed model named '\(model)'. See `quail list`.")
        }
        guard let base = localBaseURL else { return .failure("Couldn't work out the endpoint address.") }

        let values = SnippetRenderer.Values(
            baseURL: base,
            apiKey: endpointInfo.apiKey,
            model: model
        )
        func fill(_ text: String) -> String {
            SnippetRenderer.render(text, with: values)
        }
        var warnings: [String] = []
        if let needed = integration.minContext, entry.effectiveContextSize < needed {
            warnings.append(
                "\(integration.name) needs at least \(needed / 1024)K of context; \(model) runs at \(entry.effectiveContextSize / 1024)K. Raise it in Quail → Settings → Models (the ctx menu), then `quail restart`."
            )
        }
        if serverController.phase == .ready, !servedModels.contains(where: { $0.id == model }) {
            warnings.append("\(model) was added after the server started — run `quail restart` first.")
        }
        return ControlResponse(ok: true, launch: ToolLaunch(
            command: recipe.command,
            args: recipe.args.map(fill),
            env: recipe.env.mapValues(fill),
            files: (recipe.files ?? [:]).mapValues(fill),
            warnings: warnings
        ))
    }
}
