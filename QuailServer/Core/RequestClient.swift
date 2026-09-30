import Foundation

/// Who sent a request, as far as the server can tell (ADR D-067): the app, from its `User-Agent`, and the machine, from
/// the connection's address. Every client shares one API key (D-039), so these are the only clues. They're kept in
/// memory for `GET /slots` (the app's Activity window) while the server runs, and never logged.
public struct RequestClient: Sendable, Equatable {
    /// The `User-Agent`'s first product without a numeric version: "claude-cli", "OpenAI/Python", "curl"; empty when
    /// the request had none.
    public let agent: String
    /// The whole `User-Agent`, cut to 160 characters.
    public let userAgent: String
    /// "local" for this Mac, otherwise the client's IP address; nil when the connection didn't say.
    public let address: String?

    /// One client: an app on a machine. Requests from it share a line in the Activity window's clients.
    public struct Key: Hashable, Sendable {
        public let agent: String
        public let address: String?
    }

    public var key: Key {
        Key(agent: agent, address: address)
    }

    /// A request whose sender isn't known (tests, internal callers).
    public static let unknown = RequestClient(agent: "", userAgent: "", address: nil)

    public init(agent: String, userAgent: String, address: String?) {
        self.agent = agent
        self.userAgent = userAgent
        self.address = address
    }

    init(_ request: HTTPRequest) {
        let userAgent = request.header("user-agent")?.trimmingCharacters(in: .whitespaces) ?? ""
        self.init(
            agent: Self.agent(userAgent: userAgent),
            userAgent: String(userAgent.prefix(160)),
            address: Self.address(peer: request.peer)
        )
    }

    /// "claude-cli/2.1.3 (external, cli)" → "claude-cli"; "OpenAI/Python 1.51.0" → "OpenAI/Python" (its "version" is a
    /// word, so it names the SDK); "curl/8.7.1" → "curl".
    static func agent(userAgent: String) -> String {
        guard let first = userAgent.split(separator: " ", maxSplits: 1).first else { return "" }
        if let slash = first.firstIndex(of: "/"), first[first.index(after: slash)...].first?.isNumber ?? true {
            return String(first[..<slash].prefix(60))
        }
        return String(first.prefix(60))
    }

    /// "local" for a loopback address (127.0.0.0/8, `::1`, or IPv4 loopback mapped into IPv6); a mapped IPv4 address
    /// written as IPv4; an interface suffix (`%lo0`) dropped.
    static func address(peer: String?) -> String? {
        guard var peer, !peer.isEmpty else { return nil }
        if let percent = peer.firstIndex(of: "%") {
            peer = String(peer[..<percent])
        }
        let lowered = peer.lowercased()
        if lowered == "::1" || lowered == "localhost" || lowered.hasPrefix("127.") || lowered.hasPrefix("::ffff:127.") {
            return "local"
        }
        if lowered.hasPrefix("::ffff:"), lowered.contains(".") {
            return String(peer.dropFirst("::ffff:".count))
        }
        return peer
    }
}
