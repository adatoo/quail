import SwiftUI

@main
struct QuailApp: App {
    /// AppState lives on AppDelegate, not a @State here, so
    /// applicationShouldTerminate / the SIGTERM handler can reach it too —
    /// see AppDelegate.swift.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Not in the menu bar while it only hosts unit tests: a second bird there was being quit mid-run, and a
        // model the tests had loaded then aborted the process as it exited.
        MenuBarExtra(isInserted: .constant(!AppDelegate.isHostingUnitTests)) {
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

        // The Quail window (ADR D-061): server, models, connect, benchmark, settings, about. Not opened at
        // launch: the MenuBarExtra comes first, and SwiftUI opens no `Window` of a menu bar app by itself.
        Window("Quail", id: MainWindow.id) {
            MainWindow(appState: appDelegate.appState, updateSettings: appDelegate.updateSettings)
                .opensInFront(id: MainWindow.id)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenMainWindowCommand()
            }
        }

        // Real windows, not `.sheet`s presented from the MenuBarExtra's
        // content — see PingSheet.swift's doc comment for why.
        Window("Ping", id: "ping") {
            PingSheet(appState: appDelegate.appState).opensInFront(id: "ping")
        }
        .defaultSize(width: 360, height: 220)
        .windowResizability(.contentSize)

        Window("Activity", id: "activity") {
            ActivityWindow(appState: appDelegate.appState).opensInFront(id: "activity")
        }
        .defaultSize(width: 340, height: 320)
        .windowResizability(.contentSize)

        Window("Logs", id: "logs") {
            LogsWindow(appState: appDelegate.appState).opensInFront(id: "logs")
        }
        .defaultSize(width: 640, height: 420)
    }
}
