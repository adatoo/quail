import Foundation

/// Adapter for the bundled `llama-server` binary running in router mode.
///
/// Router mode (launched with no model argument, just `--models-dir`) scans
/// a folder of GGUF files and loads/unloads them on demand behind one HTTP
/// endpoint — see docs/ARCHITECTURE.md §4 and D-004. Confirmed against a
/// real b11081 build: `GET /health`, `GET /models`, `POST /models/load`
/// all behave as documented. See D-009 for what killing it involves.
struct LlamaCppRuntime: Runtime {
    let executableURL: URL
    private let urlSession: URLSession
    /// Where llama-server writes its log; `nil` is the real one
    /// (`Paths.logFile`). Tests that launch a real server pass their own,
    /// so they never write into (or truncate) the user's log.
    private let logFile: URL?

    init(executableURL: URL, urlSession: URLSession = .shared, logFile: URL? = nil) {
        self.executableURL = executableURL
        self.urlSession = urlSession
        self.logFile = logFile
    }

    var id: RuntimeID {
        .llamaCpp
    }

    var supportedFormats: Set<ModelFormat> {
        [.gguf]
    }

    /// llama-server is vendored into the app bundle, not installed by uv —
    /// it's always present once the app itself is.
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
        if let apiKey = config.apiKey, !apiKey.isEmpty {
            args += ["--api-key", apiKey]
        }
        if let presetsFile = config.presetsFile {
            args += ["--models-preset", presetsFile.path]
        }
        // Deliberately no --no-webui: the built-in web UI stays available
        // by default (docs/IMPLEMENTATION_PLAN.md Phase 1 step 3).
        return LaunchSpec(
            executableURL: executableURL,
            arguments: args,
            environment: [:],
            currentDirectoryURL: executableURL.deletingLastPathComponent()
        )
    }

    func health(base: URL, apiKey: String?) async throws -> Health {
        try await get(Health.self, at: base.appending(path: "health"), apiKey: apiKey)
    }

    func listModels(base: URL, apiKey: String?) async throws -> [ServedModel] {
        struct Response: Decodable { let data: [ServedModel] }
        return try await get(Response.self, at: base.appending(path: "models"), apiKey: apiKey).data
    }

    func select(model: ModelRef, base: URL, apiKey: String?) async throws -> SelectAction {
        var request = Self.authorized(URLRequest(url: base.appending(path: "models/load")), apiKey: apiKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": model.id])
        let (data, response) = try await urlSession.data(for: request)
        try Self.checkStatus(response, data: data)
        // Router mode hot-swaps via /models/load; it never needs a restart.
        return .hotSwapped
    }

    func webUIURL(base: URL) -> URL? {
        base
    }

    private func get<T: Decodable>(_: T.Type, at url: URL, apiKey: String?) async throws -> T {
        let request = Self.authorized(URLRequest(url: url), apiKey: apiKey)
        let (data, response) = try await urlSession.data(for: request)
        try Self.checkStatus(response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RuntimeError.decoding(String(describing: error))
        }
    }

    private static func authorized(_ request: URLRequest, apiKey: String?) -> URLRequest {
        var request = request
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func checkStatus(_ response: URLResponse, data _: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw RuntimeError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else { throw RuntimeError.httpStatus(http.statusCode) }
    }
}
