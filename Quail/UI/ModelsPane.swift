import os
import SwiftUI

/// The Quail window's Models page (docs/IMPLEMENTATION_PLAN.md Phase 2 step 7):
/// installed models with format badge, size, fit verdict and loaded
/// state; delete with confirm; store relocation behind a real
/// `NSOpenPanel`; and the Hugging Face token field deferred from step 5.
///
/// Verdicts are computed, not stored: `ModelPreview.installed` re-reads
/// each model's header (mmap-cheap) and re-runs `FitEstimator` against
/// `DeviceInfo.current()`, so the pane shows today's device truth even
/// though `catalog.json`'s `contextSize` — the value actually fed to
/// `presets.ini` — is only refreshed on Start. Running off the main
/// actor because "cheap" is per-file, not per-store: ten models × 85 ms
/// is a visible hitch.
struct ModelsPane: View {
    let appState: AppState
    /// Tests only: stay in the first moments before anything has been read.
    var startsLoading = false

    /// The user's explicit ask for step 7: "MLX is preferred — should
    /// have a switch/filter to just show MLX models."
    @State private var formatFilter: FormatFilter = .all
    @State private var rows: [InstalledModel] = []
    /// Whether the store has been read at all yet: until then the list shows a placeholder, not "No models".
    @State private var hasLoaded = false
    /// Whether the rows' fit verdicts are still being worked out.
    @State private var verdictsPending = true
    @State private var verdicts: [String: FitEstimate] = [:]
    @State private var contextChoices: [String: [ContextChoice]] = [:]
    @State private var kvCacheChoices: [String: [KVCacheChoice]] = [:]
    @State private var loadedStates: [String: String] = [:]
    @State private var showAddSheet = false
    @State private var pendingDeletion: String?
    @State private var showDeleteConfirm = false
    @State private var relocationError: String?
    @State private var deletionError: String?
    @State private var loadError: String?
    /// Models asked to unload that the server still lists, so their row says so until they go.
    @State private var unloading: Set<String> = []
    @State private var tokenDraft = ""
    /// Carried from `ContentUnavailable`'s recommendation button into the
    /// sheet it opens, so the empty-state nudge (§7's own top pick for
    /// this Mac) lands the user straight on that family rather than an
    /// unselected list.
    @State private var preselectFamily: Catalog.Family?
    @State private var showCleanUp = false
    @State private var showImport = false
    /// This Mac's chip, for matching benchmark results (read in `refresh`,
    /// not per render — `DeviceInfo.current()` touches IOKit and Metal).
    @State private var chip: String?
    /// "Apple M4 Pro · 64 GB · comfortable up to ~55B", read with `chip`.
    @State private var deviceLine: String?

    enum FormatFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case gguf = "GGUF"
        case mlx = "MLX"

        var id: String {
            rawValue
        }
    }

    var body: some View {
        Form {
            // What fits here, in a line; the About page has the facts behind it.
            if let deviceLine, !deviceLine.isEmpty {
                Section {
                    HStack {
                        Label("This Mac: \(deviceLine)", systemImage: "desktopcomputer")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Details") { appState.mainPage = .about }
                            .controlSize(.small)
                    }
                }
            }
            // Only when there are MLX models that won't load; the Server page says it either way.
            if !appState.canServe(.mlxSafetensors), !appState.modelStore.installedMLXDirectories().isEmpty {
                Section {
                    MLXUnavailableBanner(appState: appState)
                }
            }
            if appState.offersImport {
                Section {
                    ImportOfferBanner(appState: appState, review: { showImport = true })
                }
            }
            loadedSection
            Section {
                installedList
            } header: {
                HStack {
                    Text("Installed")
                    Spacer()
                    Picker("Show", selection: $formatFilter) {
                        ForEach(FormatFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Button("Add Model…") {
                        preselectFamily = nil
                        showAddSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } footer: {
                if !rows.isEmpty {
                    Text(
                        "Send \"model\": \"<id>\" in a request to pick a model. Each row's settings (the sliders) have its id to copy, its context size and more."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if appState.installs.phase != .idle || loadError != nil {
                Section {
                    installProgress
                }
            }

            storeSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showCleanUp) {
            CleanUpSheet(appState: appState)
        }
        .sheet(isPresented: $showImport) {
            ImportModelsSheet(appState: appState)
        }
        .sheet(isPresented: $showAddSheet) {
            AddModelSheet(appState: appState, defaultFilter: formatFilter, preselect: preselectFamily)
        }
        .alert(
            "Delete \(pendingDeletion ?? "")?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                let id = pendingDeletion
                Task {
                    if let id {
                        do {
                            try await appState.deleteInstalledModel(id: id)
                        } catch {
                            deletionError = "Couldn't delete \(id): \(error.localizedDescription)"
                        }
                    }
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes the file(s) and the catalog row together; presets are regenerated. The server is stopped first if a model was loaded."
            )
        }
        .alert("Could not delete the model", isPresented: .init(
            get: { deletionError != nil }, set: {
                if !$0 {
                    deletionError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
        .alert("Could not relocate the store", isPresented: .init(
            get: { relocationError != nil }, set: {
                if !$0 {
                    relocationError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(relocationError ?? "")
        }
        .onAppear {
            tokenDraft = appState.hfToken ?? ""
            seedFromLastVisit()
        }
        // Keyed on the server phase: opening the pane refreshes once,
        // and every stop→ready transition refreshes again (the verdicts
        // re-check against current device facts, the Load buttons appear).
        // While the router is running, loaded state is also re-polled on
        // a timer — a model can load behind the pane's back (the
        // router's own web UI, auto-load on the first chat request, a
        // ping), and there is no push channel from llama-server to know
        // about it. 2 s, same cadence the Logs window tails at.
        .task { await appState.scanForImports() }
        .task(id: appState.serverController.phase) {
            await refresh()
            await appState.pollLoadedStates { loadedStates = $0 }
        }
        // An unloaded model leaves the Loaded section; forget that it was being unloaded.
        .onChange(of: appState.servedModels.filter { $0.status.value != "unloaded" }.map(\.id)) { _, ids in
            unloading.formIntersection(ids)
        }
        .onChange(of: appState.storeRevision) { _, _ in
            Task { await refresh() }
        }
        // The menu's Add model… (or the Server page's) asks for the sheet, whether or not this page was showing.
        .onAppear(perform: openRequestedAddSheet)
        .onChange(of: appState.addModelRequested) { _, _ in openRequestedAddSheet() }
        .onChange(of: appState.installs.phase) { _, newPhase in
            // Rows only appear/verify once an install reaches a terminal
            // phase; the downloading phase re-renders by observation.
            switch newPhase {
            case .installed, .failed:
                Self.logger.notice("install reached \(String(describing: newPhase), privacy: .public); refreshing")
                Task { await refresh() }
            default:
                break
            }
        }
    }

    private func openRequestedAddSheet() {
        guard appState.addModelRequested else { return }
        appState.addModelRequested = false
        preselectFamily = nil
        showAddSheet = true
    }

    private var entries: [InstalledModel] {
        switch formatFilter {
        case .all: rows
        case .gguf: rows.filter { $0.format == .gguf }
        case .mlx: rows.filter { $0.format == .mlxSafetensors }
        }
    }

    /// The top pick for this Mac, per §7's "Recommendations" — shown in
    /// the empty-state nudge below without waiting on any network
    /// verdict (that's `AddModelSheet`'s own job once opened); this is
    /// just "what would head the recommended list", from catalog data
    /// alone.
    private var topRecommendation: Catalog.Family? {
        Recommender.topPick(catalog: appState.catalog, device: DeviceInfo.current())
    }

    /// `entry`'s catalog family's strengths (ADR D-052), matched as the Add Model sheet matches
    /// installed models to families.
    private func strengths(of entry: InstalledModel) -> [ModelStrength] {
        guard let family = appState.catalog.families.first(where: {
            !InstalledLookup.entries(for: $0, in: [entry]).isEmpty
        }) else { return [] }
        return ModelStrength.strengths(of: family, format: entry.format)
    }

    private var measuredSpeeds: [String: Double] {
        appState.benchmarks.measuredSpeeds(chip: chip)
    }

    /// What the server has loaded or is loading, at the top where it can't be missed (issue #134): each with what
    /// it's doing, and Unload. Only while the server is ready; the Installed list below still shows every model.
    @ViewBuilder private var loadedSection: some View {
        if appState.serverController.phase == .ready {
            let served = appState.servedModels.filter { ["loaded", "loading"].contains($0.status.value) }
            Section("Loaded") {
                if served.isEmpty {
                    Label(noneLoadedText, systemImage: "moon.zzz")
                        .foregroundStyle(.secondary)
                } else {
                    // One Form row holding them all: as separate rows, a grouped Form drew only the first inside
                    // the section's card.
                    VStack(spacing: 6) {
                        ForEach(Array(served.enumerated()), id: \.element.id) { index, model in
                            if index > 0 {
                                Divider()
                            }
                            loadedRow(model)
                        }
                    }
                }
            }
        }
    }

    private var noneLoadedText: String {
        if let id = appState.config.defaultModelID {
            return "No model loaded — the default, \(id), loads on the first request"
        }
        return "No model loaded — a request loads the model it names, or choose one below and Load"
    }

    private func loadedRow(_ model: ServedModel) -> some View {
        let activity = appState.activity.server
        let entry = rows.first { $0.id == model.id }
        return LoadedModelRow(
            id: model.id,
            entry: entry,
            loading: model.status.value == "loading",
            unloading: unloading.contains(model.id),
            waitingFor: activity.models.first { $0.id == model.id }?.waitingFor ?? model.status.waitingFor ?? [],
            live: activity.models.first { $0.id == model.id },
            requests: activity.requests.filter { $0.model == model.id },
            serverMemoryBytes: appState.activity.system.serverMemoryBytes,
            isDefault: appState.config.defaultModelID == model.id,
            onUnload: {
                unloading.insert(model.id)
                Task {
                    do {
                        try await appState.unloadModel(id: model.id)
                        loadError = nil
                        loadedStates = await appState.loadedModelStates()
                    } catch {
                        unloading.remove(model.id)
                        loadError = String(describing: error)
                    }
                }
            },
            onToggleDefault: {
                appState.setDefaultModel(appState.config.defaultModelID == model.id ? nil : model.id)
            }
        )
    }

    @ViewBuilder private var installedList: some View {
        if !hasLoaded {
            ModelsLoadingPlaceholder()
        } else if entries.isEmpty {
            ContentUnavailable(
                filter: formatFilter,
                recommended: topRecommendation,
                add: {
                    preselectFamily = nil
                    showAddSheet = true
                },
                addRecommended: { family in
                    preselectFamily = family
                    showAddSheet = true
                }
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            ForEach(entries) { entry in
                ModelRow(
                    entry: entry,
                    verdict: verdicts[entry.id],
                    verdictPending: verdictsPending && verdicts[entry.id] == nil,
                    loaded: loadedStates[entry.id],
                    serverReady: appState.serverController.phase == .ready,
                    servable: appState.canServe(entry.format),
                    isDefault: appState.config.defaultModelID == entry.id,
                    contextChoices: contextChoices[entry.id] ?? [],
                    kvCacheChoices: kvCacheChoices[entry.id] ?? [],
                    measuredSpeed: measuredSpeeds[entry.id],
                    strengths: strengths(of: entry),
                    onSetContext: { tokens in
                        Task { await appState.setContextSize(tokens, forModel: entry.id) }
                    },
                    onSetKVCache: { setting in
                        Task { await appState.setKVCache(setting, forModel: entry.id) }
                    },
                    onLoad: {
                        Task {
                            do {
                                try await appState.selectModel(id: entry.id)
                                loadError = nil
                                await pollUntilLoaded(entry.id)
                            } catch {
                                loadError = String(describing: error)
                            }
                        }
                    },
                    onToggleDefault: {
                        appState.setDefaultModel(appState.config.defaultModelID == entry.id ? nil : entry.id)
                    },
                    onDelete: {
                        pendingDeletion = entry.id
                        showDeleteConfirm = true
                    },
                    onBenchmark: {
                        appState.benchmarks.requestedModel = entry.id
                        appState.mainPage = .benchmark
                    }
                )
            }
        }
    }

    /// Two labelled rows — the store folder and the Hugging Face token —
    /// with the rarely used actions (Clean Up, Move, Reload) in a menu.
    /// Redesigned after user feedback: five buttons in one row truncated
    /// ("Show in Fin…") and squeezed the path to "/Users/…/Models".
    private var storeSection: some View {
        Section {
            LabeledContent("Models folder") {
                HStack(spacing: 8) {
                    Text((appState.modelStore.rootURL.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(appState.modelStore.rootURL.path)
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(appState.modelStore.ggufDirectory)
                    }
                    .help("Open the GGUF models folder. Models added or deleted there show up here automatically.")
                    Menu {
                        Button("Clean Up…") { showCleanUp = true }
                        Button("Import Models from Other Apps…") { showImport = true }
                        Button("Move Folder…") { relocate() }
                            .disabled(
                                appState.installs.isDownloading
                                    || !appState.serverController.phase.isStoppedForRelocation
                            )
                        Divider()
                        Button("Reload") { Task { await refresh() } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Clean up leftovers, move the folder, reload")
                }
            }
            LabeledContent("Hugging Face token") {
                HStack(spacing: 8) {
                    SecureField("Hugging Face token", text: $tokenDraft, prompt: Text("Only needed for gated repos"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        appState.setHFToken(tokenDraft)
                        tokenDraft = appState.hfToken ?? ""
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Clear") {
                        appState.clearHFToken()
                        tokenDraft = ""
                    }
                    .disabled(appState.hfToken == nil)
                }
            }
        } header: {
            Text("Storage and downloads")
        }
    }

    @ViewBuilder private var installProgress: some View {
        switch appState.installs.phase {
        case let .downloading(written, total, file):
            VStack(alignment: .leading, spacing: 4) {
                if let target = appState.installs.target {
                    HStack {
                        Text("Downloading \(target.repo)")
                        if let quant = target.quant {
                            Text("(\(quant))").foregroundStyle(.secondary)
                        }
                        Text("— \(file)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: total > 0 ? Double(written) / Double(total) : 0)
                    .frame(maxWidth: 260, alignment: .leading)
                Text(ByteCountFormatter.string(fromByteCount: written, countStyle: .file) + " of " + ByteCountFormatter
                    .string(
                        fromByteCount: total,
                        countStyle: .file
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { appState.installs.cancel() }
                    if !appState.installs.queue.isEmpty {
                        Text("\(appState.installs.queue.count) more queued")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        case .installed:
            Label("Installed.", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.green)
        case .idle:
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func relocate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move store here"
        panel.message = "Quail will move every model into this folder and use it from now on."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await appState.relocateModelsDirectory(to: url)
                await refresh()
            } catch {
                relocationError = describe(error)
            }
        }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case AppState.RelocationError.downloadInFlight: "A download is running — cancel it first."
        default: String(describing: error)
        }
    }

    /// After a Load click the router moves through `loading` to
    /// `loaded` on its own (a cold model load is seconds); poll so the
    /// badge updates without a manual Reload. Bounded — a load that
    /// stalls forever shows the last known state, not an endless spinner.
    private func pollUntilLoaded(_ id: String) async {
        for _ in 0 ..< 20 {
            let states = await appState.loadedModelStates()
            loadedStates = states
            if states[id] == "loaded" || states[id] == nil {
                return
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    private static let logger = Logger(subsystem: "com.datoos.quail", category: "ModelsPane")

    /// The last list shown, so reopening the tab starts from it (the refresh then replaces it).
    private func seedFromLastVisit() {
        guard !hasLoaded, !startsLoading, let last = appState.lastModelsSnapshot else { return }
        rows = last.rows
        verdicts = last.verdicts
        contextChoices = last.contextChoices
        kvCacheChoices = last.kvCacheChoices
        verdictsPending = false
        hasLoaded = true
    }

    private func refresh() async {
        guard !startsLoading else { return }
        Self.logger.notice("refresh: start")
        let store = appState.modelStore
        // The rows first, from the store's own index (a small file), so the list isn't empty while each model's
        // header is read for its verdict below.
        // An empty index proves nothing (a model dropped in by hand isn't in it until the reconcile below), so the
        // placeholder stays until then.
        if !hasLoaded {
            let indexed = await Task.detached(priority: .userInitiated) { store.loadCatalog().entries }.value
            if !indexed.isEmpty {
                rows = indexed.sorted { $0.id < $1.id }
                hasLoaded = true
            }
        }
        verdictsPending = true
        let device = DeviceInfo.current()
        chip = device.chipName
        deviceLine = device.summaryLine
        let runtime = appState.config.runtimeID
        let bandwidth = ChipBandwidthTable.loadFromBundle()
        // Disk reconciliation + verdicts off the main actor; the pane
        // reads (does not write) catalog.json — persistence stays
        // start()/install()'s job, so merely looking at the pane never
        // mutates the store.
        let result = await Task.detached(priority: .utility) {
            let catalog = store.refreshedCatalog(device: device, ggufRuntime: runtime, bandwidthTable: bandwidth)
            var verdicts: [String: FitEstimate] = [:]
            var choices: [String: [ContextChoice]] = [:]
            var kvChoices: [String: [KVCacheChoice]] = [:]
            for entry in catalog.entries {
                verdicts[entry.id] = ModelPreview.installed(
                    entry: entry, store: store, device: device,
                    ggufRuntime: runtime, bandwidthTable: bandwidth
                )
                choices[entry.id] = ModelPreview.contextChoices(
                    entry: entry, store: store, device: device, ggufRuntime: runtime
                ).map { ContextChoice(tokens: $0.tokens, verdict: $0.verdict, fitsWith4BitKV: $0.fitsWith4BitKV) }
                kvChoices[entry.id] = ModelPreview.kvCacheChoices(
                    entry: entry, store: store, device: device, ggufRuntime: runtime
                ).map { KVCacheChoice(setting: $0.setting, verdict: $0.verdict) }
            }
            return (catalog.entries, verdicts, choices, kvChoices)
        }.value
        rows = result.0
        verdicts = result.1
        contextChoices = result.2
        kvCacheChoices = result.3
        verdictsPending = false
        hasLoaded = true
        appState.lastModelsSnapshot = .init(
            rows: result.0, verdicts: result.1, contextChoices: result.2, kvCacheChoices: result.3
        )
        // The server's loaded states last: a busy server shouldn't hold the list back.
        loadedStates = await appState.loadedModelStates()
        Self.logger.notice("refresh: done, rows \(result.0.map(\.id), privacy: .public)")
    }
}

/// Loaded-state + verdict + size for one installed model.
private struct ModelRow: View {
    let entry: InstalledModel
    let verdict: FitEstimate?
    /// Still being worked out: "Checking…", not "Fit unknown".
    let verdictPending: Bool
    let loaded: String?
    let serverReady: Bool
    /// Whether the chosen runtime can serve this model's format; an MLX row under llama.cpp can't.
    let servable: Bool
    /// Whether this is `Config.defaultModelID` — the one row gets
    /// `load-on-startup = true` in `presets.ini` (ADR D-017).
    let isDefault: Bool
    let contextChoices: [ContextChoice]
    let kvCacheChoices: [KVCacheChoice]
    /// Generation speed from this model's latest Benchmark on this Mac.
    let measuredSpeed: Double?
    /// What its catalog family is good for; empty for a model from outside the catalog.
    let strengths: [ModelStrength]
    let onSetContext: (Int?) -> Void
    let onSetKVCache: (KVCacheSetting) -> Void
    let onLoad: () -> Void
    let onToggleDefault: () -> Void
    let onDelete: () -> Void
    let onBenchmark: () -> Void

    @State private var showSettings = false

    /// Two lines, so the name has the row's width to itself: the id and its
    /// loaded-state on top; format, size, context, measured speed and fit
    /// verdict beneath; actions in a column on the right. (One line of
    /// nine controls truncated the id — "Qwen3…4_K_M" — and put every
    /// row's columns in a different place.)
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.id)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Confirmed undiscoverable otherwise: `entry.id` is
                        // exactly the string a client must send as `"model"` in
                        // its request body (the preset alias — ModelStore.
                        // regeneratePresets), but nothing in the app said so
                        // anywhere. A context menu on the id itself, right where
                        // you'd look for it.
                        .contextMenu {
                            Button("Copy Model ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.id, forType: .string)
                            }
                            Button("Model Settings…") { showSettings = true }
                            if servable {
                                Button("Benchmark…", action: onBenchmark)
                            }
                            Divider()
                            Button("Delete…", role: .destructive, action: onDelete)
                        }
                        .help("Send \"model\": \"\(entry.id)\" in requests to select this one")
                    if loaded == "loaded" {
                        Badge(text: "loaded", color: .green).fixedSize()
                    } else if let loaded {
                        Badge(text: loaded, color: .gray).fixedSize()
                    }
                }
                HStack(spacing: 10) {
                    Badge(text: entry.format == .gguf ? "GGUF" : "MLX", color: entry.format == .gguf ? .blue : .purple)
                    Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                        .monospacedDigit()
                    // What the settings popover changes, and a way into it.
                    Button {
                        showSettings = true
                    } label: {
                        HStack(spacing: 2) {
                            Text(contextLabel)
                            Image(systemName: "chevron.down")
                                .imageScale(.small)
                        }
                        .font(.caption)
                        .monospacedDigit()
                    }
                    .buttonStyle(.borderless)
                    .help("Context size and KV cache — click to change")
                    if let measuredSpeed {
                        Label(
                            String(format: "%.0f tok/s", measuredSpeed),
                            systemImage: "gauge.with.dots.needle.67percent"
                        )
                        .monospacedDigit()
                        .help("Generation speed measured by Benchmark on this Mac")
                    }
                    if let verdict {
                        FitVerdictBadge(estimate: verdict)
                    } else if verdictPending {
                        Badge(text: "Checking…", color: .secondary)
                    } else {
                        // Never a blank: say it couldn't be judged, and why.
                        Badge(text: "Fit unknown", color: .secondary)
                            .help(entry.format == .gguf
                                ? "Couldn't read this model's header, or its architecture isn't supported by the estimate yet."
                                : "Couldn't read this model's config.json.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if !strengths.isEmpty {
                    StrengthChips(strengths: strengths, limit: 5)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            // Hot swap (step 8): an installed model can be loaded into the running router with a click, if the
            // chosen runtime serves its format. Otherwise the row says what would, rather than offering a button
            // that must fail.
            if !servable {
                Text("Needs the Quail server runtime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Choose Quail server on the Server page (with the server stopped) to run MLX models.")
            } else if serverReady, loaded != nil, loaded != "loaded" {
                Button("Load", action: onLoad)
                    .controlSize(.small)
            } else if serverReady, loaded == nil {
                // The router only knows the models it started with (it
                // never rescans) — Load would 404 until a restart.
                Badge(text: "Restart to load", color: .orange)
                    .help("Added since the server started. Restart the server (menu) to use it.")
            }
            // Usable while stopped (unlike Load) — it just sets what gets written into presets.ini on the next
            // Start, for a model the chosen runtime serves.
            if servable {
                Button(action: onToggleDefault) {
                    Image(systemName: isDefault ? "star.fill" : "star")
                        .foregroundStyle(isDefault ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isDefault ? "Default — loads automatically on Start" : "Load automatically on Start")
            }
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Model settings: context size, KV cache, loading on Start")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                ModelSettingsView(
                    entry: entry,
                    servable: servable,
                    isDefault: isDefault,
                    contextChoices: contextChoices,
                    kvCacheChoices: kvCacheChoices,
                    onSetContext: onSetContext,
                    onSetKVCache: onSetKVCache,
                    onToggleDefault: onToggleDefault,
                    onBenchmark: {
                        showSettings = false
                        onBenchmark()
                    },
                    onDelete: {
                        showSettings = false
                        // After the popover has gone: an alert presented while it closes can be lost.
                        Task { @MainActor in onDelete() }
                    }
                )
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete model")
        }
        .padding(.vertical, 4)
    }

    private var contextLabel: String {
        let size = "\(RemoteFitBadge.contextLabel(entry.effectiveContextSize)) context"
        return entry.effectiveKVCache == .full ? size : "\(size) · \(entry.effectiveKVCache.label) KV"
    }
}

/// A model the server has loaded or is loading: its name, format and context, its memory, what it's doing, and
/// Unload (issue #134).
private struct LoadedModelRow: View {
    let id: String
    /// The store's entry for it, when it's one of the installed models (it always should be).
    let entry: InstalledModel?
    let loading: Bool
    let unloading: Bool
    /// While it loads: the busy models it's waiting on to finish their requests (ADR D-068).
    let waitingFor: [String]
    /// What `/slots` says about it: load time and, for MLX, its memory.
    let live: ServerActivity.Model?
    let requests: [ServerActivity.Request]
    /// The server's whole footprint, for a GGUF model (llama.cpp doesn't say per model).
    let serverMemoryBytes: Int64?
    let isDefault: Bool
    let onUnload: () -> Void
    let onToggleDefault: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle().fill(dotColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 5) {
                Text(id)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Send \"model\": \"\(id)\" in requests to use this one")
                HStack(spacing: 10) {
                    if let entry {
                        Badge(
                            text: entry.format == .gguf ? "GGUF" : "MLX",
                            color: entry.format == .gguf ? .blue : .purple
                        )
                        Text("\(RemoteFitBadge.contextLabel(entry.effectiveContextSize)) context")
                    }
                    if let memory = memoryText {
                        Text(memory)
                    }
                    Text(activityText).foregroundStyle(activityColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Nothing to press while it loads or unloads; the line under the name says which.
            if !loading, !unloading {
                Button("Unload", action: onUnload)
                    .controlSize(.small)
                    .help(requests.isEmpty
                        ? "Free this model's memory; it loads again on its next request"
                        : "Stop its requests in progress and free its memory")
            }
            Button(action: onToggleDefault) {
                Image(systemName: isDefault ? "star.fill" : "star")
                    .foregroundStyle(isDefault ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isDefault ? "Default — loads automatically on Start" : "Load automatically on Start")
        }
        .padding(.vertical, 4)
    }

    private var dotColor: Color {
        if loading || unloading {
            return .orange
        }
        return requests.isEmpty ? .green : .blue
    }

    /// MLX reports each model's memory; for GGUF, the server's footprint is the closest there is.
    private var memoryText: String? {
        if let bytes = live?.memoryBytes {
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        }
        if entry?.format == .gguf, let serverMemoryBytes {
            return "server \(ByteCountFormatter.string(fromByteCount: serverMemoryBytes, countStyle: .memory))"
        }
        return nil
    }

    private var activityText: String {
        if loading {
            if !waitingFor.isEmpty {
                // An MLX folder's name is owner--repo; the repo is enough to recognise it on one line.
                let names = waitingFor.map { $0.components(separatedBy: "--").last ?? $0 }
                return "Waiting for \(names.joined(separator: ", ")) to finish"
            }
            return live?.loadingSeconds.map { "Loading \(Int($0)) s" } ?? "Loading…"
        }
        if unloading {
            return requests.isEmpty ? "Unloading…" : "Stopping \(requests.count) request\(requests.count == 1 ? "" : "s")…"
        }
        if requests.isEmpty {
            return "Idle"
        }
        let count = "\(requests.count) request\(requests.count == 1 ? "" : "s")"
        if let reading = requests.filter({ $0.phase == .readingPrompt }).max(by: { $0.promptTotal < $1.promptTotal }) {
            return "\(count) · reading a prompt \(Int((reading.promptFraction * 100).rounded(.down)))%"
        }
        let speed = requests.compactMap(\.predictedPerSecond).reduce(0, +)
        return speed > 0 ? "\(count) · \(Int(speed.rounded())) tok/s" : count
    }

    private var activityColor: Color {
        loading || unloading ? .orange : requests.isEmpty ? .secondary : .blue
    }
}

private struct ContentUnavailable: View {
    let filter: ModelsPane.FormatFilter
    /// This Mac's top pick, if one's known — see `ModelsPane.
    /// topRecommendation`'s doc comment for why this doesn't wait on a
    /// network verdict.
    let recommended: Catalog.Family?
    let add: () -> Void
    let addRecommended: (Catalog.Family) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(filter == .all ? "No models installed yet." : "No \(filter.rawValue) models installed yet.")
                .foregroundStyle(.secondary)
            // The pick is a GGUF quant — not something to offer under MLX.
            if filter != .mlx, let recommended, let quant = recommended.gguf?.defaultQuant {
                Button("Recommended: \(recommended.name) (\(quant)) — Add…") { addRecommended(recommended) }
            } else {
                Button("Add model…", action: add)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

extension ServerController.Phase {
    /// Relocation wants the store files quiescent; failed is as stopped
    /// as stopped for file purposes.
    var isStoppedForRelocation: Bool {
        self == .stopped || isFailed
    }
}

/// One option in a model's context picker.
struct ContextChoice: Identifiable, Equatable {
    let tokens: Int
    let verdict: FitVerdict?
    /// Doesn't fit at the model's KV cache setting, but would with a 4-bit one (ADR D-057).
    var fitsWith4BitKV = false

    var id: Int {
        tokens
    }

    var verdictLabel: String {
        fitsWith4BitKV ? "Won't fit (fits with a 4-bit KV cache)" : Self.label(for: verdict)
    }

    static func label(for verdict: FitVerdict?) -> String {
        switch verdict {
        case .comfortable: "Comfortable"
        case .tight: "Tight"
        case .wontFit: "Won't fit"
        case nil: "fit unknown"
        }
    }
}

/// One option in a model's KV cache picker (ADR D-057).
struct KVCacheChoice: Identifiable, Equatable {
    let setting: KVCacheSetting
    let verdict: FitVerdict?

    var id: String {
        setting.rawValue
    }
}

/// What the Installed list shows before the store has been read: rows shaped like the real ones, so the pane
/// doesn't claim there are no models for the moment it takes to look.
private struct ModelsLoadingPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0 ..< 3, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    Text(index == 1 ? "mlx-community--Qwen3-8B-4bit" : "Qwen3.6-35B-A3B-UD-Q4_K_M")
                        .font(.body)
                    HStack(spacing: 8) {
                        Text("GGUF · 19.8 GB · 32K ctx · Comfortable")
                        Text("Chat · Coding")
                    }
                    .font(.caption)
                }
                .redacted(reason: .placeholder)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading your models…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityLabel("Reading your models")
    }
}
