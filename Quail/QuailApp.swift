import SwiftUI

@main
struct QuailApp: App {
    /// AppState lives on AppDelegate, not a @State here, so
    /// applicationShouldTerminate / the SIGTERM handler can reach it too —
    /// see AppDelegate.swift.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(appState: appDelegate.appState)
        } label: {
            // Reflects ServerController.phase — see AppState.statusSymbolName
            // and docs/IMPLEMENTATION_PLAN.md Phase 1 step 6.
            Image(systemName: appDelegate.appState.statusSymbolName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appDelegate.appState)
        }

        // Real windows, not `.sheet`s presented from the MenuBarExtra's
        // content — see PingSheet.swift's doc comment for why.
        Window("Ping", id: "ping") {
            PingSheet(appState: appDelegate.appState)
        }
        .defaultSize(width: 360, height: 220)
        .windowResizability(.contentSize)

        Window("Logs", id: "logs") {
            LogsWindow(appState: appDelegate.appState)
        }
        .defaultSize(width: 640, height: 420)
    }
}
