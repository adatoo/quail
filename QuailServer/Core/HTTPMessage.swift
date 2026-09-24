import Foundation

struct HTTPRequest: Equatable, Sendable {
    var method: String
    /// The request target as sent: path plus optional `?query`.
    var target: String
    /// Header names are lowercased; repeated headers are joined with ", ".
    var headers: [String: String]
    var body: Data

    var path: String {
        target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

struct HTTPResponse: Sendable {
    enum Body: Sendable {
        case data(Data)
        /// Sent with chunked transfer encoding, one chunk per element; the
        /// producer frames its own payload (e.g. SSE `data: …\n\n`). Ending
        /// consumption early — the client went away — ends the stream, so a
        /// producer should stop work in `onTermination`.
        case stream(AsyncStream<Data>)
    }

    var status: Int
    var headers: [(name: String, value: String)]
    var body: Body
    var closeConnection = false

    init(status: Int, headers: [(name: String, value: String)] = [], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ status: Int = 200, _ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: .data(data)
        )
    }

    /// The OpenAI-style error body llama-server also sends, so clients that
    /// parse `error.message` keep working.
    static func error(_ status: Int, type: String, message: String) -> HTTPResponse {
        struct Body: Encodable {
            struct Detail: Encodable {
                let message: String
                let type: String
                let code: Int
            }

            let error: Detail
        }
        return json(status, Body(error: .init(message: message, type: type, code: status)))
    }

    static func statusText(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 421: "Misdirected Request"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }
}

enum HTTPParseError: Error, Equatable {
    case malformed(String)
    case headersTooLarge
    /// A chunked (or otherwise encoded) request body; OpenAI clients send
    /// Content-Length, so this is refused rather than half-supported.
    case unsupportedTransferEncoding
    case bodyTooLarge
}

struct HTTPRequestHead: Equatable, Sendable {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]

    var contentLength: Int {
        headers["content-length"].flatMap { Int($0) } ?? 0
    }

    var wantsContinue: Bool {
        headers["expect"]?.lowercased() == "100-continue"
    }

    /// HTTP/1.1 keeps the connection open unless told otherwise; 1.0 the reverse.
    var keepAlive: Bool {
        let connection = headers["connection"]?.lowercased() ?? ""
        if version == "HTTP/1.0" {
            return connection.contains("keep-alive")
        }
        return !connection.contains("close")
    }
}

enum HTTPRequestParser {
    static let maxHeaderBytes = 64 * 1024
    private static let separator = Data([13, 10, 13, 10])

    /// Parses a request head from the front of `buffer`. Returns `nil` when the
    /// head isn't complete yet; otherwise the head and how many bytes it took.
    static func parseHead(_ buffer: Data, maxBodyBytes: Int) throws -> (head: HTTPRequestHead, length: Int)? {
        guard let end = buffer.range(of: separator) else {
            if buffer.count > maxHeaderBytes {
                throw HTTPParseError.headersTooLarge
            }
            return nil
        }
        if end.upperBound > maxHeaderBytes {
            throw HTTPParseError.headersTooLarge
        }
        guard let text = String(data: buffer[buffer.startIndex ..< end.lowerBound], encoding: .utf8) else {
            throw HTTPParseError.malformed("the request head isn't UTF-8")
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3 else { throw HTTPParseError.malformed("bad request line") }
        let version = String(requestLine[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            throw HTTPParseError.malformed("unsupported version \(version)")
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                throw HTTPParseError.malformed("bad header line")
            }
            let name = line[..<colon].lowercased()
            if name.contains(" ") {
                throw HTTPParseError.malformed("bad header name")
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        if headers["transfer-encoding"] != nil {
            throw HTTPParseError.unsupportedTransferEncoding
        }
        if let rawLength = headers["content-length"] {
            guard let length = Int(rawLength), length >= 0, !rawLength.contains(",") else {
                throw HTTPParseError.malformed("bad Content-Length")
            }
            if length > maxBodyBytes {
                throw HTTPParseError.bodyTooLarge
            }
        }
        let head = HTTPRequestHead(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            version: version,
            headers: headers
        )
        return (head, buffer.distance(from: buffer.startIndex, to: end.upperBound))
    }
}
