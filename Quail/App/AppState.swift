import Foundation
import Observation

/// Observable root of the app's UI state. Owns the persisted `Config`, the
/// `ServerController` state machine, and translates between the two — the
/// menu and Settings only ever talk to this, never to `ServerController`
/// or `Keychain` directly.
///
/// Every dependency is injected with a real default, so tests can swap in
/// `FakeRuntime` and `FakeSecretStore` and a scratch `configURL` — see
/// AGENTS.md ("tests using a fake Runtime where a process would otherwise
/// be needed") and `AppStateTests.swift`.
@MainActor
@Observable
final class AppState {
    private(set) var config: Config
    let serverController: ServerController

    /// Exposed (not just handed to `ServerController`) because the Ping
    /// sheet and Logs window both need to talk to the same runtime/log
    /// store `ServerController` is driving — see `PingSheet` and
    /// `LogsWindow`.
    let runtime: any Runtime
    let logStore: LogStore

    private let configURL: URL
    private let secretStore: any SecretStore

    private static let apiKeyAccount = "llamaCppAPIKey"

    init(
        config: Config = .load(),
        configURL: URL = Paths.configFile,
        secretStore: any SecretStore = Keychain(),
        runtime: any Runtime = LlamaCppRuntime(executableURL: Paths.llamaServerExecutable),
        logStore: LogStore = LogStore()
    ) {
        self.config = config
        self.configURL = configURL
        self.secretStore = secretStore
        self.runtime = runtime
        self.logStore = logStore
        serverController = ServerController(runtime: runtime, logStore: logStore)
    }

    // MARK: - Server state, as the menu wants to show it

    var statusLabel: String {
        switch serverController.phase {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .ready: "Running"
        case .stopping: "Stopping…"
        case .failed: "Failed"
        }
    }

    /// SF Symbol name for the menu bar icon (Phase 1 step 6: "Icon states:
    /// stopped/starting/running/failed"). `.stopping` reuses the starting
    /// glyph — both are transient, in-between states.
    var statusSymbolName: String {
        switch serverController.phase {
        case .stopped: "bird"
        case .starting, .stopping: "bird.fill"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var canStart: Bool {
        serverController.phase == .stopped || serverController.phase.isFailed
    }

    var canStop: Bool {
        serverController.phase == .ready || serverController.phase == .starting
    }

    var baseURL: URL? {
        serverController.baseURL
    }

    func start() async {
        await serverController.start(config: endpointConfig())
    }

    func stop() async {
        await serverController.stop()
    }

    // MARK: - Endpoint settings

    func setHost(_ host: String) {
        guard host != config.host else { return }
        config.host = host
        persist()
    }

    func setPort(_ port: Int) {
        guard port != config.port else { return }
        config.port = port
        persist()
    }

    /// Whether `--api-key` is passed to the runtime. Off by default,
    /// matching Postgres.app's "trust" default on loopback — see ADR
    /// D-010.
    func setAPIKeyEnabled(_ enabled: Bool) {
        guard enabled != config.apiKeyEnabled else { return }
        if enabled {
            try? secretStore.set(Self.generateAPIKey(), account: Self.apiKeyAccount)
        } else {
            try? secretStore.delete(account: Self.apiKeyAccount)
        }
        config.apiKeyEnabled = enabled
        persist()
    }

    /// The current API key, if the toggle is on and one is stored. `nil`
    /// otherwise — including if Keychain access unexpectedly fails, in
    /// which case the runtime simply launches without `--api-key` rather
    /// than crashing.
    var apiKey: String? {
        guard config.apiKeyEnabled else { return nil }
        return try? secretStore.get(account: Self.apiKeyAccount)
    }

    func regenerateAPIKey() {
        guard config.apiKeyEnabled else { return }
        try? secretStore.set(Self.generateAPIKey(), account: Self.apiKeyAccount)
    }

    // MARK: - Open at login

    func setOpenAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        config.openAtLogin = LoginItem.isEnabled // reflect the actual outcome, not the request
        persist()
    }

    private func endpointConfig() -> EndpointConfig {
        EndpointConfig(
            host: config.host,
            port: config.port,
            apiKey: apiKey,
            modelsDirectory: Paths.defaultGGUFDirectory,
            modelsMax: config.modelsMax
        )
    }

    private func persist() {
        try? config.save(to: configURL)
    }

    /// 32 random bytes, hex-encoded — the same shape as llama-server's own
    /// `--api-key` documentation examples.
    private static func generateAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
