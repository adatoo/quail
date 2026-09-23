import Foundation

/// One tool Quail can help connect to its endpoint — defined as data in
/// `Resources/integrations.json`, so adding a tool is a JSON edit, not code.
/// Every snippet is checked against the tool's own current docs
/// (`docsURL`), never written from memory.
struct Integration: Sendable, Equatable, Identifiable, Decodable {
    enum Category: String, Sendable, Decodable, CaseIterable {
        case codingAgent = "coding-agent"
        case editor
        case chatApp = "chat-app"
        case sdk

        var title: String {
            switch self {
            case .codingAgent: "Coding agents"
            case .editor: "Editors"
            case .chatApp: "Chat apps"
            case .sdk: "Code"
            }
        }
    }

    /// Which of the endpoint's APIs the tool speaks — decides what the
    /// Test button checks.
    enum API: String, Sendable, Decodable {
        case openAIChat = "openai-chat"
        case openAIResponses = "openai-responses"
        case anthropic
    }

    enum Format: String, Sendable, Decodable {
        case json, yaml, toml, shell, text
    }

    let id: String
    let name: String
    let category: Category
    let api: API
    /// Where the snippet goes: a file path, "your shell profile", or a
    /// settings screen — shown as-is.
    let `where`: String
    let format: Format
    /// With `{{baseURL}}` (no trailing slash, no `/v1`), `{{apiKey}}`,
    /// `{{model}}`, `{{host}}`, `{{port}}` placeholders.
    let snippet: String
    let docsURL: URL
    let notes: String?
    /// The smallest model context (tokens) the tool works with — the
    /// Connect tab warns when the chosen model runs smaller (ADR D-020).
    let minContext: Int?
    /// How `quail launch` starts the tool pointed at Quail — `nil` for
    /// tools configured in their own settings screens.
    let launch: LaunchRecipe?

    struct LaunchRecipe: Sendable, Equatable, Decodable {
        let command: String
        let args: [String]
        let env: [String: String]
        /// File name → contents, written to a temp dir (`{{tempDir}}`).
        let files: [String: String]?
        /// Short names for `quail launch` ("claude" for "claude-code").
        let aliases: [String]?
    }

    private struct File: Decodable {
        let integrations: [Integration]
    }

    static func decodeList(from data: Data) throws -> [Integration] {
        try JSONDecoder().decode(File.self, from: data).integrations
    }

    static func bundled(in bundle: Bundle = .main) -> [Integration] {
        guard let url = bundle.url(forResource: "integrations", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return (try? decodeList(from: data)) ?? []
    }
}

/// Fills a snippet's placeholders.
enum SnippetRenderer {
    struct Values: Sendable, Equatable {
        var baseURL: URL
        /// `nil` when the endpoint has no API key; many tools still insist
        /// on a non-empty key, so a harmless stand-in is rendered instead.
        var apiKey: String?
        var model: String
    }

    /// What a snippet shows when the endpoint has no key: llama-server
    /// ignores the header entirely without `--api-key`.
    static let noKeyStandIn = "no-key-needed"

    static func render(_ template: String, with values: Values) -> String {
        var base = values.baseURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let replacements: [String: String] = [
            "{{baseURL}}": base,
            "{{apiKey}}": values.apiKey.flatMap { $0.isEmpty ? nil : $0 } ?? noKeyStandIn,
            "{{model}}": values.model,
            "{{host}}": values.baseURL.host() ?? "127.0.0.1",
            "{{port}}": values.baseURL.port.map(String.init) ?? "8080",
        ]
        return replacements.reduce(template) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    /// Any `{{…}}` left unfilled — a template typo. Used by tests.
    static func unfilledPlaceholders(in rendered: String) -> [String] {
        let pattern = /\{\{[^}]*\}\}/
        return rendered.matches(of: pattern).map { String($0.output) }
    }
}
