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
    @State private var loadError: String?
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
                    Text("Send \"model\": \"<id>\" in a request to pick a model — right-click a row to copy its id.")
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
                    // Best-effort: the row disappearing (or not) is
                    // reflected by the catalog read below.
                    if let id {
                        try? await appState.deleteInstalledModel(id: id)
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
        .onChange(of: appState.storeRevision) { _, _ in
            Task { await refresh() }
        }
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
            Text("Storage")
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
                            if servable {
                                Button("Benchmark…", action: onBenchmark)
                            }
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
                    contextMenuButton
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
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete model")
        }
        .padding(.vertical, 4)
    }

    /// Per-model context size (ADR D-020): Automatic, or a fixed size —
    /// each option labelled with its fit on this Mac.
    private var contextMenuButton: some View {
        Menu {
            Button {
                onSetContext(nil)
            } label: {
                let auto = entry.contextSize.map { " (\(RemoteFitBadge.contextLabel($0)))" } ?? ""
                Label("Automatic\(auto)", systemImage: entry.userContextSize == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(contextChoices) { choice in
                Button {
                    onSetContext(choice.tokens)
                } label: {
                    Label(
                        "\(RemoteFitBadge.contextLabel(choice.tokens)) — \(choice.verdictLabel)",
                        systemImage: entry.userContextSize == choice.tokens ? "checkmark" : ""
                    )
                }
                .disabled(choice.verdict == .wontFit)
            }
            if !kvCacheChoices.isEmpty {
                Divider()
                Section("KV cache") {
                    ForEach(kvCacheChoices) { choice in
                        Button {
                            onSetKVCache(choice.setting)
                        } label: {
                            Label(
                                "\(choice.setting.label) — \(ContextChoice.label(for: choice.verdict))",
                                systemImage: entry.effectiveKVCache == choice.setting ? "checkmark" : ""
                            )
                        }
                        .disabled(choice.verdict == .wontFit)
                    }
                }
            }
        } label: {
            Text(contextLabel)
                .font(.caption)
                .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(
            "Context size — how much text the model can work with at once. Coding agents need 32K or more. "
                + "An 8-bit or 4-bit KV cache holds a longer context in the same memory, a little less accurately "
                + "(and, for MLX models, reading prompts more slowly). Applies on the next Start."
        )
    }

    private var contextLabel: String {
        let size = "\(RemoteFitBadge.contextLabel(entry.effectiveContextSize)) ctx"
        return entry.effectiveKVCache == .full ? size : "\(size) · \(entry.effectiveKVCache.label) KV"
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
