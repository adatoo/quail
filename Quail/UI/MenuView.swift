import SwiftUI

/// The MenuBarExtra's dropdown content.
///
/// Phase 1 will add status, current model, Start/Stop, Test… and Logs…
/// (docs/IMPLEMENTATION_PLAN.md, "Menu" step). This is the minimal shell
/// that proves the app launches as a menu-bar-only item.
struct MenuView: View {
    let appState: AppState

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.statusLabel)
                .font(.headline)

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
        .frame(minWidth: 200)
    }
}
