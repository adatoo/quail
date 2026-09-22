import SwiftUI

/// The MenuBarExtra's dropdown content: status, Start/Stop, Test…, Logs…,
/// Settings, Quit.
struct MenuView: View {
    let appState: AppState

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

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

            Button("Test…") {
                openWindow(id: "ping")
            }
            .disabled(appState.serverController.phase != .ready)

            Button("Logs…") {
                openWindow(id: "logs")
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
