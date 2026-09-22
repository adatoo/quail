import AppKit
import Foundation
import Observation
import SwiftUI

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

    /// The menu bar icon is always the same bird glyph — only its colour
    /// changes with `ServerController.phase` (Phase 1 step 6: "Icon
    /// states: stopped/starting/running/failed"). An earlier version swapped
    /// to unrelated SF Symbols (a checkmark, a warning triangle) per state,
    /// which read as "the app changed" rather than "the server's status
    /// changed" — a colour on the same glyph reads correctly at a glance
    /// and is how most menu-bar status utilities do this.
    var statusColor: Color {
        switch serverController.phase {
        case .stopped: .gray
        case .starting, .stopping: .yellow
        case .ready: .green
        case .failed: .red
        }
    }

    /// The actual menu bar icon. `MenuBarExtra` renders a plain
    /// `Image(systemName:)` label as an AppKit template image regardless
    /// of any SwiftUI `.foregroundStyle` applied to it — confirmed by
    /// testing it, the bird stayed plain white in every phase. Baking the
    /// colour into the `NSImage` itself and marking it non-template is
    /// the only way to get a real colour onto a status item's icon.
    var menuBarIcon: NSImage {
        let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(statusColor)])
        let image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: statusLabel)?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
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
