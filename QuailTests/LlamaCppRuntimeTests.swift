import Foundation
import Testing
@testable import Quail

@Suite("LlamaCppRuntime")
struct LlamaCppRuntimeTests {
    private static func makeSession(handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    private static let base = URL(string: "http://127.0.0.1:8080")!
    private static let executable = URL(fileURLWithPath: "/tmp/fake/llama-server")

    // MARK: - launchSpec

    @Test("launchSpec includes host, port, models-dir, models-max and log-file")
    func launchSpecBuildsExpectedArguments() {
        let runtime = LlamaCppRuntime(executableURL: Self.executable)
        let config = EndpointConfig(
            host: "127.0.0.1",
            port: 8099,
            apiKey: nil,
            modelsDirectory: URL(fileURLWithPath: "/tmp/models"),
            modelsMax: 2
        )
        let spec = runtime.launchSpec(config: config, model: nil)

        #expect(spec.executableURL == Self.executable)
        #expect(spec.arguments.contains("--host"))
        #expect(spec.arguments.contains("127.0.0.1"))
        #expect(spec.arguments.contains("--port"))
        #expect(spec.arguments.contains("8099"))
        #expect(spec.arguments.contains("--models-dir"))
        #expect(spec.arguments.contains("/tmp/models"))
        #expect(spec.arguments.contains("--models-max"))
        #expect(spec.arguments.contains("2"))
        #expect(spec.arguments.contains("--log-file"))
        #expect(!spec.arguments.contains("--api-key"))
        #expect(!spec.arguments.contains("--no-webui"), "web UI must stay on by default")
        #expect(spec.environment.isEmpty, "never inherit the shell environment")
    }

    @Test("launchSpec includes --api-key only when one is set")
    func launchSpecIncludesAPIKeyWhenPresent() {
        let runtime = LlamaCppRuntime(executableURL: Self.executable)
        let config = EndpointConfig(apiKey: "secret-123", modelsDirectory: URL(fileURLWithPath: "/tmp/models"))
        let spec = runtime.launchSpec(config: config, model: nil)

        #expect(spec.arguments.contains("--api-key"))
        #expect(spec.arguments.contains("secret-123"))
    }

    // MARK: - health

    @Test("health decodes a real /health payload as up")
    func healthDecodesUp() async throws {
        let session = Self.makeSession { _ in (200, Fixtures.health) }
        let runtime = LlamaCppRuntime(executableURL: Self.executable, urlSession: session)

        let health = try await runtime.health(base: Self.base, apiKey: nil)
        #expect(health.isUp)
    }

    @Test("health throws httpStatus on a non-2xx response")
    func healthThrowsOnBadStatus() async throws {
        let session = Self.makeSession { _ in (503, Data()) }
        let runtime = LlamaCppRuntime(executableURL: Self.executable, urlSession: session)

        await #expect(throws: RuntimeError.httpStatus(503)) {
            _ = try await runtime.health(base: Self.base, apiKey: nil)
        }
    }

    // MARK: - listModels

    @Test("listModels decodes a real router-mode /models payload, ignoring unmodelled fields")
    func listModelsDecodesRealPayload() async throws {
        let session = Self.makeSession { _ in (200, Fixtures.modelsWithOneLoaded) }
        let runtime = LlamaCppRuntime(executableURL: Self.executable, urlSession: session)

        let models = try await runtime.listModels(base: Self.base, apiKey: nil)
        #expect(models.count == 1)
        #expect(models[0].id == "gguf")
        #expect(models[0].status.value == "loaded")
        #expect(models[0].status.failed == nil)
    }

    @Test("listModels decodes an empty router with no models on disk")
    func listModelsDecodesEmpty() async throws {
        let session = Self.makeSession { _ in (200, Fixtures.modelsEmpty) }
        let runtime = LlamaCppRuntime(executableURL: Self.executable, urlSession: session)

        let models = try await runtime.listModels(base: Self.base, apiKey: nil)
        #expect(models.isEmpty)
    }

    // MARK: - select

    @Test("select posts the model id and returns hotSwapped on success")
    func selectPostsModelAndHotSwaps() async throws {
        let capturedBody = CapturedBody()
        let session = Self.makeSession { request in
            capturedBody.set(request.httpBodyStreamData() ?? Data())
            return (200, #"{"success":true}"#.data(using: .utf8)!)
        }
        let runtime = LlamaCppRuntime(executableURL: Self.executable, urlSession: session)

        let action = try await runtime.select(model: ModelRef(id: "gguf"), base: Self.base, apiKey: nil)
        #expect(action == .hotSwapped)

        let bodyJSON = try JSONSerialization.jsonObject(with: capturedBody.data ?? Data()) as? [String: String]
        #expect(bodyJSON?["model"] == "gguf")
    }

    @Test("select throws httpStatus when the router rejects the request")
    func selectThrowsOnBadStatus() async throws {
        let session = Self.makeSession { _ in
            (404, #"{"error":{"message":"File Not Found"}}"#.data(using: .utf8)!)
        }
        let runtime = LlamaCppRuntime(executableURL: Self.executable, urlSession: session)

        await #expect(throws: RuntimeError.httpStatus(404)) {
            _ = try await runtime.select(model: ModelRef(id: "nope"), base: Self.base, apiKey: nil)
        }
    }

    // MARK: - Authorization header

    //
    // Confirmed empirically against a real b11081 build with --api-key set:
    // /health is exempt, but /models, /v1/models and /v1/chat/completions
    // all 401 without "Authorization: Bearer <key>". See Runtime.swift's
    // doc comment on why every method here takes apiKey uniformly.

    @Test("listModels sends Authorization: Bearer <key> when an API key is set")
    func listModelsSendsAuthorizationHeaderWhenAPIKeySet() async throws {
        let capturedHeader = CapturedHeader()
        let session = Self.makeSession { request in
            capturedHeader.set(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Fixtures.modelsEmpty)
        }
        let runtime = LlamaCppRuntime(executableURL: Self.executable, urlSession: session)

        _ = try await runtime.listModels(base: Self.base, apiKey: "secret-123")
        #expect(capturedHeader.value == "Bearer secret-123")
    }

    @Test("listModels sends no Authorization header when there's no API key")
    func listModelsOmitsAuthorizationHeaderWhenNoAPIKey() async throws {
        let capturedHeader = CapturedHeader()
        let session = Self.makeSession { request in
            capturedHeader.set(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Fixtures.modelsEmpty)
        }
        let runtime = LlamaCppRuntime(executableURL: Self.executable, urlSession: session)

        _ = try await runtime.listModels(base: Self.base, apiKey: nil)
        #expect(capturedHeader.value == nil)
    }
}

// MARK: - Test support

/// `StubURLProtocol`'s handler runs synchronously on the calling thread
/// before the mocked network call "completes", so by the time
/// `select(model:base:)` returns, `data` has already been set — no actor
/// hop or synchronization needed for this single-request-per-test usage.
private final class CapturedBody: @unchecked Sendable {
    private(set) var data: Data?
    func set(_ data: Data) {
        self.data = data
    }
}

private final class CapturedHeader: @unchecked Sendable {
    private(set) var value: String?
    func set(_ value: String?) {
        self.value = value
    }
}

private extension URLRequest {
    /// `URLProtocol` only sees `httpBodyStream` for POST bodies set via
    /// `URLRequest.httpBody` once `URLSession` has processed the request in
    /// some configurations; this reads whichever is present.
    func httpBodyStreamData() -> Data? {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}

/// Captured real JSON payloads from a live `llama-server` (b11081), so the
/// decoding tests exercise the actual shape of the API rather than a
/// hand-guessed one.
private enum Fixtures {
    static let health = #"{"status":"ok"}"#.data(using: .utf8)!

    static let modelsEmpty = #"{"data":[],"object":"list"}"#.data(using: .utf8)!

    static let modelsWithOneLoaded = """
    {"data":[{"id":"gguf","aliases":[],"tags":[],"object":"model","owned_by":"llamacpp",\
    "created":1790067779,"status":{"value":"loaded","args":["/path/llama-server","--host",\
    "127.0.0.1","--port","62219","--alias","gguf","--model","/path/Qwen3-0.6B-Q8_0.gguf"]},\
    "architecture":{"input_modalities":["text"],"output_modalities":["text"]},\
    "source":"models_dir","can_remove":false,"meta":{"vocab_type":2,"n_vocab":151936,\
    "n_ctx":40960,"n_ctx_train":40960,"n_embd":1024,"n_params":596049920,\
    "size":633495552,"ftype":"Q8_0"}}],"object":"list"}
    """.data(using: .utf8)!
}

/// Intercepts every request made by a session configured with it and
/// returns a canned (status, body) via `handler`.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
