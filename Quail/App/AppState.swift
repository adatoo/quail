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

    /// Swappable only via `relocateModelsDirectory` — the store root can
    /// move (docs/ARCHITECTURE.md §6: "relocatable; path stored as a
    /// bookmark") without restarting the app.
    private(set) var modelStore: ModelStore

    /// The in-flight download the Models pane observes. Owns its own
    /// `HFDownloader` by default; tests inject one pointed at a stub
    /// session.
    let installs: ModelInstallController

    private let configURL: URL
    private let secretStore: any SecretStore
    let catalogLocations: Catalog.Locations

    /// The curated download list, bundled ⊕ weekly-refresh cache ⊕
    /// user-added repos — see `Catalog.swift`. A stored property, not a
    /// computed read of the files on every access, for the same reason
    /// `apiKey` is: whatever UI observes it (step 7's Models pane) needs
    /// `@Observable` to see changes, and every mutation path below
    /// re-reads it explicitly after writing.
    private(set) var catalog: Catalog

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
    /// - Parameter catalogLocations: overrides where the catalog's three
    ///   sources live — tests pass a scratch directory so nothing reads
    ///   or writes the real `~/Library/Application Support/Quail`.
    init(
        config: Config = .load(),
        configURL: URL = Paths.configFile,
        secretStore: any SecretStore = Keychain(),
        runtime: any Runtime = LlamaCppRuntime(executableURL: Paths.llamaServerExecutable),
        logStore: LogStore = LogStore(),
        modelsRootURL: URL? = nil,
        catalogLocations: Catalog.Locations = .default
    ) {
        self.config = config
        self.configURL = configURL
        self.secretStore = secretStore
        self.runtime = runtime
        self.logStore = logStore
        self.catalogLocations = catalogLocations
        catalog = Catalog.current(locations: catalogLocations)
        let resolvedRoot = modelsRootURL
            ?? Paths.resolveModelsDirectory(bookmark: config.modelsDirectoryBookmark)
            ?? Paths.defaultModelsDirectory
        let store = ModelStore(rootURL: resolvedRoot)
        modelStore = store
        // So `Models/gguf` exists to drop a file into even before the
        // first Start — `start()` alone used to be the only thing that
        // created it, which meant a hand-placed model (Phase 1's own
        // "Done when") needed one earlier, model-less Start just to
        // create the folder. Now that a model-less Start is refused
        // outright (`canStart`/`hasServableModel`, below), that chicken-
        // and-egg would otherwise be permanent.
        try? store.ensureDirectoriesExist()
        installs = ModelInstallController(modelStore: store)
        serverController = ServerController(runtime: runtime, logStore: logStore)
        apiKey = config.apiKeyEnabled ? try? secretStore.get(account: Self.apiKeyAccount) : nil
        hfToken = try? secretStore.get(account: Self.hfTokenAccount)
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

    /// Whether at least one GGUF is on disk and installable as a router
    /// preset — only GGUF counts, since nothing can serve an MLX model
    /// until Phase 3. Deliberately computed, not cached: it reads the
    /// same disk scan `installedGGUFFiles()` already does for
    /// `regeneratePresets`/`refreshedCatalog`, so there's one source of
    /// truth and no cache to keep in sync across install/delete/relocate
    /// — a hand-placed model (Phase 1's own "Done when") is picked up
    /// the same way as one Quail downloaded itself.
    var hasServableModel: Bool {
        !modelStore.installedGGUFFiles().isEmpty
    }

    var canStart: Bool {
        (serverController.phase == .stopped || serverController.phase.isFailed) && hasServableModel
    }

    var canStop: Bool {
        serverController.phase == .ready || serverController.phase == .starting
    }

    /// Which `SettingsView` tab is showing. Plain UI state, not
    /// persisted — it lives here rather than as `SettingsView`'s own
    /// `@State` only because the menu (`MenuView`'s "Add model…" item,
    /// shown when `hasServableModel` is false) needs to steer the
    /// Settings window to the Models tab before `openSettings()` opens
    /// it; SwiftUI's `openSettings` action takes no arguments.
    var settingsTab: SettingsTab = .general

    var baseURL: URL? {
        serverController.baseURL
    }

    func start() async {
        // Guards callers other than the menu (the menu disables the
        // button via canStart, which is the same check) — starting the
        // router with no preset section is a server that binds and does
        // nothing useful, not a real failure ServerController could
        // report.
        guard hasServableModel else { return }
        // Best-effort: if the store can't be created or presets.ini can't
        // be written (e.g. a relocated store's volume is unmounted), the
        // server itself will fail to bind and HealthProbe's timeout
        // surfaces that as .failed — there's no separate failure path for
        // this yet.
        try? modelStore.ensureDirectoriesExist()
        // Reconcile the catalog with the disk (hand-placed models gain
        // rows, deleted ones lose them) and set each model's per-device
        // context size from FitEstimator before generating presets —
        // Phase 2 step 4's deferred wiring. Reads device facts fresh
        // every Start (free RAM changes; so should the verdicts).
        let refreshed = modelStore.refreshedCatalog(
            device: DeviceInfo.current(),
            ggufRuntime: config.runtimeID,
            bandwidthTable: ChipBandwidthTable.loadFromBundle()
        )
        try? modelStore.saveCatalog(refreshed)
        try? modelStore.regeneratePresets(catalog: refreshed)
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
    /// token stored in Keychain").
    ///
    /// A real stored property kept in sync by the setters below, for the
    /// reason `apiKey` learned in PR 13: the Models pane binds to this,
    /// and a computed Keychain read-through would make edits invisible
    /// to `@Observable`.
    private(set) var hfToken: String?

    func setHFToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? secretStore.set(trimmed, account: Self.hfTokenAccount)
        hfToken = trimmed
    }

    func clearHFToken() {
        try? secretStore.delete(account: Self.hfTokenAccount)
        hfToken = nil
    }

    // MARK: - Catalog

    /// Adds a user-pasted repo as an uncurated catalog entry
    /// (docs/IMPLEMENTATION_PLAN.md step 6: "user-added repo URLs become
    /// uncurated entries"). `format` is resolved by whatever UI collected
    /// this — step 7's "Add model…" sheet queries the Hub before
    /// confirming a paste, so it can say `.gguf`/`.mlxSafetensors`; `nil`
    /// (an entry added by an older caller or a CLI-side affordance)
    /// leaves both variants unset, and the picker shows the row without
    /// badges until it is either removed or replaced by a curated one.
    /// No-ops on a repo already present in the curated list or in the
    /// user list.
    func addUserCatalogRepo(_ repo: String, format: ModelFormat? = nil) {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entries = Catalog.loadUserEntries(from: catalogLocations.userEntriesFile)
        guard !entries.contains(where: { $0.repo == trimmed }) else { return }
        entries.append(Catalog.UserEntry(repo: trimmed, format: format, addedAt: .init()))
        try? Catalog.saveUserEntries(entries, to: catalogLocations.userEntriesFile)
        catalog = Catalog.current(locations: catalogLocations)
    }

    func removeUserCatalogRepo(_ repo: String) {
        var entries = Catalog.loadUserEntries(from: catalogLocations.userEntriesFile)
        let before = entries.count
        entries.removeAll { $0.repo == repo }
        guard entries.count != before else { return }
        try? Catalog.saveUserEntries(entries, to: catalogLocations.userEntriesFile)
        catalog = Catalog.current(locations: catalogLocations)
    }

    /// Checks the weekly remote refresh (no-op unless `QuailCatalogURL`
    /// is set in `Info.plist` and the cached copy is a week old — see
    /// `CatalogRefresher`) and reloads `catalog` if it pulled a newer
    /// revision. Called on app launch from `AppDelegate` — a
    /// long-running menu-bar agent therefore refreshes on the cadence it
    /// restarts at, not a background timer; revisit only if launches
    /// turn out rarer than a week in practice.
    func refreshCatalog() async {
        let refresher = CatalogRefresher(locations: catalogLocations, urlSession: .shared)
        if case .updated = await refresher.refreshIfNeeded() {
            catalog = Catalog.current(locations: catalogLocations)
        }
    }

    // MARK: - Model store management

    /// Loaded-state for the Models pane's badges: model id -> status
    /// string from the running router ("loaded"/"loading"/"unloaded"),
    /// empty when the server isn't up. Best-effort by design — a stale
    /// server mid-shutdown shouldn't blank the pane, so failures read
    /// as "nothing loaded" rather than propagating.
    func loadedModelStates() async -> [String: String] {
        guard let base = baseURL else { return [:] }
        guard let models = try? await runtime.listModels(base: base, apiKey: apiKey) else { return [:] }
        return Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.status.value) })
    }

    /// Hot-swap: ask the running router to load an installed GGUF
    /// (docs/IMPLEMENTATION_PLAN.md step 8 — llama.cpp router mode's
    /// `POST /models/load`, already verified against a real b11081
    /// server in PR 7's integration testing; the runtime can also be
    /// asked to evict per `modelsMax`, and that budget is set at launch
    /// — changing it needs a restart, which is Settings' job, not
    /// here). MLX models throw `needsMLXRuntime` because nothing that
    /// can serve them exists yet — Phase 3.
    func selectModel(id: String) async throws {
        guard let base = baseURL, serverController.phase == .ready else {
            throw ModelSelectionError.serverNotRunning
        }
        let catalog = modelStore.loadCatalog()
        guard let entry = catalog.entries.first(where: { $0.id == id }) else {
            throw ModelSelectionError.notInstalled
        }
        guard entry.format == .gguf else {
            throw ModelSelectionError.needsMLXRuntime
        }
        _ = try await runtime.select(model: ModelRef(id: id), base: base, apiKey: apiKey)
    }

    enum ModelSelectionError: Error, Equatable, CustomStringConvertible {
        case serverNotRunning
        case notInstalled
        case needsMLXRuntime

        var description: String {
            switch self {
            case .serverNotRunning: "start the server first"
            case .notInstalled: "that model isn't installed"
            case .needsMLXRuntime: "MLX models need an MLX runtime (Phase 3)"
            }
        }
    }

    /// How many models router-mode llama.cpp may keep loaded at once
    /// (docs/ARCHITECTURE.md §6's hot-swap budget; ADR D-011 defaults it
    /// to 1 until loaded-state is visible — it is, as of the Models
    /// pane, but 1 stays the default until step 8's click-to-load makes
    /// more meaningful).
    func setModelsMax(_ count: Int) {
        guard count >= 1, count != config.modelsMax else { return }
        config.modelsMax = count
        persist()
    }

    /// Moves the whole store to a new folder and repoints at it — the
    /// point `Paths.makeModelsDirectoryBookmark` has existed for since
    /// PR 9 (docs/IMPLEMENTATION_PLAN.md step 7: "where it finally gets
    /// called, behind a 'Relocate…' button"). Contents move with it
    /// (same-volume renames are instant; cross-volume is a real copy —
    /// multi-GB models make that slow, which is why this runs off the
    /// main actor and the UI shows progress).
    ///
    /// Refuses a store with an install in flight: `ModelInstallController`
    /// holds paths into the current root, and moving underneath it would
    /// strand partials.
    func relocateModelsDirectory(to newRoot: URL) async throws {
        guard !installs.isDownloading else { throw RelocationError.downloadInFlight }
        let previous = modelStore
        guard previous.rootURL.standardizedFileURL != newRoot.standardizedFileURL else { return }

        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        for item in try FileManager.default.contentsOfDirectory(
            at: previous.rootURL, includingPropertiesForKeys: nil
        ) {
            // .partial stays behind: the in-progress-at-best is not worth
            // moving mid-relocate, and a resume starts from zero on the
            // new location's absence, which is correct.
            if item.lastPathComponent == ".partial" {
                continue
            }
            try FileManager.default.moveItem(
                at: item,
                to: newRoot.appendingPathComponent(item.lastPathComponent)
            )
        }

        modelStore = ModelStore(rootURL: newRoot)
        installs.modelStore = modelStore
        config.modelsDirectoryBookmark = try Paths.makeModelsDirectoryBookmark(for: newRoot)
        persist()
    }

    enum RelocationError: Error, Equatable {
        case downloadInFlight
    }

    /// Removes a model: its files and its `catalog.json` row together
    /// (docs/ARCHITECTURE.md §6: "Deletion removes the files and the
    /// catalog row"), plus `presets.ini` regeneration. A loaded model is
    /// handled the §6-sanctioned "or a restart" way: the server is
    /// stopped first (step 8's `POST /models/unload` equivalent will
    /// make this gentler), and stays stopped — restarting it
    /// automatically after an explicit destructive action is the
    /// surprising half of that choice, so the user presses Start again.
    enum ModelDeletionError: Error, Equatable {
        case notInstalled
        case downloadInFlight
    }

    func deleteInstalledModel(id: String) async throws {
        guard !installs.isDownloading else { throw ModelDeletionError.downloadInFlight }
        var catalog = modelStore.loadCatalog()
        guard let index = catalog.entries.firstIndex(where: { $0.id == id }) else {
            throw ModelDeletionError.notInstalled
        }
        let entry = catalog.entries[index]
        await serverController.stop()

        let fm = FileManager.default
        switch entry.format {
        case .gguf:
            // The model plus every companion: split shards (a
            // `<id>-NNNNN-of-NNNNN.gguf` set, however many landed) and
            // the name-paired vision projectors (`mmproj-<id>…`,
            // ARCHITECTURE §6 "paired by name").
            let stem = id
            for file in (try? fm.contentsOfDirectory(at: modelStore.ggufDirectory, includingPropertiesForKeys: nil)) ??
                []
            {
                let name = file.deletingPathExtension().lastPathComponent
                let isMain = name == stem
                let isShard = name.hasPrefix("\(stem)-") && name.contains("-of-")
                let isProjector = file.lastPathComponent.hasPrefix("mmproj-\(stem)")
                if isMain || isShard || isProjector {
                    try? fm.removeItem(at: file)
                }
            }
        case .mlxSafetensors:
            try? fm.removeItem(at: modelStore.mlxDirectory.appendingPathComponent(id, isDirectory: true))
        }

        catalog.entries.remove(at: index)
        try modelStore.saveCatalog(catalog)
        try modelStore.regeneratePresets(catalog: catalog)
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
