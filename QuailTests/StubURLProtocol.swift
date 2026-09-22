import Foundation

/// A canned HTTP response for `StubURLProtocol` to return.
struct StubResponse: Sendable {
    var statusCode: Int
    var headers: [String: String] = [:]
    var body: Data = .init()
    /// If set, `body` is ignored and these are delivered to the client
    /// sequentially instead, with `interChunkDelay` between each —
    /// lets a test exercise mid-stream behavior (progress events,
    /// cancellation) against a response that arrives over time rather
    /// than all at once.
    var chunks: [Data]?
    var interChunkDelay: TimeInterval = 0

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    init(statusCode: Int, headers: [String: String] = [:], chunks: [Data], interChunkDelay: TimeInterval = 0) {
        self.statusCode = statusCode
        self.headers = headers
        self.chunks = chunks
        self.interChunkDelay = interChunkDelay
    }
}

/// Intercepts every request made by a session configured with it and
/// returns a canned `StubResponse` via `handler`. Shared across
/// `LlamaCppRuntimeTests` and `HFDownloaderTests`.
///
/// Redirects work "for real": returning a 3xx `StubResponse` with a
/// `Location` header lets URLSession's own redirect machinery take over,
/// including invoking a per-task `URLSessionTaskDelegate`'s
/// `willPerformHTTPRedirection` (e.g. `HFDownloader`'s
/// range-preserving one) exactly as it would for a live network
/// redirect — the redirected request then re-enters `canInit`/
/// `startLoading` as a fresh stubbed request, so `handler` sees both
/// legs and can assert on either one by inspecting `request.url`/headers.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> StubResponse)?

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
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: stub.headers
        )!
        // A 3xx with a Location header is a redirect, not a body —
        // report it through the redirect channel so URLSession's own
        // machinery (including any task delegate's
        // willPerformHTTPRedirection) runs exactly as on a live network.
        if (300 ..< 400).contains(stub.statusCode),
           let location = stub.headers.first(where: { $0.key.lowercased() == "location" })?.value,
           let redirectURL = URL(string: location, relativeTo: url)?.absoluteURL
        {
            var redirectRequest = URLRequest(url: redirectURL)
            redirectRequest.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if let chunks = stub.chunks {
            for chunk in chunks {
                if stub.interChunkDelay > 0 {
                    Thread.sleep(forTimeInterval: stub.interChunkDelay)
                }
                client?.urlProtocol(self, didLoad: chunk)
            }
        } else {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
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
