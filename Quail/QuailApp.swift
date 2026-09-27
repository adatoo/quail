import SwiftUI

@main
struct QuailApp: App {
    /// AppState lives on AppDelegate, not a @State here, so
    /// applicationShouldTerminate / the SIGTERM handler can reach it too —
    /// see AppDelegate.swift.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(appState: appDelegate.appState, updateSettings: appDelegate.updateSettings)
        } label: {
            // Always the same bird glyph; only the colour reflects
            // ServerController.phase — see AppState.menuBarIcon's doc
            // comment for why this has to be a colour-baked NSImage
            // rather than a plain Image(systemName:) with .foregroundStyle.
            // While the server is busy, a few words beside it (ADR D-060).
            MenuBarLabel(appState: appDelegate.appState)
        }
        // The default `.menu` style renders a real NSMenu — standard
        // full-width items, native hover highlighting, real separators.
        // An earlier `.window` style drew its own floating panel by hand,
        // which looked and behaved unlike every other menu bar app.

        Settings {
            SettingsView(appState: appDelegate.appState, updateSettings: appDelegate.updateSettings).opensInFront()
        }

        // Real windows, not `.sheet`s presented from the MenuBarExtra's
        // content — see PingSheet.swift's doc comment for why.
        Window("Ping", id: "ping") {
            PingSheet(appState: appDelegate.appState).opensInFront()
        }
        .defaultSize(width: 360, height: 220)
        .windowResizability(.contentSize)

        Window("Activity", id: "activity") {
            ActivityWindow(appState: appDelegate.appState).opensInFront()
        }
        .defaultSize(width: 340, height: 320)
        .windowResizability(.contentSize)

        Window("Logs", id: "logs") {
            LogsWindow(appState: appDelegate.appState).opensInFront()
        }
        .defaultSize(width: 640, height: 420)
    }
}
