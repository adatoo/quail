import SwiftUI

/// The "Add model…" sheet (docs/IMPLEMENTATION_PLAN.md Phase 2 step 7):
/// the curated catalog list or a pasted Hugging Face repo, a format
/// switch honouring the pane's filter, a quant picker for GGUF, a
/// pre-download fit verdict (§7: "Both are read from the Hub file
/// listing before download, so the verdict shows in the picker"), and
/// download progress.
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
    /// recommendation button — selects that family immediately rather
    /// than waiting for `loadRecommendedSelection()`'s own pick.
    var preselect: Catalog.Family?

    @Environment(\.dismiss) private var dismiss
    private let device = DeviceInfo.current()

    @State private var filter: ModelsPane.FormatFilter = .all
    @State private var pasteField = ""
    @State private var selection: Selection?
    @State private var listing: HFRepo?
    @State private var listingError: String?
    @State private var format: ModelFormat = .gguf
    @State private var quant: String?
    @State private var verdict: FitEstimate?

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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add model").font(.headline)
                    if let tierHeaderLine {
                        Text(tierHeaderLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(ModelsPane.FormatFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            .padding()

            familyList

            Divider()

            detail
                .frame(minHeight: 150)
                .padding()
        }
        .frame(width: 560, height: 560)
        .onAppear {
            filter = defaultFilter
            if let preselect {
                selection = .curated(preselect)
            }
        }
        // Keyed on the resolved repo, not just the selection: flipping a
        // curated family's format points at a different repo/listing.
        .task(id: loadKey) { await loadListing() }
        .task(id: resolvedPick) { await loadVerdict() }
        // §7: "Recommendations ... filtered to Comfortable" — runs once
        // per sheet lifetime (`AppState.loadCatalogVerdicts` itself skips
        // anything already fetched, so reopening the sheet is free).
        .task {
            await appState.loadCatalogVerdicts()
            if selection == nil, let first = recommendedFamilies.first {
                selection = .curated(first)
            }
        }
    }

    // MARK: - Left: the picker

    @ViewBuilder private var familyList: some View {
        List(selection: $selection) {
            if recommendedFamilies.isEmpty {
                ForEach(filteredFamilies) { family in familyRow(family) }
                pastedRow
            } else {
                Section("Recommended for this Mac") {
                    ForEach(recommendedFamilies) { family in familyRow(family) }
                }
                let rest = filteredFamilies.filter { family in !recommendedFamilies.contains { $0.id == family.id } }
                Section("All Models") {
                    ForEach(rest) { family in familyRow(family) }
                    pastedRow
                }
            }
        }
        .frame(maxHeight: 220)

        HStack {
            TextField("…or paste a Hugging Face repo (owner/name)", text: $pasteField)
                .textFieldStyle(.roundedBorder)
                .onSubmit(lookupPasted)
            Button("Look up", action: lookupPasted)
                .disabled(pasteField.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding([.horizontal, .bottom])
    }

    @ViewBuilder private var pastedRow: some View {
        if case let .pasted(repo)? = selection, !filteredFamilies.contains(where: { $0.id == repo }) {
            Label(repo, systemImage: "link").tag(Selection.pasted(repo))
        }
    }

    private func familyRow(_ family: Catalog.Family) -> some View {
        HStack {
            Text(family.name)
            if !family.isCurated {
                Text("user-added")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.secondary.opacity(0.2), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let repo = family.gguf?.repo, let verdict = appState.catalogVerdicts[repo] {
                FitVerdictBadge(estimate: verdict)
                if let speed = verdict.estimatedTokensPerSecond {
                    Text("~\(speed.rounded()) tok/s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if family.gguf != nil {
                Text("GGUF").font(.caption2).foregroundStyle(.blue)
            }
            if family.mlx != nil {
                Text("MLX").font(.caption2).foregroundStyle(.purple)
            }
        }
        .tag(Selection.curated(family))
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

    /// §7's "Recommendations": curated, in-tier, GGUF-capable families
    /// verified Comfortable, honouring whatever format filter the user
    /// already has selected (an MLX-only browse shouldn't recommend a
    /// GGUF model it won't show anywhere else in the list).
    private var recommendedFamilies: [Catalog.Family] {
        let finalized = Recommender.finalize(
            candidates: Recommender.candidates(catalog: appState.catalog, device: device),
            verdicts: appState.catalogVerdicts
        )
        let allowed = Set(filteredFamilies.map(\.id))
        return finalized.filter { allowed.contains($0.id) }
    }

    private var tierHeaderLine: String? {
        guard let bytes = device.unifiedMemoryBytes,
              let (_, tier) = appState.catalog.tier(forMemoryBytes: bytes),
              let range = tier.recommendedRange
        else { return nil }
        let chip = device.chipName.map { "\($0) · " } ?? ""
        let gb = Int(Double(bytes) / 1_073_741_824)
        return "\(chip)\(gb) GB · showing \(Int(range.lowerBound))–\(Int(range.upperBound))B models"
    }

    private func lookupPasted() {
        let repo = pasteField.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://huggingface.co/", with: "")
        guard !repo.isEmpty else { return }
        selection = .pasted(repo)
    }

    // MARK: - Right: the pick + verdict + action

    @ViewBuilder private var detail: some View {
        switch appState.installs.phase {
        case let .downloading(written, total, file):
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading \(file)")
                ProgressView(value: total > 0 ? Double(written) / Double(total) : 0)
                Text(ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
                    + " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { appState.installs.cancel() }
                Button("Close") { dismiss() }
            }
        case .installed:
            VStack(alignment: .leading, spacing: 8) {
                Label("Installed.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Done") { dismiss() }
            }
        default:
            detailForSelection
        }
    }

    @ViewBuilder private var detailForSelection: some View {
        if selection == nil {
            Text("Pick a family, or paste a repo.")
                .foregroundStyle(.secondary)
        } else if let listingError {
            Label(listingError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.callout)
        } else if listing == nil {
            ProgressView().controlSize(.small)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                availableFormatsPicker
                quantPicker
                verdictLine
                Spacer()
                HStack {
                    Button("Download") { startDownload() }
                        .disabled(!canDownload || appState.installs.isDownloading)
                    if let total = pickBytes, total > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
            .labelsHidden()
        } else if let only = formats.first {
            LabeledContent("Format", value: only == .gguf ? "GGUF (llama.cpp)" : "MLX")
                .onAppear { format = only }
        }
    }

    @ViewBuilder private var quantPicker: some View {
        let options = quantOptions
        if format == .gguf, !options.isEmpty {
            Picker("Quant", selection: Binding(
                get: { quant ?? options.first ?? "" },
                set: { quant = $0; verdict = nil }
            )) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
        }
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
        verdict = nil
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

    private func loadVerdict() async {
        guard let listing, let pick = resolvedPick, canDownload else { verdict = nil; return }
        verdict = try? await ModelPreview.remote(
            repo: listing.id,
            format: format,
            listing: listing,
            ggufFile: resolvedFiles?.first,
            downloader: appState.installs.downloader,
            device: DeviceInfo.current(),
            ggufRuntime: appState.config.runtimeID,
            bandwidthTable: ChipBandwidthTable.loadFromBundle(),
            token: appState.hfToken
        )
        _ = pick
    }

    @ViewBuilder private var verdictLine: some View {
        if let verdict {
            switch verdict.verdict {
            case .comfortable:
                Label(
                    "Comfortable on this Mac\(verdict.estimatedTokensPerSecond.map { " · ~\($0.rounded()) tok/s" } ?? "")",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.green).font(.callout)
            case let .tight(reduced):
                Label("Tight — runs at \(reduced)-token context on this Mac", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.yellow).font(.callout)
            case .wontFit:
                Label("Won't fit on this Mac", systemImage: "xmark.circle")
                    .foregroundStyle(.red).font(.callout)
            }
        }
    }

    private func startDownload() {
        guard let files = resolvedFiles, let repo = listing?.id else { return }
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
