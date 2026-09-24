import Foundation
import Testing
@testable import QuailServerCore

@Suite("HTTPRequestParser")
struct HTTPParserTests {
    private func parse(_ text: String, maxBody: Int = 1024) throws -> (head: HTTPRequestHead, length: Int)? {
        try HTTPRequestParser.parseHead(Data(text.utf8), maxBodyBytes: maxBody)
    }

    @Test("a complete head parses, with lowercased names and the byte count it used")
    func parsesHead() throws {
        let body = #"{"model":"a"}"#
        let text = "POST /models/load?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 13\r\nX-Api-Key: k\r\n\r\n" +
            body
        let (head, length) = try #require(try parse(text))
        #expect(head.method == "POST")
        #expect(head.target == "/models/load?x=1")
        #expect(head.headers["content-length"] == "13")
        #expect(head.headers["x-api-key"] == "k")
        #expect(head.contentLength == 13)
        // The body isn't part of the head.
        #expect(length == text.utf8.count - body.utf8.count)
    }

    @Test("an incomplete head asks for more bytes")
    func incomplete() throws {
        #expect(try parse("GET /health HTTP/1.1\r\nHost: x\r\n") == nil)
        #expect(try parse("") == nil)
    }

    @Test("request path drops the query")
    func path() {
        let request = HTTPRequest(method: "GET", target: "/models?limit=2", headers: [:], body: Data())
        #expect(request.path == "/models")
        #expect(HTTPRequest(method: "GET", target: "/", headers: [:], body: Data()).path == "/")
    }

    @Test("keep-alive follows the HTTP version and the Connection header")
    func keepAlive() throws {
        #expect(try #require(try parse("GET / HTTP/1.1\r\n\r\n")).head.keepAlive)
        #expect(try !#require(try parse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n")).head.keepAlive)
        #expect(try !#require(try parse("GET / HTTP/1.0\r\n\r\n")).head.keepAlive)
        #expect(try #require(try parse("GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n")).head.keepAlive)
    }

    @Test("Expect: 100-continue is recognised")
    func expectContinue() throws {
        let head = try #require(try parse("POST / HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")).head
        #expect(head.wantsContinue)
    }

    @Test("repeated headers are joined")
    func repeatedHeaders() throws {
        let head = try #require(try parse("GET / HTTP/1.1\r\nAccept: a\r\nAccept: b\r\n\r\n")).head
        #expect(head.headers["accept"] == "a, b")
    }

    @Test(
        "malformed heads are refused",
        arguments: [
            "GET /\r\n\r\n",
            "GET / HTTP/2\r\n\r\n",
            "GET / HTTP/1.1\r\nNoColonHere\r\n\r\n",
            "GET / HTTP/1.1\r\nBad Name: x\r\n\r\n",
            "GET / HTTP/1.1\r\nContent-Length: twelve\r\n\r\n",
            "GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "GET / HTTP/1.1\r\nContent-Length: 4, 5\r\n\r\n",
        ]
    )
    func malformed(text: String) {
        #expect(throws: HTTPParseError.self) { try parse(text) }
    }

    @Test("chunked request bodies are refused rather than half-supported")
    func chunkedRequest() {
        #expect(throws: HTTPParseError.unsupportedTransferEncoding) {
            try parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
        }
    }

    @Test("a body over the limit is refused from the head alone")
    func bodyTooLarge() {
        #expect(throws: HTTPParseError.bodyTooLarge) {
            try parse("POST / HTTP/1.1\r\nContent-Length: 2000\r\n\r\n", maxBody: 1024)
        }
    }

    @Test("a head that never ends is refused once it's too big")
    func headersTooLarge() {
        let endless = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequestParser.maxHeaderBytes + 10)
        #expect(throws: HTTPParseError.headersTooLarge) { try parse(endless) }
    }

    @Test("JSON responses have sorted keys and the OpenAI-style error shape")
    func responses() {
        let error = HTTPResponse.error(404, type: "not_found_error", message: "nope")
        guard case let .data(body) = error.body else {
            Issue.record("expected a data body")
            return
        }
        #expect(String(decoding: body, as: UTF8.self) ==
            #"{"error":{"code":404,"message":"nope","type":"not_found_error"}}"#)
        #expect(error.status == 404)
    }
}
