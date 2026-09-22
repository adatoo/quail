import Foundation

/// Everything about how Quail runs its server that the user can change,
/// persisted as JSON at `Paths.configFile`. The API key itself is
/// deliberately not a property here — see `Keychain.swift` and AGENTS.md
/// ("Secrets (API key, HF token) go in Keychain, never in the JSON").
///
/// `init(from:)` is hand-written (rather than the synthesized one) so that
/// a `config.json` written by an older version of Quail — missing a field
/// added since — decodes with that field's default instead of failing
/// outright. Every property must have a matching case in `init(from:)` and
/// `encode(to:)` be added below when a new one is introduced.
struct Config: Sendable, Equatable, Codable {
    var runtimeID: RuntimeID = .llamaCpp
    var host: String = "127.0.0.1"
    var port: Int = 8080
    var modelsMax: Int = 1
    var apiKeyEnabled: Bool = false
    var openAtLogin: Bool = false
    var autoStartServer: Bool = false
    /// Set once the Models pane (Phase 2 step 7) lets someone relocate the
    /// store; `Paths.resolveModelsDirectory(bookmark:)` turns this back
    /// into a URL. `nil` means "use `Paths.defaultModelsDirectory`".
    var modelsDirectoryBookmark: Data?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case runtimeID, host, port, modelsMax, apiKeyEnabled, openAtLogin, autoStartServer, modelsDirectoryBookmark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config()
        runtimeID = try container.decodeIfPresent(RuntimeID.self, forKey: .runtimeID) ?? fallback.runtimeID
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? fallback.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? fallback.port
        modelsMax = try container.decodeIfPresent(Int.self, forKey: .modelsMax) ?? fallback.modelsMax
        apiKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .apiKeyEnabled) ?? fallback.apiKeyEnabled
        openAtLogin = try container.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? fallback.openAtLogin
        autoStartServer = try container.decodeIfPresent(Bool.self, forKey: .autoStartServer) ?? fallback.autoStartServer
        modelsDirectoryBookmark = try container.decodeIfPresent(Data.self, forKey: .modelsDirectoryBookmark)
            ?? fallback.modelsDirectoryBookmark
    }
}

extension Config {
    /// Reads `config.json`, falling back to defaults if it's missing,
    /// unreadable, or malformed — a corrupt config should never stop Quail
    /// from launching.
    static func load(from url: URL = Paths.configFile) -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    /// Writes `config.json` atomically, creating `Application Support/Quail`
    /// first if needed.
    func save(to url: URL = Paths.configFile) throws {
        try Paths.ensureDirectoriesExist()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
