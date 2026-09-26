import Foundation
import Testing
@testable import Quail

@Suite("Connect")
struct ConnectTests {
    private static let values = SnippetRenderer.Values(
        baseURL: URL(string: "http://127.0.0.1:8080")!, apiKey: "k3y", model: "Qwen3-8B-Q4_K_M"
    )

    @Test("render fills every placeholder; a missing key becomes a harmless stand-in")
    func render() {
        let template = "{{baseURL}}/v1 {{apiKey}} {{model}} {{host}}:{{port}}"
        #expect(SnippetRenderer.render(template, with: Self.values)
            == "http://127.0.0.1:8080/v1 k3y Qwen3-8B-Q4_K_M 127.0.0.1:8080")
        var noKey = Self.values
        noKey.apiKey = nil
        #expect(SnippetRenderer.render("{{apiKey}}", with: noKey) == SnippetRenderer.noKeyStandIn)
        #expect(SnippetRenderer.unfilledPlaceholders(in: "a {{typo}} b") == ["{{typo}}"])
        #expect(SnippetRenderer.render("{{contextSize}} {{maxOutput}}", with: Self.values) == "32768 8192")
        var small = Self.values
        small.contextSize = 8192
        #expect(SnippetRenderer.render("{{contextSize}} {{maxOutput}}", with: small) == "8192 2048")
    }

    @Test("every bundled integration decodes and renders with no leftover placeholders")
    func bundledIntegrations() {
        let integrations = Integration.bundled()
        #expect(integrations.count >= 10)
        #expect(Set(integrations.map(\.id)).count == integrations.count)
        for integration in integrations {
            let rendered = SnippetRenderer.render(integration.snippet, with: Self.values)
            #expect(SnippetRenderer.unfilledPlaceholders(in: rendered).isEmpty, "\(integration.id)")
            #expect(rendered.contains("127.0.0.1"), "\(integration.id) never uses the base URL")
            if integration.format == .json {
                // JSON snippets must be valid JSON once filled in (a
                // fragment wrapped in braces, if it isn't a whole object).
                let text = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
                let wrapped = text.hasPrefix("{") ? text : "{\(text)}"
                #expect((try? JSONSerialization.jsonObject(with: Data(wrapped.utf8))) != nil, "\(integration.id)")
            }
        }
    }

    @Test("EndpointAddress: loopback for this Mac, LAN address for other devices, nothing for loopback-only")
    func endpointAddress() {
        #expect(EndpointAddress.localBase(host: "0.0.0.0", port: 8080)?.absoluteString == "http://127.0.0.1:8080")
        #expect(EndpointAddress.localBase(host: "127.0.0.1", port: 9000)?.absoluteString == "http://127.0.0.1:9000")
        #expect(EndpointAddress.networkBase(host: "0.0.0.0", port: 8080, lanAddress: "192.168.1.20")?
            .absoluteString == "http://192.168.1.20:8080")
        #expect(EndpointAddress.networkBase(host: "127.0.0.1", port: 8080, lanAddress: "192.168.1.20") == nil)
        #expect(EndpointAddress.networkBase(host: "0.0.0.0", port: 8080, lanAddress: nil) == nil)
    }

    @Test("ConnectionTester surfaces the server's own error message")
    func errorMessage() {
        let body = Data(#"{"error":{"message":"Invalid API Key","type":"authentication_error","code":401}}"#.utf8)
        #expect(ConnectionTester.errorMessage(in: body) == "Invalid API Key")
        #expect(ConnectionTester.errorMessage(in: Data("not json".utf8)) == nil)
    }
}
