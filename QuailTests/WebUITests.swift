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
            "connect-src 'self'", "img-src data:", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'",
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

    @Test("the app's ticket is exchanged for the key, and the page forgets it; the exchange is open, the ticket is not")
    func signInWithTicket() async {
        let script = WebUI.script
        let replace = script.range(of: "window.history.replaceState")
        let exchange = script.range(of: "\"/auth/exchange\"")
        #expect(replace != nil && exchange != nil)
        if let replace, let exchange {
            #expect(replace.lowerBound < exchange.lowerBound, "the fragment goes before the network call")
        }

        let harness = RouteHarness(apiKey: "k")
        #expect(await harness.send("/auth/ticket", "").status == 401)
        let issued = await harness.json("/auth/ticket", "", headers: ["authorization": "Bearer k"])
        let ticket = issued.json["ticket"] as? String ?? ""
        #expect(!ticket.isEmpty)
        // Another origin can't trade it.
        let foreign = await harness.json(
            "/auth/exchange", #"{"ticket":"\#(ticket)"}"#,
            headers: ["origin": "http://evil.example", "host": "127.0.0.1:8080"]
        )
        #expect(foreign.status == 403)
        let mine = await harness.json(
            "/auth/exchange", #"{"ticket":"\#(ticket)"}"#,
            headers: ["origin": "http://127.0.0.1:8080", "host": "127.0.0.1:8080"]
        )
        #expect(mine.status == 200 && mine.json["key"] as? String == "k")
        #expect(await harness.json("/auth/exchange", #"{"ticket":"\#(ticket)"}"#).status == 401)
        #expect(await harness.get("/auth/exchange").status == 405)

        let open = RouteHarness()
        let noKey = await open.json("/auth/ticket", "")
        let openTicket = noKey.json["ticket"] as? String ?? ""
        let traded = await open.json("/auth/exchange", #"{"ticket":"\#(openTicket)"}"#)
        #expect(traded.status == 200 && traded.json["key"] is NSNull)
    }

    // MARK: Markdown

    /// `MD.parse(source)` run in JavaScriptCore, as JSON.
    private func parse(_ source: String) throws -> Any {
        let context = try #require(JSContext())
        context.evaluateScript(WebUI.markdown)
        context.setObject(source, forKeyedSubscript: "source" as NSString)
        let json = try #require(context.evaluateScript("JSON.stringify(MD.parse(source))")?.toString())
        #expect(context.exception == nil, "\(String(describing: context.exception))")
        return try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    private func types(_ tree: Any) -> [String] {
        ((tree as? [[String: Any]]) ?? []).compactMap { $0["t"] as? String }
    }

    @Test("Markdown blocks: headings, paragraphs, fences, quotes, lists, tables, rules and maths")
    func markdownBlocks() throws {
        let tree = try parse("""
        # Title
        Some *text* and **bold** with `code`.
        Next line.

        ```swift
        let x = 1
        ```

        > quoted

        - one
        - two
          - nested

        1. first
        2. second

        | a | b |
        |:--|--:|
        | 1 | 2 |

        ---

        $$
        x^2
        $$
        """)
        #expect(types(tree) == ["h", "p", "code", "quote", "list", "list", "table", "hr", "math"])
        let blocks = try #require(tree as? [[String: Any]])
        #expect(blocks[2]["lang"] as? String == "swift" && blocks[2]["text"] as? String == "let x = 1")
        #expect(blocks[5]["ordered"] as? Bool == true)
        let items = try #require(blocks[4]["items"] as? [[[String: Any]]])
        #expect(items.count == 2)
        #expect(types(items[1]) == ["p", "list"]) // the nested list belongs to the second item
        #expect(blocks[6]["align"] as? [String] == ["left", "right"])
        #expect(blocks[8]["text"] as? String == "x^2")
        let paragraph = try #require(blocks[1]["inline"] as? [[String: Any]])
        #expect(paragraph.compactMap { $0["t"] as? String } == [
            "text",
            "em",
            "text",
            "strong",
            "text",
            "code",
            "text",
            "br",
            "text",
        ])
    }

    @Test("Markdown inline: links, strikethrough, escapes, intraword underscores, dollars in prose")
    func markdownInline() throws {
        let tree =
            try parse(#"[site](https://example.org) ~~gone~~ \*literal\* snake_case_name costs $5 and $10 $x^2$"#)
        let inline = try #require((tree as? [[String: Any]])?.first?["inline"] as? [[String: Any]])
        let kinds = inline.compactMap { $0["t"] as? String }
        #expect(kinds == ["link", "text", "del", "text", "math"])
        #expect(inline[0]["href"] as? String == "https://example.org")
        let text = inline.compactMap { $0["text"] as? String }.joined()
        #expect(text.contains("*literal*") && text.contains("snake_case_name") && text.contains("$5 and $10"))
    }

    @Test("hostile Markdown stays text: HTML is never parsed, and only http(s) and mailto links survive")
    func markdownHostile() throws {
        let tree =
            try parse(
                #"<img src=x onerror=alert(1)> <script>alert(1)</script> [x](javascript:alert(1)) [y](data:text/html,hi)"#
            )
        let inline = try #require((tree as? [[String: Any]])?.first?["inline"] as? [[String: Any]])
        #expect((inline.first?["text"] as? String)?.hasPrefix("<img src=x onerror=alert(1)>") == true)
        let context = try #require(JSContext())
        context.evaluateScript(WebUI.markdown)
        for href in [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "data:text/html,hi",
            "/models/unload",
            "//evil.example",
            "vbscript:x",
        ] {
            context.setObject(href, forKeyedSubscript: "href" as NSString)
            #expect(context.evaluateScript("MD.safeHref(href)")?.isNull == true, "\(href)")
        }
        for href in ["https://example.org/a?b=c", "http://localhost:8080", "mailto:someone@example.org"] {
            context.setObject(href, forKeyedSubscript: "href" as NSString)
            #expect(context.evaluateScript("MD.safeHref(href)")?.toString() == href)
        }
        // Parsing never throws, whatever the input.
        for odd in [
            "```",
            "* ",
            "|",
            "|-|",
            "> ",
            "[",
            "](",
            "$$",
            "**",
            "~~~\n",
            "1.",
            String(repeating: "*", count: 500),
        ] {
            _ = try parse(odd)
        }
    }

    @Test("the model list says each model's format, so the page knows which settings apply")
    func modelFormat() async throws {
        let response = await RouteHarness().get("/v1/models")
        let json = try #require(JSONSerialization.jsonObject(with: Data(body(response).utf8)) as? [String: Any])
        let first = try #require((json["data"] as? [[String: Any]])?.first)
        #expect(first["format"] as? String == "gguf")
    }

    @Test("/sw.js retires the service worker llama.cpp's page left on this origin, and needs no key")
    func serviceWorkerKillSwitch() async {
        let harness = RouteHarness(apiKey: "k")
        for path in ["/sw.js", "/service-worker.js"] {
            let response = await harness.get(path)
            #expect(response.status == 200, "\(path)")
            #expect(header(response, "Content-Type") == "application/javascript; charset=utf-8")
            #expect(header(response, "Cache-Control") == "no-store")
            let script = body(response)
            for needed in ["skipWaiting", "caches.delete", "registration.unregister", "client.navigate"] {
                #expect(script.contains(needed), "\(needed)")
            }
        }
        #expect(await RouteHarness(webUI: false).get("/sw.js").status == 404)
        for pattern in ["http://", "https://", "importScripts", "eval(", "fetch("] {
            #expect(!WebUI.serviceWorkerKillSwitch.contains(pattern), "\(pattern)")
        }
        // The page itself removes any registration it finds, in case the worker was already gone.
        #expect(WebUI.script.contains("getRegistrations()") && WebUI.script.contains("unregister()"))
    }
}
