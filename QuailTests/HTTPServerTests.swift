import Foundation
import Testing
@testable import QuailServerCore

@Suite("HTTPServer", .timeLimit(.minutes(1)))
struct HTTPServerTests {
    private static let describe: HTTPHandler = { request in
        .json(200, ["method": request.method, "path": request.path, "length": "\(request.body.count)"])
    }

    private static func start(
        maxBodyBytes: Int = 4 * 1024 * 1024,
        handler: @escaping HTTPHandler = describe
    ) async throws -> (server: HTTPServer, port: Int) {
        let server = HTTPServer(
            host: "127.0.0.1",
            port: 0,
            maxBodyBytes: maxBodyBytes,
            log: ServerLog(toStandardError: false)
        )
        return try await (server, server.start(handler: handler))
    }

    private static func url(_ port: Int, _ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    // MARK: Ordinary requests

    @Test("GET and POST round-trip, including a body of a megabyte")
    func getAndPost() async throws {
        let (server, port) = try await Self.start()
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: Self.url(port, "/hello?x=1"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        #expect(decoded == ["method": "GET", "path": "/hello", "length": "0"])

        var request = URLRequest(url: Self.url(port, "/upload"))
        request.httpMethod = "POST"
        request.httpBody = Data(repeating: 0x61, count: 1_000_000)
        let (postData, _) = try await URLSession.shared.data(for: request)
        #expect(try JSONDecoder().decode([String: String].self, from: postData)["length"] == "1000000")
    }

    @Test("a connection serves several requests, including two sent back to back")
    func keepAliveAndPipelining() async throws {
        let (server, port) = try await Self.start()
        defer { server.stop() }
        let client = try RawHTTPClient(port: port)

        client.send("GET /one HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(client.read(until: #""path":"/one""#).contains("HTTP/1.1 200 OK"))

        client.send("GET /two HTTP/1.1\r\nHost: x\r\n\r\nGET /three HTTP/1.1\r\nHost: x\r\n\r\n")
        let both = client.read(until: #""path":"/three""#)
        #expect(both.contains(#""path":"/two""#))
        #expect(both.contains("Connection: keep-alive"))
    }

    @Test("Expect: 100-continue gets its interim response before the body is sent")
    func expectContinue() async throws {
        let (server, port) = try await Self.start()
        defer { server.stop() }
        let client = try RawHTTPClient(port: port)

        client.send("POST /big HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
        #expect(client.read(until: "\r\n\r\n").hasPrefix("HTTP/1.1 100 Continue"))

        client.send("hello")
        #expect(client.read(until: #""length":"5""#).contains("HTTP/1.1 200 OK"))
    }

    @Test("HTTP/1.0 and Connection: close end the connection after the response")
    func closes() async throws {
        let (server, port) = try await Self.start()
        defer { server.stop() }
        let client = try RawHTTPClient(port: port)

        client.send("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        let (text, closed) = client.readToEnd()
        #expect(text.contains("HTTP/1.1 200 OK"))
        #expect(text.contains("Connection: close"))
        #expect(closed)
    }

    // MARK: Refusals

    @Test("a malformed request gets 400 and the connection closes")
    func malformed() async throws {
        let (server, port) = try await Self.start()
        defer { server.stop() }
        let client = try RawHTTPClient(port: port)

        client.send("this is not http\r\n\r\n")
        let (text, closed) = client.readToEnd()
        #expect(text.hasPrefix("HTTP/1.1 400 Bad Request"))
        #expect(text.contains("invalid_request_error"))
        #expect(closed)
    }

    @Test("a chunked request body gets 501, not a hang")
    func chunkedRequest() async throws {
        let (server, port) = try await Self.start()
        defer { server.stop() }
        let client = try RawHTTPClient(port: port)

        client.send("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")
        let (text, closed) = client.readToEnd()
        #expect(text.hasPrefix("HTTP/1.1 501 Not Implemented"))
        #expect(closed)
    }

    @Test("a body over the limit gets 413 before it's read")
    func bodyTooLarge() async throws {
        let (server, port) = try await Self.start(maxBodyBytes: 100)
        defer { server.stop() }
        let client = try RawHTTPClient(port: port)

        client.send("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5000\r\n\r\n")
        #expect(client.readToEnd().text.hasPrefix("HTTP/1.1 413 Content Too Large"))
    }

    @Test("an oversized head gets 431")
    func headersTooLarge() async throws {
        let (server, port) = try await Self.start()
        defer { server.stop() }
        let client = try RawHTTPClient(port: port)

        client.send("GET / HTTP/1.1\r\nX-Padding: " + String(
            repeating: "a",
            count: HTTPRequestParser.maxHeaderBytes + 100
        ))
        #expect(client.readToEnd().text.hasPrefix("HTTP/1.1 431"))
    }

    // MARK: Streaming

    @Test("a streamed response arrives chunk by chunk")
    func streaming() async throws {
        let (server, port) = try await Self.start { _ in
            let chunks = AsyncStream<Data> { continuation in
                Task {
                    for index in 1 ... 3 {
                        continuation.yield(Data("data: \(index)\n\n".utf8))
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    continuation.finish()
                }
            }
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/event-stream")], body: .stream(chunks))
        }
        defer { server.stop() }

        let (bytes, response) = try await URLSession.shared.bytes(from: Self.url(port, "/stream"))
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
        var lines: [String] = []
        for try await line in bytes.lines where !line.isEmpty {
            lines.append(line)
        }
        #expect(lines == ["data: 1", "data: 2", "data: 3"])
    }

    @Test("the response is chunked on the wire, with a terminating zero chunk")
    func chunkedFraming() async throws {
        let (server, port) = try await Self.start { _ in
            HTTPResponse(status: 200, body: .stream(AsyncStream { continuation in
                continuation.yield(Data("hello".utf8))
                continuation.finish()
            }))
        }
        defer { server.stop() }
        let client = try RawHTTPClient(port: port)

        client.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        let text = client.read(until: "0\r\n\r\n")
        #expect(text.contains("Transfer-Encoding: chunked"))
        #expect(text.hasSuffix("5\r\nhello\r\n0\r\n\r\n"))
    }

    @Test("a client that goes away stops the producer")
    func disconnectStopsProducer() async throws {
        let stopped = TestFlag()
        let (server, port) = try await Self.start { _ in
            let chunks = AsyncStream<Data> { continuation in
                let producer = Task {
                    while !Task.isCancelled {
                        continuation.yield(Data("data: tick\n\n".utf8))
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                }
                continuation.onTermination = { _ in
                    stopped.set()
                    producer.cancel()
                }
            }
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/event-stream")], body: .stream(chunks))
        }
        defer { server.stop() }

        let client = try RawHTTPClient(port: port)
        client.send("GET /forever HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(client.read(until: "data: tick").contains("data: tick"))
        #expect(!stopped.isSet)

        // Drop the connection; the next send fails and the stream ends.
        _ = consume client
        #expect(await eventually { stopped.isSet })
    }

    // MARK: Binding

    @Test("a port already in use is a clear error, not a silent second listener")
    func portInUse() async throws {
        let (first, port) = try await Self.start()
        defer { first.stop() }

        let second = HTTPServer(host: "127.0.0.1", port: port, log: ServerLog(toStandardError: false))
        await #expect(throws: HTTPServerError.self) {
            _ = try await second.start(handler: Self.describe)
        }
        second.stop()

        // ...and the first server is still the one answering.
        let (_, response) = try await URLSession.shared.data(from: Self.url(port, "/still-here"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("stop() closes open connections")
    func stopClosesConnections() async throws {
        let (server, port) = try await Self.start()
        let client = try RawHTTPClient(port: port)
        client.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(client.read(until: "\r\n\r\n").contains("200 OK"))

        server.stop()
        #expect(client.readToEnd().closed)
    }
}
