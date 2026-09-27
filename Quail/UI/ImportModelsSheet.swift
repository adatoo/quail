import SwiftUI

/// The Models pane's one-time offer (Phase 4 step 2, ADR D-059): models other apps downloaded, ready to move in.
struct ImportOfferBanner: View {
    let appState: AppState
    let review: () -> Void

    var body: some View {
        let candidates = appState.importCandidates
        let bytes = candidates.reduce(0) { $0 + $1.bytes }
        let sources = ImportCandidate.Source.allCases.filter { source in candidates.contains { $0.source == source } }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(.tint)
            Text(
                "Found \(candidates.count) model\(candidates.count == 1 ? "" : "s") "
                    + "(\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) in "
                    + "\(ListFormatter.localizedString(byJoining: sources.map(\.rawValue))). Move them into Quail?"
            )
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Not Now") { appState.declineImport() }
                .controlSize(.small)
            Button("Review…", action: review)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .font(.callout)
    }
}

/// Lists the models found in other apps' folders, each with a checkbox, and moves the chosen ones into the store.
struct ImportModelsSheet: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var scanned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Models from Other Apps")
                .font(.headline)
            Text(
                "Models downloaded by llama.cpp, LM Studio, the Hugging Face cache or oMLX can move into Quail's "
                    + "models folder. They're moved, not copied, so they no longer appear in the other app."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !scanned {
                ProgressView("Looking…").frame(maxWidth: .infinity, minHeight: 160)
            } else if appState.importCandidates.isEmpty {
                Text("No models found in those folders.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(appState.importCandidates) { candidate in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(candidate.id) },
                        set: { on in
                            if on {
                                chosen.insert(candidate.id)
                            } else {
                                chosen.remove(candidate.id)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.id).lineLimit(1).truncationMode(.middle)
                            Text(
                                "\(candidate.format == .gguf ? "GGUF" : "MLX") · "
                                    + "\(ByteCountFormatter.string(fromByteCount: candidate.bytes, countStyle: .file)) · "
                                    + candidate.source.rawValue
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .help(candidate.location.path)
                }
                .frame(minHeight: 200)
            }

            if let progress = appState.importProgress {
                ProgressView(value: Double(progress.moved), total: Double(max(progress.total, 1))) {
                    Text("Moving…")
                }
            }
            ForEach(appState.importErrors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(appState.importProgress != nil)
                Button(chosen.isEmpty ? "Move" : "Move \(chosen.count) Model\(chosen.count == 1 ? "" : "s")") {
                    Task {
                        await appState.importModels(chosen)
                        if appState.importErrors.isEmpty {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || appState.importProgress != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            await appState.scanForImports()
            chosen = Set(appState.importCandidates.map(\.id))
            scanned = true
        }
    }
}
