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
    /// `nil` in the App Store build, which has no in-app updater.
    var updateSettings: UpdateSettings?

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

        // The router never rescans its models; a download, a delete, or a
        // change in Finder since Start only takes effect after a restart.
        if appState.serverController.phase == .ready, appState.modelsChangedSinceStart {
            Text("Models changed — restart to apply")
                .disabled(true)
            Button("Restart Server") {
                Task { await appState.restart() }
            }
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
        let _ = appState.storeRevision // likewise for Finder changes (StoreWatcher → reconcileStore)
        if !appState.hasServableModel {
            Text("No model installed")
                .disabled(true)
            Button("Start") {}
                .disabled(true)
            Button("Add model…") {
                appState.settingsTab = .models
                bringToFront { openSettings() }
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
            bringToFront { openWindow(id: "ping") }
        }
        .disabled(appState.serverController.phase != .ready)

        Button("Benchmark…") {
            appState.settingsTab = .benchmark
            bringToFront { openSettings() }
        }

        Button("Connect a Tool…") {
            appState.settingsTab = .connect
            bringToFront { openSettings() }
        }

        // D-001: runtimes ship their own chat UIs — link to them. Quail server's page is signed in with a
        // one-time ticket (D-042); llama.cpp's needs the key pasted into its settings (Settings → Endpoint
        // has a Copy button), since it reads nothing from the URL.
        // A runtime with no web UI of its own (Rapid-MLX) gets `quail chat`
        // instead: the same item, copying the command to the clipboard.
        let chat = chatEntry
        Button(chat.menuTitle) {
            switch chat {
            case let .browser(url):
                let runtime = appState.runtime, key = appState.serverController.apiKey
                Task {
                    let signedIn = await runtime.chatURL(base: url, apiKey: key) ?? url
                    NSWorkspace.shared.open(signedIn)
                }
            case let .terminal(command):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
        .disabled(appState.serverController.phase != .ready)

        Button("Logs…") {
            bringToFront { openWindow(id: "logs") }
        }

        Divider()

        Button("Settings…") {
            bringToFront { openSettings() }
        }
        .keyboardShortcut(",")

        if let updateSettings {
            Button("Check for Updates…") { updateSettings.checkNow() }
        }

        Divider()

        Button("Quit Quail") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// The address the server was launched on (not live Settings, which
    /// can differ until a restart), made browsable, when the runtime has a
    /// web UI there; otherwise the terminal hand-off for the default (or
    /// first loaded) model.
    private var chatEntry: ChatEntry {
        var webUI: URL?
        if let launched = appState.serverController.baseURL, let host = launched.host(), let port = launched.port,
           let base = EndpointAddress.localBase(host: host, port: port)
        {
            webUI = appState.runtime.webUIURL(base: base)
        }
        let loaded = appState.servedModels.first { $0.status.value == "loaded" }?.id
        return ChatEntry.resolve(webUI: webUI, model: appState.config.defaultModelID ?? loaded)
    }

    /// Opens a window *in front*. Quail is a menu-bar-only app
    /// (`LSUIElement`); on macOS 14+ `NSApp.activate()` is only a request
    /// the frontmost app may decline, so Settings/Logs/Test used to open
    /// behind other apps or on another Space (user-reported; confirmed via
    /// the window server — the Settings window existed but wasn't
    /// onscreen, because the frontmost app was full-screen on its own
    /// Space). After opening, each visible Quail window is allowed onto
    /// the current (possibly full-screen) Space and ordered front
    /// regardless of activation, and the newest is made key.
    private func bringToFront(_ open: () -> Void) {
        let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        NSApp.activate()
        open()
        // SwiftUI shows the window a few run-loop turns later, so poll
        // briefly for it rather than acting on the very next turn.
        Task { @MainActor in
            for _ in 0 ..< 20 {
                let visible = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey && $0.level == .normal }
                let opened = visible.filter { !before.contains(ObjectIdentifier($0)) }
                if let target = opened.last ?? (visible.isEmpty ? nil : visible.last) {
                    for window in visible {
                        // .fullScreenAuxiliary: may appear on a full-screen
                        // app's Space — otherwise, with e.g. a full-screen
                        // terminal in front, the window opens on the desktop
                        // Space and seems to vanish (the user-reported case).
                        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
                    }
                    target.orderFrontRegardless()
                    target.makeKey()
                    NSApp.activate()
                    if !opened.isEmpty {
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
