import SwiftUI

/// The "Add model…" sheet (docs/IMPLEMENTATION_PLAN.md Phase 2 step 7):
/// the curated catalog list or a pasted Hugging Face repo, a format
/// switch honouring the pane's filter, a quant picker for GGUF, a
/// pre-download fit verdict (§7: "Both are read from the Hub file
/// listing before download, so the verdict shows in the picker"), and
/// download progress.
///
/// Two columns: a searchable list on the left (every row carries a fit
/// badge — or says why it can't), the selected model's details on the
/// right, and a standard footer with Cancel / Download. Redesigned after
/// user feedback: the earlier single-column version clipped the list,
/// never named the selected model, and left most verdicts blank.
///
/// All the real decisions — which files a pick means, what the verdict
/// is — live in `ModelAddPlan`/`ModelPreview` (unit-tested); this view
/// sequences them.
struct AddModelSheet: View {
    let appState: AppState
    /// Starts where the pane's filter left off — the user asked for the
    /// MLX-preferred browse to survive into the sheet, not reset.
    var defaultFilter: ModelsPane.FormatFilter = .all
    /// Set when the sheet was opened from `ModelsPane`'s empty-state
    /// recommendation button — selects that family immediately.
    var preselect: Catalog.Family?

    @Environment(\.dismiss) private var dismiss
    private let device = DeviceInfo.current()

    @State private var filter: ModelsPane.FormatFilter = .all
    @State private var query = ""
    @State private var selection: Selection?
    @State private var listing: HFRepo?
    @State private var listingError: String?
    @State private var format: ModelFormat = .gguf
    @State private var quant: String?
    @State private var pickFit: RemoteFit = .checking
    /// What's on disk, so rows can say "Installed" and an installed pick
    /// offers Delete instead of a second download.
    @State private var installed: [InstalledModel] = []
    @State private var pendingDelete: InstalledModel?
    @State private var deleteError: String?

    /// The repo the listing currently corresponds to ("" when nothing
    /// is selectable) — changes when selection or format change.
    private var loadKey: String {
        guard let selection, let repo = currentRepo(for: selection) else { return "" }
        return repo
    }

    private enum Selection: Hashable {
        case curated(Catalog.Family)
        case pasted(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 350)
                Divider()
                ScrollView {
                    detail
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 580)
        .onAppear {
            filter = defaultFilter
            appState.installs.acknowledgeFinished()
            if let preselect {
                selection = .curated(preselect)
            }
        }
        .onChange(of: selection) { _, _ in appState.installs.acknowledgeFinished() }
        .onChange(of: appState.installs.installedCount) { _, _ in
            Task { await reloadInstalled() }
        }
        .task { await reloadInstalled() }
        .onChange(of: appState.storeRevision) { _, _ in Task { await reloadInstalled() } }
        .alert(
            "Delete \(pendingDelete?.id ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: {
                if !$0 {
                    pendingDelete = nil
                }
            })
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete {
                    Task { await delete(entry) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the model's files from this Mac. If it's loaded, the server is stopped first.")
        }
        // Keyed on the resolved repo, not just the selection: flipping a
        // curated family's format points at a different repo/listing.
        .task(id: loadKey) { await loadListing() }
        .task(id: resolvedPick) { await loadPickFit() }
        // §7: "Recommendations ... filtered to Comfortable". Also fills
        // every other row's badge; already-resolved families are skipped,
        // so reopening the sheet is cheap.
        .task {
            await appState.loadCatalogVerdicts()
            if selection == nil, let first = recommendedFamilies.first {
                selection = .curated(first)
            }
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Model").font(.title3.bold())
                Text(deviceLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Format", selection: $filter) {
                ForEach(ModelsPane.FormatFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// "Apple M4 Pro · 64 GB · comfortable up to ~55B" — from the
    /// measured GPU ceiling (see `FitEstimator.approxMaxParamsB`), never
    /// the catalog tier's open-ended upper bound, which once rendered as
    /// "showing 35–999B models".
    private var deviceLine: String {
        var parts: [String] = []
        if let chip = device.chipName {
            parts.append(chip)
        }
        if let bytes = device.unifiedMemoryBytes {
            parts.append("\(Int(Double(bytes) / 1_073_741_824)) GB")
        }
        if let ceiling = device.gpuWorkingSetCeilingBytes {
            let maxParams = FitEstimator.approxMaxParamsB(gpuCeilingBytes: ceiling, comfortable: true)
            parts.append("comfortable up to ~\(maxParams)B")
        }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            switch appState.installs.phase {
            case .installed where installedPick == nil && !appState.installs.isDownloading:
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            default:
                if let entry = installedPick {
                    Button("Delete…", role: .destructive) { pendingDelete = entry }
                    Spacer()
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Installed") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                } else {
                    if let total = pickBytes, total > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) download")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    // `.sheet` supplies no close chrome on macOS; downloads carry on when it's hidden.
                    Button(appState.installs.isDownloading ? "Hide" : "Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(downloadButtonTitle) { startDownload() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canDownload || pickStanding != nil)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Left: search + list

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search, or paste owner/name from Hugging Face", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(lookupPasted)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .padding(10)

            List(selection: $selection) {
                if let repo = pastedCandidate {
                    Section("Hugging Face") {
                        Label("Look up \(repo)", systemImage: "arrow.down.circle")
                            .tag(Selection.pasted(repo))
                    }
                }
                if case let .pasted(repo)? = selection, repo != pastedCandidate {
                    Section("Hugging Face") {
                        Label(repo, systemImage: "link").tag(Selection.pasted(repo))
                    }
                }
                if !recommendedFamilies.isEmpty, query.isEmpty {
                    Section("Recommended for This Mac") {
                        ForEach(recommendedFamilies) { familyRow($0) }
                    }
                }
                let rest = visibleFamilies.filter { family in
                    !(query.isEmpty && recommendedFamilies.contains { $0.id == family.id })
                }
                Section(query.isEmpty ? "All Models" : "Matches") {
                    ForEach(rest) { familyRow($0) }
                    if rest.isEmpty {
                        Text("No catalog models match.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func familyRow(_ family: Catalog.Family) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(family.name).lineLimit(1).help(family.name)
                    if !family.isCurated {
                        Badge(text: "user-added", color: .secondary)
                    }
                }
                Text(subtitle(for: family))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // A tick, not a pill: with both pills the family's name lost
            // its last words ("Qwen3.6 35B-A3B (…").
            if let standing = familyStanding(family) {
                Image(systemName: standing == .downloading ? "arrow.down.circle.fill" : "clock")
                    .foregroundStyle(standing == .downloading ? Color.accentColor : .secondary)
                    .help(standing == .downloading ? "Downloading" : "Queued")
            } else if !InstalledLookup.entries(for: family, in: installed).isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
                    .help("Installed")
            }
            RemoteFitBadge(fit: appState.catalogFits[family.id])
                .fixedSize()
        }
        .padding(.vertical, 2)
        .tag(Selection.curated(family))
    }

    private func familyStanding(_ family: Catalog.Family) -> ModelInstallController.Standing? {
        let repos = [family.gguf?.repo, family.mlx?.repo].compactMap(\.self)
        let installs = appState.installs
        if installs.isDownloading, let target = installs.target, repos.contains(target.repo) {
            return .downloading
        }
        return installs.queue.contains { repos.contains($0.target.repo) } ? .queued : nil
    }

    /// "32B · 3B active · coding · GGUF, MLX"
    private func subtitle(for family: Catalog.Family) -> String {
        var parts: [String] = []
        if let params = family.paramsB {
            parts.append("\(Self.formatParams(params))B")
        }
        if let active = family.activeParamsB {
            parts.append("\(Self.formatParams(active))B active")
        }
        if let role = family.role, role != "general" {
            parts.append(role)
        }
        let formats = [family.gguf != nil ? "GGUF" : nil, family.mlx != nil ? "MLX" : nil].compactMap(\.self)
        parts.append(formats.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    private static func formatParams(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%g", value)
    }

    private var filteredFamilies: [Catalog.Family] {
        appState.catalog.families.filter { family in
            switch filter {
            case .all: true
            case .gguf: family.gguf != nil
            case .mlx: family.mlx != nil
            }
        }
    }

    /// `filteredFamilies` narrowed by the search text (name or repo).
    private var visibleFamilies: [Catalog.Family] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return filteredFamilies }
        return filteredFamilies.filter { family in
            family.name.localizedCaseInsensitiveContains(needle)
                || (family.gguf?.repo.localizedCaseInsensitiveContains(needle) ?? false)
                || (family.mlx?.repo.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    /// The search text as a repo id, when it looks like one
    /// ("owner/name", or a huggingface.co URL).
    private var pastedCandidate: String? {
        let repo = query.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://huggingface.co/", with: "")
        let parts = repo.split(separator: "/")
        guard parts.count == 2, !repo.contains(" ") else { return nil }
        return repo
    }

    /// §7's "Recommendations": curated, in-tier, GGUF-capable families
    /// verified Comfortable, honouring whatever format filter the user
    /// already has selected.
    private var recommendedFamilies: [Catalog.Family] {
        let finalized = Recommender.finalize(
            candidates: Recommender.candidates(catalog: appState.catalog, device: device),
            verdicts: appState.catalogVerdicts
        )
        let allowed = Set(filteredFamilies.map(\.id))
        return finalized.filter { allowed.contains($0.id) }
    }

    private func lookupPasted() {
        guard let repo = pastedCandidate else { return }
        selection = .pasted(repo)
    }

    // MARK: - Right: the selected model

    /// The downloads (running, waiting, and how the last one ended) above whatever model is selected, so
    /// choosing another model never hides what's downloading.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            downloads
            detailForSelection
        }
    }

    @ViewBuilder private var downloads: some View {
        let installs = appState.installs
        if installs.isDownloading || !installs.queue.isEmpty || installs.phase != .idle {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if case let .downloading(written, total, file) = installs.phase, let target = installs.target {
                        HStack(alignment: .firstTextBaseline) {
                            Label(Self.describe(target), systemImage: "arrow.down.circle")
                                .font(.headline)
                            Spacer()
                            Button("Cancel", role: .destructive) { installs.cancel() }
                                .controlSize(.small)
                        }
                        ProgressView(value: total > 0 ? Double(written) / Double(total) : 0)
                        Text(ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
                            + " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                            + " · " + file)
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .lineLimit(1).truncationMode(.middle)
                    }
                    switch installs.phase {
                    case let .installed(id):
                        Label(
                            "Installed \(id). Star it in the Models list to load it on Start.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    case let .failed(message):
                        Label("Download failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    case .idle, .downloading:
                        EmptyView()
                    }
                    if !installs.queue.isEmpty {
                        Text("Up next").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(installs.queue) { job in
                            HStack {
                                Image(systemName: "clock").foregroundStyle(.secondary)
                                Text(Self.describe(job.target)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Remove") { installs.removeQueued(job.id) }
                                    .controlSize(.small)
                            }
                            .font(.callout)
                        }
                    }
                    if installs.isDownloading {
                        Text("Downloads carry on if you close this window. You can queue more meanwhile.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// "owner/name · Q4_K_M · GGUF"
    private static func describe(_ target: ModelInstallController.Target) -> String {
        [target.repo, target.quant, target.format == .gguf ? "GGUF" : "MLX"].compactMap(\.self).joined(separator: " · ")
    }

    /// What Download would fetch for the current pick, to compare against running and queued downloads.
    private var pickTarget: ModelInstallController.Target? {
        guard let repo = listing?.id else { return nil }
        return .init(repo: repo, format: format, quant: format == .gguf ? quant ?? quantOptions.first : nil)
    }

    private var pickStanding: ModelInstallController.Standing? {
        pickTarget.flatMap { appState.installs.standing(of: $0) }
    }

    private var downloadButtonTitle: String {
        switch pickStanding {
        case .downloading: "Downloading…"
        case .queued: "Queued"
        case nil: appState.installs.isDownloading ? "Add to Queue" : "Download"
        }
    }

    @ViewBuilder private var detailForSelection: some View {
        if let selection {
            VStack(alignment: .leading, spacing: 16) {
                titleBlock(for: selection)
                if let listingError {
                    Label(listingError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if listing == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the repo from Hugging Face…").foregroundStyle(.secondary)
                    }
                } else {
                    Form {
                        availableFormatsPicker
                        quantPicker
                    }
                    .formStyle(.columns)
                    if format == .mlxSafetensors, !appState.canServe(.mlxSafetensors) {
                        Label(
                            "MLX models run on the Quail server runtime (Settings → Endpoint). With llama.cpp chosen, choose GGUF to use it now.",
                            systemImage: "info.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    if let entry = installedPick {
                        Label(
                            "Installed\(entry.bytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file) : "") — it's in your Models list as \(entry.id).",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let deleteError {
                        Label(deleteError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    FitCard(fit: pickFit, gpuCeilingBytes: device.gpuWorkingSetCeilingBytes)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Choose a model on the left, or paste a Hugging Face repo into the search field.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private func titleBlock(for selection: Selection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch selection {
            case let .curated(family):
                Text(family.name).font(.title2.bold())
                Text(subtitle(for: family)).foregroundStyle(.secondary)
                if let license = family.license {
                    Text("License: \(license)").font(.caption).foregroundStyle(.secondary)
                }
            case let .pasted(repo):
                Text(repo).font(.title2.bold())
                Text("From Hugging Face — not in Quail's curated catalog").foregroundStyle(.secondary)
            }
            if let repo = currentRepo(for: selection), let url = URL(string: "https://huggingface.co/\(repo)") {
                Link(repo, destination: url).font(.caption)
            }
        }
    }

    private var availableFormats: [ModelFormat] {
        guard let listing else { return [] }
        if case let .curated(family)? = selection {
            var formats: [ModelFormat] = []
            if family.gguf != nil {
                formats.append(.gguf)
            }
            if family.mlx != nil {
                formats.append(.mlxSafetensors)
            }
            return formats.filter { listingOf($0) != nil || $0 == format }
        }
        return ModelAddPlan.format(guessing: listing).map { [$0] } ?? []
    }

    private func listingOf(_ candidate: ModelFormat) -> String? {
        guard case let .curated(family)? = selection else { return listing?.id }
        return family.repo(for: candidate)
    }

    @ViewBuilder private var availableFormatsPicker: some View {
        let formats = availableFormats
        if formats.count > 1 {
            Picker("Format", selection: $format) {
                ForEach(formats, id: \.self) { f in
                    Text(f == .gguf ? "GGUF (llama.cpp)" : "MLX").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
        } else if let only = formats.first {
            LabeledContent("Format", value: only == .gguf ? "GGUF (llama.cpp)" : "MLX")
                .onAppear { format = only }
        }
    }

    /// Each option shows its download size, and the catalog's own pick
    /// is marked — "Q4_K_M" alone means nothing to most people.
    @ViewBuilder private var quantPicker: some View {
        let options = quantOptions
        if format == .gguf, !options.isEmpty {
            Picker("Quantization", selection: Binding(
                get: { quant ?? options.first ?? "" },
                set: { quant = $0 }
            )) {
                ForEach(options, id: \.self) { option in
                    Text(quantLabel(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320)
        }
    }

    private func quantLabel(_ option: String) -> String {
        var label = option
        if let listing {
            let bytes = ModelAddPlan.ggufFiles(for: listing, quant: option, mmproj: mmprojName)
                .reduce(0) { $0 + $1.sizeBytes }
            if bytes > 0 {
                label += " — " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }
        }
        if case let .curated(family)? = selection, family.gguf?.defaultQuant == option {
            label += " (recommended)"
        }
        if installedEntry(format: .gguf, quant: option) != nil {
            label += " — installed"
        }
        return label
    }

    private var quantOptions: [String] {
        guard format == .gguf, let listing else { return [] }
        let labels: [String] = if case let .curated(family)? = selection, let variant = family.gguf {
            variant.quants
        } else {
            ModelAddPlan.quants(in: listing)
        }
        // Only offer what the repo actually has.
        return labels.filter { q in
            !ModelAddPlan.ggufFiles(for: listing, quant: q, mmproj: mmprojName).isEmpty
        }
    }

    private var mmprojName: String? {
        guard case let .curated(family)? = selection else { return nil }
        return family.gguf?.mmproj
    }

    /// The resolved file set for the current pick — `nil` until a
    /// download target is unambiguous, which also gates the button.
    private var resolvedFiles: [HFFile]? {
        guard let listing else { return nil }
        switch format {
        case .mlxSafetensors:
            let files = ModelAddPlan.mlxFiles(for: listing)
            return files.isEmpty ? nil : files
        case .gguf:
            let chosen = quant ?? quantOptions.first
            guard let chosen else { return nil }
            let files = ModelAddPlan.ggufFiles(for: listing, quant: chosen, mmproj: mmprojName)
            return files.isEmpty ? nil : files
        }
    }

    private var resolvedPick: String? {
        guard let files = resolvedFiles, let repo = listing?.id else { return nil }
        return repo + "|" + (quant ?? "") + "|" + files.reduce(0) { $0 + $1.sizeBytes }.description
    }

    private var canDownload: Bool {
        resolvedFiles != nil
    }

    private var pickBytes: Int64? {
        resolvedFiles?.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Effects

    private func loadListing() async {
        listing = nil
        listingError = nil
        quant = nil
        pickFit = .checking
        guard let selection else { return }
        let repo = currentRepo(for: selection)
        guard let repo else { return }
        do {
            let found = try await appState.installs.downloader.listFiles(repo: repo, token: appState.hfToken)
            guard listing?.id != found.id else { return }
            listing = found
            if case let .curated(family) = selection, family.repo(for: format) == nil,
               let alt = [ModelFormat.gguf, .mlxSafetensors].first(where: { family.repo(for: $0) != nil })
            {
                format = alt
            }
            quant = defaultQuant()
        } catch let error as HFDownloadError {
            listingError = ModelInstallController.describe(error)
        } catch {
            listingError = String(describing: error)
        }
    }

    /// The repo to list for a selection, given the format currently in
    /// effect — a curated family switching GGUF↔MLX lists a different
    /// repo, so this drives the listing reload (see `loadKey`).
    private func currentRepo(for selection: Selection) -> String? {
        switch selection {
        case let .pasted(repo):
            repo
        case let .curated(family):
            family.repo(for: format) ?? family.repo(for: .gguf) ?? family.repo(for: .mlxSafetensors)
        }
    }

    private func defaultQuant() -> String? {
        if case let .curated(family)? = selection, format == .gguf,
           let preferred = family.gguf?.defaultQuant, quantOptions.contains(preferred)
        {
            return preferred
        }
        return quantOptions.first
    }

    /// The selected pick's verdict — always ends in an estimate or a
    /// stated reason, never a silent blank.
    private func loadPickFit() async {
        pickFit = .checking
        guard let listing, let files = resolvedFiles else {
            if listing != nil {
                pickFit = .unknown("Nothing downloadable for this choice")
            }
            return
        }
        let bandwidth = ChipBandwidthTable.loadFromBundle()
        switch format {
        case .gguf:
            pickFit = await ModelPreview.remoteGGUFFit(
                repo: listing.id, files: files, downloader: appState.installs.downloader,
                device: DeviceInfo.current(), ggufRuntime: appState.config.runtimeID,
                bandwidthTable: bandwidth, token: appState.hfToken, cache: appState.shapeCache
            )
        case .mlxSafetensors:
            pickFit = await ModelPreview.remoteMLXFit(
                repo: listing.id, listing: listing, downloader: appState.installs.downloader,
                device: DeviceInfo.current(), bandwidthTable: bandwidth, token: appState.hfToken,
                cache: appState.shapeCache
            )
        }
    }

    /// The installed entry for the current pick (format + quant), if any.
    private var installedPick: InstalledModel? {
        installedEntry(format: format, quant: format == .gguf ? (quant ?? quantOptions.first) : nil)
    }

    private func installedEntry(format: ModelFormat, quant: String?) -> InstalledModel? {
        switch selection {
        case let .curated(family)?:
            InstalledLookup.entry(for: family, format: format, quant: quant, in: installed)
        case let .pasted(repo)?:
            InstalledLookup.entry(forRepo: listing?.id ?? repo, format: format, quant: quant, in: installed)
        case nil:
            nil
        }
    }

    /// Disk-reconciled, like the Models pane — a hand-placed GGUF counts too.
    private func reloadInstalled() async {
        let store = appState.modelStore
        let device = DeviceInfo.current()
        let runtime = appState.config.runtimeID
        let bandwidth = ChipBandwidthTable.loadFromBundle()
        installed = await Task.detached(priority: .utility) {
            store.refreshedCatalog(device: device, ggufRuntime: runtime, bandwidthTable: bandwidth).entries
        }.value
    }

    private func delete(_ entry: InstalledModel) async {
        pendingDelete = nil
        do {
            try await appState.deleteInstalledModel(id: entry.id)
            deleteError = nil
        } catch {
            deleteError = "Couldn't delete \(entry.id): \(error)"
        }
        await reloadInstalled()
    }

    private func startDownload() {
        guard canDownload, pickStanding == nil,
              let files = resolvedFiles, let repo = listing?.id else { return }
        let familyID: String?
        if case let .curated(family)? = selection {
            familyID = family.id
        } else {
            familyID = nil
            appState.addUserCatalogRepo(repo, format: format)
        }
        appState.installs.install(
            repo: repo, files: files, format: format,
            quant: format == .gguf ? quant ?? quantOptions.first : nil,
            family: familyID
        )
    }
}

/// The verdict for the selected pick, spelled out: what it needs, what
/// this Mac has, how fast — or why there's no verdict.
private struct FitCard: View {
    let fit: RemoteFit
    let gpuCeilingBytes: Int64?

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                icon.font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.headline)
                    if let explanation {
                        Text(explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        }
    }

    @ViewBuilder private var icon: some View {
        switch fit {
        case .checking:
            ProgressView().controlSize(.small)
        case let .estimate(estimate):
            switch estimate.verdict {
            case .comfortable: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .tight: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            case .wontFit: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        case .unknown:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        switch fit {
        case .checking: "Checking fit on this Mac…"
        case let .estimate(estimate):
            switch estimate.verdict {
            case .comfortable: "Runs comfortably on this Mac"
            case let .tight(reduced): "Tight fit — runs with a reduced \(RemoteFitBadge.contextLabel(reduced)) context"
            case .wontFit: "Won't fit on this Mac"
            }
        case .unknown: "Fit unknown"
        }
    }

    private var explanation: String? {
        switch fit {
        case .checking: return nil
        case let .unknown(reason): return reason
        case let .estimate(estimate):
            let needed = ByteCountFormatter.string(fromByteCount: estimate.ramNeededBytes, countStyle: .memory)
            let available = gpuCeilingBytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory)
            }
            var line = "Needs about \(needed)"
            if let available {
                line += " of the \(available) this Mac's GPU can use"
            }
            line += "."
            if let speed = estimate.estimatedTokensPerSecond, estimate.verdict != .wontFit {
                line += " Roughly \(Int(speed.rounded())) tokens/s."
            }
            if estimate.verdict == .wontFit {
                line += " Try a smaller quantization or a smaller model."
            }
            return line
        }
    }
}
