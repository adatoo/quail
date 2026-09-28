import AppKit

/// Starting the server from the UI — the menu or the Server page — so both give the one-time warning before it
/// first listens on the network. (`quail start` over the socket doesn't ask: the CLI user chose the host.)
@MainActor
enum ServerActions {
    static func start(_ appState: AppState) {
        if appState.needsNetworkWarning, !confirmNetworkStart(appState) {
            return
        }
        Task { await appState.start() }
    }

    /// The one-time warning before the server first listens on the network (Phase 4 step 3). Returns whether to
    /// go ahead: "Listen on This Mac Only" switches the host back to loopback and starts; Cancel doesn't start.
    static func confirmNetworkStart(_ appState: AppState) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Quail server will listen on your network"
        let host = appState.config.host
        alert.informativeText = appState.networkExposure == .open
            ? "The host is \(host), so other devices on your network can reach the server, and with the API key off, "
            + "anyone on it can use your models. Turn the key on in Quail → Server, or keep the server to this Mac."
            : "The host is \(host), so other devices on your network can reach the server. They need its API key "
            + "(Quail → Server) to use it."
        alert.alertStyle = appState.networkExposure == .open ? .critical : .warning
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Listen on This Mac Only")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            appState.acknowledgeNetworkWarning()
            return true
        case .alertSecondButtonReturn:
            appState.acknowledgeNetworkWarning()
            appState.setHost("127.0.0.1")
            return true
        default:
            return false
        }
    }
}
