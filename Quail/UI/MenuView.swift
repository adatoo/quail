import SwiftUI

/// The MenuBarExtra's dropdown content: status, Start/Stop, Test…, Logs…,
/// the Quail window's pages, Quit.
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
    /// `nil` where no updater runs (previews and tests).
    var updateSettings: UpdateSettings?

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
        // What it's doing, while it's doing something (ADR D-060).
        if appState.serverController.phase == .ready, let busy = appState.activity.busyLabel {
            Text(busy)
                .disabled(true)
        }

        // The router never rescans its models, and the address, key and models loaded at once are launch
        // flags: a download, a delete, a change in Finder or on the Server page only takes effect after a restart.
        if let reason = appState.restartReason {
            Text(reason)
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
                appState.addModelRequested = true
                openMain(.models)
            }
        } else if appState.canStart {
            Button("Start") {
                ServerActions.start(appState)
            }
        } else {
            Button("Stop") {
                Task { await appState.stop() }
            }
            .disabled(!appState.canStop)
        }

        Button("Test…") {
            bringToFront(id: "ping") { openWindow(id: "ping") }
        }
        .disabled(appState.serverController.phase != .ready)

        Button("Activity…") {
            bringToFront(id: "activity") { openWindow(id: "activity") }
        }

        Button("Benchmark…") {
            openMain(.benchmark)
        }

        Button("Connect a Tool…") {
            openMain(.connect)
        }

        // D-001: runtimes ship their own chat UIs — link to them. Quail server's page is signed in with a
        // one-time ticket (D-042); llama.cpp's needs the key pasted into its settings (the Server page has
        // a Copy button), since it reads nothing from the URL.
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
            bringToFront(id: "logs") { openWindow(id: "logs") }
        }

        Toggle(
            "Keep Mac Awake While Serving",
            isOn: Binding(get: { appState.config.keepAwake }, set: { appState.setKeepAwake($0) })
        )

        Divider()

        // The Quail window (ADR D-061), on whichever page it last showed (the Server page the first time).
        // It holds the settings too, so it keeps Settings' ⌘,.
        Button("Open Quail") {
            openMain(nil)
        }
        .keyboardShortcut(",")

        // The website's docs (ADR D-062), or the README until there is one.
        Button("Quail Help") {
            NSWorkspace.shared.open(Website.help(base: Website.base()))
        }

        if let updateSettings {
            switch updateSettings.status {
            case let .readyToInstall(version):
                if let installNow = updateSettings.installNow {
                    Button("Restart to Install Quail \(version)", action: installNow)
                }
            case let .downloading(version):
                Button("Downloading Quail \(version)…") {}.disabled(true)
            default:
                Button("Check for Updates…") { updateSettings.checkNow() }
                    .disabled(!updateSettings.canCheckNow)
            }
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

    /// Opens the Quail window at `page`, or at the page it last showed.
    private func openMain(_ page: MainPage?) {
        if let page {
            appState.mainPage = page
        }
        bringToFront(id: MainWindow.id) { openWindow(id: MainWindow.id) }
    }
}
