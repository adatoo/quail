import SwiftUI

/// Says that the chosen runtime (llama.cpp) can't run MLX models, with a button to switch to Quail server;
/// shown above the Models list and in Add Model (ADR D-027 amendment of 2026-09-28).
struct MLXUnavailableBanner: View {
    let appState: AppState
    /// Overrides the shared note, e.g. for a model about to be downloaded.
    var message: String?

    var body: some View {
        if let note = message ?? appState.mlxUnavailableNote {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(note)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if RuntimeID.available.contains(.quail) {
                    Button("Use Quail Server") { appState.setRuntime(.quail) }
                        .controlSize(.small)
                        .disabled(!appState.canChangeRuntime)
                        .help(appState
                            .canChangeRuntime ? "Switch the runtime to Quail server" : "Stop the server to switch")
                }
            }
            .font(.callout)
        }
    }
}
