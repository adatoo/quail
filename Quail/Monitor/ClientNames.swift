import Foundation

/// What the Activity window calls a client (ADR D-067): the app, named from its `User-Agent` by the Connect list's
/// `userAgents` prefixes, and the machine, "this Mac" or its IP address.
enum ClientNames {
    /// The Connect list, read once.
    static let known = Integration.bundled()

    /// "Claude Code", "curl"; the `User-Agent`'s own first product when no tool claims it ("OpenAI/JS",
    /// "python-httpx"); "Unknown app" when the request had none.
    static func app(agent: String, userAgent: String, integrations: [Integration] = known) -> String {
        let candidates = [userAgent, agent].filter { !$0.isEmpty }.map { $0.lowercased() }
        for integration in integrations {
            for prefix in integration.userAgents ?? [] where !prefix.isEmpty {
                if candidates.contains(where: { $0.hasPrefix(prefix.lowercased()) }) {
                    return integration.name
                }
            }
        }
        switch agent {
        case "": return "Unknown app"
        case "Quail": return "Quail"
        case "Mozilla": return "Browser"
        default: return agent
        }
    }

    /// "this Mac" for a request from this Mac; otherwise its address, or "unknown machine".
    static func machine(_ address: String?) -> String {
        switch address {
        case "local": "this Mac"
        case let address?: address
        case nil: "unknown machine"
        }
    }

    /// "Claude Code · this Mac".
    static func label(_ key: ClientKey, userAgent: String, integrations: [Integration] = known) -> String {
        "\(app(agent: key.agent, userAgent: userAgent, integrations: integrations)) · \(machine(key.address))"
    }
}
