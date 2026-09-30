import Foundation
import Testing
@testable import QuailServerCore

@Suite("Request client (ADR D-067)")
struct RequestClientTests {
    @Test("the app is the User-Agent's first product, without a numeric version", arguments: [
        ("claude-cli/2.1.3 (external, cli)", "claude-cli"),
        ("OpenAI/Python 1.51.0", "OpenAI/Python"),
        ("OpenAI/JS 4.67.3", "OpenAI/JS"),
        ("curl/8.7.1", "curl"),
        ("codex_cli_rs/0.40.0 (Mac OS 15.6.0; arm64) iTerm.app/3.5", "codex_cli_rs"),
        ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", "Mozilla"),
        ("Quail/114 CFNetwork/1568 Darwin/25.0.0", "Quail"),
        ("python-requests/2.32.3", "python-requests"),
        ("aider", "aider"),
        ("tool/", "tool"),
        ("", ""),
    ])
    func agent(userAgent: String, expected: String) {
        #expect(RequestClient.agent(userAgent: userAgent) == expected)
    }

    @Test("this Mac is \"local\"; other addresses are kept, a mapped IPv4 address written plainly", arguments: [
        ("127.0.0.1", "local"),
        ("127.0.1.1", "local"),
        ("::1", "local"),
        ("::1%lo0", "local"),
        ("::ffff:127.0.0.1", "local"),
        ("192.168.1.20", "192.168.1.20"),
        ("::ffff:192.168.1.20", "192.168.1.20"),
        ("fe80::1c2a:5bff:fe00:1%en0", "fe80::1c2a:5bff:fe00:1"),
    ] as [(String, String)])
    func address(peer: String, expected: String) {
        #expect(RequestClient.address(peer: peer) == expected)
    }

    @Test("an unknown peer has no address")
    func noPeer() {
        #expect(RequestClient.address(peer: nil) == nil)
        #expect(RequestClient.address(peer: "") == nil)
    }

    @Test("read from a request: the header is case-insensitive, and a long User-Agent is cut to 160 characters")
    func fromRequest() {
        let long = "claude-cli/2.1.3 " + String(repeating: "x", count: 300)
        let request = HTTPRequest(
            method: "POST", target: "/v1/messages", headers: ["user-agent": long], body: Data(), peer: "::1"
        )
        let client = RequestClient(request)
        #expect(client.agent == "claude-cli")
        #expect(client.userAgent.count == 160)
        #expect(client.address == "local")
        let bare = RequestClient(HTTPRequest(method: "GET", target: "/", headers: [:], body: Data()))
        #expect(bare == RequestClient(agent: "", userAgent: "", address: nil))
    }
}
