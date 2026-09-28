import SwiftUI

/// One installed model's settings, in a popover from its row on the Models page (ADR D-061): its id to copy,
/// its context size (ADR D-020) and KV cache (ADR D-057), each option labelled with how it fits on this Mac, and
/// whether it loads when the server starts (ADR D-017). They used to hide in a small "ctx" menu and a star.
struct ModelSettingsView: View {
    let entry: InstalledModel
    /// Whether the chosen runtime can serve this model's format; only then can it load on Start or be benchmarked.
    let servable: Bool
    let isDefault: Bool
    let contextChoices: [ContextChoice]
    let kvCacheChoices: [KVCacheChoice]
    let onSetContext: (Int?) -> Void
    let onSetKVCache: (KVCacheSetting) -> Void
    let onToggleDefault: () -> Void
    let onBenchmark: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.id)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    CopyButton(text: entry.id)
                        .controlSize(.small)
                }
                Text("Send this as \"model\" in a request to use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Context size")
                    Spacer()
                    contextMenu
                }
                caption("How much text it can work with at once. Coding agents need 32K or more.")
            }
            if !kvCacheChoices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("KV cache")
                        Spacer()
                        kvCacheMenu
                    }
                    caption(
                        "8-bit or 4-bit holds a longer context in the same memory, a little less accurately"
                            + (entry.format == .mlxSafetensors ? ", and reads prompts more slowly." : ".")
                    )
                }
            }

            if servable {
                Toggle(
                    "Load when the server starts",
                    isOn: Binding(get: { isDefault }, set: { _ in onToggleDefault() })
                )
                .help("The default model (the star on its row). One model is the default at a time.")
            }

            caption("Changes apply the next time the server starts.")

            Divider()

            HStack {
                if servable {
                    Button("Benchmark…", action: onBenchmark)
                }
                Spacer()
                Button("Delete…", role: .destructive, action: onDelete)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Automatic, or a fixed size — each labelled with its fit on this Mac; sizes that won't fit can't be chosen.
    private var contextMenu: some View {
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
        } label: {
            Text(
                entry.userContextSize == nil
                    ? "Automatic (\(RemoteFitBadge.contextLabel(entry.effectiveContextSize)))"
                    : RemoteFitBadge.contextLabel(entry.effectiveContextSize)
            )
            .monospacedDigit()
        }
        .fixedSize()
    }

    private var kvCacheMenu: some View {
        Menu {
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
        } label: {
            Text(entry.effectiveKVCache.label)
        }
        .fixedSize()
    }
}
