import AppKit
import Foundation
import Observation
import os
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
        catalogLocations: Catalog.Locations = .default,
        downloader: HFDownloader = HFDownloader(),
        serverPreflight: (@Sendable (EndpointConfig) async -> PreflightResult)? = ServerPreflight.live
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
        installs = ModelInstallController(downloader: downloader, modelStore: store)
        serverController = ServerController(runtime: runtime, logStore: logStore, preflight: serverPreflight)
        apiKey = config.apiKeyEnabled ? try? secretStore.get(account: Self.apiKeyAccount) : nil
        hfToken = try? secretStore.get(account: Self.hfTokenAccount)
    }

    // MARK: - Server state, as the menu wants to show it

    /// What the running router reports about its models (`GET /models`),
    /// refreshed every couple of seconds while running — see
    /// `startModelPolling()`. Empty whenever the server isn't `.ready`.
    private(set) var servedModels: [ServedModel] = []
    private var modelPollTask: Task<Void, Never>?

    /// How a `.ready` server looks in the menu, from what's actually
    /// loaded rather than from config. Found by live testing: an earlier
    /// version showed yellow for "no default model", which read as "broken"
    /// while Test passed fine (router mode loads whatever model a request
    /// names). Colour now means only: green = serving, yellow = a model is
    /// still loading, red = the default model failed to load.
    struct ReadyStatus: Equatable {
        var label: String
        var detail: String
        var color: Color
    }

    static func readyStatus(models: [ServedModel], defaultModelID: String?) -> ReadyStatus {
        if let defaultModelID,
           let failed = models.first(where: { $0.id == defaultModelID && $0.status.failed == true })
        {
            let code = failed.status.exitCode.map { " (exit \($0))" } ?? ""
            return ReadyStatus(
                label: "Running — default model failed",
                detail: "\(failed.id) failed to load\(code) — see Logs",
                color: .red
            )
        }
        if let loading = models.first(where: { $0.status.value == "loading" }) {
            return ReadyStatus(label: "Loading model…", detail: "Loading \(loading.id)…", color: .yellow)
        }
        let loaded = models.filter { $0.status.value == "loaded" }.map(\.id)
        if loaded.isEmpty {
            return ReadyStatus(label: "Running", detail: "No model loaded — loads on first request", color: .green)
        }
        return ReadyStatus(label: "Running", detail: "Loaded: \(loaded.joined(separator: ", "))", color: .green)
    }

    private var currentReadyStatus: ReadyStatus {
        Self.readyStatus(models: servedModels, defaultModelID: config.defaultModelID)
    }

    var statusLabel: String {
        switch serverController.phase {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .ready: currentReadyStatus.label
        case .stopping: "Stopping…"
        case .failed: "Failed"
        }
    }

    /// The menu's model line: what's loaded while running; what *will*
    /// load (the default) otherwise.
    var modelStatusLine: String {
        if serverController.phase == .ready {
            return currentReadyStatus.detail
        }
        return config.defaultModelID.map { "Default model: \($0)" } ?? "No default model — loads on first request"
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
        case .ready: currentReadyStatus.color
        case .failed: .red
        }
    }

    /// Re-reads `servedModels` from the running router; clears it when
    /// the server isn't ready. A failed read keeps the last known list
    /// rather than flickering the menu on one dropped request.
    func refreshServedModels() async {
        guard serverController.phase == .ready, let base = serverController.baseURL else {
            servedModels = []
            return
        }
        if let models = try? await runtime.listModels(base: base, apiKey: serverController.apiKey) {
            servedModels = models
        }
    }

    /// Polls for as long as a start is in effect (cancelled by `stop()`),
    /// so the icon follows a model loading, finishing, being swapped by
    /// a client request, or failing — none of which Quail itself causes.
    private func startModelPolling() {
        modelPollTask?.cancel()
        modelPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refreshServedModels()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
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
        // Reconcile the catalog with the disk and set each model's
        // per-device context size before generating presets — see
        // `reconcileStore`. Reads device facts fresh every Start.
        await reconcileStore()
        signatureAtStart = modelStore.presetSignature()
        await serverController.start(config: endpointConfig())
        await refreshServedModels() // so the first menu look after Start is already accurate
        startModelPolling()
    }

    func stop() async {
        modelPollTask?.cancel()
        modelPollTask = nil
        await serverController.stop()
        servedModels = []
        signatureAtStart = nil
    }

    /// The menu's "Restart" for `modelsChangedSinceStart`.
    func restart() async {
        await stop()
        await start()
    }

    // MARK: - Store reconciliation

    /// `ModelStore.presetSignature()` as of the last Start — `nil` while
    /// stopped.
    private var signatureAtStart: [String]?

    /// The store's models differ from what the running server was started
    /// with — added, deleted (in Quail or in Finder), or a projector
    /// changed. The router never rescans (confirmed against the real
    /// binary), so these only take effect after a restart; the menu says so.
    private(set) var modelsChangedSinceStart = false

    private var storeWatcher: StoreWatcher?

    private static let storeLog = Logger(subsystem: "com.datoos.quail", category: "Store")

    /// A store event for both the Logs window and the persistent unified
    /// log (`log show --predicate 'subsystem == "com.datoos.quail"'`) —
    /// the Logs window's buffer is in memory only, and "what happened to my
    /// model?" needs an answer after a relaunch too.
    private func note(_ text: String) async {
        Self.storeLog.notice("\(text, privacy: .public)")
        await logStore.append(stream: .stderr, text: "quail: \(text)")
    }

    /// Watches the current store's folders; call again after relocating.
    /// Not started from `init` so tests' `AppState`s don't watch anything.
    func startWatchingStore() {
        let store = modelStore
        storeWatcher?.stop()
        storeWatcher = StoreWatcher(
            directories: [store.ggufDirectory, store.mlxDirectory],
            snapshot: { store.contentSnapshot() },
            onSettled: { [weak self] in await self?.reconcileStore() }
        )
        storeWatcher?.start()
    }

    /// Brings every record in line with what's actually on disk — run at
    /// launch, before each Start, and whenever the store's folders change
    /// (so deleting a model in Finder is handled like deleting it here):
    /// - `catalog.json` gains hand-placed models and loses missing ones.
    /// - A default model whose file is gone is cleared, with a Logs line
    ///   saying so (same as an in-app delete), rather than the menu naming
    ///   a model that silently never loads.
    /// - `presets.ini` is regenerated.
    /// - `storeRevision` bumps so the Models pane and Add-model sheet
    ///   refresh; `modelsChangedSinceStart` is set if the server is running
    ///   on a now-different set of models.
    /// Leftovers (unlinked projectors, abandoned partial downloads) are
    /// never deleted here — see `ModelStore.leftovers`.
    func reconcileStore() async {
        let store = modelStore
        let device = DeviceInfo.current()
        let runtime = config.runtimeID
        let bandwidth = ChipBandwidthTable.loadFromBundle()
        let (refreshed, onDisk) = await Task.detached(priority: .utility) {
            (
                store.refreshedCatalog(device: device, ggufRuntime: runtime, bandwidthTable: bandwidth),
                Set(store.installedGGUFFiles().map { $0.deletingPathExtension().lastPathComponent })
            )
        }.value
        let previous = store.loadCatalog()
        if refreshed != previous {
            try? store.saveCatalog(refreshed)
        }
        // An audit trail for the store: models appearing or disappearing
        // outside Quail (Finder, another app) — found by live testing that
        // "where did my model go?" had no answer anywhere.
        let before = Set(previous.entries.map(\.id))
        let after = Set(refreshed.entries.map(\.id))
        for id in before.subtracting(after).sorted() {
            await note("model \(id) is no longer in the store (removed outside Quail)")
        }
        for id in after.subtracting(before).sorted() {
            await note("found model \(id) in the store")
        }
        if let defaultID = config.defaultModelID, !onDisk.contains(defaultID) {
            config.defaultModelID = nil
            persist()
            await note("default model \(defaultID) is no longer in the store (deleted outside Quail?) — cleared")
        }
        try? store.regeneratePresets(catalog: refreshed, defaultModelID: config.defaultModelID)
        if let signatureAtStart {
            modelsChangedSinceStart = store.presetSignature() != signatureAtStart
        } else {
            modelsChangedSinceStart = false
        }
        storeRevision += 1
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

    /// Pre-download fit verdicts for `Recommender.candidates`' families
    /// (docs/ARCHITECTURE.md §7: "Both are read from the Hub file
    /// listing before download, so the verdict shows in the picker") —
    /// what lets the Add-model sheet show a "Recommended for this Mac"
    /// section without the user clicking each family first. Keyed by
    /// GGUF repo id; see `Recommender.finalize`'s doc comment for why
    /// one verdict (at the catalog's default quant) is enough. Kept here
    /// rather than as the sheet's own `@State` so reopening it doesn't
    /// refetch — a sheet dismissed and reopened mid-browse shouldn't
    /// re-hit the network for every family again.
    /// Keyed by family id. A family with no entry hasn't been queued yet.
    private(set) var catalogFits: [String: RemoteFit] = [:]

    /// `catalogFits`' successful estimates, keyed by GGUF repo id — the
    /// shape `Recommender.finalize` takes.
    var catalogVerdicts: [String: FitEstimate] {
        var result: [String: FitEstimate] = [:]
        for family in catalog.families {
            if case let .estimate(estimate)? = catalogFits[family.id], let repo = family.gguf?.repo {
                result[repo] = estimate
            }
        }
        return result
    }

    /// Looks up every family in the list — not just the in-tier
    /// recommendation candidates, which is all an earlier version did,
    /// leaving most rows blank — with those candidates first so the
    /// Recommended section fills quickly. Up to 3 at once. Families
    /// already resolved are skipped; ones that failed are retried (the
    /// reason may have been transient, or a token since added).
    func loadCatalogVerdicts() async {
        let device = DeviceInfo.current()
        let bandwidth = ChipBandwidthTable.loadFromBundle()
        let ggufRuntime = config.runtimeID
        let downloader = installs.downloader
        let token = hfToken
        let candidateIDs = Set(Recommender.candidates(catalog: catalog, device: device).map(\.id))
        let families = catalog.families
            .filter { family in
                switch catalogFits[family.id] {
                case .estimate?, .checking?: false
                case .unknown?, nil: true
                }
            }
            .sorted { candidateIDs.contains($0.id) && !candidateIDs.contains($1.id) }
        for family in families {
            catalogFits[family.id] = .checking
        }

        await withTaskGroup(of: (String, RemoteFit).self) { group in
            var pending = families[...]

            func addNext() {
                guard let family = pending.popFirst() else { return }
                group.addTask {
                    let fit = await ModelPreview.catalogFit(
                        family: family, downloader: downloader, device: device,
                        ggufRuntime: ggufRuntime, bandwidthTable: bandwidth, token: token
                    )
                    return (family.id, fit)
                }
            }

            for _ in 0 ..< 3 {
                addNext()
            }
            for await (id, fit) in group {
                catalogFits[id] = fit
                addNext()
            }
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

    /// Hands `update` fresh `loadedModelStates()` every `interval` while
    /// the server is ready; returns once it isn't, or once the calling
    /// task is cancelled. The cancellation exit matters: a view's
    /// `.task` loop written as `while ready { try? await Task.sleep … }`
    /// never ends when the view goes away — the cancelled sleep returns
    /// instantly and `try?` hides it — and spun on `GET /models` until
    /// it used up every ephemeral port on the Mac (user-reported: a
    /// `quail run` turn failing with `EADDRNOTAVAIL`).
    func pollLoadedStates(every interval: Duration = .seconds(2), _ update: ([String: String]) -> Void) async {
        while !Task.isCancelled, serverController.phase == .ready {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard serverController.phase == .ready else { return }
            await update(loadedModelStates())
        }
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

    /// The model whose `presets.ini` section gets `load-on-startup = true`
    /// (ADR D-017) — applies next Start, same as `modelsMax`; a running
    /// server isn't reconfigured live. `id: nil` clears it (the star
    /// toggle passing the already-default row's own id back off).
    func setDefaultModel(_ id: String?) {
        guard id != config.defaultModelID else { return }
        config.defaultModelID = id
        persist()
    }

    /// The Models pane's per-model context picker (ADR D-020). `nil` is
    /// Automatic. Takes effect at the next Start — while running, the menu
    /// shows "Models changed — restart to apply".
    func setContextSize(_ tokens: Int?, forModel id: String) async {
        var catalog = modelStore.loadCatalog()
        guard let index = catalog.entries.firstIndex(where: { $0.id == id }),
              catalog.entries[index].userContextSize != tokens
        else { return }
        catalog.entries[index].userContextSize = tokens
        try? modelStore.saveCatalog(catalog)
        await reconcileStore()
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
        storeRevision += 1
        if storeWatcher != nil {
            startWatchingStore()
        }
    }

    enum RelocationError: Error, Equatable {
        case downloadInFlight
    }

    /// Removes a model: its files and its `catalog.json` row together
    /// (docs/ARCHITECTURE.md §6: "Deletion removes the files and the
    /// catalog row"), plus `presets.ini` regeneration. A *loaded* (or
    /// loading) model is handled the §6-sanctioned "or a restart" way: the
    /// server is stopped first and stays stopped — restarting it
    /// automatically after an explicit destructive action is the
    /// surprising half of that choice, so the user presses Start again.
    /// Deleting a model the server isn't using leaves it running (an
    /// earlier version stopped it unconditionally, contradicting this
    /// comment); the router keeps that preset until the next Start, and a
    /// request naming it fails to load rather than finding stale weights.
    enum ModelDeletionError: Error, Equatable {
        case notInstalled
        case downloadInFlight
    }

    /// Bumped whenever the store's contents change outside a download
    /// (delete, relocate), so every view showing installed models can
    /// refresh — the Models pane and the Add-model sheet both delete.
    private(set) var storeRevision = 0

    func deleteInstalledModel(id: String) async throws {
        guard !installs.isDownloading else { throw ModelDeletionError.downloadInFlight }
        var catalog = modelStore.loadCatalog()
        guard let index = catalog.entries.firstIndex(where: { $0.id == id }) else {
            throw ModelDeletionError.notInstalled
        }
        let entry = catalog.entries[index]
        await refreshServedModels()
        let inUse = servedModels.contains { $0.id == id && ["loaded", "loading"].contains($0.status.value) }
        if inUse {
            await stop()
        }

        let fm = FileManager.default
        switch entry.format {
        case .gguf:
            // The model plus every companion: split shards (a
            // `<id>-NNNNN-of-NNNNN.gguf` set, however many landed) and
            // its vision projector (`ModelStore.projectorFilename` — an
            // exact name: a prefix match would also have taken
            // `mmproj-<id>-Other.gguf`, another model's).
            let stem = id
            for file in (try? fm.contentsOfDirectory(at: modelStore.ggufDirectory, includingPropertiesForKeys: nil)) ??
                []
            {
                let name = file.deletingPathExtension().lastPathComponent
                let isMain = name == stem
                let isShard = name.hasPrefix("\(stem)-") && name.contains("-of-")
                let isProjector = file.lastPathComponent == ModelStore.projectorFilename(forModelID: stem)
                if isMain || isShard || isProjector {
                    try? fm.removeItem(at: file)
                }
            }
        case .mlxSafetensors:
            try? fm.removeItem(at: modelStore.mlxDirectory.appendingPathComponent(id, isDirectory: true))
        }

        catalog.entries.remove(at: index)
        try modelStore.saveCatalog(catalog)
        await note("deleted model \(id) (from Quail)")
        if config.defaultModelID == id {
            setDefaultModel(nil)
        }
        try modelStore.regeneratePresets(catalog: catalog, defaultModelID: config.defaultModelID)
        storeRevision += 1
    }

    // MARK: - Open at login

    /// Start the server when Quail launches (`quail service enable`, and
    /// Settings → General). Stored for a long time but never acted on until
    /// the CLI's "always on" needed it — see `AppDelegate`.
    func setAutoStartServer(_ enabled: Bool) {
        guard enabled != config.autoStartServer else { return }
        config.autoStartServer = enabled
        persist()
    }

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

    /// 12 random bytes, base64url-encoded without padding — exactly 16
    /// characters (96 bits of entropy — still enormous for a secret
    /// whose job is deterring casual access on a loopback/LAN endpoint,
    /// see ADR D-010, not resisting a nation-state). Base64url (`-`/`_`,
    /// no `+`/`/`) rather than plain base64: copy-pasted into a shell
    /// `Authorization: Bearer …` header or a URL, `+`/`/` need escaping
    /// and `=` padding is visual noise; none of that applies here.
    /// Previously 32 hex characters (16 bytes) — shortened again, and
    /// switched to base64, per user feedback that hex reads as
    /// needlessly long and was overflowing the Endpoint settings field.
    private static func generateAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
