import Foundation
import Network

enum HTTPServerError: Error, Equatable, LocalizedError {
    case bindFailed(host: String, port: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case let .bindFailed(host, port, reason): "couldn't listen on \(host):\(port): \(reason)"
        }
    }
}

typealias HTTPHandler = @Sendable (HTTPRequest) async -> HTTPResponse

/// A small HTTP/1.1 server on `Network.framework` (D-028: no swift-nio). It
/// speaks exactly what OpenAI-style clients send — Content-Length bodies,
/// keep-alive, `Expect: 100-continue` — and answers with a whole body or a
/// chunked stream.
final class HTTPServer: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let maxBodyBytes: Int
    private let log: ServerLog
    private let queue = DispatchQueue(label: "quail-server.http")

    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    /// How long to wait for a port that nothing listens on but that can't be bound yet (see `start`).
    let bindWait: Duration

    init(
        host: String, port: Int, maxBodyBytes: Int = 64 * 1024 * 1024, bindWait: Duration = .seconds(75),
        log: ServerLog
    ) {
        self.host = host
        self.port = port
        self.maxBodyBytes = maxBodyBytes
        self.bindWait = bindWait
        self.log = log
    }

    /// Binds and starts serving; returns the bound port (useful with port 0).
    ///
    /// Right after another server on this port stops, the port can refuse a bind for up to a minute though
    /// nothing listens on it: a client that kept a connection open (a browser tab, a polling app) leaves the
    /// old server's side in FIN_WAIT_2, and Network.framework's `allowLocalEndpointReuse` doesn't get past that
    /// the way BSD `SO_REUSEADDR` does. That is what a switch from llama-server to `quail-server` on the same
    /// port looks like, so a refused bind with no listener is waited out; a port something really listens on
    /// still fails at once.
    func start(handler: @escaping HTTPHandler) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: bindWait)
        var announced = false
        while true {
            do {
                return try await listen(handler: handler)
            } catch let HTTPServerError.bindFailed(_, _, reason)
                where reason == "address already in use" && port != 0 && ContinuousClock.now < deadline
                && !Self.somethingListens(host: host, port: port)
            {
                if !announced {
                    announced = true
                    log.log(
                        .warn,
                        "port \(port) is still held by connections to a server that just stopped; waiting for it"
                    )
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// A plain connect: true only if something accepts connections on the port.
    static func somethingListens(host: String, port: Int) -> Bool {
        let probe = host == "0.0.0.0" || host == "::" ? "127.0.0.1" : host == "localhost" ? "127.0.0.1" : host
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(probe, String(port), &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                let connected = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
                close(fd)
                if connected {
                    return true
                }
            }
            cursor = info.pointee.ai_next
        }
        return false
    }

    private func listen(handler: @escaping HTTPHandler) async throws -> Int {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // SSE tokens shouldn't wait for a full packet
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Quail restarts a crashed server within seconds; don't fail on TIME_WAIT.
        parameters.allowLocalEndpointReuse = true
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: Self.endpointHost(host), port: endpointPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw HTTPServerError.bindFailed(host: host, port: port, reason: error.localizedDescription)
        }

        listener.newConnectionHandler = { [self] connection in
            let http = HTTPConnection(connection, maxBodyBytes: maxBodyBytes, queue: queue)
            let id = ObjectIdentifier(http)
            lock.withLock { connections[id] = http }
            Task {
                await http.serve(handler: handler)
                lock.withLock { _ = connections.removeValue(forKey: id) }
            }
        }

        let bound: Int = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [host, port] state in
                switch state {
                case .ready:
                    if once.claim() {
                        continuation.resume(returning: Int(listener.port?.rawValue ?? UInt16(port)))
                    }
                case let .failed(error):
                    if once.claim() {
                        continuation.resume(throwing: HTTPServerError.bindFailed(
                            host: host, port: port, reason: Self.describe(error)
                        ))
                    }
                case .cancelled:
                    if once.claim() {
                        continuation.resume(throwing: HTTPServerError.bindFailed(
                            host: host, port: port, reason: "cancelled"
                        ))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener }
        return bound
    }

    func stop() {
        let (listener, open) = lock.withLock { () -> (NWListener?, [HTTPConnection]) in
            let result = (self.listener, Array(connections.values))
            self.listener = nil
            connections = [:]
            return result
        }
        listener?.cancel()
        for connection in open {
            connection.cancel()
        }
    }

    private static func endpointHost(_ host: String) -> NWEndpoint.Host {
        switch host {
        case "0.0.0.0": .ipv4(.any)
        case "::": .ipv6(.any)
        case "localhost": .ipv4(.loopback)
        default: NWEndpoint.Host(host)
        }
    }

    private static func describe(_ error: NWError) -> String {
        if case let .posix(code) = error, code == .EADDRINUSE {
            return "address already in use"
        }
        return error.localizedDescription
    }
}

/// One client connection: reads requests in order, answers each, and stays open
/// for the next until either side closes.
final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let maxBodyBytes: Int
    private let queue: DispatchQueue
    /// Only touched from `serve`, which runs one request at a time.
    private var buffer = Data()

    init(_ connection: NWConnection, maxBodyBytes: Int, queue: DispatchQueue) {
        self.connection = connection
        self.maxBodyBytes = maxBodyBytes
        self.queue = queue
    }

    func cancel() {
        connection.cancel()
    }

    func serve(handler: @escaping HTTPHandler) async {
        connection.start(queue: queue)
        defer { connection.cancel() }
        do {
            while true {
                guard let request = try await readRequest() else { return }
                // nil: the client left while its request was being worked on.
                guard var response = await respond(to: request.request, using: handler) else { return }
                if !request.keepAlive {
                    response.closeConnection = true
                }
                try await write(response)
                if response.closeConnection {
                    return
                }
            }
        } catch let error as HTTPParseError {
            try? await write(Self.response(for: error))
        } catch {
            // The peer went away, or a send failed; nothing to answer.
        }
    }

    // MARK: Watching for a client that leaves

    /// The read of the next bytes, started as soon as a request is being handled. It has two
    /// readers: `respond` peeks at its outcome to notice the client leaving, and `readRequest`
    /// consumes it, so a pipelined request that arrives meanwhile isn't lost.
    private var pendingReceive: Task<Data?, any Error>?

    private func takePendingReceive() -> Task<Data?, any Error> {
        defer { pendingReceive = nil }
        return pendingReceive ?? Task { try await self.receive() }
    }

    private func armPendingReceive() -> Task<Data?, any Error> {
        if let pendingReceive {
            return pendingReceive
        }
        let task = Task { try await self.receive() }
        pendingReceive = task
        return task
    }

    /// Runs the handler while watching the socket. A client that closes before the answer is
    /// ready — a long prompt still being processed, a model still loading — cancels the handler,
    /// which stops the engine (D-037), instead of letting it finish work nobody will read.
    private func respond(to request: HTTPRequest, using handler: @escaping HTTPHandler) async -> HTTPResponse? {
        let work = Task { await handler(request) }
        let receive = armPendingReceive()
        let finished = OnceFlag()
        let clientLeft = OnceFlag()
        // Deliberately not awaited: if the handler finishes first this simply outlives it, and
        // its late result is ignored (`finished` is claimed by then).
        Task {
            // Bytes mean a pipelined request, not a departure. `nil` is a close or an error.
            let dataArrived = await (try? receive.value) != nil
            guard !dataArrived, finished.claim() else { return }
            _ = clientLeft.claim()
            work.cancel()
        }
        let response = await work.value
        if clientLeft.claim() {
            // Nobody cancelled it: the answer stands. Stop the watcher acting on a later close.
            _ = finished.claim()
            return response
        }
        return nil
    }

    // MARK: Reading

    private func readRequest() async throws -> (request: HTTPRequest, keepAlive: Bool)? {
        var parsed: (head: HTTPRequestHead, length: Int)?
        while parsed == nil {
            parsed = try HTTPRequestParser.parseHead(buffer, maxBodyBytes: maxBodyBytes)
            if parsed == nil {
                guard let more = try await takePendingReceive().value else { return nil }
                buffer.append(more)
            }
        }
        let (head, headLength) = parsed!
        buffer.removeFirst(headLength)

        if head.wantsContinue, head.contentLength > 0 {
            try await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        while buffer.count < head.contentLength {
            guard let more = try await takePendingReceive().value else { return nil }
            buffer.append(more)
        }
        let body = Data(buffer.prefix(head.contentLength))
        buffer.removeFirst(head.contentLength)
        let request = HTTPRequest(method: head.method, target: head.target, headers: head.headers, body: body)
        return (request, head.keepAlive)
    }

    /// The next bytes, or `nil` when the peer has closed. Never empty.
    private func receive() async throws -> Data? {
        while true {
            let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            if chunk == nil || !(chunk?.isEmpty ?? true) {
                return chunk
            }
        }
    }

    // MARK: Writing

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func write(_ response: HTTPResponse) async throws {
        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.statusText(response.status))\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += response.closeConnection ? "Connection: close\r\n" : "Connection: keep-alive\r\n"

        switch response.body {
        case let .data(body):
            head += "Content-Length: \(body.count)\r\n\r\n"
            try await send(Data(head.utf8) + body)
        case let .stream(chunks):
            head += "Transfer-Encoding: chunked\r\n\r\n"
            try await send(Data(head.utf8))
            // A failed send throws out of the loop, which ends consumption of
            // `chunks` and lets its producer see the termination and stop.
            for await chunk in chunks where !chunk.isEmpty {
                let framed = Data(String(chunk.count, radix: 16).utf8) + Data("\r\n".utf8) + chunk + Data("\r\n".utf8)
                try await send(framed)
            }
            try await send(Data("0\r\n\r\n".utf8))
        }
    }

    private static func response(for error: HTTPParseError) -> HTTPResponse {
        var response: HTTPResponse = switch error {
        case let .malformed(reason):
            .error(400, type: "invalid_request_error", message: reason)
        case .headersTooLarge:
            .error(431, type: "invalid_request_error", message: "request headers too large")
        case .unsupportedTransferEncoding:
            .error(
                501,
                type: "invalid_request_error",
                message: "chunked request bodies are not supported; send Content-Length"
            )
        case .bodyTooLarge:
            .error(413, type: "invalid_request_error", message: "request body too large")
        }
        response.closeConnection = true
        return response
    }
}
