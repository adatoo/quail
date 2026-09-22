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
    let modelStore: ModelStore

    private let configURL: URL
    private let secretStore: any SecretStore

    private static let apiKeyAccount = "llamaCppAPIKey"
    private static let hfTokenAccount = "huggingFaceToken"

    /// - Parameter modelsRootURL: overrides `ModelStore`'s root — tests
    ///   pass a scratch temp directory so they never touch the real
    ///   `~/Library/Application Support/Quail/Models`. Production leaves
    ///   this `nil`, which resolves `config.modelsDirectoryBookmark` (if
    ///   the store's been relocated) or falls back to
    ///   `Paths.defaultModelsDirectory`. This can't just be another
    ///   defaulted `ModelStore` parameter: its default would need
    ///   `config`, and default-argument expressions can't reference
    ///   another parameter.
    init(
        config: Config = .load(),
        configURL: URL = Paths.configFile,
        secretStore: any SecretStore = Keychain(),
        runtime: any Runtime = LlamaCppRuntime(executableURL: Paths.llamaServerExecutable),
        logStore: LogStore = LogStore(),
        modelsRootURL: URL? = nil
    ) {
        self.config = config
        self.configURL = configURL
        self.secretStore = secretStore
        self.runtime = runtime
        self.logStore = logStore
        let resolvedRoot = modelsRootURL
            ?? Paths.resolveModelsDirectory(bookmark: config.modelsDirectoryBookmark)
            ?? Paths.defaultModelsDirectory
        modelStore = ModelStore(rootURL: resolvedRoot)
        serverController = ServerController(runtime: runtime, logStore: logStore)
        apiKey = config.apiKeyEnabled ? try? secretStore.get(account: Self.apiKeyAccount) : nil
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
        // Best-effort: if the store can't be created or presets.ini can't
        // be written (e.g. a relocated store's volume is unmounted), the
        // server itself will fail to bind and HealthProbe's timeout
        // surfaces that as .failed — there's no separate failure path for
        // this yet.
        try? modelStore.ensureDirectoriesExist()
        try? modelStore.regeneratePresets(catalog: modelStore.loadCatalog())
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
            let newKey = Self.generateAPIKey()
            try? secretStore.set(newKey, account: Self.apiKeyAccount)
            apiKey = newKey
        } else {
            try? secretStore.delete(account: Self.apiKeyAccount)
            apiKey = nil
        }
        config.apiKeyEnabled = enabled
        persist()
    }

    /// The current API key, if the toggle is on and one is stored. `nil`
    /// otherwise — including if Keychain access unexpectedly fails, in
    /// which case the runtime simply launches without `--api-key` rather
    /// than crashing.
    ///
    /// A real stored property, kept in sync with the Keychain by every
    /// method below, rather than a computed read-through to
    /// `secretStore` — `@Observable` only tracks stored-property access,
    /// so a computed pass-through here meant `regenerateAPIKey()` updated
    /// the Keychain correctly but SwiftUI had no signal that anything had
    /// changed, and `SettingsView` kept showing the old value. Found via
    /// manual testing: clicking "Regenerate" visibly did nothing.
    private(set) var apiKey: String?

    func regenerateAPIKey() {
        guard config.apiKeyEnabled else { return }
        let newKey = Self.generateAPIKey()
        try? secretStore.set(newKey, account: Self.apiKeyAccount)
        apiKey = newKey
    }

    /// Sets a user-chosen API key directly, rather than a random one —
    /// e.g. to match a key some other tool already expects. A no-op if
    /// the toggle is off (mirrors `regenerateAPIKey`) or if `key` is
    /// empty once trimmed; use the toggle itself to actually clear the
    /// key.
    func setAPIKey(_ key: String) {
        guard config.apiKeyEnabled else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? secretStore.set(trimmed, account: Self.apiKeyAccount)
        apiKey = trimmed
    }

    // MARK: - Hugging Face token

    /// A user's HF access token, for `HFDownloader` to send as
    /// `Authorization: Bearer` when downloading from a gated repo — see
    /// docs/ARCHITECTURE.md §6 ("Gated repos take a user-supplied HF
    /// token stored in Keychain"). No Settings UI reads or writes this
    /// yet; it lands with Phase 2 step 7's Models pane, the first thing
    /// that actually needs to prompt for one.
    ///
    /// Deliberately a computed pass-through to `secretStore`, unlike
    /// `apiKey` above — there's no view observing this yet, so the
    /// `@Observable` reactivity problem `apiKey` hit doesn't apply here.
    /// If a future UI binds to this directly, learn from that: give it a
    /// real stored property, updated explicitly by whatever sets it,
    /// rather than reading through on every access.
    var hfToken: String? {
        try? secretStore.get(account: Self.hfTokenAccount)
    }

    func setHFToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? secretStore.set(trimmed, account: Self.hfTokenAccount)
    }

    func clearHFToken() {
        try? secretStore.delete(account: Self.hfTokenAccount)
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
            modelsDirectory: modelStore.ggufDirectory,
            modelsMax: config.modelsMax,
            presetsFile: modelStore.presetsFile
        )
    }

    private func persist() {
        try? config.save(to: configURL)
    }

    /// 16 random bytes, hex-encoded (128 bits of entropy — plenty for a
    /// secret whose job is deterring casual access on a loopback/LAN
    /// endpoint, see ADR D-010, not resisting a nation-state). Previously
    /// 32 bytes (64 hex characters): needlessly long for that threat
    /// model and awkward to read, select, or copy — shortened per user
    /// feedback.
    private static func generateAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
