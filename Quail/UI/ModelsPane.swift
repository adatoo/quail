import SwiftUI

/// The Models settings tab (docs/IMPLEMENTATION_PLAN.md Phase 2 step 7):
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

    /// The user's explicit ask for step 7: "MLX is preferred — should
    /// have a switch/filter to just show MLX models."
    @State private var formatFilter: FormatFilter = .all
    @State private var rows: [InstalledModel] = []
    @State private var verdicts: [String: FitEstimate] = [:]
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

    enum FormatFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case gguf = "GGUF"
        case mlx = "MLX"

        var id: String {
            rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Show", selection: $formatFilter) {
                ForEach(FormatFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding([.horizontal, .top])

            installedList

            Divider()

            storeSection
        }
        .frame(minHeight: 320)
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
        .onAppear { tokenDraft = appState.hfToken ?? "" }
        // Keyed on the server phase: opening the pane refreshes once,
        // and every stop→ready transition refreshes again (the verdicts
        // re-check against current device facts, the Load buttons appear).
        // While the router is running, loaded state is also re-polled on
        // a timer — a model can load behind the pane's back (the
        // router's own web UI, auto-load on the first chat request, a
        // ping), and there is no push channel from llama-server to know
        // about it. 2 s, same cadence the Logs window tails at.
        .task(id: appState.serverController.phase) {
            await refresh()
            while appState.serverController.phase == .ready {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard appState.serverController.phase == .ready else { break }
                loadedStates = await appState.loadedModelStates()
            }
        }
        .onChange(of: appState.installs.phase) { _, newPhase in
            // Rows only appear/verify once an install reaches a terminal
            // phase; the downloading phase re-renders by observation.
            switch newPhase {
            case .installed, .failed:
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
        Recommender.candidates(catalog: appState.catalog, device: DeviceInfo.current()).first
    }

    @ViewBuilder private var installedList: some View {
        if entries.isEmpty {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(entries) { entry in
                ModelRow(
                    entry: entry,
                    verdict: verdicts[entry.id],
                    loaded: loadedStates[entry.id],
                    serverReady: appState.serverController.phase == .ready,
                    isDefault: appState.config.defaultModelID == entry.id,
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
                    }
                )
            }
            .frame(maxHeight: 260)
        }
    }

    private var storeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            installProgress

            HStack {
                Text("Store:")
                    .foregroundStyle(.secondary)
                Text(appState.modelStore.rootURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reload") {
                    Task { await refresh() }
                }
                .help("Re-read the store and the server's loaded models")
                Button("Add model…") {
                    preselectFamily = nil
                    showAddSheet = true
                }
                Button("Relocate…") { relocate() }
                    .disabled(
                        appState.installs.isDownloading
                            || !appState.serverController.phase.isStoppedForRelocation
                    )
            }

            HStack {
                SecureField("Hugging Face token (for gated repos)", text: $tokenDraft)
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
        .padding()
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
                Button("Cancel") { appState.installs.cancel() }
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
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func refresh() async {
        loadedStates = await appState.loadedModelStates()
        let store = appState.modelStore
        let device = DeviceInfo.current()
        let runtime = appState.config.runtimeID
        let bandwidth = ChipBandwidthTable.loadFromBundle()
        // Disk reconciliation + verdicts off the main actor; the pane
        // reads (does not write) catalog.json — persistence stays
        // start()/install()'s job, so merely looking at the pane never
        // mutates the store.
        let result = await Task.detached(priority: .utility) {
            let catalog = store.refreshedCatalog(device: device, ggufRuntime: runtime, bandwidthTable: bandwidth)
            var verdicts: [String: FitEstimate] = [:]
            for entry in catalog.entries {
                verdicts[entry.id] = ModelPreview.installed(
                    entry: entry, store: store, device: device,
                    ggufRuntime: runtime, bandwidthTable: bandwidth
                )
            }
            return (catalog.entries, verdicts)
        }.value
        rows = result.0
        verdicts = result.1
    }
}

/// Loaded-state + verdict + size for one installed model.
private struct ModelRow: View {
    let entry: InstalledModel
    let verdict: FitEstimate?
    let loaded: String?
    let serverReady: Bool
    /// Whether this is `Config.defaultModelID` — the one row gets
    /// `load-on-startup = true` in `presets.ini` (ADR D-017).
    let isDefault: Bool
    let onLoad: () -> Void
    let onToggleDefault: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.id)
                .lineLimit(1)
                .truncationMode(.middle)
            Badge(text: entry.format == .gguf ? "GGUF" : "MLX", color: entry.format == .gguf ? .blue : .purple)
            if loaded == "loaded" {
                Badge(text: "loaded", color: .green)
            } else if let loaded {
                Badge(text: loaded, color: .gray)
            }
            Spacer()
            // Hot swap (step 8): an installed GGUF can be loaded into the
            // running router with a click. MLX rows get the badge-only
            // treatment — their runtimes are Phase 3, and offering a
            // button that must fail would be a lie about capability.
            if serverReady, entry.format == .gguf, loaded != "loaded" {
                Button("Load", action: onLoad)
                    .controlSize(.small)
            }
            if let verdict {
                FitVerdictBadge(estimate: verdict)
            }
            Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            // Usable while stopped (unlike Load) — it just sets what
            // gets written into presets.ini on the next Start. GGUF
            // only: `load-on-startup` is a llama.cpp router-mode
            // preset key, and nothing can serve MLX yet (Phase 3).
            if entry.format == .gguf {
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
        .padding(.vertical, 2)
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
            if let recommended, let quant = recommended.gguf?.defaultQuant {
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
