import Foundation
import Testing
@testable import QuailServerCore

@Suite("RequestGuard", .timeLimit(.minutes(1)))
struct RequestGuardTests {
    private func request(
        _ method: String = "POST",
        _ target: String = "/models/load",
        host: String? = "127.0.0.1:8080",
        origin: String? = nil,
        extra: [String: String] = [:]
    ) -> HTTPRequest {
        var headers = extra
        if let host {
            headers["host"] = host
        }
        if let origin {
            headers["origin"] = origin
        }
        return HTTPRequest(method: method, target: target, headers: headers, body: Data())
    }

    private func header(_ response: HTTPResponse, _ name: String) -> String? {
        response.headers.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    private func refusal(_ verdict: RequestGuard.Verdict) -> HTTPResponse? {
        if case let .respond(response) = verdict {
            response
        } else {
            nil
        }
    }

    private func proceedsWithOrigin(_ verdict: RequestGuard.Verdict) -> String?? {
        if case let .proceed(origin) = verdict {
            .some(origin)
        } else {
            nil
        }
    }

    @Test("a request with no Origin passes untouched (curl, SDKs, the app)")
    func noOrigin() {
        let guardian = RequestGuard(bindHost: "127.0.0.1")
        #expect(proceedsWithOrigin(guardian.evaluate(request())) == .some(nil))
        #expect(proceedsWithOrigin(guardian.evaluate(request(host: nil))) == .some(nil))
    }

    @Test("a cross-origin request is refused with no CORS headers, GET or POST")
    func foreignOrigin() throws {
        let guardian = RequestGuard(bindHost: "127.0.0.1")
        for method in ["GET", "POST"] {
            let response = try #require(refusal(guardian.evaluate(request(method, origin: "https://evil.example"))))
            #expect(response.status == 403)
            #expect(header(response, "access-control-allow-origin") == nil)
            #expect(header(response, "access-control-allow-credentials") == nil)
        }
    }

    @Test("the null origin (sandboxed frames, file://) is refused")
    func nullOrigin() {
        #expect(refusal(RequestGuard(bindHost: "127.0.0.1").evaluate(request(origin: "null")))?.status == 403)
    }

    @Test("a page this server serves itself (same host and port) is allowed, with no CORS headers")
    func sameOrigin() {
        let guardian = RequestGuard(bindHost: "127.0.0.1")
        let verdict = guardian.evaluate(request(origin: "http://127.0.0.1:8080"))
        #expect(proceedsWithOrigin(verdict) == .some(nil))
        // A different port on the same host is a different origin.
        #expect(refusal(guardian.evaluate(request(origin: "http://127.0.0.1:3000")))?.status == 403)
        // So is another scheme.
        #expect(refusal(guardian.evaluate(request(origin: "https://127.0.0.1:8080")))?.status == 403)
    }

    @Test("an allowed origin gets exactly its own Allow-Origin, Vary, and never credentials")
    func allowedOrigin() {
        let guardian = RequestGuard(bindHost: "127.0.0.1", allowedOrigins: ["http://localhost:3000/"])
        let verdict = guardian.evaluate(request(origin: "http://LOCALHOST:3000"))
        #expect(proceedsWithOrigin(verdict) == .some("http://LOCALHOST:3000"))
        let decorated = guardian.decorate(HTTPResponse(status: 200), origin: "http://LOCALHOST:3000")
        #expect(header(decorated, "access-control-allow-origin") == "http://LOCALHOST:3000")
        #expect(header(decorated, "vary") == "Origin")
        #expect(header(decorated, "access-control-allow-credentials") == nil)
        #expect(refusal(guardian.evaluate(request(origin: "http://localhost:3001")))?.status == 403)
    }

    @Test("* allows any origin, but still by echoing that origin, not *")
    func wildcard() {
        let guardian = RequestGuard(bindHost: "127.0.0.1", allowedOrigins: ["*"])
        #expect(proceedsWithOrigin(guardian.evaluate(request(origin: "https://anything.example"))) ==
            .some("https://anything.example"))
    }

    @Test("a preflight from an allowed origin is answered; from any other it is refused")
    func preflight() throws {
        let guardian = RequestGuard(bindHost: "127.0.0.1", allowedOrigins: ["http://localhost:3000"])
        let ask = request("OPTIONS", "/v1/chat/completions", origin: "http://localhost:3000", extra: [
            "access-control-request-method": "POST",
            "access-control-request-headers": "authorization, content-type",
            "access-control-request-private-network": "true",
        ])
        let response = try #require(refusal(guardian.evaluate(ask)))
        #expect(response.status == 204)
        #expect(header(response, "access-control-allow-origin") == "http://localhost:3000")
        #expect(header(response, "access-control-allow-headers") == "authorization, content-type")
        #expect(header(response, "access-control-allow-methods")?.contains("POST") == true)
        #expect(header(response, "access-control-allow-private-network") == "true")
        #expect(header(response, "access-control-allow-credentials") == nil)

        let foreign = request("OPTIONS", "/v1/chat/completions", origin: "https://evil.example")
        #expect(refusal(guardian.evaluate(foreign))?.status == 403)
    }

    @Test("an OPTIONS with no Origin gets a plain 204")
    func plainOptions() {
        let response = refusal(RequestGuard(bindHost: "127.0.0.1").evaluate(request("OPTIONS", origin: nil)))
        #expect(response?.status == 204)
        #expect(response.flatMap { header($0, "access-control-allow-origin") } == nil)
    }

    @Test("on a loopback bind, a Host that isn't loopback is refused (DNS rebinding), even with a matching Origin")
    func dnsRebinding() {
        let guardian = RequestGuard(bindHost: "127.0.0.1")
        #expect(refusal(guardian.evaluate(request(host: "evil.example:8080")))?.status == 421)
        // The rebinding page's Origin equals its Host, which the same-origin rule alone would accept.
        #expect(refusal(guardian.evaluate(request(host: "evil.example:8080", origin: "http://evil.example:8080")))?
            .status == 421)
        for lookalike in [
            "127.0.0.1.evil.example",
            "localhost.evil.example",
            "notlocalhost",
            "127.0.0.256",
            "128.0.0.1",
        ] {
            #expect(refusal(guardian.evaluate(request(host: lookalike)))?.status == 421, "\(lookalike)")
        }
    }

    @Test("loopback names are all accepted on a loopback bind", arguments: [
        "127.0.0.1", "127.0.0.1:8080", "localhost", "LOCALHOST:9", "[::1]", "[::1]:8080", "127.5.6.7:1",
    ])
    func loopbackHosts(_ host: String) {
        #expect(proceedsWithOrigin(RequestGuard(bindHost: "127.0.0.1").evaluate(request(host: host))) != nil)
    }

    @Test("bound to a LAN address, any Host is fine but a foreign Origin is still refused")
    func lanBind() {
        let guardian = RequestGuard(bindHost: "0.0.0.0")
        #expect(proceedsWithOrigin(guardian.evaluate(request(host: "studio.local:8080"))) == .some(nil))
        #expect(proceedsWithOrigin(guardian.evaluate(request(
            host: "192.168.1.20:8080",
            origin: "http://192.168.1.20:8080"
        ))) == .some(nil))
        #expect(refusal(guardian.evaluate(request(host: "studio.local:8080", origin: "https://evil.example")))?
            .status == 403)
    }

    @Test("origin and host parsing")
    func parsing() {
        #expect(RequestGuard.authority(of: "http://localhost:3000") == "localhost:3000")
        #expect(RequestGuard.authority(of: "https://a.b") == "a.b")
        #expect(RequestGuard.authority(of: "null") == nil)
        #expect(RequestGuard.authority(of: "http://a.b/path") == nil)
        #expect(RequestGuard.authority(of: "ftp://a.b") == nil)
        #expect(RequestGuard.hostname(of: "[::1]:8080") == "::1")
        #expect(RequestGuard.hostname(of: "localhost:8080") == "localhost")
        #expect(RequestGuard.hostname(of: "localhost") == "localhost")
    }

    @Test("--allow-origin is repeatable, in both flag forms")
    func argument() throws {
        let command = try ServerArguments.parse([
            "--models-dir",
            "/m",
            "--allow-origin",
            "http://a:1",
            "--allow-origin=http://b:2",
        ])
        guard case let .run(arguments) = command else { Issue.record("expected run"); return }
        #expect(arguments.allowedOrigins == ["http://a:1", "http://b:2"])
        let none = try ServerArguments.parse(["--models-dir", "/m"])
        guard case let .run(defaults) = none else { Issue.record("expected run"); return }
        #expect(defaults.allowedOrigins.isEmpty)
    }
}
