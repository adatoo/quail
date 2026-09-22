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
    @State private var tokenDraft = ""

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
            AddModelSheet(appState: appState, defaultFilter: formatFilter)
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
        .task { await refresh() }
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

    @ViewBuilder private var installedList: some View {
        if entries.isEmpty {
            ContentUnavailable(
                filter: formatFilter,
                add: { showAddSheet = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(entries) { entry in
                ModelRow(
                    entry: entry,
                    verdict: verdicts[entry.id],
                    loaded: loadedStates[entry.id],
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
                Button("Add model…") { showAddSheet = true }
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
            EmptyView()
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
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.id)
                .lineLimit(1)
                .truncationMode(.middle)
            badge(entry.format == .gguf ? "GGUF" : "MLX", entry.format == .gguf ? .blue : .purple)
            if let loaded {
                badge(loaded, loaded == "loaded" ? .green : .gray)
            }
            Spacer()
            if let verdict {
                verdictTag(verdict)
            }
            Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete model")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func verdictTag(_ estimate: FitEstimate) -> some View {
        switch estimate.verdict {
        case .comfortable:
            badge("Comfortable", .green)
        case let .tight(reduced):
            badge("Tight · \(reduced)", .yellow)
        case .wontFit:
            badge("Won't fit", .red)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct ContentUnavailable: View {
    let filter: ModelsPane.FormatFilter
    let add: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(filter == .all ? "No models installed yet." : "No \(filter.rawValue) models installed yet.")
                .foregroundStyle(.secondary)
            Button("Add model…", action: add)
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
