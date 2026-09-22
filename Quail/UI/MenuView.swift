import SwiftUI

/// The MenuBarExtra's dropdown content: status, Start/Stop, Settings, Quit.
///
/// "Test…" and "Logs…" (docs/IMPLEMENTATION_PLAN.md Phase 1 steps 8–9) land
/// in the next PR alongside the ping sheet and log window they open.
struct MenuView: View {
    let appState: AppState

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(appState.statusLabel, systemImage: appState.statusSymbolName)
                .font(.headline)

            if case let .failed(reason) = appState.serverController.phase {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if appState.canStart {
                Button("Start") {
                    Task { await appState.start() }
                }
            } else {
                Button("Stop") {
                    Task { await appState.stop() }
                }
                .disabled(!appState.canStop)
            }

            Divider()

            Button("Settings…") {
                openSettings()
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit Quail") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(minWidth: 220)
    }
}
