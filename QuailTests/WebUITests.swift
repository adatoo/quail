import CryptoKit
import Foundation
import JavaScriptCore
import Testing
@testable import Quail
@testable import QuailServerCore

@Suite("Web page", .timeLimit(.minutes(1)))
struct WebUITests {
    private func body(_ response: HTTPResponse) -> String {
        guard case let .data(data) = response.body else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func header(_ response: HTTPResponse, _ name: String) -> String? {
        response.headers.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    /// What sits between `<tag>` and `</tag>` in the served page.
    private func inner(_ tag: String, of html: String) -> String? {
        guard let open = html.range(of: "<\(tag)>"), let close = html.range(of: "</\(tag)>") else { return nil }
        return String(html[open.upperBound ..< close.lowerBound])
    }

    // MARK: serving

    @Test("/ and /index.html serve the page, with no key, while the API behind it still wants one")
    func served() async {
        let harness = RouteHarness(apiKey: "sekret")
        for path in ["/", "/index.html"] {
            let response = await harness.get(path)
            #expect(response.status == 200, "\(path)")
            #expect(header(response, "Content-Type") == "text/html; charset=utf-8")
            #expect(body(response).hasPrefix("<!doctype html>"))
        }
        #expect(await harness.get("/v1/models").status == 401)
        #expect(await harness.get("/props").status == 401)
    }

    @Test("only GET reads the page; the icon request gets an empty answer")
    func methodsAndIcon() async {
        let harness = RouteHarness()
        #expect(await harness.send("/", "{}").status == 405)
        #expect(await harness.get("/favicon.ico").status == 204)
    }

    @Test("--no-webui turns the page off and /props says so")
    func disabled() async throws {
        let off = RouteHarness(webUI: false)
        #expect(await off.get("/").status == 404)
        #expect(await off.get("/index.html").status == 404)
        let on = RouteHarness()
        for (harness, expected) in [(on, true), (off, false)] {
            let response = await harness.get("/props?model=Alpha")
            let json = try #require(JSONSerialization.jsonObject(with: Data(body(response).utf8)) as? [String: Any])
            #expect(json["ui"] as? Bool == expected)
        }
    }

    @Test("a page on another origin, or another host name, can't read it")
    func guarded() async {
        let harness = RouteHarness()
        let foreign = await harness.get("/", headers: ["origin": "http://evil.example", "host": "127.0.0.1:8080"])
        #expect(foreign.status == 403)
        #expect(await harness.get("/", headers: ["host": "evil.example"]).status == 421)
        #expect(await harness.get("/", headers: ["origin": "http://127.0.0.1:8080", "host": "127.0.0.1:8080"])
            .status == 200)
    }

    // MARK: hardening

    @Test("the policy allows this script and this style by hash, and nothing from anywhere else")
    func contentSecurityPolicy() async throws {
        let response = await RouteHarness().get("/")
        let html = body(response)
        let script = try #require(inner("script", of: html))
        let style = try #require(inner("style", of: html))
        func hash(_ text: String) -> String {
            Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
        }
        let policy = try #require(header(response, "Content-Security-Policy"))
        let directives = Set(policy.components(separatedBy: "; "))
        #expect(directives == [
            "default-src 'none'", "script-src 'sha256-\(hash(script))'", "style-src 'sha256-\(hash(style))'",
            "connect-src 'self'", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'",
        ])
        #expect(header(response, "X-Content-Type-Options") == "nosniff")
        #expect(header(response, "Referrer-Policy") == "no-referrer")
        #expect(header(response, "X-Frame-Options") == "DENY")
        #expect(header(response, "Cache-Control") == "no-store")
    }

    @Test("the page has one inline script, one inline style, and loads nothing")
    func selfContained() {
        let html = WebUI.html
        #expect(html.components(separatedBy: "<script").count == 2)
        #expect(html.components(separatedBy: "<style").count == 2)
        for tag in ["<link", "<img", "<iframe", "<object", "<embed", "<form action", "<base", "src=", "href="] {
            #expect(!html.contains(tag), "\(tag)")
        }
        // The policy would block these anyway (no hash covers them); a page that has them is broken.
        #expect(!html.contains(" style=\""))
        #expect(html.range(of: #" on[a-z]+="#, options: .regularExpression) == nil)
    }

    @Test("nothing in the page can turn a model's words into markup or code, or reach another host", arguments: [
        "innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "createContextualFragment", "DOMParser",
        "eval(", "new Function", "setTimeout(\"", "setAttribute(\"style\"", "javascript:", "srcdoc",
        "http://", "https://", "ws://", "//cdn", "importScripts", "XMLHttpRequest", "sendBeacon", "WebSocket",
    ])
    func forbidden(pattern: String) {
        #expect(!WebUI.script.contains(pattern))
        #expect(!WebUI.html.contains(pattern))
    }

    @Test("every fetch goes to a path on this server")
    func onlyRelativeFetches() {
        let script = WebUI.script
        let calls = script.components(separatedBy: "api(").dropFirst()
            .map { String($0.prefix(while: { $0 != "," && $0 != ")" })) }
        #expect(!calls.isEmpty)
        for call in calls where !call.isEmpty && !call.hasPrefix("path") {
            #expect(call.hasPrefix("\"/"), "\(call)")
        }
        #expect(script.components(separatedBy: "fetch(").count == 2)
    }

    @Test("the script is valid JavaScript")
    func parses() throws {
        let context = try #require(JSContext())
        context.setObject(WebUI.script, forKeyedSubscript: "source" as NSString)
        // `new Function` compiles without running, so a syntax error surfaces and nothing else happens.
        _ = context.evaluateScript("new Function(source)")
        #expect(context.exception == nil, "\(String(describing: context.exception))")
    }
}
