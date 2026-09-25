import Foundation

/// Adapter for the bundled `quail-server` (ADR D-027): the same router-mode HTTP shapes as
/// `llama-server` (`/health`, `/models`, `POST /models/load`), so it reuses that adapter's calls, and
/// it serves MLX models from the store's `mlx/` folder as well as GGUF.
struct QuailServerRuntime: Runtime {
    let executableURL: URL
    /// The HTTP side is llama-server's; `quail-server` answers the same requests (ServerCompatibilityTests).
    private let http: LlamaCppRuntime
    private let logFile: URL?

    init(executableURL: URL, urlSession: URLSession = .shared, logFile: URL? = nil) {
        self.executableURL = executableURL
        self.logFile = logFile
        http = LlamaCppRuntime(executableURL: executableURL, urlSession: urlSession, logFile: logFile)
    }

    var id: RuntimeID {
        .quail
    }

    var supportedFormats: Set<ModelFormat> {
        [.gguf, .mlxSafetensors]
    }

    var installState: InstallState {
        .bundled
    }

    func launchSpec(config: EndpointConfig, model _: ModelRef?) -> LaunchSpec {
        var args = [
            "--host", config.host,
            "--port", String(config.port),
            "--models-dir", config.modelsDirectory.path,
            "--models-max", String(config.modelsMax),
            "--log-file", (logFile ?? Paths.logFile(for: id)).path,
        ]
        if let mlxDirectory = config.mlxDirectory {
            args += ["--mlx-dir", mlxDirectory.path]
        }
        if let apiKey = config.apiKey, !apiKey.isEmpty {
            args += ["--api-key", apiKey]
        }
        if let presetsFile = config.presetsFile {
            args += ["--models-preset", presetsFile.path]
        }
        return LaunchSpec(
            executableURL: executableURL,
            arguments: args,
            environment: [:],
            currentDirectoryURL: executableURL.deletingLastPathComponent()
        )
    }

    func health(base: URL, apiKey: String?) async throws -> Health {
        try await http.health(base: base, apiKey: apiKey)
    }

    func listModels(base: URL, apiKey: String?) async throws -> [ServedModel] {
        try await http.listModels(base: base, apiKey: apiKey)
    }

    func select(model: ModelRef, base: URL, apiKey: String?) async throws -> SelectAction {
        try await http.select(model: model, base: base, apiKey: apiKey)
    }

    /// Its own chat page at `/` (ADR D-042).
    func webUIURL(base: URL) -> URL? {
        base
    }
}

extension RuntimeID {
    /// The adapter for this runtime; the deferred ones fall back to llama.cpp.
    func makeRuntime() -> any Runtime {
        switch self {
        case .quail: QuailServerRuntime(executableURL: Paths.quailServerExecutable)
        case .llamaCpp, .omlx, .rapidMLX: LlamaCppRuntime(executableURL: Paths.llamaServerExecutable)
        }
    }

    var displayName: String {
        switch self {
        case .llamaCpp: "llama.cpp"
        case .quail: "Quail server"
        case .omlx: "oMLX"
        case .rapidMLX: "Rapid-MLX"
        }
    }
}
