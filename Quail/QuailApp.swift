import SwiftUI

@main
struct QuailApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Quail", systemImage: "bird") {
            MenuView(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
