import SwiftUI

/// The MenuBarExtra's dropdown content: status, Start/Stop, Test…, Logs…,
/// Settings, Quit.
///
/// This is a plain, flat list of `Button`/`Divider`/`Text` — no `VStack`,
/// padding, or explicit frame. `MenuBarExtra`'s default `.menu` style
/// (see `QuailApp.swift`) turns top-level children like these directly
/// into real `NSMenuItem`s; wrapping them in a layout container instead
/// draws one custom `.window`-style panel by hand, which is what made the
/// old version of this menu look and behave unlike every other menu bar
/// app (non-standard hover/highlight, no real separators, non-full-width
/// rows).
struct MenuView: View {
    let appState: AppState

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(appState.statusLabel)
            .disabled(true)

        if case let .failed(reason) = appState.serverController.phase {
            Text(reason)
                .disabled(true)
        }

        // While running: what the server actually has loaded (polled —
        // see `AppState.servedModels`). Otherwise: what Start will load.
        if appState.hasServableModel {
            Text(appState.modelStatusLine)
                .disabled(true)
        }

        Divider()

        // `hasServableModel` reads the filesystem directly (deliberately
        // not cached — see its doc comment), which Swift's Observation
        // can't track on its own: nothing here would ever re-render on
        // a download completing without also reading some *stored*
        // `@Observable` property that changes at that moment. Reading
        // `installs.phase` (its value is unused) is that trigger — a
        // finished download moves it to `.installed`, which is exactly
        // when a freshly re-read `hasServableModel` needs to be seen.
        let _ = appState.installs.phase
        if !appState.hasServableModel {
            Text("No model installed")
                .disabled(true)
            Button("Start") {}
                .disabled(true)
            Button("Add model…") {
                appState.settingsTab = .models
                openSettings()
            }
        } else if appState.canStart {
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
}
