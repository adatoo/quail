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
    /// On by default (ADR D-039): with no key, any web page you open could drive the runtime
    /// (llama-server answers every origin). Turn it off in Settings → Endpoint.
    var apiKeyEnabled: Bool = true
    /// Whether the on-by-default rule has been applied to this config. A `config.json` written
    /// before D-039 has `apiKeyEnabled: false` because that was the default, not a choice, so it's
    /// switched on once; after that the setting is the user's.
    var apiKeyDefaultApplied: Bool = true
    var openAtLogin: Bool = false
    var autoStartServer: Bool = false
    /// Set once the Models pane (Phase 2 step 7) lets someone relocate the
    /// store; `Paths.resolveModelsDirectory(bookmark:)` turns this back
    /// into a URL. `nil` means "use `Paths.defaultModelsDirectory`".
    var modelsDirectoryBookmark: Data?
    /// The GGUF whose `presets.ini` section gets `load-on-startup = true`
    /// (ADR D-017) — confirmed against the real vendored binary: router
    /// mode loads that one model immediately at startup, with no client
    /// request needed, unlike every other preset (which stays `unloaded`
    /// until a Load click or a request names it). `nil` means "load
    /// nothing automatically", today's behaviour. Set/cleared via
    /// `AppState.setDefaultModel`; cleared automatically if the model is
    /// deleted.
    var defaultModelID: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case runtimeID, host, port, modelsMax, apiKeyEnabled, apiKeyDefaultApplied, openAtLogin, autoStartServer,
             modelsDirectoryBookmark,
             defaultModelID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config()
        runtimeID = try container.decodeIfPresent(RuntimeID.self, forKey: .runtimeID) ?? fallback.runtimeID
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? fallback.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? fallback.port
        modelsMax = try container.decodeIfPresent(Int.self, forKey: .modelsMax) ?? fallback.modelsMax
        apiKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .apiKeyEnabled) ?? fallback.apiKeyEnabled
        // Absent means the file predates the on-by-default rule.
        apiKeyDefaultApplied = try container.decodeIfPresent(Bool.self, forKey: .apiKeyDefaultApplied) ?? false
        openAtLogin = try container.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? fallback.openAtLogin
        autoStartServer = try container.decodeIfPresent(Bool.self, forKey: .autoStartServer) ?? fallback.autoStartServer
        modelsDirectoryBookmark = try container.decodeIfPresent(Data.self, forKey: .modelsDirectoryBookmark)
            ?? fallback.modelsDirectoryBookmark
        defaultModelID = try container.decodeIfPresent(String.self, forKey: .defaultModelID) ?? fallback.defaultModelID
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
