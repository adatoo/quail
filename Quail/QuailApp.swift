import SwiftUI

@main
struct QuailApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(appState: appState)
        } label: {
            // Reflects ServerController.phase — see AppState.statusSymbolName
            // and docs/IMPLEMENTATION_PLAN.md Phase 1 step 6.
            Image(systemName: appState.statusSymbolName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState)
        }
    }
}
