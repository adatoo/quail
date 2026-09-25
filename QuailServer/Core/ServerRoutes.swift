import Foundation

/// The HTTP surface, in the shapes llama-server's router mode uses, so
/// `LlamaCppRuntime`, the benchmark, `quail chat` and every Connect snippet see
/// no difference. Step 2 has the management routes; the inference routes
/// (`/v1/chat/completions`, `/v1/messages`, …) arrive with the shared chat layer.
/// Every request passes `RequestGuard` first (ADR D-036).
struct ServerRoutes: Sendable {
    let router: ModelRouter
    let apiKey: String?
    let log: ServerLog
    let requestGuard: RequestGuard
    private let inference: InferenceRoutes

    init(
        router: ModelRouter,
        apiKey: String?,
        log: ServerLog,
        requestGuard: RequestGuard = RequestGuard(bindHost: "127.0.0.1"),
        buildLabel: String = "quail-server"
    ) {
        self.router = router
        self.apiKey = apiKey
        self.log = log
        self.requestGuard = requestGuard
        inference = InferenceRoutes(router: router, log: log, buildLabel: buildLabel)
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch requestGuard.evaluate(request) {
        case let .respond(response):
            response
        case let .proceed(origin):
            await requestGuard.decorate(route(request), origin: origin)
        }
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path
        // Open like llama-server's: a liveness probe carries no key.
        if path == "/health" {
            return request.method == "GET" ? .json(200, ["status": "ok"]) : methodNotAllowed()
        }
        if let denied = authorize(request) {
            return denied
        }

        switch path {
        case "/models", "/v1/models":
            return request.method == "GET" ? await listModels() : methodNotAllowed()
        case "/models/load":
            return request.method == "POST" ? await loadModel(request) : methodNotAllowed()
        case "/models/unload":
            return request.method == "POST" ? await unloadModel(request) : methodNotAllowed()
        default:
            if let response = await inference.handle(request) {
                return response
            }
            return .error(404, type: "not_found_error", message: "File Not Found")
        }
    }

    // MARK: Auth

    private func authorize(_ request: HTTPRequest) -> HTTPResponse? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        var presented = request.header("x-api-key")
        if presented == nil, let authorization = request.header("authorization") {
            let prefix = "bearer "
            if authorization.lowercased().hasPrefix(prefix) {
                presented = String(authorization.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let presented, Self.constantTimeEqual(presented, apiKey) {
            return nil
        }
        return .error(401, type: "authentication_error", message: "Invalid API Key")
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = a.count ^ b.count
        for index in 0 ..< max(a.count, b.count) {
            difference |= Int(index < a.count ? a[index] : 0) ^ Int(index < b.count ? b[index] : 0)
        }
        return difference == 0
    }

    // MARK: Models

    private func listModels() async -> HTTPResponse {
        let models = await router.snapshots().map(ModelJSON.init)
        return .json(200, ModelListJSON(data: models))
    }

    private func loadModel(_ request: HTTPRequest) async -> HTTPResponse {
        guard let id = Self.modelID(in: request) else { return missingModel() }
        do {
            try await router.load(id) // queued; the status reads `loading` until it's ready
            return .json(200, ["success": true])
        } catch {
            return routerError(error)
        }
    }

    private func unloadModel(_ request: HTTPRequest) async -> HTTPResponse {
        guard let id = Self.modelID(in: request) else { return missingModel() }
        do {
            try await router.unload(id)
            return .json(200, ["success": true])
        } catch {
            return routerError(error)
        }
    }

    private static func modelID(in request: HTTPRequest) -> String? {
        struct Body: Decodable { let model: String }
        return (try? JSONDecoder().decode(Body.self, from: request.body))?.model
    }

    private func missingModel() -> HTTPResponse {
        .error(400, type: "invalid_request_error", message: "the request body needs a \"model\" field")
    }

    private func routerError(_ error: any Error) -> HTTPResponse {
        switch error as? RouterError {
        case .unknownModel:
            .error(404, type: "not_found_error", message: error.localizedDescription)
        case .shuttingDown:
            .error(503, type: "unavailable_error", message: error.localizedDescription)
        case .loadFailed, nil:
            .error(500, type: "server_error", message: error.localizedDescription)
        }
    }

    private func methodNotAllowed() -> HTTPResponse {
        .error(405, type: "invalid_request_error", message: "Method Not Allowed")
    }
}

// MARK: JSON shapes

private struct ModelListJSON: Encodable {
    let object = "list"
    let data: [ModelJSON]
}

private struct ModelJSON: Encodable {
    struct Status: Encodable {
        let value: String
        let failed: Bool?
        let exitCode: Int?

        enum CodingKeys: String, CodingKey {
            case value
            case failed
            case exitCode = "exit_code"
        }
    }

    struct Architecture: Encodable {
        let inputModalities: [String]
        let outputModalities = ["text"]

        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
            case outputModalities = "output_modalities"
        }
    }

    let id: String
    let aliases: [String] = []
    let tags: [String] = []
    let object = "model"
    let ownedBy = "quail"
    let created: Int
    let status: Status
    let architecture: Architecture
    let source: String
    let canRemove = false

    enum CodingKeys: String, CodingKey {
        case id, aliases, tags, object
        case ownedBy = "owned_by"
        case created, status, architecture, source
        case canRemove = "can_remove"
    }

    init(_ snapshot: ModelSnapshot) {
        id = snapshot.entry.id
        created = Int(snapshot.entry.createdAt.timeIntervalSince1970)
        source = snapshot.entry.kind == .gguf ? "models_dir" : "mlx_dir"
        architecture = Architecture(inputModalities: snapshot.entry.projector == nil ? ["text"] : ["text", "image"])
        // llama-server reports a failed load as "unloaded" plus `failed`, which
        // is what `ServedModel` decodes.
        switch snapshot.state {
        case .unloaded: status = Status(value: "unloaded", failed: nil, exitCode: nil)
        case .loading: status = Status(value: "loading", failed: nil, exitCode: nil)
        case .loaded: status = Status(value: "loaded", failed: nil, exitCode: nil)
        case .failed: status = Status(value: "unloaded", failed: true, exitCode: 1)
        }
    }
}
