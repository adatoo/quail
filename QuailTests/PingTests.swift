import Foundation
import Testing
@testable import Quail

/// Exercises `PingRunner`'s three-step chain against `FakeRuntime` (for
/// health/listModels) and a stubbed `URLSession` (for the raw
/// `/v1/chat/completions` SSE call `PingRunner` makes directly — see its
/// doc comment for why that one isn't part of the `Runtime` protocol).
@Suite("PingRunner", .timeLimit(.minutes(1)))
@MainActor
struct PingTests {
    private static let base = URL(string: "http://127.0.0.1:8080")!

    private static var dummySpec: LaunchSpec {
        LaunchSpec(
            executableURL: URL(fileURLWithPath: "/bin/true"),
            arguments: [],
            environment: [:],
            currentDirectoryURL: nil
        )
    }

    /// Deliberately `"unloaded"`, not `"loaded"` — router mode lists a
    /// model this way until first used, and the model-loaded step must
    /// still succeed (see Ping.swift's doc comment on why).
    private static let unusedModel = ServedModel(
        id: "gguf",
        status: .init(value: "unloaded", failed: nil, exitCode: nil)
    )

    private static func makeSession(handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PingStubURLProtocol.self]
        PingStubURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    @Test("all three steps succeed: healthy runtime, a model on disk (even if not yet loaded), a real SSE stream")
    func allStepsSucceed() async {
        let runtime = FakeRuntime(launchSpec: Self.dummySpec)
        await runtime.setListModelsResult(.success([Self.unusedModel]))
        let session = Self.makeSession { _ in (200, PingFixtures.sseBody) }
        let runner = PingRunner(runtime: runtime, base: Self.base, apiKey: nil, urlSession: session)

        await runner.run()

        #expect(isSucceeded(runner.serverUp))
        #expect(isSucceeded(runner.modelLoaded))
        #expect(isSucceeded(runner.firstToken))
    }

    @Test("stops at server-up on health failure; never attempts model or first-token")
    func stopsAtServerUpOnHealthFailure() async {
        let runtime = FakeRuntime(launchSpec: Self.dummySpec, healthResults: [.failure(RuntimeError.httpStatus(503))])
        let runner = PingRunner(runtime: runtime, base: Self.base, apiKey: nil, urlSession: .shared)

        await runner.run()

        #expect(!isSucceeded(runner.serverUp))
        #expect(runner.modelLoaded == .pending)
        #expect(runner.firstToken == .pending)
    }

    @Test("stops at model-loaded when nothing is loaded; never attempts first-token")
    func stopsAtModelLoadedWhenNoneLoaded() async {
        let runtime = FakeRuntime(launchSpec: Self.dummySpec)
        await runtime.setListModelsResult(.success([]))
        let runner = PingRunner(runtime: runtime, base: Self.base, apiKey: nil, urlSession: .shared)

        await runner.run()

        #expect(isSucceeded(runner.serverUp))
        #expect(runner.modelLoaded == .failed("no model found"))
        #expect(runner.firstToken == .pending)
    }

    @Test("first-token fails clearly when the stream ends with no data chunk")
    func firstTokenFailsWithNoToken() async {
        let runtime = FakeRuntime(launchSpec: Self.dummySpec)
        await runtime.setListModelsResult(.success([Self.unusedModel]))
        let session = Self.makeSession { _ in (200, "data: [DONE]\n\n".data(using: .utf8)!) }
        let runner = PingRunner(runtime: runtime, base: Self.base, apiKey: nil, urlSession: session)

        await runner.run()

        #expect(runner.firstToken == .failed("stream ended with no token"))
    }

    @Test("first-token fails with the HTTP status when the completions call is rejected")
    func firstTokenFailsOnBadStatus() async {
        let runtime = FakeRuntime(launchSpec: Self.dummySpec)
        await runtime.setListModelsResult(.success([Self.unusedModel]))
        let session = Self.makeSession { _ in (401, Data()) }
        let runner = PingRunner(runtime: runtime, base: Self.base, apiKey: nil, urlSession: session)

        await runner.run()

        #expect(runner.firstToken == .failed("HTTP 401"))
    }

    @Test("first-token includes the first listed model's id in the request body")
    func firstTokenIncludesModelID() async throws {
        // Router mode 400s with "model name is missing from the request"
        // without this — confirmed against a real b11081 build.
        let runtime = FakeRuntime(launchSpec: Self.dummySpec)
        await runtime.setListModelsResult(.success([Self.unusedModel]))
        let capturedBody = CapturedBody()
        let session = Self.makeSession { request in
            capturedBody.set(request.pingTestBody())
            return (200, PingFixtures.sseBody)
        }
        let runner = PingRunner(runtime: runtime, base: Self.base, apiKey: nil, urlSession: session)

        await runner.run()

        let body = try #require(capturedBody.data)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == Self.unusedModel.id)
    }

    private final class CapturedBody: @unchecked Sendable {
        private(set) var data: Data?
        func set(_ data: Data?) {
            self.data = data
        }
    }

    private func isSucceeded(_ state: PingStepState) -> Bool {
        if case .succeeded = state {
            return true
        }
        return false
    }
}

/// Not nested in `PingTests` because that `@MainActor` struct's static
/// members would inherit its isolation, and the `@Sendable` stub closures
/// above need a plain, non-isolated `Data` constant.
private enum PingFixtures {
    static let sseBody = """
    data: {"choices":[{"delta":{"content":"Hi"}}]}

    data: [DONE]

    """.data(using: .utf8)!
}

/// Intercepts every request made by a session configured with it and
/// returns a canned (status, body) via `handler` — same shape as
/// `LlamaCppRuntimeTests`' stub, private to this file to avoid a name
/// collision.
private final class PingStubURLProtocol: URLProtocol, @unchecked Sendable {
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

private extension URLRequest {
    /// `URLProtocol` only sees `httpBodyStream` for POST bodies set via
    /// `URLRequest.httpBody` once `URLSession` has processed the request in
    /// some configurations; this reads whichever is present. Same helper
    /// as `LlamaCppRuntimeTests.httpBodyStreamData()`, duplicated (not
    /// shared) since `private extension` is file-scoped.
    func pingTestBody() -> Data? {
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
