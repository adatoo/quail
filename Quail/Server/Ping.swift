import Foundation

/// Where one row of the Ping sheet is (docs/IMPLEMENTATION_PLAN.md Phase 1
/// step 8): not started, in flight, done with a timing, or failed with a
/// message. A later step never runs if an earlier one fails — `PingRunner`
/// stops the chain rather than reporting misleading downstream failures.
enum PingStepState: Sendable, Equatable {
    case pending
    case running
    case succeeded(TimeInterval)
    case failed(String)
}

/// Drives the three Ping sheet rows against a real runtime: server up
/// (`/health`), model loaded (`/models` non-empty — docs/IMPLEMENTATION_PLAN.md
/// Phase 1 step 8's own wording; deliberately *not* filtered to
/// `status == "loaded"`, since router mode lists a model as `"unloaded"`
/// until the first request auto-loads it, confirmed against a real
/// b11081 build — requiring `"loaded"` here would fail this step for
/// every model that's never been used yet, which is the common case for
/// someone who just dropped a GGUF in and clicked Test), first token (a
/// real streamed `/v1/chat/completions` with `max_tokens: 1`, timing to
/// the first SSE chunk — this is what actually triggers that auto-load).
/// No chat — this never surfaces the token's content, only whether and how
/// fast one arrived.
///
/// The completions call is deliberately not part of the `Runtime` protocol:
/// every runtime Quail supports is meant to expose an OpenAI-compatible
/// `/v1/chat/completions`, so this talks to it directly with `URLSession`
/// rather than asking every adapter to implement identical SSE parsing.
@MainActor
@Observable
final class PingRunner {
    private(set) var serverUp: PingStepState = .pending
    private(set) var modelLoaded: PingStepState = .pending
    private(set) var firstToken: PingStepState = .pending
    /// The model the first-token step actually talked to — shown in the
    /// sheet so a pass/fail is about a named model, not an anonymous one.
    private(set) var modelID: String?

    private let runtime: any Runtime
    private let base: URL
    private let apiKey: String?
    private let preferredModelID: String?
    private let urlSession: URLSession

    enum PingError: Error, Sendable, Equatable, CustomStringConvertible {
        case noModelLoaded
        case noTokenReceived
        case httpStatus(Int)

        var description: String {
            switch self {
            case .noModelLoaded: "no model found"
            case .noTokenReceived: "stream ended with no token"
            case let .httpStatus(code): "HTTP \(code)"
            }
        }
    }

    /// - Parameter preferredModelID: the configured default model
    ///   (`Config.defaultModelID`), used when nothing is loaded yet.
    init(
        runtime: any Runtime,
        base: URL,
        apiKey: String?,
        preferredModelID: String? = nil,
        urlSession: URLSession = .shared
    ) {
        self.runtime = runtime
        self.base = base
        self.apiKey = apiKey
        self.preferredModelID = preferredModelID
        self.urlSession = urlSession
    }

    /// Which listed model to ping: one that's already loaded (or loading)
    /// first, then the configured default, then whatever's listed first.
    /// Found by live testing: always taking `models.first` pinged the
    /// alphabetically-first model (e.g. a 0.6B smoke-test model) — and with
    /// the default `modelsMax` of 1, that request made the router *evict*
    /// the user's actual default model to load it. A test shouldn't change
    /// what's loaded.
    static func choose(from models: [ServedModel], preferred: String?) -> ServedModel? {
        models.first { $0.status.value == "loaded" }
            ?? models.first { $0.status.value == "loading" }
            ?? models.first { $0.id == preferred }
            ?? models.first
    }

    func run() async {
        serverUp = .running
        modelLoaded = .pending
        firstToken = .pending
        modelID = nil

        serverUp = await Self.timed {
            let health = try await self.runtime.health(base: self.base, apiKey: self.apiKey)
            guard health.isUp else { throw PingError.httpStatus(0) }
        }
        guard case .succeeded = serverUp else { return }

        modelLoaded = .running
        var chosenID: String?
        modelLoaded = await Self.timed {
            let models = try await self.runtime.listModels(base: self.base, apiKey: self.apiKey)
            guard let chosen = Self.choose(from: models, preferred: self.preferredModelID) else {
                throw PingError.noModelLoaded
            }
            chosenID = chosen.id
        }
        modelID = chosenID
        guard case .succeeded = modelLoaded, let chosenID else { return }

        firstToken = .running
        firstToken = await Self.timed { try await self.streamFirstToken(modelID: chosenID) }
    }

    /// Times `body`, turning it into a `.succeeded`/`.failed` state — the
    /// same do/catch-and-time shape all three steps share.
    private static func timed(_ body: () async throws -> Void) async -> PingStepState {
        let start = Date()
        do {
            try await body()
            return .succeeded(Date().timeIntervalSince(start))
        } catch {
            return .failed(describe(error))
        }
    }

    /// - Parameter modelID: router mode 400s with "model name is missing
    ///   from the request" without this — confirmed against a real b11081
    ///   build. Chosen by `choose(from:preferred:)`.
    private func streamFirstToken(modelID: String) async throws {
        var request = URLRequest(url: base.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "messages": [["role": "user", "content": "Hi"]],
            "max_tokens": 1,
            "stream": true,
        ])

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PingError.httpStatus(0) }
        guard (200 ..< 300).contains(http.statusCode) else { throw PingError.httpStatus(http.statusCode) }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" {
                continue
            }
            return // first real SSE chunk — that's the first token
        }
        throw PingError.noTokenReceived
    }

    private static func describe(_ error: Error) -> String {
        if let pingError = error as? PingError {
            return pingError.description
        }
        if let runtimeError = error as? RuntimeError {
            switch runtimeError {
            case .invalidResponse: return "invalid response"
            case let .httpStatus(code): return "HTTP \(code)"
            case let .decoding(detail): return "decoding error: \(detail)"
            }
        }
        return error.localizedDescription
    }
}
