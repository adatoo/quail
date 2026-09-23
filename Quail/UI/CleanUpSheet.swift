import SwiftUI

/// Lists what's in the store but used by no model — projectors whose model
/// is gone, and abandoned partial downloads — and moves the chosen ones to
/// the Trash (recoverable, unlike an in-place delete). Nothing here is
/// removed without the user choosing it.
struct CleanUpSheet: View {
    let appState: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var leftovers: [StoreLeftover]?
    @State private var selected: Set<String> = []
    @State private var failures: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clean Up Store").font(.title3.bold())
            Text("Files in the model store that no installed model uses.")
                .foregroundStyle(.secondary)

            if let leftovers {
                if leftovers.isEmpty {
                    Label("Nothing to clean up.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List(leftovers) { item in
                        Toggle(isOn: binding(for: item)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1).truncationMode(.middle)
                                Text(description(of: item)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(minHeight: 180)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }

            ForEach(failures, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }

            HStack {
                Text(selectedTotal)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") { Task { await trashSelected() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load() }
    }

    private func binding(for item: StoreLeftover) -> Binding<Bool> {
        Binding(
            get: { selected.contains(item.id) },
            set: { isOn in
                if isOn {
                    selected.insert(item.id)
                } else {
                    selected.remove(item.id)
                }
            }
        )
    }

    private func description(of item: StoreLeftover) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        switch item.kind {
        case .unlinkedProjector: return "\(size) · vision projector not linked to any installed model"
        case .partialDownload: return "\(size) · unfinished download (resumes if you download it again)"
        }
    }

    private var selectedTotal: String {
        let bytes = (leftovers ?? []).filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
        return bytes > 0 ? "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) selected" : ""
    }

    private func load() async {
        let store = appState.modelStore
        let active = appState.installs.isDownloading ? appState.installs.target?.repo : nil
        let found = await Task.detached(priority: .utility) { store.leftovers(activeRepo: active) }.value
        leftovers = found
        selected = Set(found.map(\.id))
    }

    private func trashSelected() async {
        failures = []
        for item in leftovers ?? [] where selected.contains(item.id) {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            } catch {
                failures.append("Couldn't move \(item.title) to the Trash: \(error.localizedDescription)")
            }
        }
        await appState.reconcileStore()
        await load()
    }
}
