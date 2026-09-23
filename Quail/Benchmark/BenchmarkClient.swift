import Foundation

/// What the benchmark asks of a running server. A protocol so the runner's
/// sequencing (warm-up, skipping, restoring what was loaded) is tested
/// against a fake, like `Runtime` is.
protocol BenchmarkClient: Sendable {
    func tokenize(_ text: String, model: String) async throws -> [Int]
    func properties(model: String) async throws -> ServerProperties
    /// Model id → router status ("loaded", "loading", "unloaded", or
    /// "failed" when its last load failed).
    func modelStates() async throws -> [String: String]
    func load(model: String) async throws
    func unload(model: String) async throws
    func complete(model: String, prompt: [Int], maxTokens: Int) async throws -> CompletionTiming
}

struct ServerProperties: Sendable, Equatable {
    var build: String?
    var contextSize: Int?
    var slots: Int?
}

/// One completion as the server timed it, plus our own time to first token.
struct CompletionTiming: Sendable, Equatable {
    var promptTokens: Int
    var promptPerSecond: Double
    var generatedTokens: Int
    var generatedPerSecond: Double
    var timeToFirstTokenMs: Double
}

enum BenchmarkError: Error, Equatable, CustomStringConvertible {
    case serverNotRunning
    case unknownModel(String)
    case notGGUF(String)
    case alreadyRunning
    case http(Int, String?)
    case badResponse(String)
    case loadTimedOut(String)
    case loadFailed(String)

    var description: String {
        switch self {
        case .serverNotRunning: "Start the server first."
        case let .unknownModel(id): "No installed model called \(id)."
        case let .notGGUF(id): "\(id) is an MLX model — only llama.cpp (GGUF) models can be benchmarked so far."
        case .alreadyRunning: "A benchmark is already running."
        case let .http(status, message): "The server answered HTTP \(status)\(message.map { ": \($0)" } ?? "")."
        case let .badResponse(what): "Unexpected answer from the server (\(what))."
        case let .loadTimedOut(id): "\(id) didn't finish loading within 10 minutes."
        case let .loadFailed(id): "\(id) failed to load — see Logs."
        }
    }
}

/// `BenchmarkClient` for llama.cpp's router (b11081): `/tokenize`, `/props`,
/// `/models/load`, `/models/unload` and streamed `/v1/completions`, whose
/// last chunk carries the server's own `timings`. All verified against the
/// vendored build before this was written.
struct LlamaCppBenchmarkClient: BenchmarkClient {
    let base: URL
    let apiKey: String?
    var urlSession: URLSession = .shared

    func tokenize(_ text: String, model: String) async throws -> [Int] {
        struct Response: Decodable { let tokens: [Int] }
        let data = try await post("tokenize", ["model": model, "content": text])
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw BenchmarkError.badResponse("/tokenize")
        }
        return response.tokens
    }

    func properties(model: String) async throws -> ServerProperties {
        var components = URLComponents(url: base.appending(path: "props"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        let data = try await send(URLRequest(url: components.url!))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BenchmarkError.badResponse("/props")
        }
        let settings = json["default_generation_settings"] as? [String: Any]
        return ServerProperties(
            build: json["build_info"] as? String,
            contextSize: settings?["n_ctx"] as? Int,
            slots: json["total_slots"] as? Int
        )
    }

    func modelStates() async throws -> [String: String] {
        struct Response: Decodable {
            struct Model: Decodable {
                struct Status: Decodable {
                    let value: String
                    let failed: Bool?
                }

                let id: String
                let status: Status
            }

            let data: [Model]
        }
        let data = try await send(URLRequest(url: base.appending(path: "models")))
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw BenchmarkError.badResponse("/models")
        }
        return Dictionary(
            response.data.map { ($0.id, $0.status.failed == true ? "failed" : $0.status.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func load(model: String) async throws {
        _ = try await post("models/load", ["model": model])
    }

    func unload(model: String) async throws {
        _ = try await post("models/unload", ["model": model])
    }

    func complete(model: String, prompt: [Int], maxTokens: Int) async throws -> CompletionTiming {
        var body = BenchmarkSuite.requestSettings
        body["model"] = model
        body["prompt"] = prompt
        body["max_tokens"] = maxTokens
        body["ignore_eos"] = true
        body["stream"] = true
        var request = authorized(URLRequest(url: base.appending(path: "v1/completions")))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = ContinuousClock.now
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw BenchmarkError.badResponse("no HTTP response") }
        guard (200 ..< 300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            throw BenchmarkError.http(http.statusCode, Self.errorMessage(in: data))
        }

        var firstToken: Duration?
        var timings: [String: Any]?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                break
            }
            if firstToken == nil {
                firstToken = ContinuousClock.now - started
            }
            if let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
               let found = json["timings"] as? [String: Any]
            {
                timings = found
            }
        }
        guard let timings,
              let promptN = timings["prompt_n"] as? Int,
              let promptPerSecond = timings["prompt_per_second"] as? Double,
              let predictedN = timings["predicted_n"] as? Int,
              let predictedPerSecond = timings["predicted_per_second"] as? Double
        else { throw BenchmarkError.badResponse("no timings in the stream") }
        let ttft = firstToken
            .map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 } ?? 0
        return CompletionTiming(
            promptTokens: promptN,
            promptPerSecond: promptPerSecond,
            generatedTokens: predictedN,
            generatedPerSecond: predictedPerSecond,
            timeToFirstTokenMs: ttft
        )
    }

    // MARK: - HTTP

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: authorized(request))
        guard let http = response as? HTTPURLResponse else { throw BenchmarkError.badResponse("no HTTP response") }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw BenchmarkError.http(http.statusCode, Self.errorMessage(in: data))
        }
        return data
    }

    private static func errorMessage(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
    }
}
